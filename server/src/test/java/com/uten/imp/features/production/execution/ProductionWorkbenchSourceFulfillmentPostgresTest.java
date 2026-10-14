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
            fixture.db.update("INSERT INTO production_material_analysis_materials(id,analysis_id,analysis_item_id,goods_id,unit_id,depth,required_qty,active,allocated_available_qty) VALUES(?,?,?,?,?,1,10,TRUE,10)",
                    componentMaterial, fixture.analysis, parentItem, goods, fixture.unit);
            fixture.db.update("UPDATE production_material_analysis_items SET source_type='MAKE_COMPONENT',root_material_id=NULL,parent_analysis_material_id=? WHERE id=?", componentMaterial, component);
            // A simulated fully allocated public pool has no formal entitlement.
            assertThat(fixture.db.queryForObject("SELECT remaining_schedule_qty FROM v_production_analysis_workbench_item_progress WHERE analysis_item_id=?", BigDecimal.class, component)).isEqualByComparingTo("6");

            for (Object[] plan : new Object[][]{{parentPlan, parentItem, 10}, {childPlan, component, 4}}) {
                fixture.db.update("INSERT INTO production_plans(id,material_analysis_id,material_analysis_item_id,status,is_deleted,is_closed,is_stopped,is_canceled) VALUES(?,?,?,1,FALSE,FALSE,FALSE,FALSE)", plan[0], fixture.analysis, plan[1]);
                fixture.db.update("INSERT INTO production_plan_items(id,plan_id,qty,iqty,is_deleted) VALUES(?,?,?,0,FALSE)", UUID.randomUUID(), plan[0], plan[2]);
                fixture.link((UUID) plan[0], (UUID) plan[1], ((Number) plan[2]).intValue());
            }
            fixture.db.update("INSERT INTO production_material_demands(id,plan_id,goods_id,unit_id,required_qty,status,is_deleted) VALUES(?,?,?,?,10,'FULFILLED',FALSE)", demand, parentPlan, goods, fixture.unit);
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
    void stockAlreadyNettedFromChildQuotaCannotFulfillTheChildAgain() throws Exception {
        try (Fixture fixture = fixture()) {
            UUID parentItem = fixture.product("10", "0", "10", "0", "MAKE");
            UUID component = fixture.product("2", "0", "0", "0", "MAKE");
            UUID material = UUID.randomUUID(), parentPlan = UUID.randomUUID();
            UUID demand = UUID.randomUUID(), reservation = UUID.randomUUID();
            UUID goods = fixture.db.queryForObject("SELECT goods_id FROM production_material_analysis_items WHERE id=?", UUID.class, component);
            fixture.db.update("INSERT INTO production_material_analysis_materials(id,analysis_id,analysis_item_id,goods_id,unit_id,depth,required_qty,active,allocated_available_qty) VALUES(?,?,?,?,?,1,10,TRUE,8)",
                    material, fixture.analysis, parentItem, goods, fixture.unit);
            fixture.db.update("UPDATE production_material_analysis_items SET source_type='MAKE_COMPONENT',root_material_id=NULL,parent_analysis_material_id=? WHERE id=?", material, component);
            fixture.db.update("INSERT INTO production_plans(id,material_analysis_id,material_analysis_item_id,status,is_deleted,is_closed,is_stopped,is_canceled) VALUES(?,?,?,1,FALSE,FALSE,FALSE,FALSE)", parentPlan, fixture.analysis, parentItem);
            fixture.db.update("INSERT INTO production_material_demands(id,plan_id,goods_id,unit_id,required_qty,status,is_deleted) VALUES(?,?,?,?,10,'FULFILLED',FALSE)", demand, parentPlan, goods, fixture.unit);
            fixture.db.update("INSERT INTO stock_reservations(id,demand_id,owner_type,qty,consumed_qty,released_qty,requires_qualified_origin,is_deleted) VALUES(?,?,'PRODUCTION_MATERIAL_DEMAND',8,0,0,FALSE,FALSE)", reservation, demand);

            // The existing eight pieces already reduced the new MAKE_COMPONENT
            // responsibility from ten to two; formalizing them is not new output.
            assertThat(fixture.db.queryForObject("SELECT remaining_schedule_qty FROM v_production_analysis_workbench_item_progress WHERE analysis_item_id=?", BigDecimal.class, component)).isEqualByComparingTo("2");
            assertThat(fixture.db.queryForObject("SELECT remaining_fulfillment_qty FROM v_production_analysis_workbench_item_progress WHERE analysis_item_id=?", BigDecimal.class, component)).isEqualByComparingTo("2");
            fixture.db.update("UPDATE stock_reservations SET qty=10 WHERE id=?", reservation);
            assertThat(fixture.db.queryForObject("SELECT remaining_fulfillment_qty FROM v_production_analysis_workbench_item_progress WHERE analysis_item_id=?", BigDecimal.class, component)).isEqualByComparingTo("0");
            fixture.db.update("UPDATE stock_reservations SET released_qty=2 WHERE id=?", reservation);
            assertThat(fixture.db.queryForObject("SELECT remaining_fulfillment_qty FROM v_production_analysis_workbench_item_progress WHERE analysis_item_id=?", BigDecimal.class, component)).isEqualByComparingTo("2");
        }
    }

    @Test
    void pendingSupplyAlreadyNettedFromChildQuotaDoesNotArrangeItAgain() throws Exception {
        try (Fixture fixture = fixture()) {
            UUID parent = fixture.product("10", "0", "10", "0", "MAKE");
            Component child = fixture.component(parent, "2", "10", "component", null);
            UUID action = fixture.supplyMaterial(child.material(), "8");
            assertThat(fixture.schedule(child.item())).isEqualByComparingTo("2");
            assertThat(fixture.fulfillment(child.item())).isEqualByComparingTo("2");
            fixture.db.update("UPDATE preplan_supply_action_allocations SET allocated_qty=10 WHERE action_id=?", action);
            assertThat(fixture.schedule(child.item())).isEqualByComparingTo("0");
            assertThat(fixture.fulfillment(child.item())).isEqualByComparingTo("2");
            fixture.db.update("UPDATE preplan_supply_actions SET status='CANCELLED' WHERE id=?", action);
            assertThat(fixture.schedule(child.item())).isEqualByComparingTo("2");
        }
    }

    @Test
    void nestedCompletedAndRemainingFrozenBatchesRetainGrossResponsibilityAfterLiveRequirementShrinks() throws Exception {
        try (Fixture fixture = fixture()) {
            UUID outer = fixture.product("10", "0", "10", "0", "MAKE");
            Component parent = fixture.component(outer, "10", "10", "parent", null);
            Component child = fixture.component(outer, "2", "2", "parent/child", null);
            fixture.db.update("UPDATE production_material_analysis_materials SET depth=2,parent_node_key='parent' WHERE id=?", child.material());
            UUID plan = fixture.plan(parent.item(), "10");
            UUID completed = fixture.demand(plan, child.goods(), "8", "8", "FULFILLED");
            UUID remaining = fixture.demand(plan, child.goods(), "2", "2", "OPEN");
            fixture.demand(plan, child.goods(), "10", "10", "RELEASED");
            UUID initial = fixture.reserve(completed, "8");
            fixture.db.update("UPDATE stock_reservations SET consumed_qty=8 WHERE id=?", initial);

            // The refreshed original C node describes only B's last two pieces;
            // the fulfilled 8 + open 2 frozen demands still belong to this child.
            assertThat(fixture.db.queryForObject("SELECT SUM(qty) FROM v_production_workbench_frozen_material_scopes WHERE material_id=?", BigDecimal.class, child.material())).isEqualByComparingTo("10");
            assertThat(fixture.schedule(child.item())).isEqualByComparingTo("2");
            assertThat(fixture.fulfillment(child.item())).isEqualByComparingTo("2");
            UUID extra = fixture.reserve(remaining, "2");
            assertThat(fixture.fulfillment(child.item())).isEqualByComparingTo("0");
            fixture.db.update("UPDATE stock_reservations SET released_qty=2 WHERE id=?", extra);
            assertThat(fixture.fulfillment(child.item())).isEqualByComparingTo("2");
            // A reversed/cancelled source cannot lend frozen demand or stock to
            // an unrelated current task merely because its material SKU matches.
            fixture.db.update("UPDATE production_plans SET is_canceled=TRUE WHERE id=?", plan);
            assertThat(fixture.fulfillment(child.item())).isEqualByComparingTo("2");
        }
    }

    @Test
    void oneFormalDemandPoolIsSplitOnceAcrossSameDimensionSiblingPaths() throws Exception {
        try (Fixture fixture = fixture()) {
            UUID parent = fixture.product("5", "0", "5", "0", "MAKE");
            Component first = fixture.component(parent, "5", "5", "a", null);
            Component second = fixture.component(parent, "5", "5", "b", first.goods());
            UUID plan = fixture.plan(parent, "5");
            UUID demand = fixture.demand(plan, first.goods(), "10", "5", "ALLOCATED");
            UUID reservation = fixture.reserve(demand, "8");
            assertThat(fixture.db.queryForObject("SELECT SUM(qty) FROM v_production_workbench_frozen_material_scopes WHERE demand_id=?", BigDecimal.class, demand)).isEqualByComparingTo("10");
            assertThat(fixture.fulfillment(first.item())).isEqualByComparingTo("0");
            assertThat(fixture.fulfillment(second.item())).isEqualByComparingTo("2");
            assertThat(fixture.schedule(first.item()).add(fixture.schedule(second.item()))).isEqualByComparingTo("2");

            fixture.db.update("UPDATE stock_reservations SET qty=10 WHERE id=?", reservation);
            assertThat(fixture.fulfillment(first.item()).add(fixture.fulfillment(second.item()))).isEqualByComparingTo("0");
            fixture.db.update("UPDATE stock_reservations SET released_qty=3 WHERE id=?", reservation);
            assertThat(fixture.fulfillment(first.item())).isEqualByComparingTo("0");
            assertThat(fixture.fulfillment(second.item())).isEqualByComparingTo("3");
            fixture.db.update("UPDATE production_material_demands SET status='REVERSED',released_qty=required_qty WHERE id=?", demand);
            assertThat(fixture.fulfillment(first.item()).add(fixture.fulfillment(second.item()))).isEqualByComparingTo("10");
        }
    }

    @Test
    void historicalMakeActionUsesItsExactMemberSetAndDoesNotTakeUnrelatedSameSkuSupply() throws Exception {
        try (Fixture fixture = fixture()) {
            UUID parent = fixture.product("5", "0", "5", "0", "MAKE");
            Component first = fixture.component(parent, "2", "5", "a", null);
            Component member = fixture.component(parent, "1", "5", "b", first.goods());
            Component unrelated = fixture.component(parent, "1", "5", "c", first.goods());
            fixture.db.update("UPDATE production_material_analysis_items SET is_deleted=TRUE WHERE id IN (?,?)", member.item(), unrelated.item());
            UUID action = UUID.randomUUID();
            fixture.db.update("INSERT INTO preplan_supply_actions(id,analysis_id,route,status,operation_type,external_document_type,external_document_id) VALUES(?,?,'MAKE','CREATED','SUPPLY','PREPLAN_MAKE_TASK',?)", action, fixture.analysis, first.item());
            for (UUID material : new UUID[]{first.material(), member.material()})
                fixture.db.update("INSERT INTO preplan_supply_action_allocations(id,analysis_id,action_id,analysis_material_id,allocated_qty,external_item_id) VALUES(?,?,?,?,1,?)", UUID.randomUUID(), fixture.analysis, action, material, first.item());
            fixture.supplyMaterial(unrelated.material(), "50");
            fixture.supplyMaterial(first.material(), "5");
            fixture.supplyMaterial(member.material(), "3");
            // Q2 already excludes eight promised pieces across a+b. The 50 on c
            // belongs to another path and cannot finish or arrange this anchor.
            assertThat(fixture.schedule(first.item())).isEqualByComparingTo("2");
            assertThat(fixture.fulfillment(first.item())).isEqualByComparingTo("2");
            fixture.db.update("UPDATE preplan_supply_action_allocations SET allocated_qty=5 WHERE analysis_material_id=? AND action_id<>?", member.material(), action);
            assertThat(fixture.schedule(first.item())).isEqualByComparingTo("0");
            assertThat(fixture.fulfillment(first.item())).isEqualByComparingTo("2");
        }
    }

    @Test
    void nonlinearFrozenSplitDoesNotCopyACompletedPackageChargeIntoTheRemainingSiblingPool() throws Exception {
        try (Fixture fixture = fixture()) {
            UUID parent = fixture.product("10", "0", "10", "0", "MAKE");
            Component packageCharge = fixture.component(parent, "2", "2", "a-package", null);
            Component perUnit = fixture.component(parent, "10", "10", "b-unit", packageCharge.goods());
            fixture.db.update("UPDATE production_material_analysis_materials SET consumption_basis='FIXED_BATCH',basis_output_qty=5,per_product_qty=0.2 WHERE id=?", packageCharge.material());
            UUID plan = fixture.plan(parent, "10");
            UUID first = fixture.demand(plan, packageCharge.goods(), "8", "6", "FULFILLED");
            UUID last = fixture.demand(plan, packageCharge.goods(), "4", "4", "OPEN");
            UUID splitRoot = UUID.randomUUID();
            for (Object[] slice : new Object[][]{{first, "6", "0", "COMPLETED"}, {last, "4", "6", "WAITING"}}) {
                UUID segment = UUID.randomUUID();
                fixture.db.update("INSERT INTO production_execution_segments(id,plan_id,planned_qty,product_unit_rate,status,is_deleted,split_root_segment_id,split_start_qty) VALUES(?,?,?,1,?,FALSE,?,?)", segment, plan, new BigDecimal((String) slice[1]), slice[3], splitRoot, new BigDecimal((String) slice[2]));
                fixture.db.update("UPDATE production_material_demands SET execution_segment_id=? WHERE id=?", segment, slice[0]);
            }
            // The first six products used both fixed charges (ceil(6/5)=2).
            // The remaining four owe only four PER_UNIT pieces: the shared
            // second demand must not assign another package charge to path a.
            fixture.reserve(last, "4");
            assertThat(fixture.db.queryForObject("SELECT SUM(qty) FROM v_production_workbench_frozen_material_scopes WHERE material_id=?", BigDecimal.class, packageCharge.material())).isEqualByComparingTo("2");
            assertThat(fixture.db.queryForObject("SELECT SUM(qty) FROM v_production_workbench_frozen_material_scopes WHERE material_id=?", BigDecimal.class, perUnit.material())).isEqualByComparingTo("10");
            assertThat(fixture.fulfillment(packageCharge.item())).isEqualByComparingTo("2");
            assertThat(fixture.fulfillment(perUnit.item())).isEqualByComparingTo("6");
        }
    }

    @Test
    void returnedOwnOutputKeepsItsCustodySourceIdentityAndOccupiesTheSharedGrossSlotOnce() throws Exception {
        try (Fixture fixture = fixture()) {
            UUID parent = fixture.product("8", "0", "8", "0", "MAKE");
            Component child = fixture.component(parent, "8", "8", "component", null);
            fixture.db.update("UPDATE production_material_analysis_items SET approved_qty=4 WHERE id=?", child.item());
            UUID parentPlan = fixture.plan(parent, "8"), ownPlan = fixture.plan(child.item(), "4");
            fixture.link(ownPlan, child.item(), 4);
            UUID planItem = fixture.db.queryForObject("SELECT id FROM production_plan_items WHERE plan_id=?", UUID.class, ownPlan);
            fixture.receive(planItem, new BigDecimal("4"), false);
            UUID report = fixture.db.queryForObject("SELECT id FROM production_daily_report_items WHERE plan_item_id=?", UUID.class, planItem);
            UUID demand = fixture.demand(parentPlan, child.goods(), "8", "8", "FULFILLED");
            UUID held = UUID.randomUUID(), transfer = UUID.randomUUID();
            fixture.db.update("INSERT INTO stock_reservations(id,owner_id,owner_type,source_doc_type,qty,consumed_qty,released_qty,requires_qualified_origin,is_deleted) VALUES(?,?,'WORKSHOP_CUSTODY','WORKSHOP_RETURN_CUSTODY',4,0,0,TRUE,FALSE)", held, demand);
            fixture.db.update("INSERT INTO production_workshop_direct_transfer_items(id,source_report_item_id) VALUES(?,?)", transfer, report);
            fixture.db.update("INSERT INTO v_workshop_direct_source_allocations(id,allocation_no,stock_reservation_id,transfer_item_id,effective_qty) VALUES(?,1,?,?,4)", UUID.randomUUID(), held, transfer);

            assertThat(fixture.fulfillment(child.item())).isEqualByComparingTo("4");
            assertThat(fixture.schedule(child.item())).isEqualByComparingTo("4");
            UUID publicStock = fixture.reserve(demand, "2");
            assertThat(fixture.fulfillment(child.item())).isEqualByComparingTo("2");
            assertThat(fixture.schedule(child.item())).isEqualByComparingTo("2");
            fixture.db.update("UPDATE stock_reservations SET released_qty=2 WHERE id=?", publicStock);
            assertThat(fixture.fulfillment(child.item())).isEqualByComparingTo("4");
        }
    }

    @Test
    void reallocationSupplementChangesTheNetChildQuotaWithoutAddingItsGrossParentDemandAgain() throws Exception {
        try (Fixture fixture = fixture()) {
            UUID parent = fixture.product("10", "0", "10", "0", "MAKE");
            Component child = fixture.component(parent, "2", "10", "component", null);
            UUID plan = fixture.plan(parent, "10");
            UUID demand = fixture.demand(plan, child.goods(), "10", "10", "ALLOCATED");
            UUID original = fixture.reserve(demand, "8");
            assertThat(fixture.fulfillment(child.item())).isEqualByComparingTo("2");

            // V568's allowance replaces four yielded pieces: uncovered=6,
            // childFuture=2, additional=4. Only Q grows from 2 to 6; neither
            // the original parent nor its retained frozen demand grows to 14.
            fixture.db.update("UPDATE stock_reservations SET released_qty=4 WHERE id=?", original);
            fixture.db.update("UPDATE production_material_analysis_items SET requested_qty=6 WHERE id=?", child.item());
            UUID relation = UUID.randomUUID(), otherOrigin = UUID.randomUUID();
            fixture.db.update("INSERT INTO preplan_analysis_stock_exact_pegs(id,stock_reservation_id,source_receipt_type,qty) VALUES(?,?,'PURCHASE',4)", UUID.randomUUID(), otherOrigin);
            fixture.db.update("INSERT INTO preplan_stock_entitlement_events(id,event_type,stock_reservation_id,beneficiary_analysis_id,beneficiary_analysis_material_id,reallocation_id,qty) VALUES(?,'REALLOCATE_OUT',?,?,?,?,4)", UUID.randomUUID(), otherOrigin, fixture.analysis, child.material(), relation);
            fixture.db.update("INSERT INTO preplan_reallocation_make_supplements(id,reallocation_id,source_analysis_material_id,child_analysis_item_id,qty,before_requested_qty,after_requested_qty,created_by) VALUES(?,?,?,?,4,2,6,?)",
                    UUID.randomUUID(), relation, child.material(), child.item(), UUID.randomUUID());
            assertThat(fixture.fulfillment(child.item())).isEqualByComparingTo("6");
            UUID replacement = fixture.reserve(demand, "2");
            assertThat(fixture.fulfillment(child.item())).isEqualByComparingTo("4");
            assertThat(fixture.schedule(child.item())).isEqualByComparingTo("4");
            fixture.db.update("UPDATE stock_reservations SET released_qty=2 WHERE id=?", replacement);
            assertThat(fixture.fulfillment(child.item())).isEqualByComparingTo("6");
            assertThat(fixture.db.queryForObject("SELECT SUM(qty) FROM v_production_workbench_frozen_material_scopes WHERE material_id=?", BigDecimal.class, child.material())).isEqualByComparingTo("10");
            assertThat(fixture.db.queryForObject("SELECT SUM(qty) FROM preplan_reallocation_make_supplements WHERE child_analysis_item_id=?", BigDecimal.class, child.item())).isEqualByComparingTo("4");
        }
    }

    @Test
    void replacementOfYieldedOwnOutputKeepsItsHistoricalCompletionAndExactSupplementResponsibility() throws Exception {
        for (Object[] scenario : new Object[][]{{"2", "8", "2", "0"}, {"10", "0", "4", "0"}, {"2", "8", "2", "2"}}) {
            try (Fixture fixture = fixture()) {
                String quota = (String) scenario[0], originalStock = (String) scenario[1];
                BigDecimal ownYield = new BigDecimal((String) scenario[2]), otherYield = new BigDecimal((String) scenario[3]);
                BigDecimal yielded = ownYield.add(otherYield);
                UUID parent = fixture.product("10", "0", "10", "0", "MAKE");
                Component child = fixture.component(parent, quota, "10", "component", null);
                fixture.db.update("UPDATE production_material_analysis_items SET approved_qty=requested_qty WHERE id=?", child.item());
                UUID parentPlan = fixture.plan(parent, "10"), ownPlan = fixture.plan(child.item(), quota);
                fixture.link(ownPlan, child.item(), Integer.parseInt(quota));
                UUID planItem = fixture.db.queryForObject("SELECT id FROM production_plan_items WHERE plan_id=?", UUID.class, ownPlan);
                fixture.receive(planItem, new BigDecimal(quota), false);
                UUID demand = fixture.demand(parentPlan, child.goods(), "10", "10", "ALLOCATED");
                UUID initialOther = !"0".equals(originalStock) ? fixture.reserve(demand, originalStock) : null;
                assertThat(fixture.fulfillment(child.item())).isEqualByComparingTo("0");

                UUID relation = UUID.randomUUID(), original = UUID.randomUUID();
                fixture.db.update("INSERT INTO preplan_analysis_stock_exact_pegs(id,stock_reservation_id,make_source_analysis_item_id,source_receipt_type,qty) VALUES(?,?,?,'MAKE',?)", UUID.randomUUID(), original, child.item(), new BigDecimal(quota));
                fixture.db.update("INSERT INTO preplan_stock_entitlement_events(id,event_type,stock_reservation_id,beneficiary_analysis_id,beneficiary_analysis_material_id,reallocation_id,qty) VALUES(?,'REALLOCATE_OUT',?,?,?,?,?)", UUID.randomUUID(), original, fixture.analysis, child.material(), relation, ownYield);
                if (otherYield.signum()>0) {
                    fixture.db.update("UPDATE stock_reservations SET released_qty=? WHERE id=?", otherYield, initialOther);
                    UUID otherOrigin = UUID.randomUUID();
                    fixture.db.update("INSERT INTO preplan_analysis_stock_exact_pegs(id,stock_reservation_id,source_receipt_type,qty) VALUES(?,?,'PURCHASE',?)", UUID.randomUUID(), otherOrigin, otherYield);
                    fixture.db.update("INSERT INTO preplan_stock_entitlement_events(id,event_type,stock_reservation_id,beneficiary_analysis_id,beneficiary_analysis_material_id,reallocation_id,qty) VALUES(?,'REALLOCATE_OUT',?,?,?,?,?)", UUID.randomUUID(), otherOrigin, fixture.analysis, child.material(), relation, otherYield);
                }
                BigDecimal next = new BigDecimal(quota).add(yielded);
                fixture.db.update("UPDATE production_material_analysis_items SET requested_qty=? WHERE id=?", next, child.item());
                fixture.db.update("INSERT INTO preplan_reallocation_make_supplements(id,reallocation_id,source_analysis_material_id,child_analysis_item_id,qty,before_requested_qty,after_requested_qty,created_by) VALUES(?,?,?,?,?,?,?,?)",
                        UUID.randomUUID(), relation, child.material(), child.item(), yielded, new BigDecimal(quota), next, UUID.randomUUID());
                // The original approved private output still counts as produced;
                // its exact yielded quantity is nevertheless a new replacement
                // quota. Other original stock cannot count toward it a second time.
                assertThat(fixture.fulfillment(child.item())).isEqualByComparingTo(yielded);
                assertThat(fixture.schedule(child.item())).isEqualByComparingTo(yielded);
                BigDecimal firstReplacement = yielded.min(new BigDecimal("2"));
                UUID replacement = fixture.reserve(demand, firstReplacement.toPlainString());
                assertThat(fixture.fulfillment(child.item())).isEqualByComparingTo(yielded.subtract(firstReplacement));
                fixture.db.update("UPDATE stock_reservations SET qty=? WHERE id=?", yielded, replacement);
                assertThat(fixture.fulfillment(child.item())).isEqualByComparingTo("0");
                assertThat(fixture.schedule(child.item())).isEqualByComparingTo("0");
            }
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
            fixture.db.update("INSERT INTO production_material_analysis_materials(id,analysis_id,analysis_item_id,goods_id,unit_id,depth,required_qty,active) VALUES(?,?,?,?,?,1,8,TRUE)", material, fixture.analysis, parentItem, goods, fixture.unit);
            fixture.db.update("UPDATE production_material_analysis_items SET source_type='MAKE_COMPONENT',root_material_id=NULL,parent_analysis_material_id=? WHERE id=?", material, component);
            for (Object[] plan : new Object[][]{{parentPlan, parentItem, 8}, {childPlan, component, 4}}) {
                fixture.db.update("INSERT INTO production_plans(id,material_analysis_id,material_analysis_item_id,status,is_deleted,is_closed,is_stopped,is_canceled) VALUES(?,?,?,1,FALSE,FALSE,FALSE,FALSE)", plan[0], fixture.analysis, plan[1]);
                fixture.db.update("INSERT INTO production_plan_items(id,plan_id,qty,iqty,is_deleted) VALUES(?,?,?,?,FALSE)", UUID.randomUUID(), plan[0], plan[2], plan[2]);
                fixture.link((UUID) plan[0], (UUID) plan[1], ((Number) plan[2]).intValue());
            }
            for (UUID planItem : fixture.db.queryForList("SELECT id FROM production_plan_items", UUID.class)) fixture.receive(planItem, fixture.db.queryForObject("SELECT qty FROM production_plan_items WHERE id=?", BigDecimal.class, planItem), false);
            fixture.db.update("INSERT INTO production_material_demands(id,plan_id,goods_id,unit_id,required_qty,status,is_deleted) VALUES(?,?,?,?,8,'FULFILLED',FALSE)", demand, parentPlan, goods, fixture.unit);
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
                    "preplan_aggregate_batches", "preplan_aggregate_material_aliases", "preplan_reallocation_make_supplements",
                    "v_workshop_direct_source_allocations", "production_workshop_direct_transfer_items",
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

    private record Component(UUID item, UUID material, UUID goods) { }

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

        private Component component(UUID parent, String requested, String required, String path, UUID sameGoods) {
            UUID item = product(requested, "0", "0", "0", "MAKE");
            UUID goods = sameGoods == null ? db.queryForObject("SELECT goods_id FROM production_material_analysis_items WHERE id=?", UUID.class, item) : sameGoods;
            UUID material = UUID.randomUUID();
            db.update("UPDATE production_material_analysis_items SET source_type='MAKE_COMPONENT',goods_id=?,root_material_id=NULL,parent_analysis_material_id=? WHERE id=?", goods, material, item);
            db.update("INSERT INTO production_material_analysis_materials(id,analysis_id,analysis_item_id,goods_id,unit_id,node_key,path,node_role,depth,required_qty,per_product_qty,parent_per_product_qty,bom_qty,consumption_basis,basis_output_qty,allow_partial_package,active) VALUES(?,?,?,?,?,?,?,'BOM_COMPONENT',1,?,1,1,1,'PER_UNIT',1,TRUE,TRUE)",
                    material, analysis, parent, goods, unit, path, path, new BigDecimal(required));
            return new Component(item, material, goods);
        }

        private UUID plan(UUID item, String qty) {
            UUID plan = UUID.randomUUID(), goods = db.queryForObject("SELECT goods_id FROM production_material_analysis_items WHERE id=?", UUID.class, item);
            db.update("INSERT INTO production_plans(id,material_analysis_id,material_analysis_item_id,status,is_deleted,is_closed,is_stopped,is_canceled) VALUES(?,?,?,1,FALSE,FALSE,FALSE,FALSE)", plan, analysis, item);
            db.update("INSERT INTO production_plan_items(id,plan_id,goods_id,unit_id,qty,iqty,unit_rate,is_deleted) VALUES(?,?,?,?,?,0,1,FALSE)", UUID.randomUUID(), plan, goods, unit, new BigDecimal(qty));
            return plan;
        }

        private UUID demand(UUID plan, UUID goods, String required, String productQty, String status) {
            UUID demand = UUID.randomUUID();
            db.update("INSERT INTO production_material_demands(id,plan_id,goods_id,unit_id,required_qty,released_qty,required_for_product_qty,status,is_deleted) VALUES(?,?,?,?,?,0,?,?,FALSE)", demand, plan, goods, unit, new BigDecimal(required), new BigDecimal(productQty), status);
            return demand;
        }

        private UUID reserve(UUID demand, String qty) {
            UUID reservation = UUID.randomUUID();
            db.update("INSERT INTO stock_reservations(id,demand_id,owner_type,qty,consumed_qty,released_qty,requires_qualified_origin,is_deleted) VALUES(?,?,'PRODUCTION_MATERIAL_DEMAND',?,0,0,FALSE,FALSE)", reservation, demand, new BigDecimal(qty));
            return reservation;
        }

        private UUID supplyMaterial(UUID material, String qty) {
            UUID action = UUID.randomUUID();
            db.update("INSERT INTO preplan_supply_actions(id,analysis_id,route,status,operation_type,external_document_type) VALUES(?,?,'BUY','CREATED','SUPPLY','PURCHASE_REQUEST')", action, analysis);
            db.update("INSERT INTO preplan_supply_action_allocations(id,analysis_id,action_id,analysis_material_id,allocated_qty) VALUES(?,?,?,?,?)", UUID.randomUUID(), analysis, action, material, new BigDecimal(qty));
            return action;
        }

        private BigDecimal schedule(UUID item) {
            return db.queryForObject("SELECT remaining_schedule_qty FROM v_production_analysis_workbench_item_progress WHERE analysis_item_id=?", BigDecimal.class, item);
        }

        private BigDecimal fulfillment(UUID item) {
            return db.queryForObject("SELECT remaining_fulfillment_qty FROM v_production_analysis_workbench_item_progress WHERE analysis_item_id=?", BigDecimal.class, item);
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
