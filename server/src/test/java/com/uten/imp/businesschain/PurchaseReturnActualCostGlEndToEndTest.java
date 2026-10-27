package com.uten.imp.businesschain;

import com.uten.imp.testsupport.FixtureDatabaseProperties;

import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.support.MigratedSchemaBaseline;
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
import org.springframework.test.annotation.DirtiesContext;
import org.springframework.test.context.TestContext;
import org.springframework.test.context.TestExecutionListeners;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.context.support.AbstractTestExecutionListener;
import org.springframework.test.context.support.DirtiesContextTestExecutionListener;
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
@TestMethodOrder(MethodOrderer.OrderAnnotation.class)
@DirtiesContext(classMode=DirtiesContext.ClassMode.AFTER_CLASS)
@TestExecutionListeners(listeners=PurchaseReturnActualCostGlEndToEndTest.Cleanup.class,
    mergeMode=TestExecutionListeners.MergeMode.MERGE_WITH_DEFAULTS)
class PurchaseReturnActualCostGlEndToEndTest {
    private static MigratedSchemaBaseline.ScopedDatabase database;
    @DynamicPropertySource static void database(DynamicPropertyRegistry registry) throws Exception {
        // Period-wide regeneration and posting-role configuration must not adopt
        // another full-chain scenario's confirmed expense or configured variance role.
        database=MigratedSchemaBaseline.openDatabase("purchase_return_gl");
        FixtureDatabaseProperties.bindSameRole(registry, database::getJdbcUrl,
                database::getUsername, database::getPassword);
    }
    public static class Cleanup extends AbstractTestExecutionListener {
        @Override public int getOrder(){return new DirtiesContextTestExecutionListener().getOrder()-1;}
        @Override public void afterTestClass(TestContext ignored) throws Exception {if(database!=null)database.close();}
    }
    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    @Autowired PurchaseRequestService requests;
    @Autowired PurchaseOrderService orders;
    @Autowired PurchaseReceiptService receipts;
    @Autowired PurchaseReturnService returns;
    @Autowired com.uten.imp.features.subcontract.order.SubcontractOrderService subcontractOrders;
    @Autowired com.uten.imp.features.subcontract.receipt.SubcontractReceiptService subcontractReceipts;
    @Autowired com.uten.imp.features.subcontract.ret.SubcontractReturnService subcontractReturns;
    @Autowired ProcurementFinanceApprovalService finance;
    @Autowired TaskClaimService claims;
    @Autowired ProcurementInspectionService inspection;
    @Autowired ProcurementIqcStockInService stockIn;
    @Autowired DocumentUnapprovalService unapproval;
    @Autowired com.uten.imp.features.finance.gl.GlPostingService gl;
    @Autowired com.uten.imp.features.finance.gl.SystemPostingStyleService styles;
    private FullChainEndToEndTest harness;
    private record F(FullChainEndToEndTest.World w,UUID requestItem,UUID order,UUID orderItem,UUID currency){}
    @BeforeEach void prepare(){harness=new FullChainEndToEndTest();beans.autowireBean(harness);}
    @AfterEach void clear(){SecurityContextHolder.clearContext();}

    @Test @Order(2) void freeSupplierReturnMustReduceInventoryByActualCustodyCostWithoutInventingSupplierCredit(){
        verifyReturn("0","1","0");
    }
    @Test @Order(3) void paidSupplierReturnMustKeepCommercialCreditAndActualInventoryCostSeparate(){
        verifyReturn("1","0","10");
    }
    private void verifyReturn(String charged,String gift,String credit){
        F f=fixture();harness.seedChartOfAccounts();
        configureVarianceRole();
        UUID receipt=receipt(f,"10","1");receipts.approve(receipt);passAndStock(f,receipt);
        assertThat(stock(f)).isEqualByComparingTo("11");assertThat(value(f)).isEqualByComparingTo("100");
        UUID source=receipts.detail(receipt).getItems().getFirst().getId();
        UUID returned=returned(f,source,charged,gift);returns.approve(returned);
        assertThat(stock(f)).isEqualByComparingTo("10");assertThat(value(f)).isEqualByComparingTo("90.9091");
        assertThat(ap(returned)).isEqualByComparingTo(new BigDecimal(credit).negate());
        assertThat(number("SELECT SUM(post.amount_delta_local) FROM stock_value_postings post JOIN stock_value_events event ON event.id=post.event_id WHERE event.source_doc_id=? AND post.owner_kind='EXTERNAL'",returned)).isEqualByComparingTo("9.0909");
        String period=java.time.YearMonth.from(BusinessTime.today()).toString();
        gl.generate(period);
        BigDecimal asset=number("SELECT COALESCE(SUM(entry.direction*entry.amount),0) FROM gl_entries entry JOIN gl_vouchers voucher ON voucher.id=entry.voucher_id WHERE voucher.source_doc_id IN (?,?) AND entry.style_id=system_posting_style_id('INVENTORY_ASSET') AND voucher.status=1 AND NOT voucher.is_deleted",receipt,returned);
        assertThat(asset).as("actual inventory custody value must equal GL asset after source-specific commercial/actual-cost variance").isEqualByComparingTo(value(f));
        BigDecimal variance=new BigDecimal("9.0909").subtract(new BigDecimal(credit));
        assertThat(number("SELECT COALESCE(SUM(entry.direction*entry.amount),0) FROM gl_entries entry JOIN gl_vouchers voucher ON voucher.id=entry.voucher_id WHERE voucher.source_doc_id=? AND entry.style_id=system_posting_style_id('PROCUREMENT_RETURN_VARIANCE') AND voucher.status=1 AND NOT voucher.is_deleted",returned)).isEqualByComparingTo(variance);
        assertThat(number("SELECT COALESCE(SUM(entry.direction*entry.amount),0) FROM gl_entries entry JOIN gl_vouchers voucher ON voucher.id=entry.voucher_id WHERE voucher.source_doc_id IN (?,?) AND voucher.status=1 AND NOT voucher.is_deleted",receipt,returned)).isZero();
        gl.generate(period);
        assertThat(number("SELECT COUNT(*) FROM gl_vouchers WHERE source_type='PROC_RETURN_VARIANCE' AND source_doc_id=?",returned)).isEqualByComparingTo("1");
        returns.reverse(returned);assertThat(stock(f)).isEqualByComparingTo("11");assertThat(value(f)).isEqualByComparingTo("100");
        assertThat(number("SELECT COUNT(*) FROM gl_vouchers WHERE source_type='PROC_RETURN_VARIANCE' AND source_doc_id=?",returned)).isZero();
        gl.generate(period);
        assertThat(number("SELECT COALESCE(SUM(entry.direction*entry.amount),0) FROM gl_entries entry JOIN gl_vouchers voucher ON voucher.id=entry.voucher_id WHERE voucher.source_doc_id IN (?,?) AND entry.style_id=system_posting_style_id('INVENTORY_ASSET') AND voucher.status=1 AND NOT voucher.is_deleted",receipt,returned)).isEqualByComparingTo("100");
    }

    @Test @Order(1) void missingVarianceRoleFailsBeforeDeletingAnExistingBalancedProjection(){
        F f=fixture();harness.seedChartOfAccounts();configureVarianceRole();
        UUID receipt=receipt(f,"10","1");receipts.approve(receipt);passAndStock(f,receipt);
        String period=java.time.YearMonth.from(BusinessTime.today()).toString();gl.generate(period);
        UUID previous=db.queryForObject("SELECT id FROM gl_vouchers WHERE source_type='AP_POST' AND source_doc_id=?",UUID.class,receipt);
        UUID returned=returned(f,receipts.detail(receipt).getItems().getFirst().getId(),"0","1");returns.approve(returned);
        // The private GL database isolates period-wide regeneration. Explicitly
        // remove the configured role here to prove the missing-role rollback path.
        // Only this isolated test fixture temporarily removes the one required mapping;
        // the public configure API correctly cannot remove an operational assignment.
        UUID previousRole=db.queryForObject("SELECT style_id FROM system_posting_style_roles WHERE role_key='PROCUREMENT_RETURN_VARIANCE'",UUID.class);
        assertThat(previousRole).isNotNull();
        String otherRoles=db.queryForObject("SELECT COALESCE(jsonb_agg(to_jsonb(role) ORDER BY role_key),'[]'::jsonb)::text FROM system_posting_style_roles role WHERE role_key<>'PROCUREMENT_RETURN_VARIANCE'",String.class);
        String projectionSql="SELECT jsonb_build_object('vouchers',(SELECT COALESCE(jsonb_agg(to_jsonb(v) ORDER BY v.id),'[]'::jsonb) FROM gl_vouchers v WHERE v.period=?), 'entries',(SELECT COALESCE(jsonb_agg(to_jsonb(e) ORDER BY e.id),'[]'::jsonb) FROM gl_entries e WHERE e.period=?))::text";
        String previousProjection=db.queryForObject(projectionSql,String.class,period,period);
        try {
            assertThat(db.update("UPDATE system_posting_style_roles SET style_id=NULL WHERE role_key='PROCUREMENT_RETURN_VARIANCE' AND style_id=?",previousRole)).isEqualTo(1);
            assertThat(db.queryForObject("SELECT system_posting_style_id('PROCUREMENT_RETURN_VARIANCE')",UUID.class)).isNull();
            assertThatThrownBy(()->gl.generate(period)).isInstanceOf(com.uten.imp.common.web.ApiException.class).hasMessageContaining("退货价差科目");
            assertThat(db.queryForObject("SELECT id FROM gl_vouchers WHERE source_type='AP_POST' AND source_doc_id=?",UUID.class,receipt)).isEqualTo(previous);
            assertThat(db.queryForObject(projectionSql,String.class,period,period)).as("missing role must preserve every previous period voucher and entry").isEqualTo(previousProjection);
            assertThat(stock(f)).isEqualByComparingTo("10");assertThat(value(f)).isEqualByComparingTo("90.9091");
        } finally {
            assertThat(db.update("UPDATE system_posting_style_roles SET style_id=? WHERE role_key='PROCUREMENT_RETURN_VARIANCE' AND style_id IS NULL",previousRole)).isEqualTo(1);
        }
        assertThat(db.queryForObject("SELECT system_posting_style_id('PROCUREMENT_RETURN_VARIANCE')",UUID.class)).isEqualTo(previousRole);
        assertThat(db.queryForObject("SELECT COALESCE(jsonb_agg(to_jsonb(role) ORDER BY role_key),'[]'::jsonb)::text FROM system_posting_style_roles role WHERE role_key<>'PROCUREMENT_RETURN_VARIANCE'",String.class)).isEqualTo(otherRoles);
        returns.reverse(returned);gl.generate(period);
    }

    @Test @Order(4) void partialReturnCostsAndCreditsKeepTheirRemaindersAndReverseToTheOriginalAsset(){
        F f=fixture();harness.seedChartOfAccounts();configureVarianceRole();UUID receipt=receipt(f,"10","1");receipts.approve(receipt);passAndStock(f,receipt);
        UUID source=receipts.detail(receipt).getItems().getFirst().getId();
        UUID first=returned(f,source,"0.375","0");returns.approve(first);
        UUID second=returned(f,source,"0.625","0");returns.approve(second);
        assertThat(stock(f)).isEqualByComparingTo("10");assertThat(value(f)).isEqualByComparingTo("90.9091");
        String period=java.time.YearMonth.from(BusinessTime.today()).toString();gl.generate(period);
        assertThat(number("SELECT SUM(entry.direction*entry.amount) FROM gl_entries entry JOIN gl_vouchers voucher ON voucher.id=entry.voucher_id WHERE voucher.source_doc_id IN (?,?,?) AND entry.style_id=system_posting_style_id('INVENTORY_ASSET') AND voucher.status=1 AND NOT voucher.is_deleted",receipt,first,second)).isEqualByComparingTo("90.9091");
        assertThat(number("SELECT SUM(entry.direction*entry.amount) FROM gl_entries entry JOIN gl_vouchers voucher ON voucher.id=entry.voucher_id WHERE voucher.source_doc_id IN (?,?) AND entry.style_id=system_posting_style_id('PROCUREMENT_RETURN_VARIANCE') AND voucher.status=1 AND NOT voucher.is_deleted",first,second)).isEqualByComparingTo("-0.9091");
        returns.reverse(second);returns.reverse(first);assertThat(stock(f)).isEqualByComparingTo("11");assertThat(value(f)).isEqualByComparingTo("100");
        gl.generate(period);
    }

    @Test @Order(5) void foreignCommercialCreditUsesFrozenLocalRateWhileInventoryUsesActualLocalIssueCost(){
        F f=fixture(true);harness.seedChartOfAccounts();configureVarianceRole();UUID receipt=receipt(f,"10","1");receipts.approve(receipt);passAndStock(f,receipt);
        UUID returned=returned(f,receipts.detail(receipt).getItems().getFirst().getId(),"1","0");var approved=returns.approve(returned);
        assertThat(approved.getTotalOriginal()).isEqualByComparingTo("10");assertThat(approved.getTotalLocal()).isEqualByComparingTo("62.34567");
        assertThat(value(f)).isEqualByComparingTo("566.7788");String period=java.time.YearMonth.from(BusinessTime.today()).toString();gl.generate(period);
        assertThat(number("SELECT SUM(entry.direction*entry.amount) FROM gl_entries entry JOIN gl_vouchers voucher ON voucher.id=entry.voucher_id WHERE voucher.source_doc_id IN (?,?) AND entry.style_id=system_posting_style_id('INVENTORY_ASSET') AND voucher.status=1 AND NOT voucher.is_deleted",receipt,returned)).isEqualByComparingTo("566.7788");
        assertThat(number("SELECT SUM(entry.direction*entry.amount) FROM gl_entries entry JOIN gl_vouchers voucher ON voucher.id=entry.voucher_id WHERE voucher.source_doc_id=? AND entry.style_id=system_posting_style_id('PROCUREMENT_RETURN_VARIANCE') AND voucher.status=1 AND NOT voucher.is_deleted",returned)).isEqualByComparingTo("-5.66777");
        returns.reverse(returned);gl.generate(period);
    }

    @Test @Order(6) void subcontractReturnCreditsOnlyTheProcessingFeeAndRemovesTheActualMaterialAndProcessingCost(){
        var w=harness.seedWorld("sc-return-gl-"+UUID.randomUUID());harness.loginAs(w.superAdminUserId());
        UUID material=harness.ensureSubcontractDirectMaterial(w,w.goodsE());harness.receiveSubcontractMaterial(w,material,"20");
        harness.seedChartOfAccounts();configureVarianceRole();
        UUID currency=db.queryForObject("SELECT id FROM currencies WHERE is_base_currency AND NOT is_deleted",UUID.class);
        var order=new com.uten.imp.features.subcontract.order.dto.OrderSaveRequest();
        order.setBillDate(BusinessTime.today());order.setSupplierId(w.supplierId());order.setWarehouseId(w.warehouseId());
        order.setCurrencyId(currency);order.setExchangeRate(BigDecimal.ONE);order.setTaxRate(BigDecimal.ZERO);order.setSettlementMethodId(settlement());
        var orderLine=new com.uten.imp.features.subcontract.order.dto.OrderItemLine();
        orderLine.setGoodsId(w.goodsE());orderLine.setUnitId(w.unitId());orderLine.setUnitRate(BigDecimal.ONE);
        orderLine.setQty(BigDecimal.TEN);orderLine.setPrice(new BigDecimal("50"));order.setItems(List.of(orderLine));
        UUID orderId=subcontractOrders.create(order).getId();
        UUID reviewer=harness.createUserWithPerms(w,"sc-return-reviewer-"+orderId,"finance_order_approval:view","finance_order_approval:approve");
        harness.loginAs(w.superAdminUserId());finance.submit("SUBCONTRACT",orderId);harness.loginAs(reviewer);
        var approval=db.queryForMap("SELECT id,version FROM procurement_order_approval_cases WHERE order_type='SUBCONTRACT' AND order_id=? AND status='PENDING'",orderId);
        UUID caseId=(UUID)approval.get("id"),claim=claims.claim("PROCUREMENT_FINANCE_APPROVE",caseId.toString()).claimId();
        finance.approveBatch(List.of(new BatchDecisionItem(caseId,((Number)approval.get("version")).longValue(),claim)),null,BigDecimal.ONE);
        harness.loginAs(w.superAdminUserId());
        UUID orderItem=db.queryForObject("SELECT id FROM subcontract_order_items WHERE order_id=?",UUID.class,orderId);
        harness.drawAndIssueSubcontract(orderItem,BigDecimal.TEN,"sc-return-draw-"+orderItem);
        var receipt=new com.uten.imp.features.subcontract.receipt.dto.ReceiptSaveRequest();
        receipt.setBillDate(BusinessTime.today());receipt.setSupplierId(w.supplierId());receipt.setWarehouseId(w.warehouseId());
        var receiptLine=new com.uten.imp.features.subcontract.receipt.dto.ReceiptItemLine();
        receiptLine.setGoodsId(w.goodsE());receiptLine.setUnitId(w.unitId());receiptLine.setUnitRate(BigDecimal.ONE);
        receiptLine.setQty(BigDecimal.TEN);receiptLine.setOrderItemId(orderItem);receipt.setItems(List.of(receiptLine));
        UUID receiptId=subcontractReceipts.create(receipt).getId();subcontractReceipts.approve(receiptId);
        UUID inspectionId=db.queryForObject("SELECT id FROM procurement_inspection_items WHERE receipt_type='SUBCONTRACT' AND receipt_id=?",UUID.class,receiptId);
        inspection.dispose("SUBCONTRACT",receiptId,inspectionId,new InspectionDispositionRequest("PASS",null,"委外材料与加工费实际入仓","sc-return-pass-"+inspectionId));
        UUID keeper=ReflectionTestUtils.invokeMethod(harness,"createIqcWarehouseConfirmer",w,"sc-return-keeper-"+receiptId);harness.loginAs(keeper);
        var command=ReflectionTestUtils.<com.uten.imp.features.warehouse.inbound.ProcurementIqcStockInContracts.ConfirmRequest>invokeMethod(harness,"latestIqcStockInRequest","SUBCONTRACT",receiptId,inspectionId,BigDecimal.TEN,"sc-return-stock-"+inspectionId,"SC-RETURN-BIN");
        stockIn.confirm("SUBCONTRACT",receiptId,command);harness.loginAs(w.superAdminUserId());ReflectionTestUtils.invokeMethod(harness,"drainCosts",w);
        assertThat(number("SELECT amount_local FROM stock_balances WHERE warehouse_id=? AND goods_id=?",w.warehouseId(),w.goodsE())).isEqualByComparingTo("600");
        var request=new com.uten.imp.features.subcontract.ret.dto.ReturnSaveRequest();
        request.setBillDate(BusinessTime.today());request.setSupplierId(w.supplierId());request.setWarehouseId(w.warehouseId());
        var line=new com.uten.imp.features.subcontract.ret.dto.ReturnItemLine();
        line.setGoodsId(w.goodsE());line.setUnitId(w.unitId());line.setUnitRate(BigDecimal.ONE);line.setQty(BigDecimal.ONE);
        line.setOrderItemId(orderItem);line.setReceiptItemId(subcontractReceipts.detail(receiptId).getItems().getFirst().getId());request.setItems(List.of(line));
        UUID returned=subcontractReturns.create(request).getId();subcontractReturns.approve(returned);
        assertThat(ap(returned)).isEqualByComparingTo("-50");
        assertThat(number("SELECT amount_local FROM stock_balances WHERE warehouse_id=? AND goods_id=?",w.warehouseId(),w.goodsE())).isEqualByComparingTo("540");
        String period=java.time.YearMonth.from(BusinessTime.today()).toString();gl.generate(period);
        assertThat(number("SELECT SUM(entry.direction*entry.amount) FROM gl_entries entry JOIN gl_vouchers voucher ON voucher.id=entry.voucher_id WHERE voucher.source_doc_id=? AND entry.style_id=system_posting_style_id('INVENTORY_ASSET') AND voucher.status=1 AND NOT voucher.is_deleted",returned)).isEqualByComparingTo("-60");
        assertThat(number("SELECT SUM(entry.direction*entry.amount) FROM gl_entries entry JOIN gl_vouchers voucher ON voucher.id=entry.voucher_id WHERE voucher.source_doc_id=? AND entry.style_id=system_posting_style_id('PROCUREMENT_RETURN_VARIANCE') AND voucher.status=1 AND NOT voucher.is_deleted",returned)).isEqualByComparingTo("10");
        gl.generate(period);assertThat(number("SELECT COUNT(*) FROM gl_vouchers WHERE source_type='PROC_RETURN_VARIANCE' AND source_doc_id=?",returned)).isEqualByComparingTo("1");
        subcontractReturns.reverse(returned);assertThat(number("SELECT amount_local FROM stock_balances WHERE warehouse_id=? AND goods_id=?",w.warehouseId(),w.goodsE())).isEqualByComparingTo("600");
        assertThat(number("SELECT COUNT(*) FROM gl_vouchers WHERE source_type='PROC_RETURN_VARIANCE' AND source_doc_id=?",returned)).isZero();gl.generate(period);
    }

    private void configureVarianceRole(){
        var role=styles.list().stream().filter(row->row.roleKey().equals("PROCUREMENT_RETURN_VARIANCE")).findFirst().orElseThrow();
        if(!role.usable()){
            UUID style=UUID.randomUUID();db.update("INSERT INTO payment_styles(id,code,name,category,level,status) VALUES(?,?,?,'EXPENSE',0,'使用')",style,"RVAR-"+style,"测试采购退货价差损益");
            styles.configure(role.roleKey(),new com.uten.imp.features.finance.gl.SystemPostingStyleService.Configure(style,role.updatedAt()));
        }
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
