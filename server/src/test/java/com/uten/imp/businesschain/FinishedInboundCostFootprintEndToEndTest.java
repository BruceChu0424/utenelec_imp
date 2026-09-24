package com.uten.imp.businesschain;

import com.uten.imp.application.concurrency.FulfillmentMutationLockPlan;
import com.uten.imp.application.concurrency.FulfillmentMutationLockPlan.InventoryDimension;
import com.uten.imp.application.port.ProductionMutationFootprintPort;
import com.uten.imp.application.port.ProductionMutationFootprintPort.WarehouseDimension;
import com.uten.imp.features.stock.StockDocService;
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
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.support.TransactionTemplate;

import java.math.BigDecimal;
import java.util.List;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.*;

/** Historical execution snapshots must lock real consumed value, independent of today's BOM. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
@SpringBootTest(webEnvironment=SpringBootTest.WebEnvironment.MOCK,properties={
        "spring.profiles.active=dev","uten.audit.retention.enabled=false","uten.reporting.materialized-view-refresh.enabled=false",
        "uten.production.readiness-reconcile.enabled=false","uten.policy-intelligence.enabled=false",
        "uten.features.goods-owner-scope-enabled=false","uten.storage.uploads-enabled=true","uten.storage.malware-scan.provider=test-only",
        "uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only",
        "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789",
        "uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only","uten.bootstrap.admin-login=full-chain-bootstrap-admin-test",
        "uten.bootstrap.admin-password=HarnessAdminPass-1!"})
class FinishedInboundCostFootprintEndToEndTest {
    @DynamicPropertySource static void database(DynamicPropertyRegistry registry) {
        FullChainEndToEndTest.registerDataSource(registry);
    }
    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    @Autowired ProductionMutationFootprintPort footprints;
    @Autowired PlatformTransactionManager transactions;
    @Autowired StockDocService stock;
    private FullChainEndToEndTest fixture;

    @BeforeEach void prepare() {
        fixture=new FullChainEndToEndTest(); beans.autowireBean(fixture);
    }

    @Test void firstReceiptAndFutureReceiptLockActualHistoricalInputsBeforeAnyCostObjectExists() {
        Case c=consumedFirstHalf("first-cost-footprint");
        assertEquals(0,db.queryForObject("SELECT COUNT(*) FROM stock_value_production_cost_objects WHERE execution_segment_id=?",
                Integer.class,c.segment()));
        assertTrue(pendingInputs(c.segment())>0);
        // A legitimate later master-data edit does not change the frozen
        // execution's original consumption or make its actual inputs disappear.
        db.update("UPDATE goods_bom_items SET is_deleted=TRUE WHERE goods_id=? AND NOT is_deleted",c.world().goodsA());
        fixture.insertBom(c.world().goodsA(),c.world().goodsC(),"9");
        var actual=document(c.inbound());
        assertActualInputs(c,actual);
        assertFalse(actual.inventoryDimensions().contains(new InventoryDimension(c.world().goodsC(),null)),
                "A new theoretical BOM component is not an actual input of this historical cost object");
        var future=new TransactionTemplate(transactions).execute(status -> footprints.forFutureFinishedInbound(
                List.of(new WarehouseDimension(c.world().warehouseId(),c.world().goodsA(),productColor(c))),List.of(c.planItem())));
        assertNotNull(future); assertActualInputs(c,future);
        fixture.confirmFinishedInboundFully(c.inbound());
        assertEquals(1,db.queryForObject("SELECT COUNT(*) FROM stock_value_production_cost_objects WHERE execution_segment_id=?",
                Integer.class,c.segment()));
    }

    @Test void subsequentConsumedInputsChangeDiscoveryAndCrossWarehouseReceiptAndWithdrawalKeepTheSameCostFamily() {
        Case c=consumedFirstHalf("partial-cost-footprint");
        fixture.confirmFinishedInboundFully(c.inbound());
        var before=document(c.inbound());
        assertEquals(0,pendingInputs(c.segment()));
        UUID destination=UUID.randomUUID();
        db.update("INSERT INTO warehouses(id,code,name,status,is_accountable) VALUES(?,?,?,'使用',TRUE)",
                destination,"COST-FP-"+destination,"成本足迹第二成品仓");
        var secondWorld=at(c.world(),destination);
        UUID secondReport=ReflectionTestUtils.invokeMethod(fixture,"reportAndApprove",secondWorld,
                c.planItem(),c.orderItem(),c.world().goodsA(),"5");
        UUID secondInbound=fixture.finishedInDocForReport(secondReport);
        var changed=document(c.inbound());
        assertNotEquals(before.fingerprint(),changed.fingerprint(),
                "New confirmed consumption must invalidate the old discovery even for an existing receipt");
        assertActualInputs(c,document(secondInbound));
        assertTrue(document(secondInbound).mainWarehouseIds().containsAll(List.of(c.world().warehouseId(),destination)));
        fixture.confirmFinishedInboundFully(secondInbound);
        ReflectionTestUtils.invokeMethod(fixture,"drainCosts",c.world());
        stock.reverseFinishedInbound(secondInbound);
        assertEquals(0,db.queryForObject("SELECT qty FROM stock_balances WHERE warehouse_id=? AND goods_id=?",
                BigDecimal.class,destination,c.world().goodsA()).compareTo(BigDecimal.ZERO));
        assertActualInputs(c,document(c.inbound()));
    }

    @Test void approvedSupplementMemberChangesTheFootprintAndItsFutureReceiptIncludesOriginalConsumedInputs() {
        Case c=consumedFirstHalf("member-cost-footprint");
        fixture.loginAs(c.world().superAdminUserId());
        var before=document(c.inbound());
        UUID allocation=db.queryForObject("""
                SELECT DISTINCT execution_segment_sales_allocation_id FROM production_daily_report_items
                WHERE execution_segment_id=? AND NOT is_deleted
                """,UUID.class,c.segment());
        var supplements=beans.getBean(com.uten.imp.features.production.dailyreport.ActualOutputSupplementService.class);
        BigDecimal actual=new BigDecimal("8");
        var preview=supplements.preview(new com.uten.imp.features.production.dailyreport.ActualOutputSupplementContracts.PreviewRequest(
                c.segment(),actual,allocation,null));
        assertTrue(preview.requiresSupplement());
        var today=com.uten.imp.common.time.BusinessTime.today();
        var requested=supplements.create(new com.uten.imp.features.production.dailyreport.ActualOutputSupplementContracts.CreateRequest(
                c.segment(),actual,allocation,preview.fingerprint(),today,today.plusDays(1),
                "核对同批实际产量后批准追加","cost-member-"+UUID.randomUUID(),null,null,null));
        beans.getBean(com.uten.imp.features.production.plan.ProductionPlanService.class).approve(requested.planId());
        var approved=supplements.detail(requested.id());
        assertNotNull(approved.proofId());
        assertEquals(2,db.queryForObject("SELECT COUNT(*) FROM fn_production_execution_cost_members(?)",Integer.class,c.segment()));
        assertNotEquals(before.fingerprint(),document(c.inbound()).fingerprint());
        UUID item=db.queryForObject("SELECT source_plan_item_id FROM production_execution_segments WHERE id=?",UUID.class,approved.supplementSegmentId());
        var future=new TransactionTemplate(transactions).execute(status -> footprints.forFutureFinishedInbound(
                List.of(new WarehouseDimension(c.world().warehouseId(),c.world().goodsA(),productColor(c))),List.of(item)));
        assertNotNull(future); assertActualInputs(c,future);
    }

    private Case consumedFirstHalf(String tag) {
        var w=fixture.seedWorld(tag+"-"+UUID.randomUUID()); fixture.loginAs(w.superAdminUserId());
        ReflectionTestUtils.invokeMethod(fixture,"receiveOpeningInputsForA",w,"10");
        UUID plan=ReflectionTestUtils.invokeMethod(fixture,"approvedPlan",w,w.goodsA(),"10","10");
        ReflectionTestUtils.invokeMethod(fixture,"issueReadyPlanAndMaterials",w,plan);
        UUID item=db.queryForObject("SELECT id FROM production_plan_items WHERE plan_id=? AND goods_id=? AND NOT is_deleted",UUID.class,plan,w.goodsA());
        UUID orderItem=db.queryForObject("SELECT order_item_id FROM plan_order_item_links WHERE plan_item_id=? AND NOT is_deleted",UUID.class,item);
        UUID segment=db.queryForObject("SELECT id FROM production_execution_segments WHERE source_plan_item_id=? AND NOT is_deleted",UUID.class,item);
        UUID report=ReflectionTestUtils.invokeMethod(fixture,"reportAndApprove",w,item,orderItem,w.goodsA(),"5");
        return new Case(w,item,orderItem,segment,fixture.finishedInDocForReport(report));
    }

    private FulfillmentMutationLockPlan document(UUID id) {
        return new TransactionTemplate(transactions).execute(status -> footprints.forStockDocuments(List.of(id)));
    }

    private void assertActualInputs(Case c,FulfillmentMutationLockPlan footprint) {
        assertNotNull(footprint);
        assertTrue(footprint.inventoryDimensions().contains(new InventoryDimension(c.world().goodsB(),null)));
        assertTrue(footprint.inventoryDimensions().contains(new InventoryDimension(c.world().goodsE(),null)));
    }

    private int pendingInputs(UUID segment) {
        return db.queryForObject("""
                SELECT COUNT(*) FROM production_material_settlement_postings posting
                JOIN production_material_demands demand ON demand.id=posting.demand_id
                JOIN stock_value_events event ON event.source_event_id=posting.id AND event.source_doc_type='PRODUCTION_CONSUMED_VALUE'
                JOIN stock_value_nodes node ON node.id=event.result_node_id AND node.active
                WHERE demand.execution_segment_id=? AND NOT EXISTS(
                    SELECT 1 FROM stock_value_production_cost_inputs input WHERE input.approved_posting_id=posting.id)
                """,Integer.class,segment);
    }

    private UUID productColor(Case c) {
        return db.queryForObject("SELECT color_id FROM production_plan_items WHERE id=?",UUID.class,c.planItem());
    }

    private static FullChainEndToEndTest.World at(FullChainEndToEndTest.World w,UUID warehouse) {
        return new FullChainEndToEndTest.World(w.departmentId(),w.employeeId(),w.superAdminUserId(),w.goodsA(),w.goodsB(),w.goodsC(),w.goodsD(),w.goodsE(),
                w.clientId(),w.supplierId(),warehouse,w.unitId(),w.currencyId(),w.colorId(),w.unitLegacy());
    }

    private record Case(FullChainEndToEndTest.World world,UUID planItem,UUID orderItem,UUID segment,UUID inbound) {}
}
