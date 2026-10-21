package com.uten.imp.businesschain;

import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.features.documents.DocumentUnapprovalService;
import com.uten.imp.features.common.taskclaim.TaskClaimService;
import com.uten.imp.features.finance.procurement.ProcurementFinanceApprovalService;
import com.uten.imp.features.purchase.order.PurchaseOrderService;
import com.uten.imp.features.purchase.receipt.PurchaseReceiptService;
import com.uten.imp.features.purchase.request.PurchaseRequestService;
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
@SpringBootTest(properties={"spring.profiles.active=dev","uten.audit.retention.enabled=false","uten.inventory.value-work.enabled=false",
    "uten.reporting.materialized-view-refresh.enabled=false","uten.production.readiness-reconcile.enabled=false",
    "uten.features.goods-owner-scope-enabled=false","uten.storage.uploads-enabled=false",
    "uten.jwt.secret=gift-regression-isolated-jwt-key-0123456789-abcdef", // gitleaks:allow synthetic test-only cryptographic fixture.
    "uten.crypto.pgp-master-key=gift-regression-isolated-pgp-key-0123456789-abcdef", // gitleaks:allow synthetic test-only cryptographic fixture.
    "uten.crypto.hmac-key=gift-regression-isolated-hmac-key-0123456789-abcdef",
    "uten.bootstrap.admin-login=full-chain-bootstrap-admin-test","uten.bootstrap.admin-password=HarnessAdminPass-1!"})
@TestMethodOrder(MethodOrderer.OrderAnnotation.class)
class ProcurementWithdrawalSourceFinalityEndToEndTest {
    @DynamicPropertySource static void database(DynamicPropertyRegistry registry){FullChainEndToEndTest.registerDataSource(registry);}
    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    @Autowired PurchaseRequestService requests;
    @Autowired PurchaseOrderService orders;
    @Autowired PurchaseReceiptService receipts;

    @Autowired ProcurementFinanceApprovalService finance;
    @Autowired TaskClaimService claims;
    @Autowired ProcurementInspectionService inspection;
    @Autowired ProcurementIqcStockInService stockIn;
    @Autowired DocumentUnapprovalService unapproval;

    private FullChainEndToEndTest harness;
    private record F(FullChainEndToEndTest.World w,UUID requestItem,UUID order,UUID orderItem,UUID currency){}
    @BeforeEach void prepare(){harness=new FullChainEndToEndTest();beans.autowireBean(harness);}
    @AfterEach void clear(){SecurityContextHolder.clearContext();}

    @Autowired com.uten.imp.application.port.InventoryValuationPort values;
    @Autowired com.uten.imp.features.stock.StockDocService ordinaryStock;
    @Autowired com.uten.imp.features.stock.StockService inventory;
    @Test @Order(1) void unrelatedRealPendingCostJobKeepsGlobalReportPendingButGiftWithdrawalFinal(){
        F f=fixture();UUID receipt=receipt(f,"10","1");receipts.approve(receipt);passAndStock(f,receipt);
        UUID otherSource=standalonePricedSource(f);
        adjust(otherSource, f.w().goodsA());
        assertThat(db.queryForObject("SELECT EXISTS(SELECT 1 FROM stock_value_jobs WHERE source_node_id=? AND status='PENDING')",Boolean.class,otherSource)).isTrue();
        var pool=new com.uten.imp.application.port.InventoryValuationPort.PoolKey(f.w().warehouseId(),f.w().goodsD(),null);
        assertThat(values.pool(pool).state()).isEqualTo(com.uten.imp.application.port.InventoryValuationPort.State.PENDING);
        allowedWithoutWrites(()->receipts.unapprovalEligibility(receipt));
        unapprove("purchaseReceipt",receipt);
        assertThat(stock(f)).isZero();assertThat(value(f)).isZero();assertThat(ap(receipt)).isZero();
        assertThat(db.queryForObject("SELECT count(*) FROM stock_value_events WHERE source_doc_id=? AND operation='POSITION_STORE_REVERSE' AND qty_base=1 AND known_value_local=0 AND result_state='FINAL'",Long.class,receipt)).isEqualTo(1L);
        assertThat(values.pool(pool).state()).isEqualTo(com.uten.imp.application.port.InventoryValuationPort.State.PENDING);
    }
    @Test @Order(2) void realPendingAncestorAdjustmentBlocksCapabilityAndForcedUndoWithoutEffects(){
        F f=fixture();UUID receipt=receipt(f,"10","1");receipts.approve(receipt);passAndStock(f,receipt);
        UUID source=db.queryForObject("""
            WITH RECURSIVE parents(id) AS (
              SELECT event.result_node_id FROM stock_value_events event
              JOIN procurement_iqc_stock_in_batch_items stock ON stock.stock_movement_id=event.movement_id
              JOIN procurement_inspection_items inspection ON inspection.id=stock.inspection_item_id
              WHERE inspection.receipt_id=? AND inspection.quantity_tranche='CHARGED' AND event.operation='POSITION_STORE'
              UNION SELECT edge.parent_node_id FROM stock_value_edges edge JOIN parents child ON child.id=edge.child_node_id WHERE edge.interval_to>edge.interval_from)
            SELECT node.id FROM parents JOIN stock_value_nodes node ON node.id=parents.id WHERE node.kind='SOURCE'
            """,UUID.class,receipt);
        adjust(source, f.w().goodsD());
        assertThat(db.queryForObject("SELECT EXISTS(SELECT 1 FROM stock_value_jobs WHERE source_node_id=? AND status='PENDING')",Boolean.class,source)).isTrue();
        blockedWithoutWrites(()->receipts.unapprovalEligibility(receipt),"成本来源");
        String before=facts();
        assertThatThrownBy(()->unapprove("purchaseReceipt",receipt)).isInstanceOf(com.uten.imp.common.web.ApiException.class).hasMessageContaining("成本来源");
        assertThat(facts()).isEqualTo(before);assertThat(stock(f)).isEqualByComparingTo("11");assertThat(value(f)).isEqualByComparingTo("100");assertThat(ap(receipt)).isEqualByComparingTo("100");
        assertThat(db.queryForObject("SELECT count(*) FROM document_unapprovals WHERE family='purchaseReceipt' AND original_id=?",Long.class,receipt)).isZero();
    }
    private UUID standalonePricedSource(F f){
        var request=new com.uten.imp.features.stock.dto.StockDocSaveRequest();request.setDocType("OTHER_IN");request.setBillDate(BusinessTime.today());request.setWarehouseId(f.w().warehouseId());
        var line=new com.uten.imp.features.stock.dto.StockDocItemLine();line.setGoodsId(f.w().goodsA());line.setUnitId(f.w().unitId());line.setUnitRate(BigDecimal.ONE);line.setQty(BigDecimal.TEN);line.setPrice(BigDecimal.TEN);line.setAmountOriginal(new BigDecimal("100"));line.setAmountLocal(new BigDecimal("100"));request.setItems(List.of(line));
        UUID id=ordinaryStock.create(request).getId();ordinaryStock.approve(id);
        return db.queryForObject("SELECT result_node_id FROM stock_value_events WHERE source_doc_id=? AND operation='RECEIVE'",UUID.class,id);
    }
    private void adjust(UUID source, UUID goods){
        new org.springframework.transaction.support.TransactionTemplate(beans.getBean(org.springframework.transaction.PlatformTransactionManager.class)).executeWithoutResult(status->{
            beans.getBean(com.uten.imp.security.TxSessionVars.class).bind();inventory.lockInventory(List.of(new com.uten.imp.features.stock.InventoryKey(goods,null)));
            var user=beans.getBean(com.uten.imp.security.SecurityContextCurrentUser.class);
            var context=new com.uten.imp.application.port.InventoryValuationPort.EventContext(UUID.randomUUID(),"TEST_COST",source,source,0,user.requireId(),user.requireEmployeeId(),"source-finality-"+UUID.randomUUID(),java.time.OffsetDateTime.now());
            values.adjustSource(new com.uten.imp.application.port.InventoryValuationPort.SourceAdjustment(context,source,new BigDecimal("5"),true));
        });
    }

    private UUID unapprove(String family,UUID id){
        unapproval.unapprove(family,id,new DocumentUnapprovalService.UnapproveRequest("procurement-cap-"+UUID.randomUUID(),"真实反审核对"));
        return db.queryForObject("SELECT draft_id FROM document_unapprovals WHERE family=? AND original_id=?",UUID.class,family,id);
    }
    private void allowedWithoutWrites(java.util.function.Supplier<com.uten.imp.application.port.DocumentUnapprovalPort.Eligibility> read){
        String before=facts();var result=read.get();assertThat(result.eligible()).withFailMessage("%s",result.reasons()).isTrue();assertThat(result.factsSnapshot()).matches("[a-f0-9]{64}");assertThat(result.relatedDocuments()).isEmpty();assertThat(facts()).isEqualTo(before);
    }
    private void blockedWithoutWrites(java.util.function.Supplier<com.uten.imp.application.port.DocumentUnapprovalPort.Eligibility> read,String message){
        String before=facts();var result=read.get();assertThat(result.eligible()).isFalse();assertThat(result.reasons()).extracting(com.uten.imp.application.port.DocumentUnapprovalPort.Reason::message).anyMatch(text->text.contains(message));assertThat(result.relatedDocuments()).isEmpty();assertThat(facts()).isEqualTo(before);
    }
    private String facts(){
        String[] tables={"stock_value_jobs","stock_value_tasks","stock_value_node_revisions","stock_value_production_cost_dirty","stock_balances","stock_movements","stock_value_pools","stock_value_nodes","stock_value_events","stock_value_postings","ar_ap_ledger","gl_vouchers","gl_entries","purchase_receipts","purchase_receipt_items","purchase_returns","purchase_return_items","purchase_order_items","subcontract_receipts","subcontract_receipt_items","subcontract_returns","subcontract_return_items","subcontract_order_items","subcontract_material_issue_items","subcontract_receipt_material_consumptions","procurement_inspection_items","procurement_iqc_rejection_cases","procurement_receipt_consideration_parts","procurement_iqc_consideration_reversals","document_unapprovals","stock_value_production_cost_objects","stock_value_production_cost_shares","stock_value_production_cost_tasks"};
        var facts=new ArrayList<String>();for(String table:tables){ facts.add(db.queryForObject("SELECT COALESCE(jsonb_agg(to_jsonb(row) ORDER BY to_jsonb(row)::text),'[]'::jsonb)::text FROM "+table+" row",String.class)); }return String.join("\n",facts);
    }

    private F fixture(){return fixture(false);}
    private F fixture(boolean foreign){
        var w=harness.seedWorld("gift-"+UUID.randomUUID());harness.loginAs(w.superAdminUserId());
        UUID currency=db.queryForObject("SELECT id FROM currencies WHERE is_base_currency AND NOT is_deleted",UUID.class);
        if(foreign){currency=w.currencyId();assertThat(db.queryForObject("SELECT is_base_currency FROM currencies WHERE id=?",Boolean.class,currency)).isFalse();}
        var req=new com.uten.imp.features.purchase.request.dto.RequestSaveRequest();req.setBillDate(BusinessTime.today());req.setWarehouseId(w.warehouseId());
        var rl=new com.uten.imp.features.purchase.request.dto.RequestItemLine();rl.setGoodsId(w.goodsD());rl.setUnitId(w.unitId());rl.setUnitRate(BigDecimal.ONE);rl.setQty(new BigDecimal("10"));rl.setGiftQty(BigDecimal.ONE);req.setItems(List.of(rl));
        var source=requests.create(req);requests.approve(source.getId());UUID requestItem=source.getItems().getFirst().getId();
        UUID reviewer=harness.createUserWithPerms(w,"gift-finance-"+UUID.randomUUID(),"finance_order_approval:view","finance_order_approval:approve");harness.loginAs(w.superAdminUserId());
        var order=new com.uten.imp.features.purchase.order.dto.OrderSaveRequest();order.setBillDate(BusinessTime.today());order.setSupplierId(w.supplierId());order.setWarehouseId(w.warehouseId());order.setCurrencyId(currency);order.setExchangeRate(BigDecimal.ONE);order.setTaxRate(BigDecimal.ZERO);order.setSettlementMethodId(settlement());
        var line=new com.uten.imp.features.purchase.order.dto.OrderItemLine();line.setGoodsId(w.goodsD());line.setUnitId(w.unitId());line.setUnitRate(BigDecimal.ONE);line.setQty(new BigDecimal("10"));line.setGiftQty(BigDecimal.ONE);line.setPrice(new BigDecimal("10"));line.setRequestItemId(requestItem);order.setItems(List.of(line));
        UUID id=orders.create(order).getId();finance.submit("PURCHASE",id);harness.loginAs(reviewer);
        var approval=db.queryForMap("SELECT id,version FROM procurement_order_approval_cases WHERE order_type='PURCHASE' AND order_id=? AND status='PENDING'",id);UUID caseId=(UUID)approval.get("id");
        UUID claim=claims.claim("PROCUREMENT_FINANCE_APPROVE",caseId.toString()).claimId();finance.approveBatch(List.of(new BatchDecisionItem(caseId,((Number)approval.get("version")).longValue(),claim)),null,foreign?new BigDecimal("6.234567"):BigDecimal.ONE);harness.loginAs(w.superAdminUserId());
        return new F(w,requestItem,id,db.queryForObject("SELECT id FROM purchase_order_items WHERE order_id=?",UUID.class,id),currency);
    }
    private UUID receipt(F f,String charged,String gift){
        var request=new com.uten.imp.features.purchase.receipt.dto.ReceiptSaveRequest();request.setBillDate(BusinessTime.today());request.setSupplierId(f.w().supplierId());request.setWarehouseId(f.w().warehouseId());
        var line=new com.uten.imp.features.purchase.receipt.dto.ReceiptItemLine();line.setGoodsId(f.w().goodsD());line.setUnitId(f.w().unitId());line.setUnitRate(BigDecimal.ONE);line.setQty(new BigDecimal(charged));line.setGiftQty(new BigDecimal(gift));line.setOrderItemId(f.orderItem());request.setItems(List.of(line));
        return receipts.create(request).getId();
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
