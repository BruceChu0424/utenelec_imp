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

/** One isolated migrated context; new business data and actual approval/quality/stock/value ports in every case. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
@SpringBootTest(properties={"spring.profiles.active=dev","uten.audit.retention.enabled=false",
    "uten.reporting.materialized-view-refresh.enabled=false","uten.production.readiness-reconcile.enabled=false",
    "uten.features.goods-owner-scope-enabled=false","uten.storage.uploads-enabled=false",
    "uten.jwt.secret=gift-regression-isolated-jwt-key-0123456789-abcdef", // gitleaks:allow synthetic cryptographic key for this isolated JUnit SpringBootTest.
    "uten.crypto.pgp-master-key=gift-regression-isolated-pgp-key-0123456789-abcdef", // gitleaks:allow synthetic cryptographic key for this isolated JUnit SpringBootTest.
    "uten.crypto.hmac-key=gift-regression-isolated-hmac-key-0123456789-abcdef",
    "uten.bootstrap.admin-login=gift-regression-bootstrap","uten.bootstrap.admin-password=GiftRegressionAdmin-1!"})
class ProcurementPhysicalReviewEndToEndTest {
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
    @Autowired com.uten.imp.features.subcontract.receipt.SubcontractReceiptService scReceipts;
    @Autowired com.uten.imp.features.subcontract.ret.SubcontractReturnService scReturns;
    private FullChainEndToEndTest harness;
    private record F(FullChainEndToEndTest.World w,UUID requestItem,UUID order,UUID orderItem,UUID currency){}
    @BeforeEach void prepare(){harness=new FullChainEndToEndTest();beans.autowireBean(harness);}
    @AfterEach void clear(){SecurityContextHolder.clearContext();}


    @Test void purchaseReceiptReviewerAmendsActualPaidAndFreeCountsButCannotUseOrdinaryEditingOrChangeSources(){
        F f=fixture();UUID id=receipt(f,"5",".25");var original=receipts.detail(id);
        Object createdAt=db.queryForObject("SELECT created_at FROM purchase_receipts WHERE id=?",Object.class,id);
        UUID reviewer=reviewer(f.w(),"purchase","purchase_receipt");harness.loginAs(reviewer);
        var review=receipts.review(id);var request=purchaseReceiptRequest(f,id,"7.3756",".6256");
        assertThatThrownBy(()->receipts.update(id,request)).isInstanceOf(org.springframework.security.access.AccessDeniedException.class);
        request.getItems().getFirst().setGoodsId(f.w().goodsC());
        assertThatThrownBy(()->receipts.updateReviewed(id,request,review.snapshot(),true)).isInstanceOf(com.uten.imp.common.web.ApiException.class);
        assertThat(number("SELECT qty FROM purchase_receipt_items WHERE receipt_id=? AND NOT is_deleted",id)).isEqualByComparingTo("5");
        request.getItems().getFirst().setGoodsId(f.w().goodsD());
        var result=receipts.updateReviewed(id,request,review.snapshot(),true);
        assertThat(result.getStatus()).isEqualTo((short)1);assertThat(result.getMakerId()).isEqualTo(original.getMakerId());
        assertThat(db.queryForObject("SELECT created_at FROM purchase_receipts WHERE id=?",Object.class,id)).isEqualTo(createdAt);
        assertThat(result.getItems().getFirst().getQty()).isEqualByComparingTo("7.3756");
        assertThat(result.getItems().getFirst().getGiftQty()).isEqualByComparingTo(".6256");
        assertThat(ap(id)).isEqualByComparingTo("73.756");assertThat(stock(f)).isZero();
        assertThat(number("SELECT received_qty FROM purchase_order_items WHERE id=?",f.orderItem())).isEqualByComparingTo("7.3756");
        assertThat(number("SELECT gift_received_qty FROM purchase_order_items WHERE id=?",f.orderItem())).isEqualByComparingTo(".6256");
        assertThat(number("SELECT SUM(received_base_qty) FROM procurement_inspection_items WHERE receipt_id=?",id)).isEqualByComparingTo("8.0012");
        assertThatThrownBy(()->receipts.updateReviewed(id,request,review.snapshot(),true)).isInstanceOf(com.uten.imp.common.web.ApiException.class);
        assertThat(ap(id)).isEqualByComparingTo("73.756");
    }

    @Test void purchaseReturnReviewerUpdatesSourceBoundCountsAndCreditsThenUnapprovalMirrorsActualIssue(){
        F f=fixture();UUID received=receipt(f,"10","1");receipts.approve(received);passAndStock(f,received);
        UUID source=receipts.detail(received).getItems().getFirst().getId();UUID id=returned(f,source,"1","0");
        var before=returns.detail(id);UUID reviewer=reviewer(f.w(),"purchase","purchase_return");harness.loginAs(reviewer);
        var view=returns.review(id);var req=purchaseReturnRequest(f,id,source,".3756",".1256");
        assertThatThrownBy(()->returns.update(id,req)).isInstanceOf(org.springframework.security.access.AccessDeniedException.class);
        var saved=returns.updateReviewed(id,req,view.snapshot(),true);
        assertThat(saved.getMakerId()).isEqualTo(before.getMakerId());assertThat(ap(id)).isEqualByComparingTo("-3.756");
        assertThat(stock(f)).isEqualByComparingTo("10.4988");
        assertThat(number("SELECT returned_qty FROM purchase_receipt_items WHERE id=?",source)).isEqualByComparingTo(".3756");
        assertThat(number("SELECT gift_returned_qty FROM purchase_receipt_items WHERE id=?",source)).isEqualByComparingTo(".1256");
        assertThatThrownBy(()->returns.updateReviewed(id,req,view.snapshot(),true)).isInstanceOf(com.uten.imp.common.web.ApiException.class);
        assertThat(stock(f)).isEqualByComparingTo("10.4988");
        harness.loginAs(f.w().superAdminUserId());returns.reverse(id);
        assertThat(stock(f)).isEqualByComparingTo("11");assertThat(value(f)).isEqualByComparingTo("100");assertThat(ap(id)).isZero();
    }

    @Test void subcontractReceiptReviewerUsesTheOriginalInputsAndNewActualQuantity(){
        SC f=subcontractFixture();var request=scReceiptRequest(f,null,"4.1256");request.setSenderId(f.w().employeeId());UUID id=scReceipts.create(request).getId();
        String receiverName=db.queryForObject("SELECT receiver_name FROM subcontract_receipts WHERE id=?",String.class,id);
        var original=scReceipts.detail(id);harness.loginAs(reviewer(f.w(),"subcontract","subcontract_receipt"));
        var view=scReceipts.review(id);request=scReceiptRequest(f,id,"5.3756");var edited=request;
        assertThatThrownBy(()->scReceipts.update(id,edited)).isInstanceOf(org.springframework.security.access.AccessDeniedException.class);
        var saved=scReceipts.updateReviewed(id,request,view.snapshot(),true);
        assertThat(saved.getMakerId()).isEqualTo(original.getMakerId());
        assertThat(db.queryForObject("SELECT receiver_name FROM subcontract_receipts WHERE id=?",String.class,id)).isEqualTo(receiverName);
        assertThat(saved.getItems().getFirst().getOrderItemId()).isEqualTo(f.orderItem());
        assertThat(saved.getItems().getFirst().getQty()).isEqualByComparingTo("5.3756");
        assertThat(ap(id)).isEqualByComparingTo("268.78");
        assertThat(number("SELECT received_qty FROM subcontract_order_items WHERE id=?",f.orderItem())).isEqualByComparingTo("5.3756");
        assertThat(number("SELECT COALESCE(SUM(qty),0) FROM stock_balances WHERE goods_id=?",f.w().goodsE())).isZero();
        assertThatThrownBy(()->scReceipts.updateReviewed(id,edited,view.snapshot(),true)).isInstanceOf(com.uten.imp.common.web.ApiException.class);
        assertThat(ap(id)).isEqualByComparingTo("268.78");
    }

    @Test void subcontractReturnReviewerCannotReplaceCustodySourceAndAmendsCreditOnce(){
        SC f=subcontractFixture();UUID received=scReceipts.create(scReceiptRequest(f,null,"10")).getId();scReceipts.approve(received);passAndStockSC(f,received);
        UUID source=scReceipts.detail(received).getItems().getFirst().getId();var originalRequest=scReturnRequest(f,null,source,"1.3756");originalRequest.getItems().getFirst().setReceiptNo("已记录的来源进仓编号");UUID id=scReturns.create(originalRequest).getId();
        var original=scReturns.detail(id);harness.loginAs(reviewer(f.w(),"subcontract","subcontract_return"));
        var view=scReturns.review(id);var request=scReturnRequest(f,id,source,"2.3756");
        assertThatThrownBy(()->scReturns.update(id,request)).isInstanceOf(org.springframework.security.access.AccessDeniedException.class);
        request.getItems().getFirst().setReceiptItemId(UUID.randomUUID());
        assertThatThrownBy(()->scReturns.updateReviewed(id,request,view.snapshot(),true)).isInstanceOf(com.uten.imp.common.web.ApiException.class);
        request.getItems().getFirst().setReceiptItemId(source);
        var saved=scReturns.updateReviewed(id,request,view.snapshot(),true);
        assertThat(db.queryForObject("SELECT receipt_no FROM subcontract_return_items WHERE return_id=? AND NOT is_deleted",String.class,id)).isEqualTo("已记录的来源进仓编号");
        assertThat(saved.getMakerId()).isEqualTo(original.getMakerId());assertThat(ap(id)).isEqualByComparingTo("-118.78");
        assertThat(number("SELECT COALESCE(SUM(qty),0) FROM stock_balances WHERE goods_id=?",f.w().goodsE())).isEqualByComparingTo("7.6244");
        assertThat(number("SELECT returned_qty FROM subcontract_receipt_items WHERE id=?",source)).isEqualByComparingTo("2.3756");
        assertThatThrownBy(()->scReturns.updateReviewed(id,request,view.snapshot(),true)).isInstanceOf(com.uten.imp.common.web.ApiException.class);
        assertThat(ap(id)).isEqualByComparingTo("-118.78");
    }

    @Test void approvalAuthorityDoesNotDiscoverAnOtherwiseHiddenPhysicalReceipt(){
        F f=fixture();UUID id=receipt(f,"2","0");
        UUID hidden=harness.createUserWithPerms(f.w(),"physical-hidden-"+UUID.randomUUID(),"purchase_receipt:view","purchase_receipt:approve");
        harness.loginAs(hidden);
        assertThatThrownBy(()->receipts.review(id)).isInstanceOf(com.uten.imp.common.web.ApiException.class);
        assertThat(ap(id)).isZero();assertThat(number("SELECT qty FROM purchase_receipt_items WHERE receipt_id=? AND NOT is_deleted",id)).isEqualByComparingTo("2");
    }

    private UUID reviewer(FullChainEndToEndTest.World w,String module,String family){
        UUID user=harness.createUserWithPerms(w,"physical-review-"+UUID.randomUUID(),module+":view:all",family+":view",family+":approve",family+":price:view");
        db.update("INSERT INTO user_permission_overrides(user_id,permission_id,effect) SELECT ?,id,'revoke' FROM permissions WHERE code=?",user,family+":edit");
        return user;
    }
    private com.uten.imp.features.purchase.receipt.dto.ReceiptSaveRequest purchaseReceiptRequest(F f,UUID id,String qty,String gift){
        var req=new com.uten.imp.features.purchase.receipt.dto.ReceiptSaveRequest();req.setBillDate(BusinessTime.today());req.setSupplierId(f.w().supplierId());req.setWarehouseId(f.w().warehouseId());
        var line=new com.uten.imp.features.purchase.receipt.dto.ReceiptItemLine();line.setGoodsId(f.w().goodsD());line.setUnitId(f.w().unitId());line.setUnitRate(BigDecimal.ONE);line.setQty(new BigDecimal(qty));line.setGiftQty(new BigDecimal(gift));line.setOrderItemId(f.orderItem());line.setSourceItemId(receipts.detail(id).getItems().getFirst().getId());req.setItems(List.of(line));return req;
    }
    private com.uten.imp.features.purchase.ret.dto.ReturnSaveRequest purchaseReturnRequest(F f,UUID id,UUID source,String qty,String gift){
        var req=new com.uten.imp.features.purchase.ret.dto.ReturnSaveRequest();req.setBillDate(BusinessTime.today());req.setSupplierId(f.w().supplierId());req.setWarehouseId(f.w().warehouseId());
        var line=new com.uten.imp.features.purchase.ret.dto.ReturnItemLine();line.setGoodsId(f.w().goodsD());line.setUnitId(f.w().unitId());line.setUnitRate(BigDecimal.ONE);line.setQty(new BigDecimal(qty));line.setGiftQty(new BigDecimal(gift));line.setOrderItemId(f.orderItem());line.setReceiptItemId(source);line.setSourceItemId(returns.detail(id).getItems().getFirst().getId());req.setItems(List.of(line));return req;
    }
    private record SC(FullChainEndToEndTest.World w,UUID orderItem){}
    private SC subcontractFixture(){
        var w=harness.seedWorld("physical-sc-"+UUID.randomUUID());harness.loginAs(w.superAdminUserId());
        UUID material=harness.ensureSubcontractDirectMaterial(w,w.goodsE());harness.receiveSubcontractMaterial(w,material,"20");
        var order=harness.submitLeafSubcontractForFinance(w);harness.loginAs(order.reviewerUserId());harness.approvePendingFinance("SUBCONTRACT",order.orderId());harness.loginAs(w.superAdminUserId());
        UUID item=db.queryForObject("SELECT id FROM subcontract_order_items WHERE order_id=? AND NOT is_deleted",UUID.class,order.orderId());harness.drawAndIssueSubcontract(item,BigDecimal.TEN,"physical-sc-draw-"+item);return new SC(w,item);
    }
    private com.uten.imp.features.subcontract.receipt.dto.ReceiptSaveRequest scReceiptRequest(SC f,UUID id,String qty){
        var req=new com.uten.imp.features.subcontract.receipt.dto.ReceiptSaveRequest();req.setBillDate(BusinessTime.today());req.setSupplierId(f.w().supplierId());req.setWarehouseId(f.w().warehouseId());
        var line=new com.uten.imp.features.subcontract.receipt.dto.ReceiptItemLine();line.setGoodsId(f.w().goodsE());line.setUnitId(f.w().unitId());line.setUnitRate(BigDecimal.ONE);line.setQty(new BigDecimal(qty));line.setOrderItemId(f.orderItem());if(id!=null)line.setSourceItemId(scReceipts.detail(id).getItems().getFirst().getId());req.setItems(List.of(line));return req;
    }
    private com.uten.imp.features.subcontract.ret.dto.ReturnSaveRequest scReturnRequest(SC f,UUID id,UUID source,String qty){
        var req=new com.uten.imp.features.subcontract.ret.dto.ReturnSaveRequest();req.setBillDate(BusinessTime.today());req.setSupplierId(f.w().supplierId());req.setWarehouseId(f.w().warehouseId());
        var line=new com.uten.imp.features.subcontract.ret.dto.ReturnItemLine();line.setGoodsId(f.w().goodsE());line.setUnitId(f.w().unitId());line.setUnitRate(BigDecimal.ONE);line.setQty(new BigDecimal(qty));line.setOrderItemId(f.orderItem());line.setReceiptItemId(source);if(id!=null)line.setSourceItemId(scReturns.detail(id).getItems().getFirst().getId());req.setItems(List.of(line));return req;
    }
    private void passAndStockSC(SC f,UUID receipt){
        harness.loginAs(f.w().superAdminUserId());UUID item=db.queryForObject("SELECT id FROM procurement_inspection_items WHERE receipt_id=?",UUID.class,receipt);inspection.dispose("SUBCONTRACT",receipt,item,new InspectionDispositionRequest("PASS",null,"真实委外检验","sc-physical-pass-"+item));
        UUID keeper=ReflectionTestUtils.invokeMethod(harness,"createIqcWarehouseConfirmer",f.w(),"physical-sc-keeper-"+receipt);harness.loginAs(keeper);
        var command=ReflectionTestUtils.<com.uten.imp.features.warehouse.inbound.ProcurementIqcStockInContracts.ConfirmRequest>invokeMethod(harness,"latestIqcStockInRequest","SUBCONTRACT",receipt,item,BigDecimal.TEN,"sc-physical-stock-"+item,"SC-PHYSICAL");stockIn.confirm("SUBCONTRACT",receipt,command);harness.loginAs(f.w().superAdminUserId());
    }
    private F fixture(){
        var w=harness.seedWorld("gift-"+UUID.randomUUID());harness.loginAs(w.superAdminUserId());
        UUID currency=db.queryForObject("SELECT id FROM currencies WHERE is_base_currency AND NOT is_deleted",UUID.class);
        var req=new com.uten.imp.features.purchase.request.dto.RequestSaveRequest();req.setBillDate(BusinessTime.today());req.setWarehouseId(w.warehouseId());
        var rl=new com.uten.imp.features.purchase.request.dto.RequestItemLine();rl.setGoodsId(w.goodsD());rl.setUnitId(w.unitId());rl.setUnitRate(BigDecimal.ONE);rl.setQty(new BigDecimal("10"));rl.setGiftQty(BigDecimal.ONE);req.setItems(List.of(rl));
        var source=requests.create(req);requests.approve(source.getId());UUID requestItem=source.getItems().getFirst().getId();
        UUID reviewer=harness.createUserWithPerms(w,"gift-finance-"+UUID.randomUUID(),"finance_order_approval:view","finance_order_approval:approve");harness.loginAs(w.superAdminUserId());
        var order=new com.uten.imp.features.purchase.order.dto.OrderSaveRequest();order.setBillDate(BusinessTime.today());order.setSupplierId(w.supplierId());order.setWarehouseId(w.warehouseId());order.setCurrencyId(currency);order.setExchangeRate(BigDecimal.ONE);order.setTaxRate(BigDecimal.ZERO);order.setSettlementMethodId(settlement());
        var line=new com.uten.imp.features.purchase.order.dto.OrderItemLine();line.setGoodsId(w.goodsD());line.setUnitId(w.unitId());line.setUnitRate(BigDecimal.ONE);line.setQty(new BigDecimal("10"));line.setGiftQty(BigDecimal.ONE);line.setPrice(new BigDecimal("10"));line.setRequestItemId(requestItem);order.setItems(List.of(line));
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
