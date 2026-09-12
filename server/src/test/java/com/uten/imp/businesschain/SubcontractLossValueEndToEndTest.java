package com.uten.imp.businesschain;

import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.stock.StockDocService;
import com.uten.imp.features.stock.valuation.InventoryValueWorkService;
import com.uten.imp.features.subcontract.order.SubcontractOrderService;
import com.uten.imp.features.subcontract.material_issue.SubcontractMaterialIssueService;
import com.uten.imp.features.subcontract.plan.SubcontractMaterialPlanService;
import com.uten.imp.features.subcontract.receipt.SubcontractReceiptService;
import com.uten.imp.features.subcontract.waste.SubcontractWasteService;
import com.uten.imp.features.finance.payables.SubcontractLossClaimService;
import com.uten.imp.features.finance.gl.GlPostingService;
import com.uten.imp.features.warehouse.inbound.ProcurementInspectionService;
import com.uten.imp.features.warehouse.inbound.ProcurementIqcStockInService;
import com.uten.imp.features.warehouse.inbound.ProcurementIqcStockInContracts.*;
import com.uten.imp.features.finance.payables.SubcontractLossClaimContracts.*;
import com.uten.imp.features.finance.procurement.ProcurementApprovalContracts.*;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import java.math.BigDecimal;
import java.time.format.DateTimeFormatter;
import java.util.*;
import static org.junit.jupiter.api.Assertions.*;

/** Actual commercial approval, physical source, loss classification, receipt and value-worker integration. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
@SpringBootTest(webEnvironment=SpringBootTest.WebEnvironment.MOCK,properties={
        "spring.profiles.active=dev","uten.audit.retention.enabled=false","uten.reporting.materialized-view-refresh.enabled=false",
        "uten.policy-intelligence.enabled=false","uten.features.goods-owner-scope-enabled=false","uten.storage.uploads-enabled=true",
        "uten.storage.malware-scan.provider=test-only","uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only",
        "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789","uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only",
        "uten.bootstrap.admin-login=full-chain-bootstrap-admin-test","uten.bootstrap.admin-password=HarnessAdminPass-1!"})
class SubcontractLossValueEndToEndTest {
    @DynamicPropertySource static void database(DynamicPropertyRegistry registry){FullChainEndToEndTest.registerDataSource(registry);}
    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    @Autowired StockDocService stockDocs;
    @Autowired SubcontractOrderService orders;
    @Autowired SubcontractMaterialIssueService issues;
    @Autowired SubcontractMaterialPlanService plans;
    @Autowired SubcontractReceiptService receipts;
    @Autowired SubcontractWasteService wastes;
    @Autowired SubcontractLossClaimService claims;
    @Autowired ProcurementInspectionService inspections;
    @Autowired ProcurementIqcStockInService stockIns;
    @Autowired InventoryValueWorkService worker;
    @Autowired GlPostingService gl;
    @Autowired org.springframework.transaction.PlatformTransactionManager transactionManager;
    private FullChainEndToEndTest fixture;
    @BeforeEach void fixture(){fixture=new FullChainEndToEndTest();beans.autowireBean(fixture);}

    @Test void normalLossKeepsApprovedFiveAndReallocatesOnlyAfterFinancialApprovalOfThree(){
        var c=ready("normal-approved-target","5","5");
        assertThrows(ApiException.class,()->changeQty(c,"3"),"尚无实退或损耗时不能减少已实发五件的商业目标");
        money(decimal("select qty from subcontract_order_items where id=?",c.item()),"5");
        UUID loss=loss(c,"2","2");
        receive(c,"1");drain();money(stock(c),"51.4");money(normalHeld(c),"1.6");
        receive(c,"2");drain();money(stock(c),"154.2");money(normalHeld(c),"0.8");
        fixture.loginAs(c.world().superAdminUserId());changeQty(c,"3");
        money(decimal("select sum(planned_qty) from subcontract_material_plan_items where order_item_id=? and not is_deleted",c.item()),"5");
        money(decimal("select sum(issued_qty) from subcontract_material_plan_items where order_item_id=? and not is_deleted",c.item()),"5");
        money(decimal("select sum(loss_replacement_qty_base) from subcontract_material_plan_items where order_item_id=? and not is_deleted",c.item()),"2");
        money(decimal("select target_qty_base from v_subcontract_normal_loss_basis where order_item_id=?",c.item()),"5");
        drain();money(stock(c),"154.2");
        fixture.loginAs(c.submitted().reviewerUserId());fixture.approvePendingFinance("SUBCONTRACT",c.submitted().orderId());
        org.springframework.security.core.context.SecurityContextHolder.clearContext();drain();
        money(stock(c),"155");money(normalHeld(c),"0");
        assertEquals(2,integer("select count(*) from stock_value_production_cost_outputs where execution_segment_id=?",c.item()));
        assertEquals(2,integer("select count(*) from stock_value_production_cost_tasks task join stock_value_production_cost_objects object on object.current_revision_id=task.revision_id where object.execution_segment_id=? and task.denominator=3 and task.input_quantity_basis=2",c.item()),
                "正常损耗2件仍为原投入，仅价值按1/3和2/3分配，不能把实物数量圆成0.6667");
        assertEquals(0,integer("select count(*) from stock_value_nodes node join stock_value_pools pool on pool.id=node.pool_id where pool.goods_id=? and node.owner_kind='LOSS'",c.world().goodsE()));
        assertTwoChildren();
    }

    @Test void physicalLossAllowsTwoMorePiecesWithoutInflatingTheCommercialTargetToSeven(){
        var c=ready("normal-replenishment","5","5");loss(c,"2","2");receive(c,"3");drain();
        fixture.loginAs(c.world().superAdminUserId());opening(c.world(),"2","2");
        UUID additional=plans.regenerateDraft(c.plan());approveIssue(c.world(),additional,c.item(),"2");
        receive(c,"2");drain();money(stock(c),"257");
        money(decimal("select qty from subcontract_order_items where id=?",c.item()),"5");
        money(decimal("select sum(at_supplier_qty) from subcontract_material_issue_items where order_item_id=?",c.item()),"7");
        money(decimal("select sum(consumed_qty) from subcontract_material_issue_items where order_item_id=?",c.item()),"5");
        money(normalHeld(c),"0");
        money(new org.springframework.transaction.support.TransactionTemplate(transactionManager).execute(status->{
            db.queryForObject("select id from subcontract_orders where id=? for update",UUID.class,c.submitted().orderId());
            return plans.minimumOrderQtyFromIssued(c.item(),BigDecimal.ONE);
        }),"5");
        assertTwoChildren();
    }

    @Test void excessLossUsesOriginalUnroundedSourceAndFinancialClaimRemainsIndependent(){
        var c=ready("excess-exact-source","5","5.000000025");UUID loss=loss(c,"3","2");drain();
        UUID line=db.queryForObject("select item.id from subcontract_waste_items item where item.waste_id=?",UUID.class,loss);
        var actual=db.queryForMap("select * from v_subcontract_waste_actual_value where waste_item_id=?",line);
        money((BigDecimal)actual.get("normal_value_local"),"2.00000001");money((BigDecimal)actual.get("excess_value_local"),"1.000000005");
        money(decimal("select item.amount_local from stock_document_items item join stock_documents document on document.id=item.doc_id where document.doc_type='OTHER_IN' and item.goods_id=?",c.world().goodsE()),"5.000000025");
        money(decimal("select node.source_amount_exact from stock_value_nodes node join stock_value_pools pool on pool.id=node.pool_id where pool.goods_id=? and node.kind='SOURCE' and node.movement_id is not null",c.world().goodsE()),"5.000000025");
        UUID caseId=db.queryForObject("select id from subcontract_loss_cases where waste_id=?",UUID.class,loss);
        fixture.loginAs(c.world().superAdminUserId());var detail=claims.detail(caseId);
        BigDecimal amount=new BigDecimal("7.000000123456789012345678");
        claims.decide(caseId,new DecisionRequest(detail.summary().version(),false,"按真实责任单确认独立赔偿金额",List.of(
                new ResolutionInput(detail.lines().getFirst().id(),"CASH_COMPENSATION",BigDecimal.ONE,amount,BusinessTime.today().plusDays(5),"尚未到账",List.of()))));
        var after=claims.detail(caseId);money(new BigDecimal(after.summary().lossBookValueLocal()),"1.000000005");
        money(new BigDecimal(after.summary().claimAmountLocal()),amount.toPlainString());
        money(decimal("select amount_original from supplier_claim_receivables where case_id=?",caseId),amount.toPlainString());
        fixture.seedChartOfAccounts();gl.generate(BusinessTime.today().format(DateTimeFormatter.ofPattern("yyyy-MM")));
        money(decimal("select sum(amount) from gl_entries where source_doc_type='SUBCONTRACT_ABNORMAL_LOSS' and source_doc_id=? and direction=1",loss),"1.000000005");
        assertTwoChildren();
    }

    @Test void missingCostStaysNullAndKnownFreeMaterialIsNotMistakenForMissingCost(){
        var unknown=ready("loss-missing-cost","3",null);UUID pending=loss(unknown,"1","0");
        UUID pendingCase=db.queryForObject("select id from subcontract_loss_cases where waste_id=?",UUID.class,pending);
        var detail=claims.detail(pendingCase);assertNull(detail.summary().lossBookValueLocal());
        assertNull(detail.lines().getFirst().lossBookValueLocal());assertEquals("MISSING_COST",detail.lines().getFirst().valuationStatus());
        assertNull(db.queryForObject("select loss_book_value_local from subcontract_loss_cases where id=?",BigDecimal.class,pendingCase));
        wastes.reverse(pending);drain();
        var free=ready("loss-known-free","3","0");UUID zero=loss(free,"1","0");
        UUID zeroCase=db.queryForObject("select id from subcontract_loss_cases where waste_id=?",UUID.class,zero);
        var valued=claims.detail(zeroCase);money(new BigDecimal(valued.summary().lossBookValueLocal()),"0");assertEquals("VALUED",valued.lines().getFirst().valuationStatus());
    }

    @Test void reversingClassifiedNormalLossRestoresTheSameSourceAfterPartialProduction(){
        var c=ready("normal-loss-reverse","5","5");UUID loss=loss(c,"2","2");receive(c,"3");drain();
        fixture.loginAs(c.world().superAdminUserId());wastes.reverse(loss);drain();money(stock(c),"153");
        money(decimal("select sum(node.owned_value_local) from stock_value_nodes node where node.owner_kind='SUBCONTRACT_WIP' and node.owner_id=?",c.issueItem()),"2");
        money(decimal("select sum(input.returned_consumption_qty) from stock_value_production_cost_inputs cost join stock_value_nodes input on input.id=cost.input_node_id where cost.execution_segment_id=?",c.item()),"2");
        money(normalHeld(c),"0");assertTwoChildren();
    }

    private CaseFixture ready(String tag,String quantity,String amount){
        var w=fixture.seedWorld(tag);fixture.loginAs(w.superAdminUserId());opening(w,quantity,amount);
        var submitted=fixture.submitLeafSubcontractForFinance(w,new BigDecimal(quantity));
        fixture.loginAs(submitted.reviewerUserId());fixture.approvePendingFinance("SUBCONTRACT",submitted.orderId());fixture.loginAs(w.superAdminUserId());
        UUID item=db.queryForObject("select id from subcontract_order_items where order_id=?",UUID.class,submitted.orderId());
        UUID issue=db.queryForObject("select header.id from subcontract_material_issues header join subcontract_material_issue_items line on line.issue_id=header.id where line.order_item_id=? and header.status=0 and not header.is_deleted",UUID.class,item);
        UUID issueItem=approveIssue(w,issue,item,quantity);
        UUID plan=db.queryForObject("select plan.plan_id from subcontract_material_issue_items issue join subcontract_material_plan_items plan on plan.id=issue.plan_item_id where issue.id=?",UUID.class,issueItem);
        return new CaseFixture(w,submitted,item,issue,issueItem,plan);
    }

    private void opening(FullChainEndToEndTest.World w,String quantity,String amount){
        fixture.loginAs(w.superAdminUserId());var command=new com.uten.imp.features.stock.dto.StockDocSaveRequest();
        command.setDocType("OTHER_IN");command.setBillDate(BusinessTime.today());command.setWarehouseId(w.warehouseId());
        var line=new com.uten.imp.features.stock.dto.StockDocItemLine();line.setGoodsId(w.goodsE());line.setUnitId(w.unitId());line.setUnitRate(BigDecimal.ONE);line.setQty(new BigDecimal(quantity));
        if(amount!=null){line.setAmountOriginal(new BigDecimal(amount));line.setAmountLocal(new BigDecimal(amount));
            line.setPrice(new BigDecimal(amount).divide(new BigDecimal(quantity),10,java.math.RoundingMode.HALF_UP));}
        command.setItems(List.of(line));stockDocs.approve(stockDocs.create(command).getId());
    }
    private UUID approveIssue(FullChainEndToEndTest.World w,UUID issue,UUID item,String quantity){
        var original=issues.detail(issue).getItems().getFirst();var command=new com.uten.imp.features.subcontract.material_issue.dto.MaterialIssueSaveRequest();
        command.setBillDate(BusinessTime.today());command.setSupplierId(w.supplierId());command.setWarehouseId(w.warehouseId());
        var line=new com.uten.imp.features.subcontract.material_issue.dto.MaterialIssueItemLine();line.setGoodsId(w.goodsE());line.setParentGoodsId(w.goodsE());
        line.setUnitId(w.unitId());line.setUnitRate(BigDecimal.ONE);line.setQty(new BigDecimal(quantity));line.setOrderItemId(item);line.setPlanItemId(original.getPlanItemId());command.setItems(List.of(line));
        issues.update(issue,command);return issues.approve(issue).getItems().getFirst().getId();
    }
    private UUID loss(CaseFixture c,String quantity,String normal){
        fixture.loginAs(c.world().superAdminUserId());var command=new com.uten.imp.features.subcontract.waste.dto.WasteSaveRequest();
        command.setBillDate(BusinessTime.today());command.setSupplierId(c.world().supplierId());command.setWarehouseId(c.world().warehouseId());
        var line=new com.uten.imp.features.subcontract.waste.dto.WasteItemLine();line.setGoodsId(c.world().goodsE());line.setUnitId(c.world().unitId());line.setUnitRate(BigDecimal.ONE);
        line.setMaterialIssueItemId(c.issueItem());line.setQty(new BigDecimal(quantity));line.setStandardQty(new BigDecimal(normal));line.setCause("核对实际材料损耗和合同允许数量");command.setItems(List.of(line));
        UUID id=wastes.create(command).getId();wastes.approve(id);return id;
    }
    private UUID receive(CaseFixture c,String quantity){
        fixture.loginAs(c.world().superAdminUserId());var command=new com.uten.imp.features.subcontract.receipt.dto.ReceiptSaveRequest();
        command.setBillDate(BusinessTime.today());command.setSupplierId(c.world().supplierId());command.setWarehouseId(c.world().warehouseId());
        command.setCurrencyId(c.world().currencyId());command.setExchangeRate(BigDecimal.ONE);command.setTaxRate(BigDecimal.ZERO);
        command.setSettlementMethodId(db.queryForObject("select settlement_method_id from subcontract_orders where id=?",UUID.class,c.submitted().orderId()));
        var line=new com.uten.imp.features.subcontract.receipt.dto.ReceiptItemLine();line.setGoodsId(c.world().goodsE());line.setOrderItemId(c.item());line.setUnitId(c.world().unitId());line.setUnitRate(BigDecimal.ONE);
        line.setQty(new BigDecimal(quantity));line.setPrice(new BigDecimal("50"));line.setAmountOriginal(line.getQty().multiply(line.getPrice()));line.setAmountLocal(line.getAmountOriginal());command.setItems(List.of(line));
        UUID receipt=receipts.create(command).getId();receipts.approve(receipt);
        UUID inspection=db.queryForObject("select id from procurement_inspection_items where receipt_type='SUBCONTRACT' and receipt_id=?",UUID.class,receipt);
        inspections.dispose("SUBCONTRACT",receipt,inspection,new com.uten.imp.features.warehouse.inbound.dto.InspectionDispositionRequest("PASS",null,"确认实际回厂合格量","normal-pass-"+receipt));
        UUID confirmer=fixture.createUserWithPerms(c.world(),"loss-stock-"+receipt,"warehouse_iqc_stock_in:view","warehouse_iqc_stock_in:confirm");fixture.loginAs(confirmer);
        var released=stockIns.detail("SUBCONTRACT",receipt).items().getFirst();
        stockIns.confirm("SUBCONTRACT",receipt,new ConfirmRequest("normal-stock-"+receipt,List.of(new ConfirmItem(released.passEventId(),new BigDecimal(quantity),released.remainingBaseQty(),"LOSS-TEST"))));
        fixture.loginAs(c.world().superAdminUserId());return receipt;
    }
    private void changeQty(CaseFixture c,String qty){orders.changeQty(c.submitted().orderId(),new OrderQtyChangeRequest(List.of(new OrderQtyChangeItem(c.item(),new BigDecimal(qty)))));}
    private void drain(){
        long deadline=System.nanoTime()+java.util.concurrent.TimeUnit.SECONDS.toNanos(30);
        for(int n=0;n<200&&System.nanoTime()<deadline;n++){
            int applied=worker.runBatch();
            if(!worker.hasPendingWork())return;
            // A scheduler may already own the remaining scope/task. Zero local
            // work is not proof that its uncommitted durable work has finished.
            if(applied==0)try{Thread.sleep(25);}catch(InterruptedException interrupted){
                Thread.currentThread().interrupt();throw new AssertionError("等待价值任务时被中断",interrupted);
            }
        }
        fail("原价值传播必须有限完成，不能在同scope内循环重算");
    }
    private BigDecimal stock(CaseFixture c){return decimal("select amount_local from stock_balances where warehouse_id=? and goods_id=?",c.world().warehouseId(),c.world().goodsE());}
    private BigDecimal normalHeld(CaseFixture c){return decimal("select coalesce(sum(node.owned_value_local),0) from stock_value_nodes node where node.owner_kind='COST_WIP' and node.owner_id=?",c.item());}
    private BigDecimal decimal(String sql,Object...args){return db.queryForObject(sql,BigDecimal.class,args);}
    private int integer(String sql,Object...args){return db.queryForObject(sql,Integer.class,args);}
    private void money(BigDecimal actual,String expected){assertNotNull(actual);assertEquals(0,actual.compareTo(new BigDecimal(expected)),"actual="+actual+", expected="+expected);}
    private void assertTwoChildren(){assertEquals(0,integer("select count(*) from (select parent_node_id from stock_value_edges group by parent_node_id having count(*)>2) invalid"));}
    private record CaseFixture(FullChainEndToEndTest.World world,FullChainEndToEndTest.ProcurementCase submitted,UUID item,UUID issue,UUID issueItem,UUID plan){}
}
