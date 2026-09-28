package com.uten.imp.businesschain;

import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.features.production.analysis.AggregateMaterialOrderContracts.BatchResult;
import com.uten.imp.features.production.analysis.AggregateMaterialOrderWriteService;
import com.uten.imp.features.production.analysis.MaterialAnalysisCommandService;
import com.uten.imp.features.production.analysis.MaterialAnalysisContracts.*;
import com.uten.imp.features.production.analysis.MaterialAnalysisService;
import com.uten.imp.features.production.analysis.PreplanMakePublicSupplyService;
import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.annotation.DirtiesContext;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.support.TransactionTemplate;
import org.testcontainers.containers.PostgreSQLContainer;

import java.math.BigDecimal;
import java.util.*;

import static org.junit.jupiter.api.Assertions.*;

/** The installed pre-V732 view is the independent quantity oracle. Real unrelated
 * sources plus rejecting probes prove evaluation scope without a timing threshold. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
@DirtiesContext(classMode = DirtiesContext.ClassMode.AFTER_CLASS)
@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.MOCK, properties = {
        "spring.profiles.active=dev", "uten.audit.retention.enabled=false", "uten.reporting.materialized-view-refresh.enabled=false",
        "uten.production.readiness-reconcile.enabled=false", "uten.features.goods-owner-scope-enabled=false",
        "uten.storage.uploads-enabled=true", "uten.storage.malware-scan.provider=test-only",
        "uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only",
        "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789",
        "uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only", "uten.bootstrap.admin-login=full-chain-bootstrap-admin-test",
        "uten.bootstrap.admin-password=HarnessAdminPass-1!"})
class ScopedMakePublicSupplyReaderPostgresTest {
    private static final PostgreSQLContainer<?> DATABASE = new PostgreSQLContainer<>("postgres:16-alpine")
            .withDatabaseName("scoped_make_public_sources").withUsername("uten").withPassword("uten");
    private static String legacyDefinition;
    private static List<Map<String, Object>> legacyColumns;
    private static final String COLUMN_QUERY = "SELECT attname,format_type(atttypid,atttypmod) type FROM pg_attribute "
            + "WHERE attrelid='v_preplan_make_public_supply_state'::regclass AND attnum>0 AND NOT attisdropped ORDER BY attnum";

    @DynamicPropertySource
    static void database(DynamicPropertyRegistry registry) {
        DATABASE.start();
        Flyway.configure().dataSource(DATABASE.getJdbcUrl(), DATABASE.getUsername(), DATABASE.getPassword())
                .locations("classpath:db/migration").target("731").load().migrate();
        var before = new JdbcTemplate(new DriverManagerDataSource(DATABASE.getJdbcUrl(), DATABASE.getUsername(), DATABASE.getPassword()));
        legacyDefinition = before.queryForObject("SELECT pg_get_viewdef('v_preplan_make_public_supply_state'::regclass,true)", String.class)
                .strip().replaceFirst(";$", "");
        legacyColumns = before.queryForList(COLUMN_QUERY);
        registry.add("spring.datasource.url", DATABASE::getJdbcUrl);
        registry.add("spring.datasource.username", DATABASE::getUsername);
        registry.add("spring.datasource.password", DATABASE::getPassword);
        registry.add("uten.storage.local-dir", () -> System.getProperty("java.io.tmpdir") + "/scoped-make-reader-" + DATABASE.getContainerId());
    }

    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    @Autowired MaterialAnalysisService analyses;
    @Autowired MaterialAnalysisCommandService commands;
    @Autowired AggregateMaterialOrderWriteService writer;
    @Autowired PlatformTransactionManager transactions;
    AggregateMaterialOrderEndToEndTest support;

    @BeforeEach
    void prepare() {
        support = new AggregateMaterialOrderEndToEndTest();
        beans.autowireBean(support);
        support.before();
    }

    @AfterEach
    void clear() { SecurityContextHolder.clearContext(); }

    @Test
    void allFifteenColumnsAndTypesMatchAcrossClaimsCancellationReceiptAndReversal() {
        assertEquals(15, legacyColumns.size());
        assertEquals(legacyColumns, db.queryForList(COLUMN_QUERY));
        Supply supply = create();
        assertExact(supply);
        UUID claim = claim(supply, "2");
        assertExact(supply);
        var target = analyses.detail(supply.target().analysisId());
        commands.cancelMakePublicClaim(target.analysisId(), claim,
                new PreplanMakePublicSupplyService.CancelRequest(target.version(), target.fingerprint(),
                        "scope-cancel-" + UUID.randomUUID(), BigDecimal.ONE, "撤回尚未入库的公共份"));
        assertExact(supply);
        produce(supply);
        assertExact(supply);
        amount("2", db.queryForObject("SELECT received_public_qty FROM fn_preplan_make_public_supply_sources(NULL,?)", BigDecimal.class, supply.item()));
        amount("1", db.queryForObject("SELECT fn_preplan_make_public_claim_received_qty(?)", BigDecimal.class, claim));
        new TransactionTemplate(transactions).executeWithoutResult(status -> {
            db.update("UPDATE production_plans SET is_stopped=TRUE WHERE id=?", supply.batch().planId());
            assertExact(supply);
            status.setRollbackOnly();
        });
        InventoryValueWorkTestSupport.drain(beans.getBean(com.uten.imp.features.stock.valuation.InventoryValueWorkService.class),
                db, List.of(supply.c().common(), supply.c().material()));
        // Reporting can produce multiple physical inbound documents. Reverse in
        // actual value-ledger order; the helper's first document is not the latest receipt.
        List<UUID> receipts = db.queryForList("""
                SELECT document.id FROM stock_documents document
                JOIN stock_document_items item ON item.doc_id=document.id
                JOIN stock_movements movement ON movement.source_doc_id=document.id AND movement.source_item_id=item.id
                  AND movement.direction=1
                JOIN stock_value_events event ON event.movement_id=movement.id AND event.operation='RECEIVE'
                JOIN stock_value_nodes head ON head.id=event.result_head_id
                WHERE item.upstream_item_id=? AND document.doc_type='FINISHED_IN' AND document.status=1
                  AND NOT document.is_deleted AND NOT item.is_deleted
                GROUP BY document.id ORDER BY max(head.node_sequence) DESC
                """, UUID.class, supply.item());
        assertFalse(receipts.isEmpty());
        for (UUID receipt : receipts) {
            beans.getBean(com.uten.imp.features.stock.StockDocService.class).reverseFinishedInbound(receipt);
            assertExact(supply);
        }
        amount("0", db.queryForObject("SELECT received_public_qty FROM fn_preplan_make_public_supply_sources(NULL,?)", BigDecimal.class, supply.item()));
        amount("1", db.queryForObject("SELECT fn_preplan_make_public_claim_pending_qty(?)", BigDecimal.class, claim));
        amount("0", db.queryForObject("SELECT sum(qty) FROM stock_balances WHERE goods_id=?", BigDecimal.class, supply.c().common()));
        assertEquals(allRows("(" + legacyDefinition + ")"), allRows("v_preplan_make_public_supply_state"));
        assertEquals(allRows("(" + legacyDefinition + ")"), allRows("fn_preplan_make_public_supply_sources(NULL,NULL)"));
    }

    @Test
    void scopeRetainsSameMainAndExactGoodsColorUnitAndActiveMaterialBoundaries() {
        Supply supply = create(), other = create();
        UUID analysis = supply.target().analysisId(), material = targetMaterial(supply);
        assertEquals(1, count(analysis));
        assertExact(supply);
        var transaction = new TransactionTemplate(transactions);
        transaction.executeWithoutResult(status -> {
            db.update("UPDATE production_material_analysis_materials SET color_id=? WHERE id=?", supply.c().world().colorId(), material);
            assertEquals(0, count(analysis)); assertScopedExact(analysis); status.setRollbackOnly();
        });
        transaction.executeWithoutResult(status -> {
            db.update("UPDATE production_material_analysis_materials SET unit_id=? WHERE id=?", other.c().world().unitId(), material);
            assertEquals(0, count(analysis)); assertScopedExact(analysis); status.setRollbackOnly();
        });
        transaction.executeWithoutResult(status -> {
            db.update("UPDATE production_material_analysis_materials SET active=FALSE WHERE id=?", material);
            assertEquals(0, count(analysis)); assertScopedExact(analysis); status.setRollbackOnly();
        });
        transaction.executeWithoutResult(status -> {
            db.update("UPDATE production_material_analysis_materials SET goods_id=? WHERE id=?", other.c().common(), material);
            assertEquals(0, count(analysis)); assertScopedExact(analysis); status.setRollbackOnly();
        });
        transaction.executeWithoutResult(status -> {
            UUID warehouse = other.c().world().warehouseId();
            db.update("UPDATE production_material_analyses SET warehouse_id=?,participating_warehouse_ids=ARRAY[?]::uuid[] WHERE id=?", warehouse, warehouse, analysis);
            assertEquals(0, count(analysis)); assertScopedExact(analysis); status.setRollbackOnly();
        });
        UUID leaf = UUID.randomUUID();
        db.update("INSERT INTO warehouses(id,code,name,parent_id,status,is_accountable) VALUES(?,?,?,?,'使用',TRUE)",
                leaf, "MAKE-SCOPE-" + leaf, "同主仓子仓", supply.c().world().warehouseId());
        transaction.executeWithoutResult(status -> {
            db.update("UPDATE production_material_analyses SET warehouse_id=?,participating_warehouse_ids=ARRAY[?]::uuid[] WHERE id=?", leaf, leaf, analysis);
            assertEquals(1, count(analysis)); assertScopedExact(analysis); status.setRollbackOnly();
        });
        assertEquals(0, count(UUID.randomUUID()));
        assertEquals("[]", scopedRows(other.target().analysisId(), supply.item()));
        assertEquals("[]", scopedRows(analysis, UUID.randomUUID()));
        // Scope selects dimensions; the existing identity guard still decides self-adoption.
        assertScopedExact(supply.c().analysis());
        assertEquals(1, db.queryForObject("SELECT count(*) FROM fn_preplan_make_public_supply_sources(?,?)", Integer.class, supply.c().analysis(), supply.item()));
    }

    @Test
    void unrelatedActualReceiptsAndClaimsAreNeverEvaluatedByAnalysisOrPointReaders() {
        Supply target = create();
        claim(target, "1");
        produce(target);
        Supply unrelated = create();
        claim(unrelated, "1");
        produce(unrelated);
        Supply pending = create();
        claim(pending, "1");
        String expected = legacyScopedRows(target.target().analysisId());
        String pointExpected = legacyPointRows(target.item());
        // The old analysis join provably evaluates unrelated sources. PostgreSQL
        // can already push a literal point key below aggregation in this fixture;
        // keep that plan as evidence, not an assumed failing negative control.
        System.out.println("LEGACY-MAKE-POINT-PLAN\n" + String.join("\n", db.queryForList(
                "EXPLAIN (COSTS FALSE) SELECT * FROM (" + legacyDefinition + ") source WHERE source_plan_item_id=?",
                String.class, target.item())));
        assertTrue(db.queryForObject("SELECT count(*) FROM v_preplan_make_public_supply_state", Integer.class) >= 3);
        Set<UUID> stockItems = new HashSet<>(db.queryForList("SELECT id FROM stock_document_items WHERE upstream_item_id=? AND bill_type='FINISHED_IN'", UUID.class, target.item()));
        Set<UUID> reports = new HashSet<>(db.queryForList("SELECT id FROM production_daily_report_items WHERE plan_item_id=?", UUID.class, target.item()));
        assertFalse(stockItems.isEmpty()); assertFalse(reports.isEmpty());
        Map<String, String> originals = new LinkedHashMap<>();
        try {
            installProbe("fn_finished_in_is_public_output", "boolean", stockItems, originals);
            installProbe("fn_daily_report_is_public_output", "boolean", reports, originals);
            assertEquals(expected, scopedRows(target.target().analysisId(), null));
            assertEquals(pointExpected, scopedRows(null, target.item()));
            assertEquals(pointExpected, scopedRows(target.target().analysisId(), target.item()));
            assertProbeRejects(() -> legacyScopedRows(target.target().analysisId()));
        } finally {
            originals.values().forEach(db::execute);
        }
        Set<UUID> claims = new HashSet<>(db.queryForList("SELECT id FROM preplan_make_public_claims WHERE source_plan_item_id=?", UUID.class, target.item()));
        assertFalse(claims.isEmpty());
        originals.clear();
        try {
            installProbe("fn_preplan_make_public_claim_cancelled_qty", "numeric", claims, originals);
            installProbe("fn_preplan_make_public_claim_received_qty", "numeric", claims, originals);
            assertEquals(expected, scopedRows(target.target().analysisId(), null));
            assertEquals(pointExpected, scopedRows(null, target.item()));
            assertProbeRejects(() -> legacyScopedRows(target.target().analysisId()));
        } finally {
            originals.values().forEach(db::execute);
        }
    }

    private void installProbe(String name, String resultType, Set<UUID> allowed, Map<String, String> originals) {
        String definition = db.queryForObject("SELECT pg_get_functiondef(CAST(? AS regprocedure))", String.class, name + "(uuid)");
        originals.put(name, definition);
        String saved = name + "_make_scope_original";
        db.execute(definition.replace("FUNCTION public." + name + "(", "FUNCTION public." + saved + "("));
        String parameters = db.queryForObject("SELECT pg_get_function_arguments(CAST(? AS regprocedure))", String.class, name + "(uuid)");
        String ids = String.join(",", allowed.stream().map(id -> "'" + id + "'::uuid").toList());
        db.execute("CREATE OR REPLACE FUNCTION " + name + "(" + parameters + ") RETURNS " + resultType + " LANGUAGE plpgsql STABLE AS $probe$ BEGIN "
                + "IF $1 IS NOT NULL AND $1 NOT IN(" + ids + ") THEN RAISE EXCEPTION 'UNRELATED_MAKE_SOURCE_EVALUATED: %',$1; END IF; "
                + "RETURN " + saved + "($1); END $probe$");
    }

    private void assertProbeRejects(org.junit.jupiter.api.function.Executable read) {
        RuntimeException failure = assertThrows(RuntimeException.class, read);
        assertTrue(failure.toString().contains("UNRELATED_MAKE_SOURCE_EVALUATED"), failure.toString());
    }

    private Supply create() {
        var c = support.create(true, true, "1");
        var batch = writer.submit(c.analysis(), support.command(c, List.of(support.input(c, c.common(), "MAKE", "5", true)))).batches().getFirst();
        UUID item = db.queryForObject("SELECT id FROM production_plan_items WHERE plan_id=?", UUID.class, batch.planId());
        UUID root = UUID.randomUUID();
        support.fixture.insertGoods(root, "SCOPE-MAKE-" + root, "公共制造供给范围目标", "自制", c.world().unitId(), c.world().unitLegacy());
        support.fixture.insertBom(root, c.common(), "1");
        var target = analyses.preview(new PreviewRequest(null, null, null, c.world().warehouseId(), "scope-target-" + root,
                List.of(new PreviewItem("OTHER", null, root, null, c.world().unitId(), "scope-root-" + root,
                        "采用公共制造供给", BusinessTime.today().plusDays(10), new BigDecimal("2")))));
        target = analyses.saveRoutes(target.analysisId(), new RouteRequest(target.version(), target.fingerprint(), "scope-route-" + root,
                target.flatMaterials().stream().map(row -> new RouteDecision(row.materialLineId(), row.actionGroupKey(),
                        row.goodsId().equals(c.material()) ? "BUY" : "MAKE", null)).toList()));
        return new Supply(c, batch, item, target);
    }

    private UUID claim(Supply supply, String qty) {
        support.fixture.loginAs(supply.c().world().superAdminUserId());
        var target = analyses.detail(supply.target().analysisId());
        commands.claimMakePublicSupply(target.analysisId(), new PreplanMakePublicSupplyService.ClaimRequest(target.version(),
                target.fingerprint(), "scope-claim-" + UUID.randomUUID(), supply.item(), targetMaterial(supply), new BigDecimal(qty)));
        return db.queryForObject("SELECT id FROM preplan_make_public_claims WHERE source_plan_item_id=? AND target_analysis_id=?", UUID.class, supply.item(), target.analysisId());
    }

    private UUID produce(Supply supply) {
        support.fixture.loginAs(supply.c().world().superAdminUserId());
        return support.produce(supply.c(), supply.batch());
    }

    private UUID targetMaterial(Supply supply) {
        return supply.target().flatMaterials().stream().filter(row -> row.goodsId().equals(supply.c().common())).findFirst().orElseThrow().materialLineId();
    }

    private void assertExact(Supply supply) {
        assertScopedExact(supply.target().analysisId());
        assertEquals(legacyPointRows(supply.item()), scopedRows(null, supply.item()));
        assertEquals(legacyPointRows(supply.item()), scopedRows(supply.target().analysisId(), supply.item()));
    }

    private void assertScopedExact(UUID analysis) { assertEquals(legacyScopedRows(analysis), scopedRows(analysis, null)); }
    private int count(UUID analysis) { return db.queryForObject("SELECT count(*) FROM fn_preplan_make_public_supply_sources(?,NULL)", Integer.class, analysis); }
    private String scopedRows(UUID analysis, UUID item) {
        return db.queryForObject("SELECT COALESCE(jsonb_agg(to_jsonb(source) ORDER BY source_plan_item_id),'[]'::jsonb)::text FROM fn_preplan_make_public_supply_sources(?,?) source", String.class, analysis, item);
    }
    private String legacyScopedRows(UUID analysis) {
        return db.queryForObject("""
                SELECT COALESCE(jsonb_agg(to_jsonb(source) ORDER BY source_plan_item_id),'[]'::jsonb)::text
                FROM (%s) source WHERE EXISTS(SELECT 1 FROM production_material_analyses target
                  JOIN production_material_analysis_materials material ON material.analysis_id=target.id AND material.active
                  WHERE target.id=? AND NOT target.is_deleted AND fn_warehouse_same_main(target.warehouse_id,source.warehouse_id)
                    AND material.goods_id=source.goods_id AND material.color_id IS NOT DISTINCT FROM source.color_id AND material.unit_id=source.unit_id)
                """.formatted(legacyDefinition), String.class, analysis);
    }
    private String legacyPointRows(UUID item) {
        return db.queryForObject("SELECT COALESCE(jsonb_agg(to_jsonb(source) ORDER BY source_plan_item_id),'[]'::jsonb)::text FROM ("
                + legacyDefinition + ") source WHERE source_plan_item_id=?", String.class, item);
    }
    private String allRows(String source) {
        return db.queryForObject("SELECT COALESCE(jsonb_agg(to_jsonb(source) ORDER BY source_plan_item_id),'[]'::jsonb)::text FROM " + source + " source", String.class);
    }
    private static void amount(String expected, BigDecimal actual) { assertEquals(0, new BigDecimal(expected).compareTo(actual)); }
    private record Supply(AggregateMaterialOrderEndToEndTest.Case c, BatchResult batch, UUID item, AnalysisView target) { }
}
