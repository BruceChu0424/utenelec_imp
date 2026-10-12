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
class GiftFreeOnlyOrderConservationEndToEndTest {
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
    @Autowired com.uten.imp.features.stock.StockDocService stockDocuments;
    @Autowired com.uten.imp.application.port.InventoryValuationPort values;
    @Autowired com.uten.imp.features.stock.InventoryMutationLock inventoryLocks;
    @Autowired org.springframework.transaction.PlatformTransactionManager transactions;
    @Autowired com.uten.imp.application.concurrency.FulfillmentMutationLocks mutationLocks;
    @Autowired com.uten.imp.common.concurrency.ProcurementMutationFootprint procurementFootprints;
    @Autowired com.uten.imp.application.port.ProductionMutationFootprintPort stockFootprints;
    @Autowired com.uten.imp.features.finance.payables.ProcurementIqcRejectionService rejections;
    private FullChainEndToEndTest harness;
    private record F(FullChainEndToEndTest.World w,UUID requestItem,UUID order,UUID orderItem,UUID currency){}
    @BeforeEach void prepare(){harness=new FullChainEndToEndTest();beans.autowireBean(harness);}
    @AfterEach void clear(){SecurityContextHolder.clearContext();}






    @Test void approvedAllFreeOrderPhysicallyReceivesAndReturnsOneWithNoPayableAndExactReverse(){
        F f=fixture();
        assertThat(number("SELECT qty FROM purchase_order_items WHERE id=?",f.orderItem())).isZero();
        assertThat(number("SELECT total_original+total_local FROM purchase_orders WHERE id=?",f.order())).isZero();
        UUID received=receipt(f,"0","1");receipts.approve(received);passAndStock(f,received);
        assertThat(stock(f)).isEqualByComparingTo("1");assertThat(value(f)).isZero();assertThat(ap(received)).isZero();
        assertThat(number("SELECT count(*) FROM ar_ap_ledger WHERE source_doc_id=?",received)).isZero();
        UUID source=receipts.detail(received).getItems().getFirst().getId();UUID returned=returned(f,source,"0","1");returns.approve(returned);
        assertThat(stock(f)).isZero();assertThat(value(f)).isZero();assertThat(ap(returned)).isZero();
        returns.reverse(returned);assertThat(stock(f)).isEqualByComparingTo("1");assertThat(value(f)).isZero();
        receipts.reverse(received);assertThat(stock(f)).isZero();assertThat(value(f)).isZero();
    }

    @Test void confirmedFreeReceiptUnapprovalKeepsExactZeroFactsWhileUnrelatedCostPublicationIsPending(){
        F f=fixture();UUID received=receipt(f,"0","1");receipts.approve(received);passAndStock(f,received);
        UUID source=receipts.detail(received).getItems().getFirst().getId();
        UUID returned=returned(f,source,"0","1");returns.approve(returned);returns.reverse(returned);
        UUID unrelated=unrelatedStockReceipt(f);
        var transaction=new org.springframework.transaction.support.TransactionTemplate(transactions);
        UUID[] adjustment={null};
        try{
            transaction.executeWithoutResult(status->{
                mutationLocks.acquireAll(List.of(
                    com.uten.imp.application.concurrency.FulfillmentMutationLocks.Footprint.undeclared(()->
                        procurementFootprints.receipts(List.of(new com.uten.imp.common.concurrency.ProcurementMutationFootprint.ReceiptRef("PURCHASE",received)))),
                    com.uten.imp.application.concurrency.FulfillmentMutationLocks.Footprint.undeclared(()->
                        stockFootprints.forStockDocuments(List.of(unrelated))))).verifyUnchanged();
                adjustment[0]=queueUnrelatedCostCorrection(f,unrelated);
                var giftPool=new com.uten.imp.application.port.InventoryValuationPort.PoolKey(
                    f.w().warehouseId(),f.w().goodsD(),null);
                assertThat(values.pool(giftPool).state()).isEqualTo(
                    com.uten.imp.application.port.InventoryValuationPort.State.PENDING);
                var command=new DocumentUnapprovalService.UnapproveRequest(
                    "gift-pending-unapproval-"+received,"原赠品实物与零成本完整，无关传播不阻断反审");
                var draft=(com.uten.imp.features.purchase.receipt.dto.ReceiptDetail)
                    unapproval.unapprove("purchaseReceipt",received,command);
                var repeated=(com.uten.imp.features.purchase.receipt.dto.ReceiptDetail)
                    unapproval.unapprove("purchaseReceipt",received,command);
                assertThat(repeated.getId()).isEqualTo(draft.getId());
                db.execute("SET CONSTRAINTS trg_stock_value_reverse_store IMMEDIATE");
                assertThat(stock(f)).isZero();assertThat(value(f)).isZero();assertThat(ap(received)).isZero();
                assertThat(number("SELECT received_qty+gift_received_qty FROM purchase_order_items WHERE id=?",f.orderItem())).isZero();
                assertThat(draft.getItems().getFirst().getQty()).isZero();
                assertThat(draft.getItems().getFirst().getGiftQty()).isEqualByComparingTo("1");
                assertThat(number("SELECT COUNT(*) FROM stock_value_events WHERE source_doc_id=? AND operation='POSITION_STORE_REVERSE' AND result_state='FINAL' AND known_value_local=0",received)).isEqualByComparingTo("1");
                assertThat(number("SELECT COUNT(*) FROM stock_value_postings posting JOIN stock_value_events event ON event.id=posting.event_id WHERE event.source_doc_id=? AND event.operation='POSITION_STORE_REVERSE'",received)).isZero();
                // Publication remains conservative even though this reversal's own source facts are final.
                assertThat(values.pool(giftPool).state()).isEqualTo(
                    com.uten.imp.application.port.InventoryValuationPort.State.PENDING);
                assertThat(db.queryForObject("SELECT status FROM stock_value_jobs WHERE event_id=?",String.class,adjustment[0])).isEqualTo("PENDING");
            });
        }finally{
            if(adjustment[0]!=null)drainUnrelatedCostCorrection(f,adjustment[0],transaction);
        }
    }

    private UUID unrelatedStockReceipt(F f){
        var request=new com.uten.imp.features.stock.dto.StockDocSaveRequest();
        request.setDocType("OTHER_IN");request.setBillDate(BusinessTime.today());request.setWarehouseId(f.w().warehouseId());
        var line=new com.uten.imp.features.stock.dto.StockDocItemLine();
        line.setGoodsId(f.w().goodsE());line.setUnitId(f.w().unitId());line.setUnitRate(BigDecimal.ONE);
        line.setQty(BigDecimal.TEN);line.setPrice(BigDecimal.TEN);request.setItems(List.of(line));
        return stockDocuments.create(request).getId();
    }

    private UUID queueUnrelatedCostCorrection(F f,UUID document){
        stockDocuments.approve(document);
        var original=db.queryForMap("SELECT source_item_id,result_node_id FROM stock_value_events WHERE source_doc_id=? AND operation='RECEIVE'",document);
        UUID event=UUID.randomUUID();
        var context=new com.uten.imp.application.port.InventoryValuationPort.EventContext(event,"TEST_GIFT_UNRELATED_COST",
            document,(UUID)original.get("source_item_id"),1,f.w().superAdminUserId(),f.w().employeeId(),event.toString(),java.time.OffsetDateTime.now());
        var correction=values.adjustSource(new com.uten.imp.application.port.InventoryValuationPort.SourceAdjustment(
            context,(UUID)original.get("result_node_id"),BigDecimal.ONE,true));
        assertThat(correction.pendingTasks()).isPositive();
        assertThat(db.queryForObject("SELECT status FROM stock_value_jobs WHERE event_id=?",String.class,correction.eventId())).isEqualTo("PENDING");
        return correction.eventId();
    }

    private void drainUnrelatedCostCorrection(F f,UUID event,org.springframework.transaction.support.TransactionTemplate transaction){
        for(int attempt=0;attempt<100;attempt++){
            List<UUID> tasks=db.queryForList("SELECT id FROM stock_value_tasks WHERE event_id=? AND status='PENDING' ORDER BY task_sequence",UUID.class,event);
            if(tasks.isEmpty())return;
            for(UUID task:tasks)transaction.executeWithoutResult(status->{
                inventoryLocks.lock(new com.uten.imp.features.stock.InventoryKey(f.w().goodsE(),null));
                values.propagate(task);
            });
        }
        fail("The unrelated fixture's actual cost correction did not finish");
    }

    private UUID failAndReturnGift(F f,UUID receipt){
        harness.loginAs(f.w().superAdminUserId());
        UUID id=db.queryForObject("SELECT id FROM procurement_inspection_items WHERE receipt_id=? AND quantity_tranche='GIFT'",UUID.class,receipt);
        inspection.dispose("PURCHASE",receipt,id,new InspectionDispositionRequest("FAIL",null,"赠品实物不合格，无计价货款","gift-fail-"+id));
        UUID failure=ReflectionTestUtils.invokeMethod(harness,"awaitIqcRejection","PURCHASE",receipt);
        assertThat(number("SELECT failed_qty FROM procurement_iqc_rejection_cases WHERE id=?",failure)).isEqualByComparingTo("1");
        assertThat(number("SELECT received_qty FROM procurement_iqc_rejection_cases WHERE id=?",failure)).isEqualByComparingTo("1");
        assertThat(number("SELECT failed_amount_original+failed_amount_local FROM procurement_iqc_rejection_cases WHERE id=?",failure)).isZero();
        assertThat(db.queryForObject("SELECT source_ap_ledger_id FROM procurement_iqc_rejection_cases WHERE id=?",UUID.class,failure)).isNull();
        long version=db.queryForObject("SELECT row_version FROM procurement_iqc_rejection_cases WHERE id=?",Long.class,failure);
        var command=new com.uten.imp.features.finance.payables.ProcurementIqcRejectionContracts.RecordReturnRequest(version,UUID.randomUUID(),"GIFT-RETURN-"+id,BusinessTime.today(),"零货款赠品实际退回供应商");
        rejections.recordReturn(failure,command);rejections.recordReturn(failure,command);
        return failure;
    }

    private F fixture(){
        var w=harness.seedWorld("gift-"+UUID.randomUUID());harness.loginAs(w.superAdminUserId());
        UUID currency=db.queryForObject("SELECT id FROM currencies WHERE is_base_currency AND NOT is_deleted",UUID.class);
        var req=new com.uten.imp.features.purchase.request.dto.RequestSaveRequest();req.setBillDate(BusinessTime.today());req.setWarehouseId(w.warehouseId());
        var rl=new com.uten.imp.features.purchase.request.dto.RequestItemLine();rl.setGoodsId(w.goodsD());rl.setUnitId(w.unitId());rl.setUnitRate(BigDecimal.ONE);rl.setQty(new BigDecimal("10"));rl.setGiftQty(BigDecimal.ONE);req.setItems(List.of(rl));
        var source=requests.create(req);requests.approve(source.getId());UUID requestItem=source.getItems().getFirst().getId();
        UUID reviewer=harness.createUserWithPerms(w,"gift-finance-"+UUID.randomUUID(),"finance_order_approval:view","finance_order_approval:approve");harness.loginAs(w.superAdminUserId());
        var order=new com.uten.imp.features.purchase.order.dto.OrderSaveRequest();order.setBillDate(BusinessTime.today());order.setSupplierId(w.supplierId());order.setWarehouseId(w.warehouseId());order.setCurrencyId(currency);order.setExchangeRate(BigDecimal.ONE);order.setTaxRate(BigDecimal.ZERO);order.setSettlementMethodId(settlement());
        var line=new com.uten.imp.features.purchase.order.dto.OrderItemLine();line.setGoodsId(w.goodsD());line.setUnitId(w.unitId());line.setUnitRate(BigDecimal.ONE);line.setQty(BigDecimal.ZERO);line.setGiftQty(BigDecimal.ONE);line.setPrice(BigDecimal.ZERO);line.setRequestItemId(requestItem);order.setItems(List.of(line));
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
        harness.loginAs(f.w().superAdminUserId());List<UUID> ids=db.queryForList("SELECT id FROM procurement_inspection_items WHERE receipt_id=? AND received_base_qty>passed_base_qty+failed_base_qty ORDER BY quantity_tranche",UUID.class,receipt);
        for(UUID id:ids)inspection.dispose("PURCHASE",receipt,id,new InspectionDispositionRequest("PASS",null,"真实收费/赠品质检","gift-pass-"+id));
        ids=db.queryForList("SELECT id FROM procurement_inspection_items WHERE receipt_id=? AND passed_base_qty>0 ORDER BY quantity_tranche",UUID.class,receipt);
        UUID keeper=ReflectionTestUtils.invokeMethod(harness,"createIqcWarehouseConfirmer",f.w(),"gift-keeper-"+receipt);harness.loginAs(keeper);
        for(UUID id:ids){BigDecimal qty=number("SELECT passed_base_qty FROM procurement_inspection_items WHERE id=?",id);
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
