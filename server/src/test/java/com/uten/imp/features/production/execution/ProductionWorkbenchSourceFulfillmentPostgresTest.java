package com.uten.imp.features.production.execution;

import com.uten.imp.support.MigratedProjectionSchema;
import com.uten.imp.support.MigratedSchemaBaseline;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.SingleConnectionDataSource;

import java.math.BigDecimal;
import java.nio.file.Files;
import java.nio.file.Path;
import java.sql.Connection;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;

/** Runs the real forward views over exact migrated column shapes. Projection
 * fixtures intentionally omit write triggers; full-chain tests own those guards. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class ProductionWorkbenchSourceFulfillmentPostgresTest {
    @Test
    void qualifiedStockWithoutWorkOrderDoesNotKeepEightCompletedProductsPending() throws Exception {
        try (Fixture fixture = fixture()) {
            for (int i = 0; i < 8; i++) fixture.completedMakeProduct();
            UUID stockProduct = fixture.product("10", "0", "0", "10", "BUY");
            assertThat(fixture.remainingSchedule()).isEqualByComparingTo("0");
            assertThat(fixture.remainingFulfillment()).isEqualByComparingTo("0");
            assertThat(fixture.activeRoots()).isZero();

            // Losing the actual stock handoff reopens a genuine source gap even
            // though all eight represented work orders are still completed.
            fixture.db.update("UPDATE production_material_analysis_items SET root_fulfilled_qty=0 WHERE id=?", stockProduct);
            assertThat(fixture.remainingSchedule()).isEqualByComparingTo("10");
            assertThat(fixture.status()).isEqualTo("PARTIALLY_SCHEDULED");
            assertThat(fixture.db.queryForObject("SELECT completed_count FROM v_production_execution_workbench_roots", Integer.class)).isEqualTo(8);
        }
    }

    @Test
    void purchaseOnlyBatchWaitsForQualifiedOutputAndLeavesActiveListAfterFulfillment() throws Exception {
        try (Fixture fixture = fixture()) {
            UUID first = fixture.product("10", "0", "0", "0", "BUY");
            UUID second = fixture.product("10", "0", "0", "0", "SUBCONTRACT");
            fixture.supply(first, "10", "BUY");
            fixture.supply(second, "10", "SUBCONTRACT");
            assertThat(fixture.status()).isEqualTo("PREPARING");
            assertThat(fixture.remainingSchedule()).isEqualByComparingTo("0");
            assertThat(fixture.remainingFulfillment()).isEqualByComparingTo("20");
            assertThat(fixture.db.queryForObject("SELECT segment_count FROM v_production_execution_workbench_roots", Integer.class)).isZero();

            // Document completion alone cannot manufacture physical fulfillment.
            fixture.db.update("UPDATE preplan_supply_actions SET status='DONE'");
            assertThat(fixture.activeRoots()).isEqualTo(1);
            assertThat(fixture.remainingFulfillment()).isEqualByComparingTo("20");

            fixture.db.update("UPDATE production_material_analysis_items SET root_fulfilled_qty=10");
            assertThat(fixture.activeRoots()).isZero();
            assertThat(fixture.remainingFulfillment()).isEqualByComparingTo("0");

            // Exact source reversal reopens only that product, with no work order.
            fixture.db.update("UPDATE production_material_analysis_items SET root_fulfilled_qty=0 WHERE id=?", first);
            assertThat(fixture.activeRoots()).isEqualTo(1);
            assertThat(fixture.remainingSchedule()).isEqualByComparingTo("10");
            assertThat(fixture.remainingFulfillment()).isEqualByComparingTo("10");
        }
    }

    @Test
    void partialSupplyAndSubmittedPlansRemainArrangedWithoutConcealingActualGaps() throws Exception {
        try (Fixture fixture = fixture()) {
            UUID product = fixture.product("10", "0", "0", "0", "BUY");
            fixture.supply(product, "6", "BUY");
            assertThat(fixture.status()).isEqualTo("PARTIALLY_SCHEDULED");
            assertThat(fixture.remainingSchedule()).isEqualByComparingTo("4");
            assertThat(fixture.remainingFulfillment()).isEqualByComparingTo("10");
            fixture.db.update("UPDATE preplan_supply_actions SET status='CANCELLED'");
            assertThat(fixture.remainingSchedule()).isEqualByComparingTo("10");

            fixture.db.update("UPDATE production_material_analysis_items SET submitted_qty=4,approved_qty=3,root_fulfilled_qty=2 WHERE id=?", product);
            assertThat(fixture.remainingSchedule()).isEqualByComparingTo("1");
            assertThat(fixture.remainingFulfillment()).isEqualByComparingTo("8");
        }
    }

    @Test
    void existingMakeAnchorCountsActualParentStockAndNeverPublicSimulationOrItsOwnOutputTwice() throws Exception {
        try (Fixture fixture = fixture()) {
            UUID parentItem = fixture.product("10", "0", "10", "0", "MAKE");
            UUID component = fixture.product("10", "0", "4", "0", "MAKE");
            UUID componentMaterial = UUID.randomUUID(), parentPlan = UUID.randomUUID(), childPlan = UUID.randomUUID();
            UUID demand = UUID.randomUUID(), reservation = UUID.randomUUID();
            UUID goods = fixture.db.queryForObject("SELECT goods_id FROM production_material_analysis_items WHERE id=?", UUID.class, component);
            fixture.db.update("INSERT INTO production_material_analysis_materials(id,analysis_id,analysis_item_id,goods_id,unit_id,depth,active,allocated_available_qty) VALUES(?,?,?,?,?,1,TRUE,10)",
                    componentMaterial, fixture.analysis, parentItem, goods, fixture.unit);
            fixture.db.update("UPDATE production_material_analysis_items SET source_type='MAKE_COMPONENT',root_material_id=NULL,parent_analysis_material_id=? WHERE id=?", componentMaterial, component);
            // A simulated fully allocated public pool has no formal entitlement.
            assertThat(fixture.db.queryForObject("SELECT remaining_schedule_qty FROM v_production_analysis_workbench_item_progress WHERE analysis_item_id=?", BigDecimal.class, component)).isEqualByComparingTo("6");

            for (Object[] plan : new Object[][]{{parentPlan, parentItem, 10}, {childPlan, component, 4}}) {
                fixture.db.update("INSERT INTO production_plans(id,material_analysis_id,material_analysis_item_id,status,is_deleted,is_closed,is_stopped,is_canceled) VALUES(?,?,?,1,FALSE,FALSE,FALSE,FALSE)", plan[0], fixture.analysis, plan[1]);
                fixture.db.update("INSERT INTO production_plan_items(id,plan_id,qty,iqty,is_deleted) VALUES(?,?,?,0,FALSE)", UUID.randomUUID(), plan[0], plan[2]);
                fixture.link((UUID) plan[0], (UUID) plan[1], ((Number) plan[2]).intValue());
            }
            fixture.db.update("INSERT INTO production_material_demands(id,plan_id,goods_id,unit_id,status,is_deleted) VALUES(?,?,?,?,'FULFILLED',FALSE)", demand, parentPlan, goods, fixture.unit);
            fixture.db.update("INSERT INTO stock_reservations(id,demand_id,owner_type,qty,consumed_qty,released_qty,requires_qualified_origin,is_deleted) VALUES(?,?,'PRODUCTION_MATERIAL_DEMAND',6,0,0,FALSE,FALSE)", reservation, demand);
            assertThat(fixture.db.queryForObject("SELECT remaining_schedule_qty FROM v_production_analysis_workbench_item_progress WHERE analysis_item_id=?", BigDecimal.class, component)).isEqualByComparingTo("0");
            assertThat(fixture.db.queryForObject("SELECT remaining_fulfillment_qty FROM v_production_analysis_workbench_item_progress WHERE analysis_item_id=?", BigDecimal.class, component)).isEqualByComparingTo("4");

            fixture.db.update("UPDATE production_plan_items SET iqty=qty");
            for (UUID planItem : fixture.db.queryForList("SELECT id FROM production_plan_items", UUID.class)) fixture.receive(planItem, fixture.db.queryForObject("SELECT qty FROM production_plan_items WHERE id=?", BigDecimal.class, planItem), false);
            assertThat(fixture.activeRoots()).isZero();
            assertThat(fixture.db.queryForObject("SELECT fn_material_analysis_fulfillment_status(?)", String.class, fixture.analysis)).isEqualTo("COMPLETED");
            fixture.db.update("UPDATE stock_reservations SET consumed_qty=6 WHERE id=?", reservation);
            assertThat(fixture.activeRoots()).isZero(); // genuine material use does not undo fulfilled supply
            fixture.db.update("UPDATE stock_reservations SET consumed_qty=0,released_qty=1 WHERE id=?", reservation);
            assertThat(fixture.remainingSchedule()).isEqualByComparingTo("1");
            assertThat(fixture.remainingFulfillment()).isEqualByComparingTo("1");
            assertThat(fixture.db.queryForObject("SELECT fn_material_analysis_fulfillment_status(?)", String.class, fixture.analysis)).isNotEqualTo("COMPLETED");
        }
    }

    @Test
    void exactClaimedPublicMakePromiseIsArrangedButNotCompletedAndCancellationReopensOnlyItsShare() throws Exception {
        try (Fixture fixture = fixture()) {
            UUID item = fixture.product("10", "0", "0", "0", "BUY"), claim = UUID.randomUUID();
            UUID root = fixture.db.queryForObject("SELECT root_material_id FROM production_material_analysis_items WHERE id=?", UUID.class, item);
            fixture.db.update("INSERT INTO preplan_make_public_claims(id,source_plan_item_id,target_analysis_id,target_material_id,qty) VALUES(?,?,?,?,10)", claim, UUID.randomUUID(), fixture.analysis, root);
            assertThat(fixture.remainingSchedule()).isEqualByComparingTo("0");
            assertThat(fixture.remainingFulfillment()).isEqualByComparingTo("10");
            assertThat(fixture.status()).isEqualTo("PREPARING");
            assertThat(fixture.db.queryForObject("SELECT fn_material_analysis_fulfillment_status(?)", String.class, fixture.analysis)).isNotEqualTo("COMPLETED");
            fixture.db.update("INSERT INTO preplan_make_public_claim_cancellations(id,claim_id,qty) VALUES(?,?,3)", UUID.randomUUID(), claim);
            assertThat(fixture.remainingSchedule()).isEqualByComparingTo("3");
            assertThat(fixture.status()).isEqualTo("PARTIALLY_SCHEDULED");
        }
    }

    @Test
    void normalWarehouseOwnOutputAndMixedTargetDoNotCreditChildInboundTwice() throws Exception {
        try (Fixture fixture = fixture()) {
            UUID parentItem = fixture.product("8", "0", "8", "0", "MAKE");
            UUID component = fixture.product("8", "0", "4", "0", "MAKE");
            UUID material = UUID.randomUUID(), parentPlan = UUID.randomUUID(), childPlan = UUID.randomUUID();
            UUID demand = UUID.randomUUID(), target = UUID.randomUUID(), origin = UUID.randomUUID(), exact = UUID.randomUUID();
            UUID goods = fixture.db.queryForObject("SELECT goods_id FROM production_material_analysis_items WHERE id=?", UUID.class, component);
            fixture.db.update("INSERT INTO production_material_analysis_materials(id,analysis_id,analysis_item_id,goods_id,unit_id,depth,active) VALUES(?,?,?,?,?,1,TRUE)", material, fixture.analysis, parentItem, goods, fixture.unit);
            fixture.db.update("UPDATE production_material_analysis_items SET source_type='MAKE_COMPONENT',root_material_id=NULL,parent_analysis_material_id=? WHERE id=?", material, component);
            for (Object[] plan : new Object[][]{{parentPlan, parentItem, 8}, {childPlan, component, 4}}) {
                fixture.db.update("INSERT INTO production_plans(id,material_analysis_id,material_analysis_item_id,status,is_deleted,is_closed,is_stopped,is_canceled) VALUES(?,?,?,1,FALSE,FALSE,FALSE,FALSE)", plan[0], fixture.analysis, plan[1]);
                fixture.db.update("INSERT INTO production_plan_items(id,plan_id,qty,iqty,is_deleted) VALUES(?,?,?,?,FALSE)", UUID.randomUUID(), plan[0], plan[2], plan[2]);
                fixture.link((UUID) plan[0], (UUID) plan[1], ((Number) plan[2]).intValue());
            }
            for (UUID planItem : fixture.db.queryForList("SELECT id FROM production_plan_items", UUID.class)) fixture.receive(planItem, fixture.db.queryForObject("SELECT qty FROM production_plan_items WHERE id=?", BigDecimal.class, planItem), false);
            fixture.db.update("INSERT INTO production_material_demands(id,plan_id,goods_id,unit_id,status,is_deleted) VALUES(?,?,?,?,'FULFILLED',FALSE)", demand, parentPlan, goods, fixture.unit);
            fixture.db.update("INSERT INTO stock_reservations(id,demand_id,owner_type,qty,consumed_qty,released_qty,requires_qualified_origin,is_deleted) VALUES(?,?,'PRODUCTION_MATERIAL_DEMAND',4,0,0,FALSE,FALSE)", target, demand);
            fixture.db.update("INSERT INTO preplan_analysis_stock_exact_pegs(id,stock_reservation_id,make_source_analysis_item_id,qty) VALUES(?,?,?,4)", exact, origin, component);
            fixture.db.update("INSERT INTO preplan_stock_entitlement_events(id,event_type,stock_reservation_id,target_stock_reservation_id,beneficiary_analysis_id,beneficiary_analysis_material_id,qty) VALUES(?,'FORMALIZE',?,?,?,?,4)", UUID.randomUUID(), origin, target, fixture.analysis, material);
            assertThat(fixture.remainingSchedule()).isEqualByComparingTo("4");
            assertThat(fixture.remainingFulfillment()).isEqualByComparingTo("4");
            assertThat(fixture.activeRoots()).isEqualTo(1);

            // One normal target now contains 4 exact own output + 2 real public
            // stock. Its FALSE marker is a warehouse-boundary flag, not a claim
            // that the entire target came from public stock.
            fixture.db.update("UPDATE stock_reservations SET qty=6 WHERE id=?", target);
            assertThat(fixture.remainingSchedule()).isEqualByComparingTo("2");
            assertThat(fixture.remainingFulfillment()).isEqualByComparingTo("2");
            assertThat(fixture.db.queryForObject("SELECT fn_material_analysis_fulfillment_status(?)", String.class, fixture.analysis)).isNotEqualTo("COMPLETED");
        }
    }

    @Test
    void publicReceiptBeforePrivateOutputDoesNotFulfillSourceAndPrivateBudgetCapsRealReceipts() throws Exception {
        try (Fixture fixture = fixture()) {
            UUID item = fixture.product("8", "0", "4", "0", "MAKE"), plan = UUID.randomUUID(), planItem = UUID.randomUUID();
            fixture.db.update("INSERT INTO production_plans(id,material_analysis_id,material_analysis_item_id,status,is_deleted,is_closed,is_stopped,is_canceled) VALUES(?,?,?,1,FALSE,FALSE,FALSE,FALSE)", plan, fixture.analysis, item);
            fixture.db.update("INSERT INTO production_plan_items(id,plan_id,qty,iqty,unit_rate,is_deleted) VALUES(?,?,6,2,2,FALSE)", planItem, plan);
            fixture.link(plan, item, 4);
            fixture.db.update("UPDATE production_material_analysis_plan_links SET public_surplus_qty=2 WHERE plan_id=?", plan);
            fixture.receive(planItem, new BigDecimal("2"), true);
            assertThat(fixture.remainingSchedule()).isEqualByComparingTo("4");
            assertThat(fixture.remainingFulfillment()).isEqualByComparingTo("8");

            UUID privateReceipt = fixture.receive(planItem, new BigDecimal("4"), false);
            fixture.db.update("UPDATE production_plan_items SET iqty=6 WHERE id=?", planItem);
            assertThat(fixture.remainingFulfillment()).isEqualByComparingTo("4");
            assertThat(fixture.remainingSchedule()).isEqualByComparingTo("4");
            // Legacy non-explicit receipts above the frozen private budget are
            // public supply by V722, and cannot fulfill this source again.
            UUID extra = fixture.receive(planItem, BigDecimal.ONE, false);
            assertThat(fixture.remainingFulfillment()).isEqualByComparingTo("4");
            fixture.db.update("UPDATE stock_documents SET status=-1 WHERE id IN (?,?)", privateReceipt, extra);
            assertThat(fixture.remainingFulfillment()).isEqualByComparingTo("8");
            // Total iqty remains six in this deliberately inconsistent projection;
            // the receipt lineage, ownership and approval state remain authoritative.
            assertThat(fixture.db.queryForObject("SELECT fn_material_analysis_fulfillment_status(?)", String.class, fixture.analysis)).isNotEqualTo("COMPLETED");
        }
    }

    private static Fixture fixture() throws Exception {
        var lease = MigratedSchemaBaseline.openDatabase("workbench_source_fulfillment");
        Connection connection = lease.openConnection();
        try {
            connection.setAutoCommit(false);
            var db = new JdbcTemplate(new SingleConnectionDataSource(connection, true));
            db.execute("CREATE SCHEMA workbench_source_fixture");
            db.execute("SET LOCAL search_path=workbench_source_fixture,public");
            MigratedProjectionSchema.copyEmptyTablesFromMigratedCatalog(connection,
                    "employees", "production_material_analyses", "production_material_analysis_items",
                    "production_material_analysis_materials", "production_plans", "production_plan_items",
                    "production_material_analysis_plan_links", "stock_documents", "stock_document_items",
                    "production_daily_report_items", "production_execution_segments", "plan_order_item_links",
                    "subplan_links", "preplan_supply_actions", "preplan_supply_action_allocations",
                    "preplan_root_output_events", "preplan_analysis_stock_exact_pegs",
                    "stock_reservations", "production_material_demands", "preplan_stock_entitlement_events",
                    "v_preplan_stock_entitlement_beneficiary_balance",
                    "preplan_make_public_claims", "preplan_make_public_claim_cancellations",
                    "preplan_aggregate_batches",
                    "v_production_execution_workbench_segments", "execution_segment_sales_allocations",
                    "sales_order_items", "sales_orders", "goods", "units", "colors");
            Path direct = Path.of("src/main/resources/db/migration/V864__production_workbench_source_fulfillment_progress.sql");
            db.execute(Files.readString(Files.exists(direct) ? direct : Path.of("server").resolve(direct)));
            return new Fixture(lease, connection, db);
        } catch (Exception failure) {
            connection.close();
            lease.close();
            throw failure;
        }
    }

    private static final class Fixture implements AutoCloseable {
        private final MigratedSchemaBaseline.ScopedDatabase lease;
        private final Connection connection;
        private final JdbcTemplate db;
        private final UUID analysis = UUID.randomUUID(), employee = UUID.randomUUID(), unit = UUID.randomUUID();

        private Fixture(MigratedSchemaBaseline.ScopedDatabase lease, Connection connection, JdbcTemplate db) {
            this.lease = lease;
            this.connection = connection;
            this.db = db;
            db.update("INSERT INTO employees(id,full_name) VALUES(?,'planner')", employee);
            db.update("INSERT INTO units(id,name) VALUES(?,'piece')", unit);
            db.update("INSERT INTO production_material_analyses(id,maker_id,status,is_deleted) VALUES(?,?,'ACTIVE',FALSE)", analysis, employee);
        }

        private UUID product(String requested, String submitted, String approved, String fulfilled, String route) {
            UUID item = UUID.randomUUID(), root = UUID.randomUUID(), goods = UUID.randomUUID();
            db.update("INSERT INTO goods(id,code,name) VALUES(?,?,?)", goods, goods.toString(), "product");
            db.update("INSERT INTO production_material_analysis_items(id,analysis_id,goods_id,unit_id,source_type,requested_qty,submitted_qty,approved_qty,root_fulfilled_qty,root_material_id,is_deleted) VALUES(?,?,?,?,'STOCK',?,?,?,?,?,FALSE)",
                    item, analysis, goods, unit, new BigDecimal(requested), new BigDecimal(submitted), new BigDecimal(approved), new BigDecimal(fulfilled), root);
            db.update("INSERT INTO production_material_analysis_materials(id,analysis_id,analysis_item_id,per_product_qty,confirmed_route,active) VALUES(?,?,?,1,?,TRUE)", root, analysis, item, route);
            return item;
        }

        private void completedMakeProduct() {
            UUID item = product("10", "0", "10", "0", "MAKE"), plan = UUID.randomUUID();
            UUID goods = db.queryForObject("SELECT goods_id FROM production_material_analysis_items WHERE id=?", UUID.class, item);
            db.update("INSERT INTO production_plans(id,maker_id,material_analysis_id,material_analysis_item_id,status,is_deleted,is_closed,is_stopped,is_canceled) VALUES(?,?,?,?,1,FALSE,FALSE,FALSE,FALSE)", plan, employee, analysis, item);
            db.update("INSERT INTO production_plan_items(id,plan_id,goods_id,unit_id,qty,iqty,is_deleted) VALUES(?,?,?,?,10,10,FALSE)", UUID.randomUUID(), plan, goods, unit);
            link(plan, item, 10);
            receive(db.queryForObject("SELECT id FROM production_plan_items WHERE plan_id=?", UUID.class, plan), BigDecimal.TEN, false);
            db.update("INSERT INTO v_production_execution_workbench_segments(segment_id,plan_id,root_type,root_id,segment_status,product_goods_id,product_code,product_name,product_unit_name,planned_qty,planned_inbound_qty,inbound_qty,reported_qty) VALUES(?,?,'ANALYSIS',?,'COMPLETED',?,?,?,'piece',10,10,10,10)",
                    UUID.randomUUID(), plan, analysis, goods, goods.toString(), "made product");
        }

        private void supply(UUID item, String qty, String route) {
            UUID action = UUID.randomUUID();
            UUID root = db.queryForObject("SELECT root_material_id FROM production_material_analysis_items WHERE id=?", UUID.class, item);
            db.update("INSERT INTO preplan_supply_actions(id,analysis_id,route,status,operation_type,external_document_type) VALUES(?,?,?,'CREATED','SUPPLY',?)",
                    action, analysis, route, "BUY".equals(route) ? "PURCHASE_REQUEST" : "SUBCONTRACT_APPLICATION");
            db.update("INSERT INTO preplan_supply_action_allocations(id,analysis_id,action_id,analysis_material_id,allocated_qty) VALUES(?,?,?,?,?)", UUID.randomUUID(), analysis, action, root, new BigDecimal(qty));
        }

        private void link(UUID plan, UUID item, int privateQty) {
            db.update("INSERT INTO production_material_analysis_plan_links(id,plan_id,analysis_id,analysis_item_id,submitted_qty,public_surplus_qty,allocation_status) VALUES(?,?,?,?,?,0,'APPROVED')",
                    UUID.randomUUID(), plan, analysis, item, privateQty);
        }

        private UUID receive(UUID planItem, BigDecimal qty, boolean publicOutput) {
            UUID document = UUID.randomUUID(), stockItem = UUID.randomUUID(), reportItem = UUID.randomUUID(), segment = UUID.randomUUID();
            BigDecimal rate = db.queryForObject("SELECT COALESCE(unit_rate,1) FROM production_plan_items WHERE id=?", BigDecimal.class, planItem);
            db.update("INSERT INTO stock_documents(id,doc_type,status,is_deleted) VALUES(?,'FINISHED_IN',1,FALSE)", document);
            db.update("INSERT INTO production_daily_report_items(id,plan_item_id,execution_segment_id,is_public_output) VALUES(?,?,?,?)", reportItem, planItem, segment, publicOutput);
            db.update("INSERT INTO stock_document_items(id,doc_id,upstream_item_id,bill_type,qty,base_qty,unit_rate,is_deleted,source_daily_report_item_id,execution_segment_id) VALUES(?,?,?,'FINISHED_IN',?,?,?,FALSE,?,?)",
                    stockItem, document, planItem, qty, qty.multiply(rate), rate, reportItem, segment);
            return document;
        }

        private BigDecimal remainingSchedule() {
            return db.queryForObject("SELECT SUM(remaining_schedule_qty) FROM v_production_analysis_workbench_item_progress", BigDecimal.class);
        }

        private BigDecimal remainingFulfillment() {
            return db.queryForObject("SELECT SUM(remaining_fulfillment_qty) FROM v_production_analysis_workbench_item_progress", BigDecimal.class);
        }

        private int activeRoots() {
            return db.queryForObject("SELECT COUNT(*) FROM v_production_execution_workbench_roots", Integer.class);
        }

        private String status() {
            return db.queryForObject("SELECT status FROM v_production_execution_workbench_roots", String.class);
        }

        @Override public void close() throws Exception {
            connection.rollback();
            connection.close();
            lease.close();
        }
    }
}
