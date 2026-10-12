package com.uten.imp.businesschain;

import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.features.documents.DocumentUnapprovalService;
import com.uten.imp.features.common.taskclaim.TaskClaimService;
import com.uten.imp.features.finance.procurement.ProcurementFinanceApprovalService;
import com.uten.imp.features.purchase.order.PurchaseOrderService;
import com.uten.imp.features.purchase.receipt.PurchaseReceiptService;
import com.uten.imp.features.purchase.request.PurchaseRequestService;
import com.uten.imp.features.purchase.ret.PurchaseReturnService;
import com.uten.imp.features.warehouse.inbound.ProcurementInspectionService;
import com.uten.imp.features.warehouse.inbound.ProcurementIqcStockInService;
import com.uten.imp.features.warehouse.inbound.dto.InspectionDispositionRequest;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.util.ReflectionTestUtils;
import java.math.BigDecimal;
import java.util.*;
import static com.uten.imp.features.finance.procurement.ProcurementApprovalContracts.*;
import static org.assertj.core.api.Assertions.*;
import static com.uten.imp.features.production.analysis.MaterialAnalysisContracts.*;

/** One isolated migrated context; new business data and actual approval/quality/stock/value ports in every case. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
@SpringBootTest(properties={"spring.profiles.active=dev","uten.audit.retention.enabled=false",
    "uten.reporting.materialized-view-refresh.enabled=false","uten.production.readiness-reconcile.enabled=false",
    "uten.features.goods-owner-scope-enabled=false","uten.storage.uploads-enabled=false",
    "uten.jwt.secret=gift-regression-isolated-jwt-key-0123456789-abcdef", // gitleaks:allow synthetic cryptographic key for this isolated JUnit SpringBootTest.
    "uten.crypto.pgp-master-key=gift-regression-isolated-pgp-key-0123456789-abcdef", // gitleaks:allow synthetic cryptographic key for this isolated JUnit SpringBootTest.
    "uten.crypto.hmac-key=gift-regression-isolated-hmac-key-0123456789-abcdef",
    "uten.bootstrap.admin-login=gift-regression-bootstrap","uten.bootstrap.admin-password=GiftRegressionAdmin-1!"})
class GiftPhysicalDemandCoverageEndToEndTest {
    @DynamicPropertySource static void database(DynamicPropertyRegistry registry){FullChainEndToEndTest.registerDataSource(registry);}
    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    @Autowired PurchaseRequestService requests;
    @Autowired PurchaseOrderService orders;
    @Autowired PurchaseReceiptService receipts;
    @Autowired PurchaseReturnService returns;
    @Autowired ProcurementFinanceApprovalService finance;
    @Autowired TaskClaimService claims;
    @Autowired ProcurementInspectionService inspection;
    @Autowired ProcurementIqcStockInService stockIn;
    @Autowired DocumentUnapprovalService unapproval;
    @Autowired com.uten.imp.features.production.plan.ProductionPlanService plans;
    @Autowired com.uten.imp.features.production.analysis.MaterialAnalysisService analyses;
    @Autowired com.uten.imp.features.production.analysis.MaterialAnalysisCommandService analysisCommands;
    private FullChainEndToEndTest harness;
    private record F(FullChainEndToEndTest.World w,UUID requestItem,UUID order,UUID orderItem,UUID currency){}
    @BeforeEach void prepare(){harness=new FullChainEndToEndTest();beans.autowireBean(harness);}
    @AfterEach void clear(){SecurityContextHolder.clearContext();}












    @Test void demandTenIsCoveredByPaidNineAndFreeOneWhileCountersRemainSeparate(){
        F f=fixture("0","9");
        assertThat(number("SELECT ordered_qty FROM purchase_request_items WHERE id=?",f.requestItem())).isEqualByComparingTo("9");
        assertThat(number("SELECT gift_ordered_qty FROM purchase_request_items WHERE id=?",f.requestItem())).isEqualByComparingTo("1");
        assertThat(number("SELECT qty FROM purchase_request_items WHERE id=?",f.requestItem())).isEqualByComparingTo("10");
        assertThat(db.queryForObject("SELECT r.is_closed FROM purchase_requests r JOIN purchase_request_items i ON i.request_id=r.id WHERE i.id=?",Boolean.class,f.requestItem())).isTrue();
        UUID received=receipt(f,"9","1");receipts.approve(received);passAndStock(f,received);
        assertThat(stock(f)).isEqualByComparingTo("10");assertThat(value(f)).isEqualByComparingTo("90");assertThat(ap(received)).isEqualByComparingTo("90");
    }

    @Test void trueProductionPlanNeedsTenAndReceivesNineChargedPlusOneFreeWithoutChangingItsOriginalNeed(){ plannedSupply(true); }
    @Test void analysisReadyTenBeforeIssueThenNewPlanUsesTenPhysicalUnitsWithoutChangingChargedNine(){ plannedSupply(false); }
    private void plannedSupply(boolean issueEarly){
        var w=harness.seedWorld("gift-plan-"+UUID.randomUUID());harness.loginAs(w.superAdminUserId());
        UUID product=UUID.randomUUID();harness.insertGoods(product,"GIFT-PLAN-"+product,"赠品备料就绪验算","自制",w.unitId(),w.unitLegacy());
        harness.insertBom(product,w.goodsD(),"1");db.update("UPDATE goods SET default_supplier_id=? WHERE id=?",w.supplierId(),w.goodsD());
        AnalysisView analysis=analyses.preview(new PreviewRequest(null,null,null,w.warehouseId(),"gift-plan-preview-"+product,List.of(new PreviewItem("STOCK",null,product,null,w.unitId(),"GIFT-PLAN-"+product,"gift coverage",BusinessTime.today(),new BigDecimal("10")))));
        UUID rootId=analysis.products().getFirst().rootMaterialLineId();
        MaterialView root=analysis.flatMaterials().stream().filter(row->row.materialLineId().equals(rootId)).findFirst().orElseThrow();
        MaterialView buy=analysis.flatMaterials().stream().filter(row->row.goodsId().equals(w.goodsD())&&row.actionable()).findFirst().orElseThrow();
        analyses.saveRoutes(analysis.analysisId(),new RouteRequest(analysis.version(),analysis.fingerprint(),"gift-plan-route-"+product,List.of(new RouteDecision(root.materialLineId(),root.actionGroupKey(),"MAKE",null),new RouteDecision(buy.materialLineId(),buy.actionGroupKey(),"BUY",null))));
        analysis=analyses.detail(analysis.analysisId());
        analysisCommands.notifySupply(analysis.analysisId(),new NotifyRequest(analysis.version(),analysis.fingerprint(),"gift-plan-notify-"+product,"BUY",List.of(buy.materialLineId()),List.of(),null));
        UUID requestItem=db.queryForObject("SELECT allocation.external_item_id FROM preplan_supply_action_allocations allocation JOIN preplan_supply_actions action ON action.id=allocation.action_id WHERE action.analysis_id=? AND action.route='BUY' AND action.status='CREATED'",UUID.class,analysis.analysisId());
        analysis=analyses.detail(analysis.analysisId());
        UUID plan=issueEarly?issuePlan(analysis,w,product):null;
        assertThat(number("SELECT qty FROM purchase_request_items WHERE id=?",requestItem)).isEqualByComparingTo("10");
        UUID currency=db.queryForObject("SELECT id FROM currencies WHERE is_base_currency AND NOT is_deleted",UUID.class);
        UUID reviewer=harness.createUserWithPerms(w,"gift-plan-finance-"+UUID.randomUUID(),"finance_order_approval:view","finance_order_approval:approve");harness.loginAs(w.superAdminUserId());
        var order=new com.uten.imp.features.purchase.order.dto.OrderSaveRequest();order.setBillDate(BusinessTime.today());order.setSupplierId(w.supplierId());order.setWarehouseId(w.warehouseId());order.setCurrencyId(currency);order.setExchangeRate(BigDecimal.ONE);order.setTaxRate(BigDecimal.ZERO);order.setSettlementMethodId(settlement());
        var line=new com.uten.imp.features.purchase.order.dto.OrderItemLine();line.setGoodsId(w.goodsD());line.setUnitId(w.unitId());line.setUnitRate(BigDecimal.ONE);line.setQty(new BigDecimal("9"));line.setGiftQty(BigDecimal.ONE);line.setPrice(new BigDecimal("10"));line.setRequestItemId(requestItem);order.setItems(List.of(line));
        UUID id=orders.create(order).getId();finance.submit("PURCHASE",id);harness.loginAs(reviewer);
        var approval=db.queryForMap("SELECT id,version FROM procurement_order_approval_cases WHERE order_type='PURCHASE' AND order_id=? AND status='PENDING'",id);UUID caseId=(UUID)approval.get("id");
        UUID claim=claims.claim("PROCUREMENT_FINANCE_APPROVE",caseId.toString()).claimId();finance.approveBatch(List.of(new BatchDecisionItem(caseId,((Number)approval.get("version")).longValue(),claim)),null,BigDecimal.ONE);harness.loginAs(w.superAdminUserId());
        F f=new F(w,requestItem,id,db.queryForObject("SELECT id FROM purchase_order_items WHERE order_id=?",UUID.class,id),currency);
        UUID received=receipt(f,"9","1");receipts.approve(received);passAndStock(f,received);
        assertThat(stock(f)).isEqualByComparingTo("10");assertThat(value(f)).isEqualByComparingTo("90");assertThat(ap(received)).isEqualByComparingTo("90");
        AnalysisView after=analyses.detail(analysis.analysisId());
        assertThat(after.products().getFirst().requestedQty()).isEqualByComparingTo("10");
        if(!issueEarly){
            assertThat(after.products().getFirst().readyNowQty()).isEqualByComparingTo("10");
            plan=issuePlan(after,w,product);
        } else {
            assertThat(after.products().getFirst().remainingQty()).isZero();
            assertThat(after.products().getFirst().issuedPlanQty()).isEqualByComparingTo("10");
        }
        assertThat(number("SELECT qty FROM production_plan_items WHERE plan_id=?",plan)).isEqualByComparingTo("10");
        assertThat(number("SELECT COALESCE(SUM(planned_qty),0) FROM production_execution_segments WHERE plan_id=? AND status='READY' AND NOT is_deleted",plan)).isEqualByComparingTo("10");
        assertThat(db.queryForObject("SELECT quantity_semantics FROM purchase_request_items WHERE id=?",String.class,requestItem)).isEqualTo("CHARGED_PLUS_GIFT_V1");
    }

    private UUID issuePlan(AnalysisView analysis,FullChainEndToEndTest.World w,UUID product){
        return analysisCommands.issueWorkshopPlans(analysis.analysisId(),new IssueWorkshopPlansRequest(analysis.version(),analysis.fingerprint(),"gift-plan-issue-"+product,w.warehouseId(),BusinessTime.today(),null,true,List.of(new IssueWorkshopPlansRequest.IssuePlanLine(analysis.products().getFirst().analysisLineId(),new BigDecimal("10"))))).plans().getFirst().planId();
    }

    private F fixture(){ return fixture("1","10"); }
    private F fixture(String requestedGift,String charged){
        var w=harness.seedWorld("gift-"+UUID.randomUUID());harness.loginAs(w.superAdminUserId());
        UUID currency=db.queryForObject("SELECT id FROM currencies WHERE is_base_currency AND NOT is_deleted",UUID.class);
        var req=new com.uten.imp.features.purchase.request.dto.RequestSaveRequest();req.setBillDate(BusinessTime.today());req.setWarehouseId(w.warehouseId());
        var rl=new com.uten.imp.features.purchase.request.dto.RequestItemLine();rl.setGoodsId(w.goodsD());rl.setUnitId(w.unitId());rl.setUnitRate(BigDecimal.ONE);rl.setQty(new BigDecimal("10"));rl.setGiftQty(new BigDecimal(requestedGift));req.setItems(List.of(rl));
        var source=requests.create(req);requests.approve(source.getId());UUID requestItem=source.getItems().getFirst().getId();
        UUID reviewer=harness.createUserWithPerms(w,"gift-finance-"+UUID.randomUUID(),"finance_order_approval:view","finance_order_approval:approve");harness.loginAs(w.superAdminUserId());
        var order=new com.uten.imp.features.purchase.order.dto.OrderSaveRequest();order.setBillDate(BusinessTime.today());order.setSupplierId(w.supplierId());order.setWarehouseId(w.warehouseId());order.setCurrencyId(currency);order.setExchangeRate(BigDecimal.ONE);order.setTaxRate(BigDecimal.ZERO);order.setSettlementMethodId(settlement());
        var line=new com.uten.imp.features.purchase.order.dto.OrderItemLine();line.setGoodsId(w.goodsD());line.setUnitId(w.unitId());line.setUnitRate(BigDecimal.ONE);line.setQty(new BigDecimal(charged));line.setGiftQty(BigDecimal.ONE);line.setPrice(new BigDecimal("10"));line.setRequestItemId(requestItem);order.setItems(List.of(line));
        UUID id=orders.create(order).getId();finance.submit("PURCHASE",id);harness.loginAs(reviewer);
        var approval=db.queryForMap("SELECT id,version FROM procurement_order_approval_cases WHERE order_type='PURCHASE' AND order_id=? AND status='PENDING'",id);UUID caseId=(UUID)approval.get("id");
        UUID claim=claims.claim("PROCUREMENT_FINANCE_APPROVE",caseId.toString()).claimId();finance.approveBatch(List.of(new BatchDecisionItem(caseId,((Number)approval.get("version")).longValue(),claim)),null,BigDecimal.ONE);harness.loginAs(w.superAdminUserId());
        return new F(w,requestItem,id,db.queryForObject("SELECT id FROM purchase_order_items WHERE order_id=?",UUID.class,id),currency);
    }
    private UUID receipt(F f,String charged,String gift){
        var request=new com.uten.imp.features.purchase.receipt.dto.ReceiptSaveRequest();request.setBillDate(BusinessTime.today());request.setSupplierId(f.w().supplierId());request.setWarehouseId(f.w().warehouseId());
        var line=new com.uten.imp.features.purchase.receipt.dto.ReceiptItemLine();line.setGoodsId(f.w().goodsD());line.setUnitId(f.w().unitId());line.setUnitRate(BigDecimal.ONE);line.setQty(new BigDecimal(charged));line.setGiftQty(new BigDecimal(gift));line.setOrderItemId(f.orderItem());request.setItems(List.of(line));
        return receipts.create(request).getId();
    }
    private UUID returned(F f,UUID source,String charged,String gift){
        var request=new com.uten.imp.features.purchase.ret.dto.ReturnSaveRequest();request.setBillDate(BusinessTime.today());request.setSupplierId(f.w().supplierId());request.setWarehouseId(f.w().warehouseId());
        var line=new com.uten.imp.features.purchase.ret.dto.ReturnItemLine();line.setGoodsId(f.w().goodsD());line.setUnitId(f.w().unitId());line.setUnitRate(BigDecimal.ONE);line.setQty(new BigDecimal(charged));line.setGiftQty(new BigDecimal(gift));line.setReceiptItemId(source);line.setOrderItemId(f.orderItem());request.setItems(List.of(line));
        return returns.create(request).getId();
    }
    private void passAndStock(F f,UUID receipt){
        harness.loginAs(f.w().superAdminUserId());List<UUID> ids=db.queryForList("SELECT id FROM procurement_inspection_items WHERE receipt_id=? ORDER BY quantity_tranche",UUID.class,receipt);
        for(UUID id:ids)inspection.dispose("PURCHASE",receipt,id,new InspectionDispositionRequest("PASS",null,"真实收费/赠品质检","gift-pass-"+id));
        UUID keeper=ReflectionTestUtils.invokeMethod(harness,"createIqcWarehouseConfirmer",f.w(),"gift-keeper-"+receipt);harness.loginAs(keeper);
        for(UUID id:ids){BigDecimal qty=number("SELECT received_base_qty FROM procurement_inspection_items WHERE id=?",id);
            var command=ReflectionTestUtils.<com.uten.imp.features.warehouse.inbound.ProcurementIqcStockInContracts.ConfirmRequest>invokeMethod(harness,"latestIqcStockInRequest","PURCHASE",receipt,id,qty,"gift-stock-"+id,"GIFT-BIN");
            var result=stockIn.confirm("PURCHASE",receipt,command);assertThat(stockIn.confirm("PURCHASE",receipt,command).batchId()).isEqualTo(result.batchId());
        }
        harness.loginAs(f.w().superAdminUserId());ReflectionTestUtils.invokeMethod(harness,"drainCosts",f.w());
    }
    private UUID settlement(){return db.queryForObject("SELECT id FROM settlement_methods WHERE status='使用' AND NOT is_deleted ORDER BY code LIMIT 1",UUID.class);}
    private BigDecimal number(String sql,Object...args){return db.queryForObject(sql,BigDecimal.class,args);}
    private BigDecimal stock(F f){return number("SELECT COALESCE(SUM(qty),0) FROM stock_balances WHERE goods_id=?",f.w().goodsD());}
    private BigDecimal value(F f){return number("SELECT COALESCE(SUM(amount_local),0) FROM stock_balances WHERE goods_id=?",f.w().goodsD());}
    private BigDecimal ap(UUID receipt){return number("SELECT COALESCE(SUM(amount_original_local),0) FROM ar_ap_ledger WHERE source_doc_id=? AND status=1 AND direction='AP'",receipt);}
}
