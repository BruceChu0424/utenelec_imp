package com.uten.imp.businesschain;

import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.features.finance.procurement.ProcurementFinanceApprovalService;
import com.uten.imp.features.production.analysis.MaterialAnalysisContracts;
import com.uten.imp.features.subcontract.short_delivery.SubcontractShortDeliveryContracts.DecisionRequest;
import com.uten.imp.features.subcontract.short_delivery.SubcontractShortDeliveryService;
import com.uten.imp.features.warehouse.inbound.ProcurementArrivalContracts.WarehouseArrivalRegisterResult;
import com.uten.imp.features.warehouse.inbound.ProcurementArrivalContracts.WarehouseArrivalRegisterRequest;
import com.uten.imp.features.warehouse.inbound.ProcurementArrivalContracts.WarehouseArrivalRegisterRequest.ArrivalLine;
import com.uten.imp.features.warehouse.inbound.WarehouseArrivalRegistrationService;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.CsvSource;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.util.ReflectionTestUtils;

import java.math.BigDecimal;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import java.util.ArrayList;
import org.junit.jupiter.api.function.Executable;

import static com.uten.imp.businesschain.AggregateMaterialOrderEndToEndTest.amount;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertAll;

/** Loss settles the contractual tail; actual private demand and issued materials retain exact quantities. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
@SpringBootTest(webEnvironment=SpringBootTest.WebEnvironment.MOCK,properties={
        "spring.profiles.active=dev","uten.audit.retention.enabled=false","uten.reporting.materialized-view-refresh.enabled=false",
        "uten.production.readiness-reconcile.enabled=false","uten.features.goods-owner-scope-enabled=false",
        "uten.storage.uploads-enabled=true","uten.storage.malware-scan.provider=test-only",
        "uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only",
        "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789",
        "uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only","uten.bootstrap.admin-login=full-chain-bootstrap-admin-test",
        "uten.bootstrap.admin-password=HarnessAdminPass-1!"})
class SubcontractAcceptedLossAnalysisEndToEndTest {
    // Explicit inputs for these scenarios; finite source values remain exact.
    private static java.util.Map<String, com.uten.imp.common.finance.BusinessPrecisionContext.Choice> scenarioChoices() {
        return java.util.Map.of(
                "subcontract.shortfall.percent", new com.uten.imp.common.finance.BusinessPrecisionContext.Choice(24, "HALF_UP"));
    }
    private final AutoCloseable scenarioPrecision = com.uten.imp.common.finance.BusinessPrecisionContext.use(scenarioChoices());
    @org.junit.jupiter.api.AfterEach void releaseScenarioPrecision() throws Exception { scenarioPrecision.close(); }

    @DynamicPropertySource static void database(DynamicPropertyRegistry registry) {
        FullChainEndToEndTest.registerDataSource(registry);
    }
    @Autowired AutowireCapableBeanFactory beans;
    @Autowired ProcurementFinanceApprovalService finance;
    @Autowired WarehouseArrivalRegistrationService arrivals;
    @Autowired SubcontractShortDeliveryService shortDeliveries;
    AggregateMaterialOrderEndToEndTest h;
    final List<Executable> analysisChecks = new ArrayList<>();
    @BeforeEach void before() { analysisChecks.clear();h=new AggregateMaterialOrderEndToEndTest();beans.autowireBean(h);h.before(); }
    @AfterEach void after() { h.after(); }

    @ParameterizedTest
    @CsvSource({"110,100,0", "100,90,10"})
    void acceptedLossPreservesBothThePublicTailAndAnyRealPrivateShortage(String ordered,String receivedQty,String remaining) {
        // 来源需求100。公共尾差：下110、收100、损耗10，私有需求足额完成。
        // 私有真缺口：下100、收90、损耗10，仍须补10，损耗不能冒充实收。
        var c=h.createWithChild("100",1,"SUBCONTRACT");var w=c.world();h.assertMasterRoute(c,c.common(),"SUBCONTRACT");
        var batch=h.writer.submit(c.analysis(),h.command(c,List.of(h.input(c,c.common(),"SUBCONTRACT",ordered,true))))
                .batches().getFirst();
        UUID applicationItem=h.db.queryForObject("SELECT id FROM subcontract_application_items WHERE application_id=? AND NOT is_deleted",UUID.class,batch.documentId());
        Object kit=ReflectionTestUtils.invokeMethod(h.fixture,"stageSubcontractKit",w,Map.of(c.common(),ordered));
        UUID order=ReflectionTestUtils.invokeMethod(h.fixture,"createSubcontractOrderFromApplication",w,c.common(),applicationItem,ordered);
        h.db.update("UPDATE subcontract_order_items SET allowed_loss_pct=10 WHERE order_id=?",order);
        ReflectionTestUtils.invokeMethod(h.fixture,"stageSubcontractKitUntilApproval",order,kit);
        UUID reviewer=ReflectionTestUtils.invokeMethod(h.fixture,"createApprover",w);
        finance.submit("SUBCONTRACT",order);h.fixture.loginAs(reviewer);h.fixture.approvePendingFinance("SUBCONTRACT",order);
        h.fixture.loginAs(w.superAdminUserId());
        UUID item=h.db.queryForObject("SELECT id FROM subcontract_order_items WHERE order_id=?",UUID.class,order);
        var frozen = h.db.queryForMap("""
                SELECT base_bom_unit_qty,material_loss_pct,bom_unit_qty,planned_qty
                FROM subcontract_material_plan_items WHERE order_item_id=? AND goods_id=? AND NOT is_deleted
                """,item,c.child());
        amount("1",(BigDecimal)frozen.get("base_bom_unit_qty"));
        amount("10",(BigDecimal)frozen.get("material_loss_pct"));
        amount("1.1",(BigDecimal)frozen.get("bom_unit_qty"));
        BigDecimal materialQty=(BigDecimal)frozen.get("planned_qty");
        amount(new BigDecimal(ordered).multiply(new BigDecimal("1.1")).toPlainString(),materialQty);
        // V961 adds normal raw-material allowance without reducing the finished target.
        h.fixture.receiveSubcontractMaterial(w,c.child(),materialQty.toPlainString());
        h.fixture.drawAndIssueSubcontract(item,new BigDecimal(ordered),"loss-analysis-draw-"+UUID.randomUUID());
        amount(materialQty.toPlainString(),h.db.queryForObject("""
                SELECT issued_qty FROM subcontract_material_plan_items
                WHERE order_item_id=? AND goods_id=? AND NOT is_deleted
                """,BigDecimal.class,item,c.child()));
        assertAnalysis(c,"0",ordered,"0");

        var inbound=new SubcontractComponentReturnLegEndToEndTest();beans.autowireBean(inbound);
        ReflectionTestUtils.setField(inbound,"fixture",h.fixture);
        WarehouseArrivalRegisterResult received=arrivals.register(new WarehouseArrivalRegisterRequest(
                "loss-analysis-"+UUID.randomUUID(),"SUBCONTRACT",BusinessTime.today(),w.supplierId(),w.warehouseId(),
                null,w.employeeId(),null,List.of(new ArrivalLine(c.common(),new BigDecimal(receivedQty),item,null,
                w.unitId(),BigDecimal.ONE,null,null)),null,null));
        Object pass=ReflectionTestUtils.invokeMethod(inbound,"passIqc",received.receiptId(),"loss-analysis-pass-"+UUID.randomUUID());
        amount("0",h.db.queryForObject("SELECT fn_subcontract_settled_loss_qty(?)",BigDecimal.class,item));
        assertAnalysis(c,"0",ordered,"0");
        UUID keeper=ReflectionTestUtils.invokeMethod(h.fixture,"createIqcWarehouseConfirmer",w,
                "loss-analysis-keeper-"+UUID.randomUUID().toString().substring(0,8));
        ReflectionTestUtils.invokeMethod(inbound,"stockIn",keeper,received.receiptId(),pass,"loss-analysis-stock-"+UUID.randomUUID(),w);
        h.fixture.loginAs(w.superAdminUserId());
        InventoryValueWorkTestSupport.drain(beans.getBean(com.uten.imp.features.stock.valuation.InventoryValueWorkService.class),
                h.db,List.of(c.common(),c.child(),c.material()));
        // New normal-loss supply must never silently settle finished shortfall.
        amount("0",h.db.queryForObject("SELECT fn_subcontract_settled_loss_qty(?)",BigDecimal.class,item));
        UUID shortCase=h.db.queryForObject("""
                SELECT id FROM subcontract_short_delivery_cases
                WHERE order_item_id=? AND status IN ('PENDING_OWNER','WAITING_MORE') AND closed_at IS NULL
                """,UUID.class,item);
        var pending=shortDeliveries.detail(shortCase).row();
        shortDeliveries.decide(shortCase,new DecisionRequest("ACCEPT_LOSS",null,
                "负责人核对实收后明确接受成品短交；正常供料损耗不能代替实收",pending.version()));
        amount(ordered,h.db.queryForObject("SELECT qty FROM subcontract_order_items WHERE id=?",BigDecimal.class,item));
        amount(receivedQty,h.db.queryForObject("SELECT received_qty FROM subcontract_order_items WHERE id=?",BigDecimal.class,item));
        amount("10",h.db.queryForObject("SELECT fn_subcontract_settled_loss_qty(?)",BigDecimal.class,item));

        assertAnalysis(c,receivedQty,remaining,remaining);
        UUID action=h.db.queryForObject("SELECT action_id FROM preplan_aggregate_batches WHERE id=?",UUID.class,batch.batchId());
        amount(receivedQty,h.db.queryForObject("SELECT fn_preplan_action_received_qty(?)",BigDecimal.class,action));
        assertAll("Every analysis phase preserves actual receipts and exact private demand",analysisChecks);
        assertFinalLossSource(c,shortCase);
    }

    private void assertFinalLossSource(AggregateMaterialOrderEndToEndTest.Case c,UUID shortCase) {
        String sql="""
                SELECT line.case_id,line.normal_value_node_id,line.excess_value_node_id,
                       line.loss_book_value_local,line.valuation_status
                FROM subcontract_loss_case_lines line JOIN subcontract_loss_cases loss ON loss.id=line.case_id
                WHERE loss.waste_id=(SELECT waste_id FROM subcontract_short_delivery_cases WHERE id=?)
                """;
        var original=h.db.queryForMap(sql,shortCase);
        assertEquals("MISSING_COST",original.get("valuation_status"),
                "A queued final cost revision must not freeze the earlier availability as VALUED");
        amount("0",(BigDecimal)original.get("loss_book_value_local"));
        InventoryValueWorkTestSupport.drain(beans.getBean(com.uten.imp.features.stock.valuation.InventoryValueWorkService.class),
                h.db,List.of(c.common(),c.child(),c.material()));
        assertEquals(original,h.db.queryForMap(sql,shortCase),"Settling work cannot replace original loss interval references");
        var detail=beans.getBean(com.uten.imp.features.finance.payables.SubcontractLossClaimService.class)
                .detail((UUID)original.get("case_id"));
        assertEquals("VALUED",detail.lines().getFirst().valuationStatus());
        amount("0",new BigDecimal(detail.lines().getFirst().lossBookValueLocal()));
    }

    private void assertAnalysis(AggregateMaterialOrderEndToEndTest.Case c,String fulfilled,String childRequirement,String remaining) {
        var before=h.analyses.detail(c.analysis());
        var view=h.analyses.preview(new MaterialAnalysisContracts.PreviewRequest(c.analysis(),before.version(),before.fingerprint(),
                c.world().warehouseId(),"loss-analysis-refresh-"+UUID.randomUUID(),before.products().stream()
                .filter(source->"SALES_ORDER_ITEM".equals(source.sourceType()))
                .map(source->new MaterialAnalysisContracts.PreviewItem("SALES_ORDER_ITEM",source.salesOrderItemId(),null,null,null,
                        null,null,source.deliveryDate(),source.requestedQty())).toList()));
        var parent=view.flatMaterials().stream().filter(row->row.goodsId().equals(c.common())).findFirst().orElseThrow();
        analysisChecks.add(()->amount("100",parent.sourceRequiredQty()));
        analysisChecks.add(()->amount("100",parent.requiredQty()));
        analysisChecks.add(()->amount(fulfilled,parent.exactPeggedQty()));
        analysisChecks.add(()->amount(remaining,parent.planningUncoveredQty()));
        analysisChecks.add(()->amount(remaining,parent.netShortageQty()));
        var child=view.flatMaterials().stream().filter(row->row.goodsId().equals(c.child())).findFirst().orElseThrow();
        analysisChecks.add(()->amount(childRequirement,child.requiredQty()));
        analysisChecks.add(()->amount(remaining,child.planningUncoveredQty()));
        // Requirement/quantity uses the exact frozen BOM; tolerance never turns an integer requirement into a fraction.
        for(var row:view.flatMaterials())analysisChecks.add(()->assertEquals(0,row.requiredQty().stripTrailingZeros().scale()>0?1:0,
                "Fractional requirement introduced by tolerance: "+row.goodsCode()+"="+row.requiredQty()));
    }
}
