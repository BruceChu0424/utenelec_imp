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
class GiftUnitRateConservationEndToEndTest {
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
    private FullChainEndToEndTest harness;
    private static final BigDecimal RATE=new BigDecimal("1.00005");
    private record F(FullChainEndToEndTest.World w,UUID requestItem,UUID order,UUID orderItem,UUID currency,UUID unit){}
    @BeforeEach void prepare(){harness=new FullChainEndToEndTest();beans.autowireBean(harness);}
    @AfterEach void clear(){SecurityContextHolder.clearContext();}


    @Test void combinedReceiptUsesItsFrozenGiftBaseForClosureFreeReturnAndUnapprovalReplay(){
        F f=fixture();UUID received=receipt(f,"1","1");receipts.approve(received);passAndStock(f,received);
        assertThat(stock(f)).isEqualByComparingTo("2.0001");assertThat(value(f)).isEqualByComparingTo("10");assertThat(ap(received)).isEqualByComparingTo("10");
        UUID source=receipts.detail(received).getItems().getFirst().getId();
        assertThat(number("SELECT charged_base_qty FROM purchase_receipt_items WHERE id=?",source)).isEqualByComparingTo("1.0001");
        assertThat(number("SELECT gift_base_qty FROM purchase_receipt_items WHERE id=?",source)).isEqualByComparingTo("1.0000");
        evidence(f,received,null,"FULL_SOURCE_STOCKED",Map.of("stockQty","2.0001","stockValue","10","AP","10","closed","true","giftBase","1.0000"));
        org.assertj.core.api.SoftAssertions checks=new org.assertj.core.api.SoftAssertions();
        checks.assertThat(closed(f)).as("Both actual frozen tranches fully stocked must close").isTrue();
        UUID returned=returned(f,source,"0","1");returns.approve(returned);
        checks.assertThat(number("SELECT gift_base_qty FROM purchase_return_items WHERE return_id=?",returned)).as("Free return mirrors source's frozen base, not separately rounded rate").isEqualByComparingTo("1.0000");
        checks.assertThat(stock(f)).as("After original free tranche is returned, original charged base remains").isEqualByComparingTo("1.0001");
        assertThat(ap(returned)).isZero();assertThat(closed(f)).isFalse();
        evidence(f,received,returned,"FREE_RETURN_APPROVED",Map.of("stockQty","1.0001","stockValue","5.0002","returnAP","0","closed","false","returnGiftBase","1.0000"));
        var returnCommand=new DocumentUnapprovalService.UnapproveRequest("gift-rate-return-unapprove-"+returned,"赠品退货镜像原冻结分量");
        var returnDraft=(com.uten.imp.features.purchase.ret.dto.ReturnDetail)unapproval.unapprove("purchaseReturn",returned,returnCommand);
        assertThat(stock(f)).isEqualByComparingTo("2.0001");assertThat(value(f)).isEqualByComparingTo("10");
        assertThat(((com.uten.imp.features.purchase.ret.dto.ReturnDetail)unapproval.unapprove("purchaseReturn",returned,returnCommand)).getId()).isEqualTo(returnDraft.getId());
        returns.approve(returnDraft.getId());
        checks.assertThat(stock(f)).as("New return generation uses the same original free base").isEqualByComparingTo("1.0001");
        returns.reverse(returnDraft.getId());assertThat(stock(f)).isEqualByComparingTo("2.0001");assertThat(value(f)).isEqualByComparingTo("10");
        checks.assertThat(closed(f)).as("Mirrored return reverse restores fulfillment").isTrue();
        // Existing value provenance deliberately blocks erasing a receipt after a
        // compensated ISSUE history. Test that guard with no side effects, then
        // exercise receipt unapproval on an independent unused physical source.
        assertThatThrownBy(()->receipts.reverse(received)).isInstanceOf(com.uten.imp.common.web.ApiException.class);
        assertThat(stock(f)).isEqualByComparingTo("2.0001");assertThat(value(f)).isEqualByComparingTo("10");assertThat(ap(received)).isEqualByComparingTo("10");
        evidence(f,received,returnDraft.getId(),"USED_RECEIPT_REVERSAL_REFUSED_WITH_NO_EFFECT",Map.of("stockQty","2.0001","stockValue","10","AP","10","domainReversal","409 unused cost head","canReverseHint","observed separately from domain"));
        F fresh=fixture();UUID untouched=receipt(fresh,"1","1");receipts.approve(untouched);passAndStock(fresh,untouched);
        var command=new DocumentUnapprovalService.UnapproveRequest("gift-rate-unapprove-"+untouched,"转换残差仍按原冻结事实反审");
        var draft=(com.uten.imp.features.purchase.receipt.dto.ReceiptDetail)unapproval.unapprove("purchaseReceipt",untouched,command);
        assertThat(stock(fresh)).isZero();assertThat(value(fresh)).isZero();assertThat(ap(untouched)).isZero();assertThat(closed(fresh)).isFalse();
        evidence(fresh,untouched,null,"UNUSED_RECEIPT_UNAPPROVED",Map.of("stockQty","0","stockValue","0","AP","0","closed","false"));
        var replay=(com.uten.imp.features.purchase.receipt.dto.ReceiptDetail)unapproval.unapprove("purchaseReceipt",untouched,command);
        assertThat(replay.getId()).isEqualTo(draft.getId());assertThat(stock(fresh)).isZero();
        receipts.approve(draft.getId());passAndStock(fresh,draft.getId());
        assertThat(stock(fresh)).isEqualByComparingTo("2.0001");assertThat(value(fresh)).isEqualByComparingTo("10");assertThat(ap(draft.getId())).isEqualByComparingTo("10");
        checks.assertThat(closed(fresh)).as("New generation's two real tranches fulfill one promise once").isTrue();
        assertThatThrownBy(()->receipts.approve(draft.getId())).isInstanceOf(com.uten.imp.common.web.ApiException.class);
        assertThat(stock(fresh)).isEqualByComparingTo("2.0001");checks.assertAll();
        evidence(fresh,draft.getId(),null,"NEW_RECEIPT_GENERATION_STOCKED_AND_REPLAY_GUARDED",Map.of("stockQty","2.0001","stockValue","10","AP","10","closed","true"));
    }

    @Test void paidFirstAndPartialGiftReceiptsCloseByTheirOwnFrozenBasesAndFreeReturnsRemainSeparate(){
        F f=fixture();UUID paid=receipt(f,"1","0");receipts.approve(paid);passAndStock(f,paid);
        assertThat(stock(f)).isEqualByComparingTo("1.0001");assertThat(closed(f)).isFalse();
        evidence(f,paid,null,"PAID_COMPLETE_GIFT_NOT_ARRIVED",Map.of("stockQty","1.0001","stockValue","10","AP","10","closed","false"));
        UUID first=receipt(f,"0","0.375");receipts.approve(first);passAndStock(f,first);assertThat(closed(f)).isFalse();
        UUID last=receipt(f,"0","0.625");receipts.approve(last);passAndStock(f,last);
        assertThat(number("SELECT SUM(gift_base_qty) FROM purchase_receipt_items WHERE receipt_id IN (?,?)",first,last)).isEqualByComparingTo("1.0000");
        assertThat(stock(f)).isEqualByComparingTo("2.0001");assertThat(value(f)).isEqualByComparingTo("10");assertThat(ap(paid)).isEqualByComparingTo("10");
        evidence(f,last,null,"PARTIAL_FREE_375_625_STOCKED",Map.of("stockQty","2.0001","stockValue","10","AP","0","closed","true"));
        org.assertj.core.api.SoftAssertions checks=new org.assertj.core.api.SoftAssertions();checks.assertThat(closed(f)).as("Partial tranches total exactly one original gift despite receipt rounding").isTrue();
        UUID source=receipts.detail(last).getItems().getFirst().getId();UUID returned=returned(f,source,"0","0.625");returns.approve(returned);
        assertThat(stock(f)).isEqualByComparingTo("1.3751");assertThat(ap(returned)).isZero();assertThat(closed(f)).isFalse();
        returns.reverse(returned);assertThat(stock(f)).isEqualByComparingTo("2.0001");assertThat(value(f)).isEqualByComparingTo("10");
        checks.assertThat(closed(f)).as("Free return reverse restores partial fulfillment").isTrue();
        assertThat(number("SELECT received_qty FROM purchase_order_items WHERE id=?",f.orderItem())).isEqualByComparingTo("1");
        assertThat(number("SELECT gift_received_qty FROM purchase_order_items WHERE id=?",f.orderItem())).isEqualByComparingTo("1");
        assertThat(number("SELECT gift_returned_qty FROM purchase_order_items WHERE id=?",f.orderItem())).isZero();checks.assertAll();
    }

    private boolean closed(F f){return db.queryForObject("SELECT is_closed FROM purchase_orders WHERE id=?",Boolean.class,f.order());}

    private void evidence(F f,UUID received,UUID returned,String action,Map<String,String> expected){
        String output=System.getProperty("uten.audit.candidate.evidencePath");if(output==null)return;
        Map<String,Object> actual=new LinkedHashMap<>();actual.put("stockQty",stock(f).toPlainString());actual.put("stockValue",value(f).toPlainString());
        actual.put("AP",ap(received).toPlainString());actual.put("closed",closed(f));
        actual.put("order",db.queryForMap("SELECT qty,gift_qty,received_qty,gift_received_qty,returned_qty,gift_returned_qty FROM purchase_order_items WHERE id=?",f.orderItem()));
        actual.put("receipt",db.queryForMap("SELECT qty,gift_qty,charged_base_qty,gift_base_qty FROM purchase_receipt_items WHERE receipt_id=?",received));
        if(returned!=null){actual.put("returnAP",ap(returned).toPlainString());actual.put("return",db.queryForMap("SELECT qty,gift_qty,charged_base_qty,gift_base_qty FROM purchase_return_items WHERE return_id=?",returned));}
        short status=db.queryForObject("SELECT status FROM purchase_receipts WHERE id=?",Short.class,received);
        actual.put("receiptStatus",status);actual.put("canReverseHint",status==1&&receipts.detail(received).isCanReverse());
        Map<String,Object> row=new LinkedHashMap<>();row.put("action",action);row.put("orderId",f.order());row.put("receiptId",received);row.put("returnId",returned);
        row.put("unitRate",RATE.toPlainString());row.put("expected",expected);row.put("actual",actual);
        try{var path=java.nio.file.Path.of(output);java.nio.file.Files.createDirectories(path.getParent());
            java.nio.file.Files.writeString(path,beans.getBean(com.fasterxml.jackson.databind.ObjectMapper.class).writeValueAsString(row)+"\n",java.nio.charset.StandardCharsets.UTF_8,
                java.nio.file.StandardOpenOption.CREATE,java.nio.file.StandardOpenOption.APPEND);
        }catch(java.io.IOException error){throw new java.io.UncheckedIOException(error);}
    }
    private F fixture(){
        var w=harness.seedWorld("gift-"+UUID.randomUUID());harness.loginAs(w.superAdminUserId());
        UUID convertedUnit=UUID.randomUUID();db.update("INSERT INTO units(id,code,name) VALUES(?,?,'box')",convertedUnit,"GIFT-RATE-"+convertedUnit);
        UUID currency=db.queryForObject("SELECT id FROM currencies WHERE is_base_currency AND NOT is_deleted",UUID.class);
        var req=new com.uten.imp.features.purchase.request.dto.RequestSaveRequest();req.setBillDate(BusinessTime.today());req.setWarehouseId(w.warehouseId());
        var rl=new com.uten.imp.features.purchase.request.dto.RequestItemLine();rl.setGoodsId(w.goodsD());rl.setUnitId(convertedUnit);rl.setUnitRate(RATE);rl.setQty(BigDecimal.ONE);rl.setGiftQty(BigDecimal.ONE);req.setItems(List.of(rl));
        var source=requests.create(req);requests.approve(source.getId());UUID requestItem=source.getItems().getFirst().getId();
        UUID reviewer=harness.createUserWithPerms(w,"gift-finance-"+UUID.randomUUID(),"finance_order_approval:view","finance_order_approval:approve");harness.loginAs(w.superAdminUserId());
        var order=new com.uten.imp.features.purchase.order.dto.OrderSaveRequest();order.setBillDate(BusinessTime.today());order.setSupplierId(w.supplierId());order.setWarehouseId(w.warehouseId());order.setCurrencyId(currency);order.setExchangeRate(BigDecimal.ONE);order.setTaxRate(BigDecimal.ZERO);order.setSettlementMethodId(settlement());
        var line=new com.uten.imp.features.purchase.order.dto.OrderItemLine();line.setGoodsId(w.goodsD());line.setUnitId(convertedUnit);line.setUnitRate(RATE);line.setQty(BigDecimal.ONE);line.setGiftQty(BigDecimal.ONE);line.setPrice(new BigDecimal("10"));line.setRequestItemId(requestItem);order.setItems(List.of(line));
        UUID id=orders.create(order).getId();finance.submit("PURCHASE",id);harness.loginAs(reviewer);
        var approval=db.queryForMap("SELECT id,version FROM procurement_order_approval_cases WHERE order_type='PURCHASE' AND order_id=? AND status='PENDING'",id);UUID caseId=(UUID)approval.get("id");
        UUID claim=claims.claim("PROCUREMENT_FINANCE_APPROVE",caseId.toString()).claimId();finance.approveBatch(List.of(new BatchDecisionItem(caseId,((Number)approval.get("version")).longValue(),claim)),null,BigDecimal.ONE);harness.loginAs(w.superAdminUserId());
        return new F(w,requestItem,id,db.queryForObject("SELECT id FROM purchase_order_items WHERE order_id=?",UUID.class,id),currency,convertedUnit);
    }
    private UUID receipt(F f,String charged,String gift){
        var request=new com.uten.imp.features.purchase.receipt.dto.ReceiptSaveRequest();request.setBillDate(BusinessTime.today());request.setSupplierId(f.w().supplierId());request.setWarehouseId(f.w().warehouseId());
        var line=new com.uten.imp.features.purchase.receipt.dto.ReceiptItemLine();line.setGoodsId(f.w().goodsD());line.setUnitId(f.unit());line.setUnitRate(RATE);line.setQty(new BigDecimal(charged));line.setGiftQty(new BigDecimal(gift));line.setOrderItemId(f.orderItem());request.setItems(List.of(line));
        return receipts.create(request).getId();
    }
    private UUID returned(F f,UUID source,String charged,String gift){
        var request=new com.uten.imp.features.purchase.ret.dto.ReturnSaveRequest();request.setBillDate(BusinessTime.today());request.setSupplierId(f.w().supplierId());request.setWarehouseId(f.w().warehouseId());
        var line=new com.uten.imp.features.purchase.ret.dto.ReturnItemLine();line.setGoodsId(f.w().goodsD());line.setUnitId(f.unit());line.setUnitRate(RATE);line.setQty(new BigDecimal(charged));line.setGiftQty(new BigDecimal(gift));line.setReceiptItemId(source);line.setOrderItemId(f.orderItem());request.setItems(List.of(line));
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
