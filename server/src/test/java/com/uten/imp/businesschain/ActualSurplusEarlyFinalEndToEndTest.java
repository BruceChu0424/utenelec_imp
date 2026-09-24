package com.uten.imp.businesschain;

import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.features.production.dailyreport.ProductionDailyReportService;
import com.uten.imp.features.production.dailyreport.ReportablePlanLineQueryService;
import com.uten.imp.features.production.dailyreport.dto.DailyReportItemLine;
import com.uten.imp.features.production.dailyreport.dto.DailyReportMaterialUsageLine;
import com.uten.imp.features.production.dailyreport.dto.DailyReportSaveRequest;
import com.uten.imp.features.production.execution.ProductionExecutionSegmentService;
import com.uten.imp.features.production.execution.SegmentTransitionRequest;
import com.uten.imp.features.production.plan.ProductionPlanService;
import com.uten.imp.features.stock.StockDocService;
import com.uten.imp.features.stock.dto.StockDocItemLine;
import com.uten.imp.features.stock.dto.StockDocSaveRequest;
import com.uten.imp.support.DailyReportApproveRequests;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.util.ReflectionTestUtils;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.support.TransactionTemplate;

import java.math.BigDecimal;
import java.util.List;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.*;

/** Actual surplus must not become an original target when a merged plan ends early. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.MOCK, properties = {
        "spring.profiles.active=dev", "uten.audit.retention.enabled=false", "uten.reporting.materialized-view-refresh.enabled=false",
        "uten.production.readiness-reconcile.enabled=false", "uten.inventory.value-work-initial-delay-ms=3600000",
        "uten.policy-intelligence.enabled=false", "uten.features.goods-owner-scope-enabled=false", "uten.storage.uploads-enabled=true",
        "uten.storage.malware-scan.provider=test-only", "uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only",
        "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789", "uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only",
        "uten.bootstrap.admin-login=full-chain-bootstrap-admin-test", "uten.bootstrap.admin-password=HarnessAdminPass-1!"})
class ActualSurplusEarlyFinalEndToEndTest {
    @DynamicPropertySource
    static void database(DynamicPropertyRegistry registry) { FullChainEndToEndTest.registerDataSource(registry); }

    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    @Autowired PlatformTransactionManager transactionManager;
    @Autowired ProductionPlanService plans;
    @Autowired ProductionExecutionSegmentService segments;
    @Autowired ReportablePlanLineQueryService sources;
    @Autowired ProductionDailyReportService reports;
    @Autowired StockDocService stock;
    @Autowired com.uten.imp.features.production.dailyreport.ActualOutputSupplementService supplements;

    @AfterEach void logout() { SecurityContextHolder.clearContext(); }

    @Test
    void earlyFinalKeepsPublicTenSeparateAndRemakesOnlyTheOtherOrdersHundred() {
        verifyEarlyFinal("110",false,false);
    }

    @Test void earlyFinalKeepsThePreviouslyAuthorizedFifteenWithoutGivingFutureReportsMoreCapacity() {
        verifyEarlyFinal("115",false,false);
    }

    @Test void earlyFinalAcceptsTheExactOriginalTwentyAllowance() {
        verifyEarlyFinal("120",false,false);
    }

    @Test void exceedingTheOriginalAllowanceStillRequiresAnAdditionalPlanForTheEntireSurplus() {
        verifyEarlyFinal("121",false,true);
    }

    @Test void earlyFinalMustResolveOtherDraftsBeforeReducingTheirSharedTask() {
        verifyEarlyFinal("115",true,false);
    }

    private void verifyEarlyFinal(String actualQty,boolean competingDraft,boolean requiresSupplement) {
        BigDecimal amount=new BigDecimal(actualQty);
        String surplus=amount.subtract(new BigDecimal("100")).toPlainString();
        var fixture = new FullChainEndToEndTest();
        beans.autowireBean(fixture);
        String tag="actual-early-final-"+actualQty+(competingDraft?"-draft":"");
        var world = fixture.seedWorld(tag);
        fixture.loginAs(world.superAdminUserId());
        UUID product = UUID.randomUUID(), material = UUID.randomUUID();
        fixture.insertGoods(product,"AEF-P-"+product,"提前完结自制件","自制",world.unitId(),world.unitLegacy());
        fixture.insertGoods(material,"AEF-M-"+material,"提前完结原料","采购",world.unitId(),world.unitLegacy());
        fixture.insertBom(product,material,"1");
        UUID orderA = fixture.createApprovedOrder(world,product,"100","100");
        UUID orderB = fixture.createApprovedOrder(world,product,"100","100");
        UUID itemA = db.queryForObject("SELECT id FROM sales_order_items WHERE order_id=?",UUID.class,orderA);
        UUID itemB = db.queryForObject("SELECT id FROM sales_order_items WHERE order_id=?",UUID.class,orderB);
        UUID plan = ReflectionTestUtils.invokeMethod(fixture,"createLegacyTestDraft",itemA,product,"100");
        UUID planItem = db.queryForObject("SELECT id FROM production_plan_items WHERE plan_id=? AND NOT is_deleted",UUID.class,plan);
        Object assignment = ReflectionTestUtils.invokeMethod(fixture,"productionAssignment",tag);
        UUID workshop = ReflectionTestUtils.invokeMethod(assignment,"workshopId");
        UUID worker = ReflectionTestUtils.invokeMethod(assignment,"workerId");
        // This is the supported prebuilt merged-sales fixture, still entirely in
        // draft. Normal approval validates both source orders and conservation.
        new TransactionTemplate(transactionManager).executeWithoutResult(status -> {
            db.update("UPDATE production_plan_items SET qty=200,oqty=200,sales_order_item_id=NULL,sales_order_no=NULL WHERE id=?",planItem);
            db.update("UPDATE production_plans SET department_id=?,worker_id=? WHERE id=?",workshop,worker,plan);
            for (UUID orderItem : List.of(itemA,itemB)) {
                db.update("INSERT INTO plan_order_item_links(id,plan_item_id,order_item_id,allocated_qty,source) VALUES(?,?,?,100,0)",UUID.randomUUID(),planItem,orderItem);
            }
        });
        plans.approve(plan);
        qty("100","SELECT planned_qty FROM sales_order_items WHERE id=?",itemA);
        qty("100","SELECT planned_qty FROM sales_order_items WHERE id=?",itemB);

        var opening = new StockDocSaveRequest();
        opening.setDocType("OTHER_IN"); opening.setBillDate(BusinessTime.today()); opening.setWarehouseId(world.warehouseId());
        var received = new StockDocItemLine();
        received.setGoodsId(material); received.setUnitId(world.unitId()); received.setUnitRate(BigDecimal.ONE);
        received.setQty(new BigDecimal("200")); received.setPrice(BigDecimal.TEN);
        received.setAmountOriginal(new BigDecimal("2000")); received.setAmountLocal(new BigDecimal("2000"));
        opening.setItems(List.of(received)); stock.approve(stock.create(opening).getId());
        ReflectionTestUtils.invokeMethod(fixture,"issueReadyPlanAndMaterials",world,plan);
        UUID segment = db.queryForObject("SELECT id FROM production_execution_segments WHERE plan_id=? AND NOT is_deleted",UUID.class,plan);
        qty("200","SELECT planned_qty FROM production_execution_segments WHERE id=?",segment);
        assertEquals(2,db.queryForObject("SELECT COUNT(*) FROM execution_segment_sales_allocations WHERE execution_segment_id=?",Integer.class,segment));
        assertEquals("READY",db.queryForObject("SELECT status FROM production_execution_segments WHERE id=?",String.class,segment));
        segments.start(plan,segment,new SegmentTransitionRequest(
                db.queryForObject("SELECT lock_version FROM production_execution_segments WHERE id=?",Long.class,segment),"aef-start-"+segment));
        // Report action scope is the actual workshop, including for administrators.
        db.update("UPDATE employees SET department_id=? WHERE id=?",workshop,world.employeeId());
        fixture.loginAs(world.superAdminUserId());
        var source = sources.list(1,20,null,workshop,List.of(segment)).getItems().stream()
                .filter(row -> itemA.equals(row.orderItemId())).findFirst().orElseThrow();
        var line = new DailyReportItemLine();
        line.setLineNo(1); line.setPlanItemId(planItem); line.setExecutionSegmentId(segment);
        line.setExecutionSegmentSalesAllocationId(source.executionSegmentSalesAllocationId()); line.setSalesOrderItemId(itemA);
        line.setGoodsId(product); line.setColorId(source.colorId()); line.setUnitId(source.unitId()); line.setUnitRate(source.unitRate());
        line.setQty(amount); line.setIsFinal(true);
        UUID demand = db.queryForObject("SELECT id FROM production_material_demands WHERE execution_segment_id=? AND NOT is_deleted",UUID.class,segment);
        var usage = new DailyReportMaterialUsageLine(); usage.setDemandId(demand); usage.setQtyBase(amount);
        var request = new DailyReportSaveRequest(); request.setIdempotencyKey("aef-report-"+segment); request.setBillDate(BusinessTime.today());
        request.setDepartmentId(workshop); request.setWorkerIds(List.of(worker)); request.setItems(List.of(line)); request.setMaterialLines(List.of(usage));
        if(requiresSupplement) {
            var preview=supplements.previewReport(new com.uten.imp.features.production.dailyreport.ActualOutputSupplementContracts.ReportPreviewRequest(request,null));
            assertTrue(preview.requiresSupplements());
            assertEquals(0,new BigDecimal("100").compareTo(preview.lines().getFirst().originalReportQty()));
            assertEquals(0,new BigDecimal("21").compareTo(preview.lines().getFirst().supplementQty()));
            assertThrows(com.uten.imp.common.web.ApiException.class,()->reports.create(request));
            qty("200","SELECT planned_qty FROM production_execution_segments WHERE id=?",segment);
            assertEquals(0,db.queryForObject("SELECT COUNT(*) FROM production_daily_report_target_events WHERE plan_item_id=?",Integer.class,planItem));
            return;
        }
        UUID report = reports.create(request).getId();
        assertThrows(org.springframework.dao.DataAccessException.class, () -> db.update(
                "UPDATE plan_order_item_links SET allocated_qty=0,capped_qty=100 WHERE plan_item_id=? AND order_item_id=?",
                planItem,itemB), "a positive cap number alone cannot erase another sales allocation");
        var approval = DailyReportApproveRequests.freshKey();
        if(competingDraft) {
            var otherSource=sources.list(1,20,null,workshop,List.of(segment)).getItems().stream()
                    .filter(row->itemB.equals(row.orderItemId())).findFirst().orElseThrow();
            var otherLine=new DailyReportItemLine();org.springframework.beans.BeanUtils.copyProperties(line,otherLine);
            otherLine.setQty(BigDecimal.ONE);otherLine.setIsFinal(false);
            otherLine.setSalesOrderItemId(itemB);otherLine.setExecutionSegmentSalesAllocationId(otherSource.executionSegmentSalesAllocationId());
            var otherUsage=new DailyReportMaterialUsageLine();otherUsage.setDemandId(demand);otherUsage.setQtyBase(BigDecimal.ONE);
            var otherRequest=new DailyReportSaveRequest();otherRequest.setIdempotencyKey("aef-other-"+segment);
            otherRequest.setBillDate(BusinessTime.today());otherRequest.setDepartmentId(workshop);otherRequest.setWorkerIds(List.of(worker));
            otherRequest.setItems(List.of(otherLine));otherRequest.setMaterialLines(List.of(otherUsage));
            var otherReport=reports.create(otherRequest);
            RuntimeException blocked=assertThrows(RuntimeException.class,()->reports.approve(report,approval));
            assertTrue(causeMessages(blocked).contains(otherReport.getBillNo()),causeMessages(blocked));
            qty("200","SELECT planned_qty FROM production_execution_segments WHERE id=?",segment);
            assertEquals(0,db.queryForObject("SELECT status FROM production_daily_reports WHERE id=?",Integer.class,report));
            assertEquals(0,db.queryForObject("SELECT COUNT(*) FROM production_daily_report_target_events WHERE report_id=?",Integer.class,report));
            reports.delete(otherReport.getId());
        }
        var approved = reports.approve(report,approval);
        assertEquals(2,approved.getItems().size());
        reports.approve(report,approval);

        qty("100","SELECT qty FROM production_plan_items WHERE id=?",planItem);
        qty("100","SELECT capped_qty FROM production_plan_items WHERE id=?",planItem);
        qty(actualQty,"SELECT fqty FROM production_plan_items WHERE id=?",planItem);
        qty("100","SELECT planned_qty FROM production_execution_segments WHERE id=?",segment);
        qty(actualQty,"SELECT fn_production_execution_cost_target(?)",segment);
        qty("100","SELECT allocated_qty FROM plan_order_item_links WHERE plan_item_id=? AND order_item_id=? AND NOT is_deleted",planItem,itemA);
        qty("100","SELECT produced_qty FROM plan_order_item_links WHERE plan_item_id=? AND order_item_id=? AND NOT is_deleted",planItem,itemA);
        qty("0","SELECT allocated_qty FROM plan_order_item_links WHERE plan_item_id=? AND order_item_id=? AND NOT is_deleted",planItem,itemB);
        qty("100","SELECT capped_qty FROM plan_order_item_links WHERE plan_item_id=? AND order_item_id=? AND NOT is_deleted",planItem,itemB);
        qty("0","SELECT produced_qty FROM plan_order_item_links WHERE plan_item_id=? AND order_item_id=? AND NOT is_deleted",planItem,itemB);
        qty(surplus,"SELECT qty FROM production_daily_report_items WHERE report_id=? AND is_actual_surplus AND NOT is_deleted",report);
        assertEquals(0,db.queryForObject("SELECT COUNT(*) FROM production_daily_report_items WHERE report_id=? AND is_actual_surplus AND (sales_order_item_id IS NOT NULL OR execution_segment_sales_allocation_id IS NOT NULL OR destination<>'WAREHOUSE')",Integer.class,report));
        qty(actualQty,"SELECT confirmed_consumed_qty FROM v_production_material_clearance WHERE demand_id=?",demand);
        qty("100","SELECT after_qty FROM production_daily_report_target_events WHERE report_id=? AND event_type='CAP'",report);
        qty("200","SELECT (overproduction_authorizations->'segments'->0->>'plannedQty')::numeric FROM production_daily_report_target_events WHERE report_id=? AND event_type='CAP'",report);
        qty("20","SELECT (overproduction_authorizations->'segments'->0->>'approvedMarginQty')::numeric FROM production_daily_report_target_events WHERE report_id=? AND event_type='CAP'",report);
        qty(surplus,"SELECT (overproduction_authorizations->'segments'->0->>'actualSurplusQty')::numeric FROM production_daily_report_target_events WHERE report_id=? AND event_type='CAP'",report);
        qty("0","SELECT fn_execution_actual_surplus_available(?)",segment);
        assertThrows(org.springframework.dao.DataAccessException.class,()->db.update(
                "UPDATE production_daily_report_target_events SET overproduction_authorizations='{}'::jsonb WHERE report_id=? AND event_type='CAP'",report));
        UUID remake = db.queryForObject("SELECT id FROM production_plans WHERE source_daily_report_id=? AND NOT is_deleted",UUID.class,report);
        assertEquals(0,db.queryForObject("SELECT status FROM production_plans WHERE id=?",Integer.class,remake));
        qty("100","SELECT SUM(qty) FROM production_plan_items WHERE plan_id=? AND NOT is_deleted",remake);
        var remakeLinks = db.queryForList("SELECT link.order_item_id,link.allocated_qty,link.source FROM plan_order_item_links link JOIN production_plan_items item ON item.id=link.plan_item_id WHERE item.plan_id=? AND NOT link.is_deleted",remake);
        assertEquals(1,remakeLinks.size());
        assertEquals(itemB,remakeLinks.getFirst().get("order_item_id"));
        assertEquals(0,new BigDecimal("100").compareTo((BigDecimal)remakeLinks.getFirst().get("allocated_qty")));
        assertEquals(1,((Number)remakeLinks.getFirst().get("source")).intValue());
        qty("100","SELECT planned_qty FROM sales_order_items WHERE id=?",itemA);
        qty("0","SELECT planned_qty FROM sales_order_items WHERE id=?",itemB);
        reports.reverse(report);
        qty("200","SELECT qty FROM production_plan_items WHERE id=?",planItem);
        qty("200","SELECT planned_qty FROM production_execution_segments WHERE id=?",segment);
        qty("100","SELECT allocated_qty FROM plan_order_item_links WHERE plan_item_id=? AND order_item_id=? AND NOT is_deleted",planItem,itemB);
        qty("100","SELECT planned_qty FROM sales_order_items WHERE id=?",itemB);
        qty("0","SELECT fqty FROM production_plan_items WHERE id=?",planItem);
        qty("0","SELECT confirmed_consumed_qty FROM v_production_material_clearance WHERE demand_id=?",demand);
        qty("20","SELECT fn_execution_actual_surplus_available(?)",segment);
        assertEquals(1,db.queryForObject("SELECT COUNT(*) FROM production_daily_report_target_events WHERE report_id=? AND event_type='RESTORE' AND overproduction_authorizations IS NULL",Integer.class,report));
        assertTrue(db.queryForObject("SELECT is_deleted FROM production_plans WHERE id=?",Boolean.class,remake));
    }

    private static String causeMessages(Throwable failure) {
        StringBuilder messages=new StringBuilder();
        for(Throwable cause=failure;cause!=null;cause=cause.getCause()) messages.append(cause.getMessage()).append('\n');
        return messages.toString();
    }

    private void qty(String expected,String sql,Object... args) {
        assertEquals(0,new BigDecimal(expected).compareTo(db.queryForObject(sql,BigDecimal.class,args)),sql);
    }
}
