package com.uten.imp.businesschain;

import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.features.production.analysis.MaterialAnalysisService;
import com.uten.imp.features.subcontract.application.SubcontractApplicationService;
import com.uten.imp.features.subcontract.application.dto.ApplicationItemLine;
import com.uten.imp.features.subcontract.application.dto.ApplicationSaveRequest;
import com.uten.imp.features.subcontract.receipt.SubcontractReceiptService;
import com.uten.imp.features.subcontract.receipt.dto.ReceiptItemLine;
import com.uten.imp.features.subcontract.receipt.dto.ReceiptSaveRequest;
import com.uten.imp.features.warehouse.inbound.ProcurementInspectionService;
import com.uten.imp.features.warehouse.inbound.ProcurementIqcStockInContracts;
import com.uten.imp.features.warehouse.inbound.ProcurementIqcStockInService;
import com.uten.imp.features.warehouse.inbound.dto.InspectionDispositionRequest;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.util.ReflectionTestUtils;

import javax.sql.DataSource;
import java.math.BigDecimal;
import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.Statement;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertTrue;

/** Real canonical provenance proofs must see only the command's physical candidates. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.MOCK, properties = {
        "spring.profiles.active=dev", "uten.audit.retention.enabled=false",
        "uten.reporting.materialized-view-refresh.enabled=false",
        "uten.production.readiness-reconcile.enabled=false",
        "uten.features.goods-owner-scope-enabled=false", "uten.storage.uploads-enabled=true",
        "uten.storage.malware-scan.provider=test-only",
        "uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only",
        "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789",
        "uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only",
        "uten.bootstrap.admin-login=full-chain-bootstrap-admin-test",
        "uten.bootstrap.admin-password=HarnessAdminPass-1!"})
class MaterialAnalysisNativeCandidatePostgresTest {
    @DynamicPropertySource
    static void database(DynamicPropertyRegistry registry) {
        FullChainEndToEndTest.registerDataSource(registry);
    }

    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    @Autowired DataSource dataSource;
    @Autowired SubcontractApplicationService applications;
    @Autowired SubcontractReceiptService receipts;
    @Autowired ProcurementInspectionService inspections;
    @Autowired ProcurementIqcStockInService stockIn;
    private AggregateMaterialOrderEndToEndTest h;

    @BeforeEach
    void prepare() {
        h = new AggregateMaterialOrderEndToEndTest();
        beans.autowireBean(h);
        h.before();
    }

    @AfterEach
    void finish() {
        if (h != null) h.after();
    }

    @Test
    void unrelatedApprovedOrdersAndStockedReceiptsDoNotExpandNativeProofCandidates() throws Exception {
        var c = h.createWithChild("1");
        var world = c.world();
        h.fixture.ensureSubcontractDirectMaterial(world, c.common());
        h.setRoute(c, c.common(), "SUBCONTRACT");
        var batch = h.writer.submit(c.analysis(), h.command(c,
                List.of(h.input(c, c.common(), "SUBCONTRACT", "3", false)))).batches().getFirst();
        UUID action = db.queryForObject("SELECT action_id FROM preplan_aggregate_batches WHERE id=?",
                UUID.class, batch.batchId());
        UUID targetItem = db.queryForObject("""
                SELECT id FROM subcontract_application_items
                WHERE application_id=? AND NOT is_deleted
                """, UUID.class, batch.documentId());
        assertNotNull(action);
        assertNotNull(targetItem);
        assertFalse(imported("subcontract_applications", batch.documentId()));
        assertFalse(imported("subcontract_application_items", targetItem));
        assertEquals(3L, db.queryForObject("""
                SELECT count(*) FROM preplan_supply_action_allocations
                WHERE action_id=? AND external_item_id=?
                """, Long.class, action, targetItem));

        proveRealNativeAndInheritedArchiveFixtures(world);
        Profile before = profile(c.analysis());
        assertTrue(before.provenanceCalls() > 0,
                "The actual canonical native-proof function must execute in the measured transaction");
        assertFalse(before.quantities().isEmpty());
        assertEquals(0, new BigDecimal("3").compareTo(before.quantities().values().stream()
                .reduce(BigDecimal.ZERO, BigDecimal::add)));

        UUID noiseMaterial = h.fixture.ensureSubcontractDirectMaterial(world, world.goodsE());
        h.fixture.receiveSubcontractMaterial(world, noiseMaterial, "32");
        for (int index = 0; index < 4; index++) addUnrelatedApprovedAndStockedOrder(world, c.analysis());

        Profile after = profile(c.analysis());
        assertEquals(before.quantities().keySet(), after.quantities().keySet());
        before.quantities().forEach((key, quantity) -> assertEquals(0,
                quantity.compareTo(after.quantities().get(key)), "Physical planned output changed for " + key));
        assertEquals(before.provenanceCalls(), after.provenanceCalls(),
                "Four unrelated, genuinely approved and stocked orders must not add native-proof candidates");
    }

    private void proveRealNativeAndInheritedArchiveFixtures(FullChainEndToEndTest.World world) {
        var nativeDraft = applications.create(application(world));
        UUID nativeItem = nativeDraft.getItems().getFirst().getId();
        assertFalse(imported("subcontract_applications", nativeDraft.getId()));
        assertFalse(imported("subcontract_application_items", nativeItem));

        var retainedDraft = applications.create(application(world));
        UUID retainedItem = retainedDraft.getItems().getFirst().getId();
        assertTrue(Boolean.TRUE.equals(db.queryForObject(
                "SELECT public.fn_imported_business_document_maintenance_allowed()", Boolean.class)),
                "Only this owned database's actual maintenance session may install the retained-parent fixture");
        Integer legacyId = db.queryForObject("""
                SELECT candidate.value FROM generate_series(1900000000,1900001024) candidate(value)
                WHERE NOT EXISTS(SELECT 1 FROM subcontract_applications document
                                 WHERE document.legacy_id=candidate.value)
                ORDER BY candidate.value LIMIT 1
                """, Integer.class);
        assertNotNull(legacyId);
        assertEquals(1, db.update("UPDATE subcontract_applications SET legacy_id=? WHERE id=?",
                legacyId, retainedDraft.getId()));
        assertTrue(Boolean.TRUE.equals(db.queryForObject("""
                SELECT NULLIF(to_jsonb(item)->>'legacy_id','') IS NULL
                   AND NULLIF(to_jsonb(item)->>'legacy_import_run_id','') IS NULL
                FROM subcontract_application_items item WHERE id=?
                """, Boolean.class, retainedItem)), "The child must inherit, not carry a fabricated marker");
        assertTrue(imported("subcontract_applications", retainedDraft.getId()));
        assertTrue(imported("subcontract_application_items", retainedItem));
        assertEquals((short) 0, db.queryForObject("SELECT status FROM subcontract_applications WHERE id=?",
                Short.class, retainedDraft.getId()), "No approval may be invented for the retained draft");
    }

    private static ApplicationSaveRequest application(FullChainEndToEndTest.World world) {
        var request = new ApplicationSaveRequest();
        request.setBillDate(BusinessTime.today());
        request.setNeedDate(BusinessTime.today().plusDays(1));
        request.setSupplierId(world.supplierId());
        request.setWarehouseId(world.warehouseId());
        var line = new ApplicationItemLine();
        line.setGoodsId(world.goodsE());
        line.setUnitId(world.unitId());
        line.setUnitRate(BigDecimal.ONE);
        line.setQty(BigDecimal.ONE);
        request.setItems(List.of(line));
        return request;
    }

    private void addUnrelatedApprovedAndStockedOrder(FullChainEndToEndTest.World world, UUID analysisId) {
        var pending = h.fixture.submitLeafSubcontractForFinance(world, BigDecimal.ONE);
        h.fixture.loginAs(pending.reviewerUserId());
        h.fixture.approvePendingFinance("SUBCONTRACT", pending.orderId());
        h.fixture.loginAs(world.superAdminUserId());
        UUID item = db.queryForObject("SELECT id FROM subcontract_order_items WHERE order_id=?",
                UUID.class, pending.orderId());
        assertEquals((short) 1, db.queryForObject("SELECT status FROM subcontract_orders WHERE id=?",
                Short.class, pending.orderId()));
        assertEquals(1L, db.queryForObject("""
                SELECT count(*) FROM procurement_order_approval_events event
                JOIN procurement_order_approval_cases approval ON approval.id=event.case_id
                WHERE approval.order_type='SUBCONTRACT' AND approval.order_id=? AND event.event_type='APPROVED'
                """, Long.class, pending.orderId()));
        assertEquals(0L, db.queryForObject("""
                SELECT count(*) FROM subcontract_order_item_sources WHERE order_item_id=?
                """, Long.class, item), "The manual noise order has no application source, especially not this analysis'");
        assertEquals(0L, db.queryForObject("""
                SELECT count(*) FROM preplan_supply_actions
                WHERE analysis_id=? AND external_document_id=?
                """, Long.class, analysisId, pending.orderId()));
        h.fixture.drawAndIssueSubcontract(item, BigDecimal.ONE, "candidate-noise-draw-" + item);

        var request = new ReceiptSaveRequest();
        request.setBillDate(BusinessTime.today());
        request.setSupplierId(world.supplierId());
        request.setWarehouseId(world.warehouseId());
        request.setCurrencyId(world.currencyId());
        request.setExchangeRate(BigDecimal.ONE);
        request.setTaxRate(BigDecimal.ZERO);
        request.setSettlementMethodId(ReflectionTestUtils.invokeMethod(h.fixture, "activeSettlementMethodId"));
        var line = new ReceiptItemLine();
        line.setOrderItemId(item);
        line.setGoodsId(world.goodsE());
        line.setUnitId(world.unitId());
        line.setUnitRate(BigDecimal.ONE);
        line.setQty(BigDecimal.ONE);
        line.setPrice(new BigDecimal("50"));
        request.setItems(List.of(line));
        UUID receipt = receipts.create(request).getId();
        receipts.approve(receipt);
        UUID inspection = db.queryForObject("""
                SELECT id FROM procurement_inspection_items
                WHERE receipt_type='SUBCONTRACT' AND receipt_id=?
                """, UUID.class, receipt);
        inspections.dispose("SUBCONTRACT", receipt, inspection, new InspectionDispositionRequest(
                "PASS", null, "Actual unrelated candidate-scope receipt", "candidate-noise-iqc-" + receipt));
        UUID keeper = ReflectionTestUtils.invokeMethod(h.fixture, "createIqcWarehouseConfirmer",
                world, "candidate-noise-keeper-" + receipt);
        h.fixture.loginAs(keeper);
        var confirm = ReflectionTestUtils.<ProcurementIqcStockInContracts.ConfirmRequest>invokeMethod(h.fixture,
                "latestIqcStockInRequest", "SUBCONTRACT", receipt, inspection, BigDecimal.ONE,
                "candidate-noise-stock-" + receipt, "CANDIDATE-NOISE");
        stockIn.confirm("SUBCONTRACT", receipt, confirm);
        h.fixture.loginAs(world.superAdminUserId());
        assertEquals(0, BigDecimal.ONE.compareTo(db.queryForObject("""
                SELECT warehouse_stocked_base_qty FROM procurement_inspection_items WHERE id=?
                """, BigDecimal.class, inspection)));
        assertFalse(imported("subcontract_orders", pending.orderId()));
        assertFalse(imported("subcontract_order_items", item));
        assertFalse(imported("subcontract_receipts", receipt));
        UUID receiptItem = db.queryForObject("SELECT id FROM subcontract_receipt_items WHERE receipt_id=?",
                UUID.class, receipt);
        assertFalse(imported("subcontract_receipt_items", receiptItem));
    }

    private boolean imported(String table, UUID id) {
        return Boolean.TRUE.equals(db.queryForObject(
                "SELECT public.fn_imported_business_document(?,?)", Boolean.class, table, id));
    }

    private Profile profile(UUID analysisId) throws Exception {
        try (Connection connection = dataSource.getConnection()) {
            connection.setAutoCommit(false);
            connection.setReadOnly(true);
            try {
                try (Statement settings = connection.createStatement()) {
                    settings.execute("SET LOCAL track_functions='all'");
                    try (ResultSet readOnly = settings.executeQuery("SELECT current_setting('transaction_read_only')")) {
                        assertTrue(readOnly.next());
                        assertEquals("on", readOnly.getString(1));
                    }
                }
                long before = provenanceCalls(connection);
                Map<String, BigDecimal> quantities = new LinkedHashMap<>();
                try (PreparedStatement query = connection.prepareStatement(parentQuery())) {
                    query.setObject(1, analysisId);
                    query.setObject(2, analysisId);
                    try (ResultSet rows = query.executeQuery()) {
                        while (rows.next()) quantities.put(rows.getString(1), rows.getBigDecimal(2));
                    }
                }
                long calls = provenanceCalls(connection) - before;
                assertTrue(calls >= 0);
                return new Profile(Map.copyOf(quantities), calls);
            } finally {
                connection.rollback();
            }
        }
    }

    private static long provenanceCalls(Connection connection) throws Exception {
        try (Statement statement = connection.createStatement(); ResultSet rows = statement.executeQuery("""
                SELECT COALESCE((SELECT calls FROM pg_stat_xact_user_functions
                    WHERE funcid='public.fn_imported_business_document_row_internal(text,jsonb,text[])'::regprocedure),0)
                """)) {
            assertTrue(rows.next());
            return rows.getLong(1);
        }
    }

    private static String parentQuery() {
        String allocations = ReflectionTestUtils.invokeMethod(MaterialAnalysisService.class,
                "allocationBudgetRowsSql", "source.analysis_id=?");
        String planned = (String) ReflectionTestUtils.getField(MaterialAnalysisService.class,
                "SUBCONTRACT_PLANNED_OUTPUT_SQL");
        assertNotNull(allocations);
        assertNotNull(planned);
        return "WITH subcontract_budget_allocations AS MATERIALIZED (" + allocations + ")\n" + """
                SELECT material.analysis_item_id || '|' || material.node_key,SUM(
                """ + planned + """
                )::numeric
                FROM preplan_supply_actions action
                JOIN subcontract_budget_allocations allocation ON allocation.action_id=action.id
                JOIN production_material_analysis_materials material
                  ON material.id=allocation.analysis_material_id AND material.active=TRUE
                WHERE action.analysis_id=? AND action.operation_type='SUPPLY' AND action.route='SUBCONTRACT'
                  AND action.status IN ('OPEN','CREATED','IN_PROGRESS') AND action.requested_qty>0
                GROUP BY 1
                """;
    }

    private record Profile(Map<String, BigDecimal> quantities, long provenanceCalls) {}
}
