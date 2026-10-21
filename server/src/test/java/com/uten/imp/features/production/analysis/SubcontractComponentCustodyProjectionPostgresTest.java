package com.uten.imp.features.production.analysis;

import com.fasterxml.jackson.databind.ObjectMapper;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.mockito.ArgumentCaptor;
import org.testcontainers.postgresql.PostgreSQLContainer;

import java.math.BigDecimal;
import java.nio.file.Files;
import java.nio.file.Path;
import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.SQLException;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.within;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

/**
 * ADR-143 §4.5 per-material subcontract draw coverage. Runs the real projection SQL against
 * minimal relations holding only the columns it reads; the two SQL helpers are the migrated
 * definitions (fn_subcontract_order_source_share from V503, fn_subcontract_draw_f per V798).
 * Aggregate public ownership reads V712 batch/event identities and frozen intent, not fake
 * private allocations; these relations must exist even when a case only uses private supply.
 */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class SubcontractComponentCustodyProjectionPostgresTest {
    private static final PostgreSQLContainer DB = new PostgreSQLContainer("postgres:16-alpine");
    private static final BigDecimal EPSILON = new BigDecimal("0.00001");

    private Connection connection;

    @BeforeAll static void start() { DB.start(); }
    @AfterAll static void stop() { DB.stop(); }

    @AfterEach
    void close() throws SQLException {
        if (connection != null) connection.close();
    }

    @BeforeEach
    void schema() throws SQLException {
        connection = DriverManager.getConnection(DB.getJdbcUrl(), DB.getUsername(), DB.getPassword());
        execute("DROP SCHEMA IF EXISTS coverage CASCADE");
        execute("CREATE SCHEMA coverage");
        execute("SET search_path TO coverage");
        execute("""
                CREATE TABLE preplan_supply_actions(id uuid PRIMARY KEY, analysis_id uuid, route text,
                    operation_type text, status text, external_document_type text, requested_qty numeric,
                    public_surplus_qty numeric NOT NULL DEFAULT 0, public_surplus_external_item_id uuid,
                    goods_id uuid, color_id uuid, unit_id uuid);
                CREATE TABLE preplan_aggregate_batches(id uuid PRIMARY KEY, analysis_id uuid NOT NULL,
                    action_id uuid NOT NULL UNIQUE REFERENCES preplan_supply_actions(id));
                CREATE TABLE preplan_aggregate_batch_events(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
                    batch_id uuid NOT NULL REFERENCES preplan_aggregate_batches(id),
                    event_type text NOT NULL CHECK(event_type IN('CREATE','APPEND','ALIAS_APPEND','CANCEL')),
                    public_delta numeric(18,4) NOT NULL DEFAULT 0,
                    intent_snapshot jsonb NOT NULL DEFAULT '{}'::jsonb CHECK(jsonb_typeof(intent_snapshot)='object'));
                CREATE TABLE preplan_supply_action_allocations(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
                    action_id uuid, analysis_id uuid, analysis_material_id uuid, allocated_qty numeric,
                    external_item_id uuid);
                CREATE TABLE subcontract_orders(id uuid PRIMARY KEY, status int, is_deleted boolean DEFAULT false);
                CREATE TABLE subcontract_order_items(id uuid PRIMARY KEY, order_id uuid, unit_rate numeric,
                    returned_qty numeric DEFAULT 0, is_deleted boolean DEFAULT false);
                CREATE TABLE subcontract_order_item_sources(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
                    order_item_id uuid, application_item_id uuid, alloc_qty numeric, line_no int);
                CREATE TABLE subcontract_receipts(id uuid PRIMARY KEY, status int, is_deleted boolean DEFAULT false);
                CREATE TABLE subcontract_receipt_items(id uuid PRIMARY KEY, receipt_id uuid, order_item_id uuid,
                    qty numeric, unit_rate numeric, is_deleted boolean DEFAULT false, finance_approval_case_id uuid);
                CREATE TABLE procurement_inspection_items(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
                    receipt_type text, receipt_item_id uuid, status text, warehouse_stocked_base_qty numeric,
                    quantity_tranche text NOT NULL DEFAULT 'LEGACY' CHECK(quantity_tranche IN('LEGACY','CHARGED','GIFT')));
                CREATE TABLE subcontract_material_plans(id uuid PRIMARY KEY, status text, is_deleted boolean DEFAULT false);
                CREATE TABLE subcontract_material_plan_items(id uuid PRIMARY KEY, plan_id uuid, order_item_id uuid,
                    goods_id uuid, color_id uuid, bom_unit_qty numeric, issued_qty numeric,
                    is_deleted boolean DEFAULT false);
                CREATE TABLE subcontract_material_issues(id uuid PRIMARY KEY, status int, is_deleted boolean DEFAULT false);
                CREATE TABLE subcontract_material_issue_items(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
                    issue_id uuid, plan_item_id uuid, qty numeric, is_deleted boolean DEFAULT false);
                CREATE TABLE stock_reservations(id uuid PRIMARY KEY, qty numeric, released_qty numeric DEFAULT 0,
                    consumed_qty numeric DEFAULT 0, status int DEFAULT 0, is_deleted boolean DEFAULT false);
                CREATE TABLE subcontract_component_stock_handoffs(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
                    plan_item_id uuid, parent_material_id uuid, child_material_id uuid,
                    source_reservation_id uuid, target_reservation_id uuid, qty numeric,
                    created_at timestamptz DEFAULT now());
                CREATE TABLE production_material_analysis_materials(id uuid PRIMARY KEY, analysis_id uuid,
                    analysis_item_id uuid, node_key text, parent_node_key text, node_role text, depth int,
                    path text, goods_id uuid, color_id uuid, active boolean DEFAULT true, unit_id uuid);
                CREATE FUNCTION fn_subcontract_draw_f(p_sets numeric, p_bom_unit_qty numeric)
                RETURNS numeric LANGUAGE sql IMMUTABLE AS $$ SELECT CEIL(p_sets * p_bom_unit_qty * 10000) / 10000 $$;
                CREATE FUNCTION fn_subcontract_order_source_share(p_order_item_id uuid, p_application_item_id uuid,
                    p_total_base numeric) RETURNS numeric LANGUAGE sql STABLE AS $$
                    WITH bounds AS (
                        SELECT src.application_item_id,
                               src.alloc_qty * COALESCE(item.unit_rate, 1) AS alloc_base,
                               COALESCE(SUM(src.alloc_qty) OVER w, 0) * COALESCE(item.unit_rate, 1)
                                   - src.alloc_qty * COALESCE(item.unit_rate, 1) AS prefix_base,
                               ROW_NUMBER() OVER w AS rn,
                               COUNT(*) OVER (PARTITION BY src.order_item_id) AS source_count
                        FROM subcontract_order_item_sources src
                        JOIN subcontract_order_items item ON item.id = src.order_item_id
                        WHERE src.order_item_id = p_order_item_id AND src.alloc_qty > 0
                        WINDOW w AS (PARTITION BY src.order_item_id ORDER BY src.line_no, src.id))
                    SELECT COALESCE((SELECT CASE WHEN b.rn = b.source_count
                            THEN GREATEST(COALESCE(p_total_base, 0) - b.prefix_base, 0)
                            ELSE GREATEST(LEAST(b.alloc_base, COALESCE(p_total_base, 0) - b.prefix_base), 0) END
                        FROM bounds b WHERE b.application_item_id = p_application_item_id), 0);
                $$;
                """);
    }

    @Test
    void publicOnlyCreateAndAppendKeepTheirFrozenOwnerWeightsWithoutPrivateAllocations() throws Exception {
        PublicWorld p = publicWorld();
        assertThat(allocationCount(p.action())).isZero();

        // CREATE 3 at 1:2, then APPEND 3 entirely for the second source: 1 + 5.
        // A repeated snapshot of the first physical parent must not double its weight.
        Map<UUID, BigDecimal[]> before = coverage(p.world().analysis);
        assertThat(before).containsOnlyKeys(p.firstChild(), p.secondChild());
        assertThat(before.get(p.firstChild())[0]).isEqualByComparingTo("1");
        assertThat(before.get(p.firstChild())[1]).isEqualByComparingTo("1");
        assertThat(before.get(p.secondChild())[0]).isEqualByComparingTo("5");
        assertThat(before.get(p.secondChild())[1]).isEqualByComparingTo("5");

        p.world().stockedReceipt(p.orderItem(), "3");
        Map<UUID, BigDecimal[]> remaining = coverage(p.world().analysis);
        assertThat(remaining.get(p.firstChild())[0]).isEqualByComparingTo("0.5");
        assertThat(remaining.get(p.firstChild())[1]).isEqualByComparingTo("0.5");
        assertThat(remaining.get(p.secondChild())[0]).isEqualByComparingTo("2.5");
        assertThat(remaining.get(p.secondChild())[1]).isEqualByComparingTo("2.5");
        assertThat(remaining.values().stream().map(row -> row[1]).reduce(BigDecimal.ZERO, BigDecimal::add))
                .isEqualByComparingTo("3");
        assertThat(allocationCount(p.action())).isZero();
    }

    @Test
    void publicOwnerRequiresTheActualProductColorAndUnit() throws Exception {
        PublicWorld p = publicWorld();
        for (String column : List.of("goods_id", "color_id", "unit_id")) {
            update("UPDATE preplan_supply_actions SET " + column + "=? WHERE id=?", UUID.randomUUID(), p.action());
            assertThat(coverage(p.world().analysis)).as("mismatched %s", column).isEmpty();
            p.world().bindActionProduct(p.action(), p.first());
        }
        assertThat(coverage(p.world().analysis)).containsOnlyKeys(p.firstChild(), p.secondChild());
        assertThat(allocationCount(p.action())).isZero();
    }

    @Test
    void privateAllocationOwnsTheWholePhysicalBatchAfterPublicOnlyIntentBecomesMixed() throws Exception {
        PublicWorld p = publicWorld();
        assertThat(coverage(p.world().analysis)).containsOnlyKeys(p.firstChild(), p.secondChild());
        update("UPDATE preplan_supply_actions SET requested_qty=6 WHERE id=?", p.action());
        UUID privateApplication = p.world().allocation(p.action(), p.first(), "6");
        p.world().source(p.orderItem(), privateApplication, "6", 2);
        update("UPDATE subcontract_material_plan_items SET issued_qty=12 WHERE id=?", p.planLine());

        Map<UUID, BigDecimal[]> mixed = coverage(p.world().analysis);
        assertThat(mixed).containsOnlyKeys(p.firstChild());
        assertThat(mixed.get(p.firstChild())[0]).isEqualByComparingTo("12");
        assertThat(mixed.get(p.firstChild())[1]).isEqualByComparingTo("12");
        assertThat(allocationCount(p.action())).isEqualTo(1);
    }

    @Test
    void sharedPrivateOwnersKeepAnExactHalfBoundaryWithoutAnArtificialCeilingTick() throws Exception {
        PublicWorld p = privateWorld();
        p.world().stockedReceipt(p.orderItem(), "3");
        Map<UUID, BigDecimal[]> rows = coverage(p.world().analysis);
        assertThat(rows).containsOnlyKeys(p.firstChild(), p.secondChild());
        assertThat(rows.get(p.firstChild())[0]).isEqualByComparingTo("0.5");
        assertThat(rows.get(p.firstChild())[1]).isEqualByComparingTo("0.5");
        assertThat(rows.get(p.secondChild())[0]).isEqualByComparingTo("2.5");
        assertThat(rows.get(p.secondChild())[1]).isEqualByComparingTo("2.5");
        assertThat(allocationCount(p.action())).isEqualTo(2);
    }

    @Test
    void genuineFractionalConsumptionStillRoundsUpForPrivateAndPublicOwners() throws Exception {
        for (boolean publicOnly : List.of(false, true)) {
            PublicWorld p = publicOnly ? publicWorld() : privateWorld();
            p.world().stockedReceipt(p.orderItem(), "1");
            Map<UUID, BigDecimal[]> rows = coverage(p.world().analysis);
            // 1/6 and 5/6 really require CEIL4 to 0.1667 and 0.8334.
            assertThat(rows.get(p.firstChild())[0]).isEqualByComparingTo("0.8333");
            assertThat(rows.get(p.secondChild())[0]).isEqualByComparingTo("4.1666");
        }
    }

    @Test
    void unitConversionAndFrozenBomKeepAnExactHalfConsumptionBoundary() throws Exception {
        World w = new World(UUID.randomUUID());
        Parent parent = w.parent("UNIT-BOUNDARY", false);
        UUID child = w.child(parent, "A", w.goodsA);
        UUID application = w.allocation(w.action("6", "0"), parent, "6");
        // One order unit is six parent base units; its frozen material need is three.
        UUID item = w.orderItem("6", application, "1");
        w.planLine(item, w.goodsA, "3", "3");
        w.stockedReceipt(item, "1");

        BigDecimal[] actual = coverage(w.analysis).get(child);
        assertThat(actual[0]).isEqualByComparingTo("2.5");
        assertThat(actual[1]).isEqualByComparingTo("5");
    }

    @Test
    void parentOutputCapUsesTheAuthoritativeFourDecimalAllocationBudget() throws Exception {
        installParentCapacity();
        World w = new World(UUID.randomUUID());
        Parent a = w.parent("CAP-A", false), b = w.parent("CAP-B", false);
        update("UPDATE production_material_analysis_materials SET goods_id=(SELECT goods_id FROM production_material_analysis_materials WHERE id=?) WHERE id=?",
                a.id(), b.id());
        UUID child = w.child(a, "A", w.goodsA);
        w.child(b, "A", w.goodsA);
        UUID action = w.action("3", "0");
        UUID application = w.allocation(action, a, "1");
        w.allocation(action, b, "2", application);
        UUID allocationA = new UUID(0, 1), allocationB = new UUID(0, 2);
        update("UPDATE preplan_supply_action_allocations SET id=? WHERE action_id=? AND analysis_material_id=?", allocationA, action, a.id());
        update("UPDATE preplan_supply_action_allocations SET id=? WHERE action_id=? AND analysis_material_id=?", allocationB, action, b.id());
        assertThat(parentCapacity(application, allocationA, "3")).isEqualByComparingTo("1");
        assertThat(parentCapacity(application, allocationA, "1")).isEqualByComparingTo("0.3333");
        UUID item = w.orderItem("1", application, "3");
        w.planLine(item, w.goodsA, "6", "18");
        w.stockedReceipt(item, "2");

        String authoritativeSql = "SELECT " + MaterialAnalysisService.allocationBudgetShareSql("1")
                + " FROM (" + MaterialAnalysisService.allocationBudgetRowsSql("source.action_id='" + action + "'::uuid")
                + ") allocation JOIN preplan_supply_actions action ON action.id=allocation.action_id WHERE allocation.id='"
                + allocationA + "'::uuid";
        BigDecimal authoritative;
        try (var query = connection.createStatement(); var rows = query.executeQuery(authoritativeSql)) {
            assertThat(rows.next()).isTrue();
            authoritative = rows.getBigDecimal(1);
        }
        assertThat(authoritative).isEqualByComparingTo("0.3333");
        BigDecimal[] actual = coverage(w.analysis).get(child);
        assertThat(actual[0]).isEqualByComparingTo("2");
        // A refreshed current BOM uses three, while the physical order retains its frozen six.
        // The original requirement still has headroom, so only the authoritative parent cap limits coverage.
        String key = a.nodeKey() + "/A";
        var node = new MaterialAnalysisService.BomNode(a.analysisItemId(), child, UUID.randomUUID(),
                w.goodsA, null, w.unit, 2, key, a.nodeKey(), BigDecimal.ONE, new BigDecimal("3"),
                new BigDecimal("3"), new BigDecimal("3.9999"), "A", "A", null, null, "piece",
                BigDecimal.ZERO, "BUY", false, "START", "PER_UNIT", BigDecimal.ONE, true, true);
        var formal = new MaterialAnalysisService.FormalMaterialCoverage(child, a.analysisItemId(), key, actual[0], actual[1]);
        var secured = MaterialAnalysisService.planFormalCoverage(List.of(formal), List.of(node));
        org.junit.jupiter.api.Assertions.assertAll(
                () -> assertThat(actual[1]).isEqualByComparingTo(authoritative),
                () -> assertThat(secured.securedTotal(a.analysisItemId() + "|" + key)).isEqualByComparingTo("0.9999"));
    }

    @Test
    void threeApplicationsSumTheirCommonDenominatorBeforeExactHalfConsumption() throws Exception {
        assertMultiApplicationConsumption(List.of("6", "6", "6"), List.of("1", "1", "1"), "0.1667");
    }

    @Test
    void differentApplicationDenominatorsDoNotInventAnExactHalfConsumptionTick() throws Exception {
        // Returned shares are 1/6 + 1/13 + 10/39 = 1/2 exactly.
        assertMultiApplicationConsumption(List.of("6", "13", "39"), List.of("1", "1", "10"), "0.2564");
    }

    @Test
    void fractionalOwnerQuantitiesAndOrderUnitRateKeepExactMaterialBoundaries() throws Exception {
        World w = new World(UUID.randomUUID());
        Parent first = w.parent("FRACTION-A", false), second = w.parent("FRACTION-B", false);
        update("UPDATE production_material_analysis_materials SET goods_id=(SELECT goods_id FROM production_material_analysis_materials WHERE id=?) WHERE id=?",
                first.id(), second.id());
        UUID firstChild = w.child(first, "A", w.goodsA), secondChild = w.child(second, "A", w.goodsA);
        UUID action = w.action("1.5", "0");
        UUID application = w.allocation(action, first, "0.5");
        w.allocation(action, second, "1", application);
        UUID item = w.orderItem("1.5", application, "1");
        w.planLine(item, w.goodsA, "3", "3");
        w.stockedReceipt(item, "0.75");

        Map<UUID, BigDecimal[]> rows = coverage(w.analysis);
        assertThat(rows.get(firstChild)[0]).isEqualByComparingTo("0.5");
        assertThat(rows.get(firstChild)[1]).isEqualByComparingTo("0.25");
        assertThat(rows.get(secondChild)[0]).isEqualByComparingTo("1");
        assertThat(rows.get(secondChild)[1]).isEqualByComparingTo("0.5");
    }

    @Test
    void halfTickExactOwnershipKeepsPriorityOverAnEarlierPublicOwner() throws Exception {
        assertExactMaterialBudget(true);
    }

    @Test
    void scaledExactOwnershipConservesTheWholeRemainingMaterialBudget() throws Exception {
        assertExactMaterialBudget(false);
    }

    @Test
    void repeatingOwnerNeedsKeepTheExactIndividualHalfTick() throws Exception {
        installParentCapacity();
        World w = new World(UUID.randomUUID());
        Parent first = w.parent("REPEAT-A", false), second = w.parent("REPEAT-B", false);
        Parent a = first.id().toString().compareTo(second.id().toString()) < 0 ? first : second;
        Parent b = a == first ? second : first;
        Parent c = w.parent("REPEAT-C", false), d = w.parent("REPEAT-D", false);
        for (Parent parent : List.of(b, c, d)) {
            update("UPDATE production_material_analysis_materials SET goods_id=(SELECT goods_id FROM production_material_analysis_materials WHERE id=?) WHERE id=?",
                    a.id(), parent.id());
        }
        UUID childA = w.child(a, "A", w.goodsA), childB = w.child(b, "A", w.goodsA);
        w.child(c, "A", w.goodsA);
        w.child(d, "A", w.goodsA);
        UUID action = w.action("90", "0");
        UUID application = w.allocation(action, b, "7");
        w.allocation(action, c, "4", application);
        w.allocation(action, a, "3", application);
        w.allocation(action, d, "76", application);
        List<Parent> allocationOrder = List.of(b, c, a, d);
        for (int i = 0; i < allocationOrder.size(); i++) {
            update("UPDATE preplan_supply_action_allocations SET id=? WHERE action_id=? AND analysis_material_id=?",
                    new UUID(0, i + 1), action, allocationOrder.get(i).id());
        }
        assertThat(parentCapacity(application, new UUID(0, 3), "1")).isEqualByComparingTo("0.0334");
        assertThat(parentCapacity(application, new UUID(0, 1), "1")).isEqualByComparingTo("0.0778");
        UUID item = w.orderItem("1", UUID.randomUUID(), "0.1107");
        w.source(item, application, "1", 2);
        UUID line = w.planLine(item, w.goodsA, "1", "0.1112");
        w.handoff(line, a, childA, "0.0334");
        w.handoff(line, b, childB, "0.0778");
        w.stockedReceipt(item, "0.1107");
        try (var query = connection.prepareStatement("SELECT fn_subcontract_order_source_share(?,?,?)")) {
            query.setObject(1, item);
            query.setObject(2, application);
            query.setBigDecimal(3, new BigDecimal("0.1107"));
            try (var rows = query.executeQuery()) {
                rows.next();
                assertThat(rows.getBigDecimal(1)).isZero();
            }
        }
        Map<UUID, BigDecimal[]> rows = coverage(w.analysis);
        assertThat(rows).containsOnlyKeys(childA, childB);
        assertThat(rows.get(childA)[0]).isEqualByComparingTo("0.0002");
        assertThat(rows.get(childB)[0]).isEqualByComparingTo("0.0003");
        assertThat(rows.values().stream().map(row -> row[0]).reduce(BigDecimal.ZERO, BigDecimal::add))
                .isEqualByComparingTo("0.0005");
    }

    private void assertExactMaterialBudget(boolean singleExact) throws Exception {
        installParentCapacity();
        World w = new World(UUID.randomUUID());
        Parent first = w.parent("EXACT-A", false), second = w.parent("EXACT-B", false);
        update("UPDATE production_material_analysis_materials SET goods_id=(SELECT goods_id FROM production_material_analysis_materials WHERE id=?) WHERE id=?",
                first.id(), second.id());
        // PostgreSQL orders UUID bytes unsigned; Java UUID.compareTo uses signed longs.
        boolean firstSortsBeforeSecond = first.id().toString().compareTo(second.id().toString()) < 0;
        Parent a = firstSortsBeforeSecond != singleExact ? first : second;
        Parent b = a == first ? second : first;
        UUID childA = w.child(a, "A", w.goodsA), childB = w.child(b, "A", w.goodsA);
        UUID action = w.action("2", "0");
        UUID application = w.allocation(action, a, "1");
        w.allocation(action, b, "1", application);
        UUID allocationA = new UUID(0, 1), allocationB = new UUID(0, 2);
        update("UPDATE preplan_supply_action_allocations SET id=? WHERE action_id=? AND analysis_material_id=?", allocationA, action, a.id());
        update("UPDATE preplan_supply_action_allocations SET id=? WHERE action_id=? AND analysis_material_id=?", allocationB, action, b.id());
        // The real capacity authority grants A the first tick even when public B sorts first.
        assertThat(parentCapacity(application, allocationA, singleExact ? "0.0005" : "1"))
                .isGreaterThanOrEqualTo(new BigDecimal("0.0003"));
        if (singleExact) assertThat(parentCapacity(application, allocationB, "0.0005")).isEqualByComparingTo("0.0002");
        UUID item = w.orderItem("1", application, singleExact ? "0.0005" : "1");
        UUID line = w.planLine(item, w.goodsA, "1", singleExact ? "0.0005" : "0.0006");
        w.handoff(line, a, childA, "0.0003");
        if (!singleExact) {
            w.handoff(line, b, childB, "0.0003");
            w.stockedReceipt(item, "0.0001");
        }
        Map<UUID, BigDecimal[]> rows = coverage(w.analysis);
        assertThat(rows).containsOnlyKeys(childA, childB);
        assertThat(rows.get(childA)[0]).isEqualByComparingTo("0.0003");
        assertThat(rows.get(childB)[0]).isEqualByComparingTo("0.0002");
        assertThat(rows.values().stream().map(row -> row[0]).reduce(BigDecimal.ZERO, BigDecimal::add))
                .isEqualByComparingTo("0.0005");
    }

    private void installParentCapacity() throws Exception {
        String migration = Files.readString(Path.of("src/main/resources/db/migration/V798__subcontract_step_draw.sql"));
        int function = migration.indexOf("CREATE OR REPLACE FUNCTION fn_subcontract_component_parent_capacity(");
        assertThat(function).isGreaterThanOrEqualTo(0);
        execute(migration.substring(function, migration.indexOf("$$;", function) + 3));
    }

    private BigDecimal parentCapacity(UUID application, UUID allocation, String total) throws SQLException {
        try (var query = connection.prepareStatement("SELECT fn_subcontract_component_parent_capacity(?,?,?)")) {
            query.setObject(1, application);
            query.setObject(2, allocation);
            query.setBigDecimal(3, new BigDecimal(total));
            try (var rows = query.executeQuery()) {
                rows.next();
                return rows.getBigDecimal(1);
            }
        }
    }

    @Test
    void distinctApplicationBudgetsStayInsideTheExistingReadTimeout() throws Exception {
        for (int count : List.of(1, 16, 128, 512)) {
            World w = new World(UUID.randomUUID());
            Parent first = w.parent("BENCH-A", false), second = w.parent("BENCH-B", false);
            update("UPDATE production_material_analysis_materials SET goods_id=(SELECT goods_id FROM production_material_analysis_materials WHERE id=?) WHERE id=?",
                    first.id(), second.id());
            UUID child = w.child(first, "A", w.goodsA);
            w.child(second, "A", w.goodsA);
            UUID item = null;
            for (int i = 0; i < count; i++) {
                int total = 1001 + i;
                UUID action = w.action(Integer.toString(total), "0");
                UUID application = w.allocation(action, first, "1");
                w.allocation(action, second, Integer.toString(total - 1), application);
                if (item == null) item = w.orderItem("1", application, "1");
                else w.source(item, application, "1", i + 1);
            }
            w.planLine(item, w.goodsA, "1", Integer.toString(count));
            execute("ANALYZE");
            long started = System.nanoTime();
            Map<UUID, BigDecimal[]> rows = coverage(w.analysis);
            double firstReadMs = (System.nanoTime() - started) / 1_000_000.0;
            assertThat(rows).hasSize(2);
            assertThat(rows.get(child)[0]).isPositive();
            assertThat(rows.values().stream().map(row -> row[0]).reduce(BigDecimal.ZERO, BigDecimal::add))
                    .isEqualByComparingTo(Integer.toString(count));
            recordExplain(w.analysis, count, firstReadMs, false);
            if (count == 512) recordExplain(w.analysis, count, firstReadMs, true);
        }
    }

    private void recordExplain(UUID analysis, int sources, double firstReadMs, boolean timing) throws Exception {
        String sql = productionSql().replace(":analysisId", "'" + analysis + "'::uuid");
        String json;
        try (var statement = connection.createStatement()) {
            statement.setQueryTimeout(10);
            try (var rows = statement.executeQuery("EXPLAIN (ANALYZE,BUFFERS,TIMING " + (timing ? "ON" : "OFF") + ",FORMAT JSON) " + sql)) {
                rows.next();
                json = rows.getString(1);
            }
        }
        Path output = Path.of(System.getProperty("uten.build.directory", "target"))
                .resolve("custody-rational-" + sources + (timing ? "-timing" : "") + "-explain.json");
        Files.createDirectories(output.getParent());
        Files.writeString(output, json);
        var plan = new ObjectMapper().readTree(json).get(0);
        System.out.printf(Locale.ROOT,
                "CUSTODY_RATIONAL_EXPLAIN sources=%d timing=%s firstReadMs=%.3f planningMs=%.3f executionMs=%.3f file=%s%n",
                sources, timing, firstReadMs, plan.get("Planning Time").doubleValue(),
                plan.get("Execution Time").doubleValue(), output);
    }

    private void assertMultiApplicationConsumption(List<String> totals, List<String> owned, String expectedNet) throws Exception {
        World w = new World(UUID.randomUUID());
        Parent first = w.parent("MULTI-A", false), second = w.parent("MULTI-B", false);
        update("UPDATE production_material_analysis_materials SET goods_id=(SELECT goods_id FROM production_material_analysis_materials WHERE id=?) WHERE id=?",
                first.id(), second.id());
        UUID child = w.child(first, "A", w.goodsA);
        w.child(second, "A", w.goodsA);
        UUID item = null;
        for (int i = 0; i < totals.size(); i++) {
            UUID action = w.action(totals.get(i), "0");
            UUID application = w.allocation(action, first, owned.get(i));
            w.allocation(action, second, new BigDecimal(totals.get(i)).subtract(new BigDecimal(owned.get(i))).toPlainString(), application);
            String ordered = i == 2 ? "2" : "1";
            if (item == null) item = w.orderItem("1", application, ordered);
            else w.source(item, application, ordered, i + 1);
        }
        w.planLine(item, w.goodsA, "1", "4");
        w.stockedReceipt(item, "3");
        Map<UUID, BigDecimal[]> rows = coverage(w.analysis);
        assertThat(rows.get(child)[0]).isEqualByComparingTo(expectedNet);
        assertThat(rows.values().stream().map(row -> row[0]).reduce(BigDecimal.ZERO, BigDecimal::add))
                .isEqualByComparingTo("1");
    }

    private PublicWorld privateWorld() throws Exception {
        World w = new World(UUID.randomUUID());
        Parent first = w.parent("PRIVATE-A", false), second = w.parent("PRIVATE-B", false);
        update("UPDATE production_material_analysis_materials SET goods_id=(SELECT goods_id FROM production_material_analysis_materials WHERE id=?) WHERE id=?",
                first.id(), second.id());
        UUID firstChild = w.child(first, "A", w.goodsA), secondChild = w.child(second, "A", w.goodsA);
        UUID action = w.action("6", "0");
        UUID application = w.allocation(action, first, "1");
        w.allocation(action, second, "5", application);
        UUID orderItem = w.orderItem("1", application, "6");
        UUID planLine = w.planLine(orderItem, w.goodsA, "1", "6");
        return new PublicWorld(w, first, firstChild, secondChild, action, orderItem, planLine);
    }

    private PublicWorld publicWorld() throws Exception {
        World w = new World(UUID.randomUUID());
        Parent first = w.parent("PUBLIC-A", false), second = w.parent("PUBLIC-B", false);
        update("UPDATE production_material_analysis_materials SET goods_id=(SELECT goods_id FROM production_material_analysis_materials WHERE id=?) WHERE id=?",
                first.id(), second.id());
        UUID firstChild = w.child(first, "A", w.goodsA), secondChild = w.child(second, "A", w.goodsA);
        UUID action = w.action("0", "6"), application = UUID.randomUUID(), batch = UUID.randomUUID();
        w.bindActionProduct(action, first);
        w.publicSurplus(action, application);
        update("INSERT INTO preplan_aggregate_batches(id,analysis_id,action_id) VALUES (?,?,?)", batch, w.analysis, action);
        Map<String, Object> firstSource = w.sourceSnapshot(first, "1", 1);
        Map<String, Object> secondSource = w.sourceSnapshot(second, "2", 2);
        w.publicEvent(batch, "CREATE", "3", List.of(firstSource, firstSource, secondSource), Map.of());
        w.publicEvent(batch, "APPEND", "3", List.of(firstSource, secondSource),
                Map.of(first.id().toString(), "0", second.id().toString(), "3"));
        UUID orderItem = w.orderItem("1", application, "6");
        UUID planLine = w.planLine(orderItem, w.goodsA, "1", "6");
        return new PublicWorld(w, first, firstChild, secondChild, action, orderItem, planLine);
    }

    private int allocationCount(UUID action) throws SQLException {
        try (var statement = connection.prepareStatement("SELECT COUNT(*) FROM preplan_supply_action_allocations WHERE action_id=?")) {
            statement.setObject(1, action);
            try (var rows = statement.executeQuery()) {
                rows.next();
                return rows.getInt(1);
            }
        }
    }

    private record PublicWorld(World world, Parent first, UUID firstChild, UUID secondChild,
                               UUID action, UUID orderItem, UUID planLine) {}

    @Test
    void stockedReturnsConsumeTheirMaterialAndCapTheRemainingParentOutput() throws Exception {
        // Q=100, b=1：领了 70 套，40 套已回厂合格入库。委外商处 30 套料仍覆盖剩余 60 套的需求。
        World w = new World(UUID.randomUUID());
        Parent p = w.parent("P", false);
        UUID childA = w.child(p, "A", w.goodsA);
        UUID action = w.action("100", "0");
        UUID application = w.allocation(action, p, "100");
        UUID orderItem = w.orderItem("1", application, "100");
        w.planLine(orderItem, w.goodsA, "1", "70");
        w.stockedReceipt(orderItem, "40");

        Map<UUID, BigDecimal[]> rows = coverage(w.analysis);

        assertThat(rows).containsOnlyKeys(childA);
        assertThat(rows.get(childA)[0]).isCloseTo(new BigDecimal("30"), within(EPSILON));
        assertThat(rows.get(childA)[1]).isCloseTo(new BigDecimal("60"), within(EPSILON));
    }

    @Test
    void everyMaterialIsCoveredOnItsOwnAndDraftsCountWithNetSent() throws Exception {
        // 两种直属物料：A 单耗 1 已发 40；B 单耗 2 已发 60 + 待仓库发 20。不同物料从不相加。
        World w = new World(UUID.randomUUID());
        Parent p = w.parent("P", false);
        UUID childA = w.child(p, "A", w.goodsA);
        UUID childB = w.child(p, "B", w.goodsB);
        UUID action = w.action("100", "0");
        UUID application = w.allocation(action, p, "100");
        UUID orderItem = w.orderItem("1", application, "100");
        w.planLine(orderItem, w.goodsA, "1", "40");
        UUID lineB = w.planLine(orderItem, w.goodsB, "2", "60");
        w.draft(lineB, "20");

        Map<UUID, BigDecimal[]> rows = coverage(w.analysis);

        assertThat(rows.get(childA)[0]).isCloseTo(new BigDecimal("40"), within(EPSILON));
        assertThat(rows.get(childB)[0]).isCloseTo(new BigDecimal("80"), within(EPSILON));
        assertThat(rows.get(childA)[1]).isCloseTo(new BigDecimal("100"), within(EPSILON));
    }

    @Test
    void mergedOrderItemSplitsPublicDrawsByApplicationWeightAndKeepsExactHandoffs() throws Exception {
        // 两张分析合并成一条订货明细(60 + 40)：公共领出的 50 按空额 60:40 分；Y 另有 10 专属交接。
        World x = new World(UUID.randomUUID());
        Parent px = x.parent("PX", false);
        UUID cx = x.child(px, "A", x.goodsA);
        UUID actionX = x.action("60", "0");
        UUID applicationX = x.allocation(actionX, px, "60");
        World y = x.sibling(UUID.randomUUID());
        Parent py = y.parent("PY", false);
        UUID cy = y.child(py, "A", x.goodsA);
        UUID actionY = y.action("40", "0");
        UUID applicationY = y.allocation(actionY, py, "40");
        UUID orderItem = x.orderItem("1", applicationX, "60");
        x.source(orderItem, applicationY, "40", 2);
        UUID line = x.planLine(orderItem, x.goodsA, "1", "50");
        x.handoff(line, py, cy, "10");

        Map<UUID, BigDecimal[]> forX = coverage(x.analysis);
        Map<UUID, BigDecimal[]> forY = coverage(y.analysis);

        BigDecimal netX = forX.get(cx)[0];
        BigDecimal netY = forY.get(cy)[0];
        assertThat(netX.add(netY)).isCloseTo(new BigDecimal("50"), within(EPSILON));
        // Y 的专属 10 归它本身；其余公共 40 按空额(X 60、Y 30)分摊。
        assertThat(netY).isCloseTo(new BigDecimal("23.3333"), within(new BigDecimal("0.0002")));
        assertThat(forX.get(cx)[1]).isCloseTo(new BigDecimal("60"), within(EPSILON));
        assertThat(forY.get(cy)[1]).isCloseTo(new BigDecimal("40"), within(EPSILON));
    }

    @Test
    void mergedOrderItemConsumesStockedReturnsBeforeSplittingPublicDraws() throws Exception {
        // 两张分析各 100 合并成一条订货明细：公共库存领出 100 套，回厂 100 合格入库，按来源先后算 X 的。
        // 领出的料已全部做进 X 的 P：X 什么都不缺，Y 一套料都没有，仍缺 100。
        World x = new World(UUID.randomUUID());
        Parent px = x.parent("PX", false);
        UUID cx = x.child(px, "A", x.goodsA);
        UUID applicationX = x.allocation(x.action("100", "0"), px, "100");
        World y = x.sibling(UUID.randomUUID());
        Parent py = y.parent("PY", false);
        UUID cy = y.child(py, "A", x.goodsA);
        UUID applicationY = y.allocation(y.action("100", "0"), py, "100");
        UUID orderItem = x.orderItem("1", applicationX, "100");
        x.source(orderItem, applicationY, "100", 2);
        UUID line = x.planLine(orderItem, x.goodsA, "1", "100");
        x.stockedReceipt(orderItem, "100");

        assertThat(coverage(x.analysis)).doesNotContainKey(cx);
        assertThat(coverage(y.analysis)).doesNotContainKey(cy);

        // 再领 40 套：只有 Y 还缺料，全部归 Y；Y 的 P 剩余计划产出仍是 100，缺口 60。
        x.draft(line, "40");
        Map<UUID, BigDecimal[]> forY = coverage(y.analysis);
        assertThat(coverage(x.analysis)).doesNotContainKey(cx);
        assertThat(forY.get(cy)[0]).isCloseTo(new BigDecimal("40"), within(EPSILON));
        assertThat(forY.get(cy)[1]).isCloseTo(new BigDecimal("100"), within(EPSILON));
    }

    @Test
    void exactHandoffConsumedUnderAnEarlierSourcesReturnsNoLongerCoversItsOwner() throws Exception {
        // 同样 100 + 100 合并：领出的 100 套全是 Y 的专属交接；回厂 100 按来源先后算 X 的。
        // 料已做成 P 入库，剩余料为 0：Y 的专属量不再覆盖，Y 仍缺 100。
        World x = new World(UUID.randomUUID());
        Parent px = x.parent("PX", false);
        UUID cx = x.child(px, "A", x.goodsA);
        UUID applicationX = x.allocation(x.action("100", "0"), px, "100");
        World y = x.sibling(UUID.randomUUID());
        Parent py = y.parent("PY", false);
        UUID cy = y.child(py, "A", x.goodsA);
        UUID applicationY = y.allocation(y.action("100", "0"), py, "100");
        UUID orderItem = x.orderItem("1", applicationX, "100");
        x.source(orderItem, applicationY, "100", 2);
        UUID line = x.planLine(orderItem, x.goodsA, "1", "100");
        x.handoff(line, py, cy, "100");

        assertThat(coverage(y.analysis).get(cy)[0]).isCloseTo(new BigDecimal("100"), within(EPSILON));
        assertThat(coverage(x.analysis)).doesNotContainKey(cx);

        x.stockedReceipt(orderItem, "100");
        assertThat(coverage(x.analysis)).doesNotContainKey(cx);
        assertThat(coverage(y.analysis)).doesNotContainKey(cy);

        // 再从公共库存领 30 套：剩余料 30 只能是给仍缺料的 Y 做的。
        x.draft(line, "30");
        Map<UUID, BigDecimal[]> forY = coverage(y.analysis);
        assertThat(forY.get(cy)[0]).isCloseTo(new BigDecimal("30"), within(EPSILON));
        assertThat(forY.get(cy)[1]).isCloseTo(new BigDecimal("100"), within(EPSILON));
        assertThat(coverage(x.analysis)).doesNotContainKey(cx);
    }

    @Test
    void rootSupplyParentCoversItsDepthOneChildrenAndPublicSurplusRaisesTheCap() throws Exception {
        // 顶层委外件(ROOT_SUPPLY)：直属物料是同一来源行的第 1 层节点；需求 1000 + 公共 500。
        World w = new World(UUID.randomUUID());
        Parent root = w.parent("ROOT_SUPPLY", true);
        UUID childA = w.child(root, "A", w.goodsA);
        UUID action = w.action("1000", "500");
        UUID application = w.allocation(action, root, "1000");
        w.publicSurplus(action, application);
        UUID orderItem = w.orderItem("1", application, "1500");
        w.planLine(orderItem, w.goodsA, "1", "1200");
        w.stockedReceipt(orderItem, "200");

        Map<UUID, BigDecimal[]> rows = coverage(w.analysis);

        assertThat(rows.get(childA)[0]).isCloseTo(new BigDecimal("1000"), within(EPSILON));
        assertThat(rows.get(childA)[1]).isCloseTo(new BigDecimal("1300"), within(EPSILON));
    }

    @Test
    void manualExcessBeyondTheApplicationIsNotAttributed() throws Exception {
        // 订货 150 只来自 100 的申请：领出 150 套，只有申请那 100 套的料归本分析。
        World w = new World(UUID.randomUUID());
        Parent p = w.parent("P", false);
        UUID childA = w.child(p, "A", w.goodsA);
        UUID action = w.action("100", "0");
        UUID application = w.allocation(action, p, "100");
        UUID orderItem = w.orderItem("1", application, "100");
        w.planLine(orderItem, w.goodsA, "1", "150");

        assertThat(coverage(w.analysis).get(childA)[0]).isCloseTo(new BigDecimal("100"), within(EPSILON));
    }

    @Test
    void partiallyOrderedSourceCapsOverageCustodyAtItsExactOutputBudget() throws Exception {
        World w = new World(UUID.randomUUID());
        Parent large = w.parent("large", false), small = w.parent("small", false);
        update("UPDATE production_material_analysis_materials SET goods_id=(SELECT goods_id FROM production_material_analysis_materials WHERE id=?) WHERE id=?",large.id(),small.id());
        UUID child = w.child(large,"A",w.goodsA);
        UUID action = w.action("110", "0");
        UUID first = w.allocation(action,small,"10"), last = w.allocation(action,large,"100");
        // Subcontract ordering admits overage on the last source. The material
        // has an original requirement of 200, but this action only commits 100.
        UUID item = w.orderItem("1",first,"10"); w.source(item,last,"150",2);
        w.planLine(item,w.goodsA,"1","160");
        BigDecimal[] actual = coverage(w.analysis).get(child);
        assertThat(actual[0]).isEqualByComparingTo("150");
        var node = new MaterialAnalysisService.BomNode(large.analysisItemId(),child,UUID.randomUUID(),
                w.goodsA,null,UUID.randomUUID(),2,"large/A","large",BigDecimal.ONE,BigDecimal.ONE,BigDecimal.ONE,
                new BigDecimal("200"),"A","A",null,null,"piece",BigDecimal.ZERO,"BUY",false,
                "START","PER_UNIT",BigDecimal.ONE,true,true);
        var formal = new MaterialAnalysisService.FormalMaterialCoverage(child,large.analysisItemId(),"large/A",actual[0],actual[1]);
        var loose = MaterialAnalysisService.planFormalCoverage(java.util.List.of(formal),java.util.List.of(node));
        var tight = MaterialAnalysisService.planFormalCoverage(java.util.List.of(formal),
                java.util.List.of(node.withSnapshotRequiredQty(new BigDecimal("100"))));
        org.junit.jupiter.api.Assertions.assertAll(
                () -> assertThat(actual[1]).isEqualByComparingTo("100"),
                () -> assertThat(loose.securedTotal(large.analysisItemId()+"|large/A")).isEqualByComparingTo("100"),
                () -> assertThat(tight.securedTotal(large.analysisItemId()+"|large/A")).isEqualByComparingTo("100"));
    }

    private Map<UUID, BigDecimal[]> coverage(UUID analysisId) throws SQLException {
        String sql = productionSql().replace(":analysisId", "'" + analysisId + "'::uuid");
        Map<UUID, BigDecimal[]> rows = new LinkedHashMap<>();
        try (var statement = connection.createStatement()) {
            statement.setQueryTimeout(10);
            try (var result = statement.executeQuery(sql)) {
                while (result.next()) {
                    rows.put(UUID.fromString(result.getString(3)),
                            new BigDecimal[]{result.getBigDecimal(6), result.getBigDecimal(7)});
                }
            }
        }
        return rows;
    }

    private static String productionSql() {
        EntityManager em = mock(EntityManager.class);
        Query query = mock(Query.class);
        when(em.createNativeQuery(anyString())).thenReturn(query);
        when(query.setParameter(anyString(), any())).thenReturn(query);
        when(query.getResultList()).thenReturn(java.util.List.of());
        SubcontractComponentCustodyProjection.coverageForAnalysis(em, UUID.randomUUID());
        var sql = ArgumentCaptor.forClass(String.class);
        verify(em).createNativeQuery(sql.capture());
        return sql.getValue();
    }

    private void execute(String sql) throws SQLException {
        try (var statement = connection.createStatement()) {
            statement.execute(sql);
        }
    }

    private void update(String sql, Object... values) throws SQLException {
        try (var statement = connection.prepareStatement(sql)) {
            for (int i = 0; i < values.length; i++) statement.setObject(i + 1, values[i]);
            statement.executeUpdate();
        }
    }

    private record Parent(UUID id, UUID analysisItemId, String nodeKey, boolean root) {}

    /** One analysis; goods identities are shared by siblings so merged orders reuse materials. */
    private final class World {
        final UUID analysis;
        final UUID goodsA;
        final UUID goodsB;
        final UUID unit = UUID.randomUUID();
        final UUID order = UUID.randomUUID();
        final UUID plan = UUID.randomUUID();
        private boolean orderCreated;
        private boolean planCreated;

        World(UUID analysis) {
            this(analysis, UUID.randomUUID(), UUID.randomUUID());
        }

        private World(UUID analysis, UUID goodsA, UUID goodsB) {
            this.analysis = analysis;
            this.goodsA = goodsA;
            this.goodsB = goodsB;
        }

        World sibling(UUID otherAnalysis) {
            return new World(otherAnalysis, goodsA, goodsB);
        }

        Parent parent(String nodeKey, boolean root) throws SQLException {
            UUID id = UUID.randomUUID();
            UUID item = UUID.randomUUID();
            update("INSERT INTO production_material_analysis_materials(id,analysis_id,analysis_item_id,node_key,parent_node_key,node_role,depth,path,goods_id,color_id,active,unit_id) VALUES (?,?,?,?,?,?,?,?,?,NULL,true,?)",
                    id, analysis, item, nodeKey, null, root ? "ROOT_SUPPLY" : "BOM_COMPONENT",
                    root ? 0 : 1, nodeKey, UUID.randomUUID(), unit);
            return new Parent(id, item, nodeKey, root);
        }

        UUID child(Parent parent, String nodeKey, UUID goods) throws SQLException {
            UUID id = UUID.randomUUID();
            String key = parent.nodeKey() + "/" + nodeKey;
            update("INSERT INTO production_material_analysis_materials(id,analysis_id,analysis_item_id,node_key,parent_node_key,node_role,depth,path,goods_id,color_id,active,unit_id) VALUES (?,?,?,?,?,?,?,?,?,NULL,true,?)",
                    id, analysis, parent.analysisItemId(), key, parent.root() ? null : parent.nodeKey(),
                    "BOM_COMPONENT", parent.root() ? 1 : 2, key, goods, unit);
            return id;
        }

        UUID action(String requested, String publicSurplus) throws SQLException {
            UUID id = UUID.randomUUID();
            update("INSERT INTO preplan_supply_actions(id,analysis_id,route,operation_type,status,external_document_type,requested_qty,public_surplus_qty,public_surplus_external_item_id) VALUES (?,?,'SUBCONTRACT','SUPPLY','CREATED','SUBCONTRACT_APPLICATION',?,?,NULL)",
                    id, analysis, new BigDecimal(requested), new BigDecimal(publicSurplus));
            return id;
        }

        UUID allocation(UUID action, Parent parent, String qty) throws SQLException {
            UUID application = UUID.randomUUID();
            allocation(action, parent, qty, application);
            return application;
        }

        void allocation(UUID action, Parent parent, String qty, UUID application) throws SQLException {
            bindActionProduct(action, parent);
            update("INSERT INTO preplan_supply_action_allocations(action_id,analysis_id,analysis_material_id,allocated_qty,external_item_id) VALUES (?,?,?,?,?)",
                    action, analysis, parent.id(), new BigDecimal(qty), application);
        }

        void bindActionProduct(UUID action, Parent parent) throws SQLException {
            update("UPDATE preplan_supply_actions action SET goods_id=parent.goods_id,color_id=parent.color_id,unit_id=parent.unit_id FROM production_material_analysis_materials parent WHERE action.id=? AND parent.id=?",
                    action, parent.id());
        }

        Map<String, Object> sourceSnapshot(Parent parent, String required, int priority) {
            return Map.of("materialLineId", parent.id().toString(), "sourceRequiredQty", required,
                    "allocationPriority", priority, "needDate", "2026-10-30");
        }

        void publicEvent(UUID batch, String type, String delta, List<Map<String, Object>> sources,
                         Map<String, String> requested) throws Exception {
            String intent = new ObjectMapper().writeValueAsString(Map.of("sources", sources,
                    "sourceRequestedQtyByMaterialLineId", requested));
            update("INSERT INTO preplan_aggregate_batch_events(batch_id,event_type,public_delta,intent_snapshot) VALUES (?,?,?,CAST(? AS jsonb))",
                    batch, type, new BigDecimal(delta), intent);
        }

        void publicSurplus(UUID action, UUID application) throws SQLException {
            update("UPDATE preplan_supply_actions SET public_surplus_external_item_id=? WHERE id=?", application, action);
        }

        UUID orderItem(String rate, UUID application, String allocQty) throws SQLException {
            if (!orderCreated) {
                update("INSERT INTO subcontract_orders VALUES (?,1,false)", order);
                orderCreated = true;
            }
            UUID item = UUID.randomUUID();
            update("INSERT INTO subcontract_order_items VALUES (?,?,?,0,false)", item, order, new BigDecimal(rate));
            source(item, application, allocQty, 1);
            return item;
        }

        void source(UUID orderItem, UUID application, String allocQty, int lineNo) throws SQLException {
            update("INSERT INTO subcontract_order_item_sources(order_item_id,application_item_id,alloc_qty,line_no) VALUES (?,?,?,?)",
                    orderItem, application, new BigDecimal(allocQty), lineNo);
        }

        UUID planLine(UUID orderItem, UUID goods, String bomUnitQty, String issued) throws SQLException {
            if (!planCreated) {
                update("INSERT INTO subcontract_material_plans VALUES (?,'OPEN',false)", plan);
                planCreated = true;
            }
            UUID line = UUID.randomUUID();
            update("INSERT INTO subcontract_material_plan_items VALUES (?,?,?,?,NULL,?,?,false)",
                    line, plan, orderItem, goods, new BigDecimal(bomUnitQty), new BigDecimal(issued));
            return line;
        }

        void draft(UUID planLine, String qty) throws SQLException {
            UUID issue = UUID.randomUUID();
            update("INSERT INTO subcontract_material_issues VALUES (?,0,false)", issue);
            update("INSERT INTO subcontract_material_issue_items(issue_id,plan_item_id,qty) VALUES (?,?,?)",
                    issue, planLine, new BigDecimal(qty));
        }

        void handoff(UUID planLine, Parent parent, UUID child, String qty) throws SQLException {
            UUID target = UUID.randomUUID();
            update("INSERT INTO stock_reservations(id,qty) VALUES (?,?)", target, new BigDecimal(qty));
            update("INSERT INTO subcontract_component_stock_handoffs(plan_item_id,parent_material_id,child_material_id,source_reservation_id,target_reservation_id,qty) VALUES (?,?,?,?,?,?)",
                    planLine, parent.id(), child, UUID.randomUUID(), target, new BigDecimal(qty));
        }

        void stockedReceipt(UUID orderItem, String qty) throws SQLException {
            UUID receipt = UUID.randomUUID();
            UUID item = UUID.randomUUID();
            update("INSERT INTO subcontract_receipts VALUES (?,1,false)", receipt);
            update("INSERT INTO subcontract_receipt_items VALUES (?,?,?,?,1,false)", item, receipt, orderItem, new BigDecimal(qty));
            update("INSERT INTO procurement_inspection_items(receipt_type,receipt_item_id,status,warehouse_stocked_base_qty) VALUES ('SUBCONTRACT',?,'RESOLVED',?)",
                    item, new BigDecimal(qty));
        }
    }
}
