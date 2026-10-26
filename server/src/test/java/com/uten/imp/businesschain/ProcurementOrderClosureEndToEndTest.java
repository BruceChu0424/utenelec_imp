package com.uten.imp.businesschain;

import com.uten.imp.common.finance.ProcurementOrderClosurePolicy;
import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.common.taskclaim.TaskClaimService;
import com.uten.imp.features.finance.procurement.ProcurementApprovalContracts.BatchDecisionItem;
import com.uten.imp.features.finance.procurement.ProcurementApprovalContracts.FinanceApproval;
import com.uten.imp.features.finance.procurement.ProcurementFinanceApprovalService;
import com.uten.imp.features.finance.procurement.ProcurementOrderClosureService;
import com.uten.imp.features.finance.procurement.ProcurementOrderClosureService.ClosureRequest;
import com.uten.imp.features.purchase.order.PurchaseOrderService;
import com.uten.imp.features.purchase.request.PurchaseRequestService;
import com.uten.imp.features.purchase.receipt.PurchaseReceiptService;
import jakarta.persistence.EntityManager;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.support.TransactionTemplate;

import java.math.BigDecimal;
import java.util.List;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

/** Real finance claims, source commitments, arrival facts and retained supplier custody. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
@org.springframework.test.annotation.DirtiesContext(classMode=org.springframework.test.annotation.DirtiesContext.ClassMode.AFTER_CLASS)
@SpringBootTest(properties = {
        "spring.profiles.active=dev", "uten.audit.retention.enabled=false",
        "uten.reporting.materialized-view-refresh.enabled=false", "uten.production.readiness-reconcile.enabled=false",
        "uten.inventory.value-work.enabled=false", "uten.features.goods-owner-scope-enabled=false",
        "uten.storage.uploads-enabled=false",
        "uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only", // gitleaks:allow shared synthetic fixture.
        "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789", // gitleaks:allow shared synthetic fixture.
        "uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only",
        "uten.bootstrap.admin-login=full-chain-bootstrap-admin-test", "uten.bootstrap.admin-password=HarnessAdminPass-1!"})
class ProcurementOrderClosureEndToEndTest {
    @DynamicPropertySource static void database(DynamicPropertyRegistry registry) {
        FullChainEndToEndTest.registerDataSource(registry);
    }

    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    @Autowired PurchaseRequestService requests;
    @Autowired PurchaseOrderService orders;
    @Autowired PurchaseReceiptService receipts;
    @Autowired com.uten.imp.features.purchase.ret.PurchaseReturnService purchaseReturns;
    @Autowired com.uten.imp.features.warehouse.inbound.ProcurementInspectionService inspections;
    @Autowired com.uten.imp.features.warehouse.inbound.ProcurementIqcStockInService stockIn;
    @Autowired ProcurementOrderClosureService closure;
    @Autowired ProcurementFinanceApprovalService finance;
    @Autowired com.uten.imp.features.subcontract.material_return.SubcontractMaterialReturnService materialReturns;
    @Autowired com.uten.imp.features.subcontract.order.SubcontractOrderService subcontractOrders;
    @Autowired com.uten.imp.features.subcontract.application.SubcontractApplicationService subcontractApplications;
    @Autowired com.uten.imp.features.warehouse.inbound.WarehouseArrivalRegistrationService arrivals;
    @Autowired TaskClaimService claims;
    @Autowired com.uten.imp.common.docnumber.DocNumberService numbers;
    @Autowired PlatformTransactionManager transactions;
    @Autowired com.uten.imp.security.TxSessionVars tx;
    @Autowired EntityManager em;
    @Autowired com.uten.imp.features.purchase.report.PurchaseReportService reports;
    private FullChainEndToEndTest harness;

    private record Fixture(FullChainEndToEndTest.World world, UUID reviewer,
                           UUID request, UUID source, UUID order, UUID item) { }

    @BeforeEach void setup() {
        harness = new FullChainEndToEndTest();
        beans.autowireBean(harness);
    }

    @AfterEach void logout() { SecurityContextHolder.clearContext(); }

    @Test void partialArrivalRemainsInIqcWhileOnlyFinanceApprovalEndsTheRemainingDelivery() {
        Fixture f = fixture("closure-partial", "2");
        UUID receipt = receipt(f, "4", "1");
        String physicalBefore = physicalFacts(receipt);
        String billNo = db.queryForObject("SELECT bill_no FROM purchase_orders WHERE id=?",String.class,f.order());
        assertThat(orders.detail(f.order()).getItems().getFirst().getDifferenceQty()).isEqualByComparingTo("-6");
        assertThat(reports.expediting(billNo,null,null,null,null,java.util.Map.of(),1,50,null,null).rows()).hasSize(1);
        var preview = closure.preview("PURCHASE", f.order());
        assertThat(preview.canSubmit()).isTrue();
        var pending = closure.submit("PURCHASE", f.order(),
                new ClosureRequest("CLOSE", "供应商停止供货", preview.fingerprint()));
        var pendingDetail = orders.detail(f.order());
        assertThat(pendingDetail.getClosureRequest().status()).isEqualTo("PENDING");
        assertThat(pendingDetail.getClosureRequest().reason()).isEqualTo("供应商停止供货");
        assertThat(pendingDetail.getFinanceApproval().status()).isEqualTo("APPROVED");
        assertOpen(f.order());
        assertThat(status(f.order())).isEqualTo("OPEN");
        assertThat(number("SELECT ordered_qty FROM purchase_request_items WHERE id=?", f.source()))
                .isEqualByComparingTo("10");
        assertThatThrownBy(() -> closure.submit("PURCHASE", f.order(),
                new ClosureRequest("CLOSE", "重复申请", preview.fingerprint()))).isInstanceOf(ApiException.class);
        assertThat(db.queryForObject("SELECT COUNT(*) FROM procurement_order_approval_cases WHERE order_id=? AND status='PENDING'", Long.class, f.order())).isEqualTo(1L);

        approve(f, pending);
        assertThat(db.queryForObject("SELECT is_closed FROM purchase_orders WHERE id=?", Boolean.class, f.order())).isTrue();
        assertThat(orders.detail(f.order()).isCanReverse()).isFalse();
        assertThat(status(f.order())).isEqualTo("CLOSED");
        db.update("UPDATE inbound_expectations SET status='OPEN' WHERE order_type='PURCHASE' AND order_id=?", f.order());
        assertThat(status(f.order())).isEqualTo("CLOSED");
        assertThatThrownBy(() -> db.update("UPDATE purchase_orders SET termination_case_id=NULL WHERE id=?", f.order()))
                .isInstanceOf(org.springframework.dao.DataAccessException.class);
        assertThat(number("SELECT qty FROM purchase_order_items WHERE id=?", f.item())).isEqualByComparingTo("10");
        assertThat(number("SELECT received_qty FROM purchase_order_items WHERE id=?", f.item())).isEqualByComparingTo("4");
        assertThat(orders.detail(f.order()).getItems().getFirst().getDifferenceQty()).isEqualByComparingTo("-6");
        var differenceRows=reports.orderDetail(billNo,null,null,null,null,null,java.util.Map.of(),1,50,null,null).rows();
        assertThat(differenceRows).hasSize(1);
        assertThat(differenceRows.getFirst().get("differenceQtyExact")).isEqualTo("-6.0000");
        assertThat(reports.expediting(billNo,null,null,null,null,java.util.Map.of(),1,50,null,null).rows()).isEmpty();
        assertThat(number("SELECT ordered_qty FROM purchase_request_items WHERE id=?", f.source())).isEqualByComparingTo("4");
        assertThat(number("SELECT gift_ordered_qty FROM purchase_request_items WHERE id=?", f.source())).isEqualByComparingTo("1");
        assertThat(requests.detail(f.request()).getItems().getFirst().getPhysicalRemainingQty()).isEqualByComparingTo("7");
        assertThat(physicalFacts(receipt)).isEqualTo(physicalBefore);
        assertThat(db.queryForObject("SELECT COUNT(*) FROM procurement_inspection_items WHERE receipt_id=? AND status<>'REVERSED'", Long.class, receipt))
                .isEqualTo(2L);

        new TransactionTemplate(transactions).executeWithoutResult(ignored -> {
            tx.bind(); ProcurementOrderClosurePolicy.recalculate(em, "PURCHASE", f.item());
        });
        assertThat(db.queryForObject("SELECT is_closed FROM purchase_orders WHERE id=?", Boolean.class, f.order())).isTrue();
        finishExistingIqc(f, receipt);
        assertThat(number("SELECT SUM(warehouse_stocked_base_qty) FROM procurement_inspection_items WHERE receipt_id=?", receipt))
                .isEqualByComparingTo("5");
        assertThat(db.queryForObject("SELECT is_closed FROM purchase_orders WHERE id=?", Boolean.class, f.order())).isTrue();
        assertThatThrownBy(() -> receipt(f, "1", "0")).isInstanceOf(ApiException.class);
        var returned=returnOne(f,receipt);
        String stopped=businessFacts(f);
        assertThatThrownBy(() -> db.update("UPDATE purchase_order_items SET received_qty=received_qty+1 WHERE id=?",f.item()))
                .isInstanceOf(org.springframework.dao.DataAccessException.class);
        assertThatThrownBy(() -> db.update("UPDATE purchase_order_items SET returned_qty=returned_qty+1 WHERE id=?",f.item()))
                .isInstanceOf(org.springframework.dao.DataAccessException.class);
        assertThat(businessFacts(f)).isEqualTo(stopped);
        assertThatThrownBy(() -> purchaseReturns.create(returned)).isInstanceOf(ApiException.class).hasMessageContaining("结束");
        assertThat(businessFacts(f)).isEqualTo(stopped);
        assertThatThrownBy(() -> receipts.reverse(receipt)).isInstanceOf(ApiException.class).hasMessageContaining("结束");
        assertThat(businessFacts(f)).isEqualTo(stopped);
    }

    @Test void unresolvedQualityMustBeCompletedBeforeAClosureCanBeSubmitted() {
        Fixture f=fixture("closure-unresolved-quality","0");
        UUID receipt=receipt(f,"4","0",false);
        var pendingQuality=closure.preview("PURCHASE",f.order());
        assertThat(pendingQuality.canSubmit()).isFalse();
        String before=businessFacts(f);
        assertThatThrownBy(() -> closure.submit("PURCHASE",f.order(),new ClosureRequest("CLOSE","不应跳过待检实物",pendingQuality.fingerprint())))
                .isInstanceOf(ApiException.class).hasMessageContaining("质检");
        assertThat(businessFacts(f)).isEqualTo(before);
        passExistingIqc(f,receipt);
        assertThat(closure.preview("PURCHASE",f.order()).canSubmit()).isTrue();
    }

    @Test void anExistingPhysicalReturnCannotBeReversedAfterItsRetainedQuantityWasFinanciallyClosed() {
        Fixture f=fixture("closure-retained-return","0");
        UUID receipt=receipt(f,"4","0"); finishExistingIqc(f,receipt);
        UUID returned=purchaseReturns.create(returnOne(f,receipt)).getId(); purchaseReturns.approve(returned);
        var preview=closure.preview("PURCHASE",f.order());
        assertThat(preview.items()).singleElement().satisfies(row -> assertThat(row.remainingQty()).isEqualByComparingTo("7"));
        approve(f,closure.submit("PURCHASE",f.order(),new ClosureRequest("CLOSE","按退货后的净留存核定结束",preview.fingerprint())));
        String before=businessFacts(f);
        assertThatThrownBy(() -> purchaseReturns.reverse(returned)).isInstanceOf(ApiException.class).hasMessageContaining("结束");
        assertThat(businessFacts(f)).isEqualTo(before);
    }

    @Test void rejectedClosurePreservesTheEffectiveOrderSourcesAndWarehouseWork() {
        Fixture f = fixture("closure-reject", "0");
        var preview = closure.preview("PURCHASE", f.order());
        var pending = closure.submit("PURCHASE", f.order(),
                new ClosureRequest("CLOSE", "旧库待核对", preview.fingerprint()));
        harness.loginAs(f.reviewer());
        finance.rejectBatch(List.of(decision(pending)), "还要继续跟进供货");
        harness.loginAs(f.world().superAdminUserId());
        assertOpen(f.order());
        assertThat(status(f.order())).isEqualTo("OPEN");
        assertThat(number("SELECT ordered_qty FROM purchase_request_items WHERE id=?", f.source())).isEqualByComparingTo("10");
        assertThat(db.queryForObject("SELECT fn_procurement_order_latest_approval_status('PURCHASE',?)", String.class, f.order()))
                .isEqualTo("APPROVED");
        assertThat(closure.preview("PURCHASE", f.order()).canSubmit()).isTrue();
        assertThat(orders.detail(f.order()).getClosureRequest().rejectionReason()).isEqualTo("还要继续跟进供货");
        assertThat(orders.detail(f.order()).getFinanceApproval().status()).isEqualTo("APPROVED");
        receipt(f, "1", "0");
    }

    @Test void closedOrderLeavesTheReturnedWorkbenchEvenWhenThePriorQuantityReviewWasRejected() {
        Fixture f=fixture("closure-after-qty-rejection","0");
        var changed=orders.changeQty(f.order(),new com.uten.imp.features.finance.procurement.ProcurementApprovalContracts.OrderQtyChangeRequest(
                List.of(new com.uten.imp.features.finance.procurement.ProcurementApprovalContracts.OrderQtyChangeItem(f.item(),new BigDecimal("9")))));
        harness.loginAs(f.reviewer());finance.rejectBatch(List.of(decision(changed.getFinanceApproval())),"金额还需核对");
        harness.loginAs(f.world().superAdminUserId());
        var preview=closure.preview("PURCHASE",f.order());
        var closing=closure.submit("PURCHASE",f.order(),new ClosureRequest("CLOSE","停止继续履约并由财务确认结束",preview.fingerprint()));
        approve(f,closing);
        assertThat(db.queryForList("SELECT task_status FROM v_procurement_decomposition_tasks WHERE action_doc_type='PURCHASE_ORDER' AND action_doc_id=?",String.class,f.order()))
                .containsExactly("COMPLETED");
    }

    @Test void reorderedDraftContainsOnlyUndeliveredChargedAndGiftQuantitiesWithoutDoubleCommitment() {
        Fixture f = fixture("closure-reorder", "2");
        receipt(f, "4", "1");
        var preview = closure.preview("PURCHASE", f.order());
        var pending = closure.submit("PURCHASE", f.order(),
                new ClosureRequest("CLOSE_AND_REORDER", "余量另找供应商", preview.fingerprint()));
        approve(f, pending);
        UUID replacement = db.queryForObject("SELECT replacement_order_id FROM procurement_order_approval_cases WHERE id=?", UUID.class, pending.caseId());
        assertThat(replacement).isNotNull();
        assertThat(orders.detail(replacement).getSupplierId()).isNull();
        assertThat(orders.detail(replacement).getWarehouseId()).isEqualTo(f.world().warehouseId());
        assertThat(orders.detail(f.order()).getClosureRequest().replacementOrderId()).isEqualTo(replacement);
        assertThat(orders.detail(f.order()).getClosureRequest().replacementBillNo()).isNotBlank();
        assertThat(number("SELECT SUM(qty) FROM purchase_order_items WHERE order_id=? AND is_deleted=FALSE", replacement))
                .isEqualByComparingTo("6");
        assertThat(number("SELECT SUM(gift_qty) FROM purchase_order_items WHERE order_id=? AND is_deleted=FALSE", replacement))
                .isEqualByComparingTo("1");
        assertThat(number("SELECT ordered_qty FROM purchase_request_items WHERE id=?", f.source())).isEqualByComparingTo("4");
        assertThat(number("SELECT gift_ordered_qty FROM purchase_request_items WHERE id=?", f.source())).isEqualByComparingTo("1");
        assertThat(requests.detail(f.request()).getItems().getFirst().getPhysicalRemainingQty()).isZero();
        assertThat(db.queryForObject("SELECT COUNT(*) FROM inbound_expectations WHERE order_id=? AND status='OPEN'", Long.class, replacement)).isZero();
        assertThatThrownBy(() -> approve(f, pending)).isInstanceOf(ApiException.class);
        assertThat(db.queryForObject("SELECT replacement_order_id FROM procurement_order_approval_cases WHERE id=?", UUID.class, pending.caseId())).isEqualTo(replacement);

        harness.loginAs(f.world().superAdminUserId());
        chooseReplacementSupplier(replacement, f.world().supplierId());
        var replacementPending = finance.submit("PURCHASE", replacement);
        approve(f, replacementPending);
        assertThat(number("SELECT ordered_qty FROM purchase_request_items WHERE id=?", f.source())).isEqualByComparingTo("10");
        assertThat(number("SELECT SUM(source.alloc_qty+source.allocated_gift_qty) FROM purchase_order_item_sources source JOIN purchase_order_items item ON item.id=source.order_item_id WHERE item.order_id=?", replacement))
                .isEqualByComparingTo("7");
    }

    @Test void changedArrivalFactsInvalidateBothSubmissionPreviewAndPendingApproval() {
        Fixture f = fixture("closure-stale", "0");
        var oldPreview = closure.preview("PURCHASE", f.order());
        receipt(f, "1", "0");
        assertThatThrownBy(() -> closure.submit("PURCHASE", f.order(),
                new ClosureRequest("CLOSE", "旧预览", oldPreview.fingerprint()))).isInstanceOf(ApiException.class);
        var fresh = closure.preview("PURCHASE", f.order());
        var pending = closure.submit("PURCHASE", f.order(), new ClosureRequest("CLOSE", "供应商停供", fresh.fingerprint()));
        receipt(f, "1", "0");
        assertThatThrownBy(() -> approve(f, pending)).isInstanceOf(ApiException.class);
        assertOpen(f.order());
        assertThat(status(f.order())).isEqualTo("OPEN");
        assertThat(db.queryForObject("SELECT status FROM procurement_order_approval_cases WHERE id=?", String.class, pending.caseId()))
                .isEqualTo("PENDING");
    }

    @Test void readOnlyBusinessUserCannotSubmitAndApprovalRequiresTheLiveFinanceClaim() {
        Fixture f = fixture("closure-permission", "0");
        UUID commercialApproval = db.queryForObject("SELECT id FROM procurement_order_approval_cases WHERE order_id=? AND status='APPROVED' AND request_type='ORDER'", UUID.class, f.order());
        assertThatThrownBy(() -> db.update("UPDATE purchase_orders SET termination_case_id=? WHERE id=?", commercialApproval, f.order()))
                .isInstanceOf(org.springframework.dao.DataAccessException.class);
        var preview = closure.preview("PURCHASE", f.order());
        UUID viewer = harness.createUserWithPerms(f.world(), "closure-view-"+UUID.randomUUID(), "purchase_order:view");
        harness.loginAs(viewer);
        assertThatThrownBy(() -> closure.submit("PURCHASE", f.order(),
                new ClosureRequest("CLOSE", "越权提交", preview.fingerprint())))
                .isInstanceOfAny(org.springframework.security.access.AccessDeniedException.class, ApiException.class);
        harness.loginAs(f.world().superAdminUserId());
        var pending = closure.submit("PURCHASE", f.order(), new ClosureRequest("CLOSE", "结束", preview.fingerprint()));
        harness.loginAs(f.reviewer());
        assertThatThrownBy(() -> finance.approveBatch(List.of(new BatchDecisionItem(pending.caseId(), pending.version())), null))
                .isInstanceOf(ApiException.class);
        assertOpen(f.order());
    }

    @Test void concurrentClosureSubmissionsCreateExactlyOnePendingFinanceCase() throws Exception {
        Fixture f = fixture("closure-concurrent", "0");
        var preview = closure.preview("PURCHASE", f.order());
        var start = new java.util.concurrent.CountDownLatch(1);
        try (var workers = java.util.concurrent.Executors.newFixedThreadPool(2)) {
            java.util.concurrent.Callable<Boolean> submit = () -> {
                harness.loginAs(f.world().superAdminUserId());
                try {
                    if (!start.await(20, java.util.concurrent.TimeUnit.SECONDS)) throw new IllegalStateException("submission barrier timeout");
                    closure.submit("PURCHASE", f.order(), new ClosureRequest("CLOSE", "并发结束", preview.fingerprint()));
                    return true;
                } catch (ApiException expectedConflict) {
                    return false;
                } finally {
                    SecurityContextHolder.clearContext();
                }
            };
            var first = workers.submit(submit);
            var second = workers.submit(submit);
            start.countDown();
            assertThat(List.of(first.get(40, java.util.concurrent.TimeUnit.SECONDS), second.get(40, java.util.concurrent.TimeUnit.SECONDS)))
                    .containsExactlyInAnyOrder(true, false);
        }
        assertThat(db.queryForObject("SELECT COUNT(*) FROM procurement_order_approval_cases WHERE order_id=? AND status='PENDING'", Long.class, f.order()))
                .isEqualTo(1L);
        assertOpen(f.order());
        assertThat(status(f.order())).isEqualTo("OPEN");
    }

    @Test void productionSupplyReturnsToItsOriginalRequestAndTransfersOnlyOnceToTheReplacementOrder() {
        var w = harness.seedWorld("closure-production-"+UUID.randomUUID());
        UUID finished = UUID.randomUUID(), material = UUID.randomUUID();
        harness.insertGoods(finished, "CP-"+finished, "结束重购成品", "自制", w.unitId(), w.unitLegacy());
        harness.insertGoods(material, "CM-"+material, "结束重购物料", "采购", w.unitId(), w.unitLegacy());
        harness.insertBom(finished, material, "2");
        db.update("UPDATE goods SET default_supplier_id=? WHERE id=?", w.supplierId(), material);
        var original = harness.submitPurchaseForFinance(w, finished, material, "10");
        harness.loginAs(original.reviewerUserId()); harness.approvePendingFinance("PURCHASE", original.orderId());
        harness.loginAs(w.superAdminUserId());
        var transfer = db.queryForMap("SELECT transfer.* FROM production_material_peg_transfers transfer JOIN purchase_order_items item ON item.id=transfer.order_item_id WHERE item.order_id=? AND transfer.status='EFFECTIVE'", original.orderId());
        UUID transferId = (UUID)transfer.get("id"), requestPeg = (UUID)transfer.get("from_peg_id"), orderPeg = (UUID)transfer.get("to_peg_id");
        UUID source = (UUID)transfer.get("request_item_id"), demand = (UUID)transfer.get("demand_id");
        assertThat(number("SELECT released_qty FROM production_material_supply_pegs WHERE id=?", requestPeg)).isEqualByComparingTo("20");
        var preview = closure.preview("PURCHASE", original.orderId());
        var pending = closure.submit("PURCHASE", original.orderId(), new ClosureRequest("CLOSE_AND_REORDER", "原供应商停止供货，补齐原生产需求", preview.fingerprint()));
        harness.loginAs(original.reviewerUserId()); finance.approveBatch(List.of(decision(pending)), null);
        harness.loginAs(w.superAdminUserId());
        UUID replacement = db.queryForObject("SELECT replacement_order_id FROM procurement_order_approval_cases WHERE id=?", UUID.class, pending.caseId());
        assertThat(number("SELECT allocated_qty-released_qty FROM production_material_supply_pegs WHERE id=?", orderPeg)).isZero();
        assertThat(number("SELECT released_qty FROM production_material_supply_pegs WHERE id=?", requestPeg)).isZero();
        assertThat(number("SELECT fn_procurement_transfer_net_qty('PURCHASE',?)", transferId)).isZero();
        assertThat(number("SELECT fn_procurement_transfer_released_qty('PURCHASE',?)", transferId)).isEqualByComparingTo("20");
        assertThat(number("SELECT required_qty FROM production_material_demands WHERE id=?", demand)).isEqualByComparingTo("20");
        assertThat(number("SELECT ordered_qty FROM purchase_request_items WHERE id=?", source)).isZero();
        assertThat(db.queryForObject("SELECT fn_procurement_order_reserves_source('PURCHASE',?)", Boolean.class, replacement)).isTrue();
        chooseReplacementSupplier(replacement, w.supplierId());
        finance.submit("PURCHASE", replacement);
        harness.loginAs(original.reviewerUserId()); harness.approvePendingFinance("PURCHASE", replacement);
        harness.loginAs(w.superAdminUserId());
        UUID replacementPeg = db.queryForObject("SELECT transfer.to_peg_id FROM production_material_peg_transfers transfer JOIN purchase_order_items item ON item.id=transfer.order_item_id WHERE item.order_id=? AND transfer.status='EFFECTIVE'", UUID.class, replacement);
        assertThat(replacementPeg).isNotEqualTo(orderPeg);
        assertThat(number("SELECT allocated_qty-released_qty FROM production_material_supply_pegs WHERE id=?", replacementPeg)).isEqualByComparingTo("20");
        assertThat(number("SELECT released_qty FROM production_material_supply_pegs WHERE id=?", requestPeg)).isEqualByComparingTo("20");
        assertThat(number("SELECT fn_procurement_transfer_net_qty('PURCHASE',?)", transferId)).isZero();
        assertThat(number("SELECT SUM(allocated_qty-released_qty) FROM production_material_supply_pegs WHERE demand_id=? AND supply_type='PURCHASE_ORDER_ITEM'", demand)).isEqualByComparingTo("20");
        assertThat(number("SELECT ordered_qty FROM purchase_request_items WHERE id=?", source)).isEqualByComparingTo("20");
    }

    @Test void mergedSourcesKeepPaidFifoAndGiftProvenanceWhenOnlyTheRemainingSharesAreReordered() {
        Fixture f = fixture("closure-merged", "2");
        orders.reverse(f.order());
        var source = new com.uten.imp.features.purchase.request.dto.RequestSaveRequest();
        source.setBillDate(BusinessTime.today()); source.setNeedDate(BusinessTime.today().plusDays(3)); source.setWarehouseId(f.world().warehouseId());
        var requested = new com.uten.imp.features.purchase.request.dto.RequestItemLine();
        requested.setGoodsId(f.world().goodsD()); requested.setUnitId(f.world().unitId()); requested.setUnitRate(BigDecimal.ONE); requested.setQty(BigDecimal.TEN);
        source.setItems(List.of(requested)); var second = requests.create(source); requests.approve(second.getId());
        UUID secondSource = second.getItems().getFirst().getId();
        var line = new com.uten.imp.features.purchase.order.dto.OrderItemLine();
        line.setGoodsId(f.world().goodsD()); line.setUnitId(f.world().unitId()); line.setUnitRate(BigDecimal.ONE);
        line.setQty(new BigDecimal("20")); line.setGiftQty(new BigDecimal("2")); line.setPrice(BigDecimal.TEN);
        line.setRequestItemIds(List.of(secondSource,f.source()));
        var request = new com.uten.imp.features.purchase.order.dto.OrderSaveRequest();
        request.setBillDate(BusinessTime.today()); request.setSupplierId(f.world().supplierId()); request.setWarehouseId(f.world().warehouseId());
        request.setCurrencyId(db.queryForObject("SELECT id FROM currencies WHERE is_base_currency AND NOT is_deleted", UUID.class));
        request.setExchangeRate(BigDecimal.ONE); request.setTaxRate(BigDecimal.ZERO);
        request.setSettlementMethodId(db.queryForObject("SELECT id FROM settlement_methods WHERE status='使用' AND NOT is_deleted ORDER BY code LIMIT 1", UUID.class));
        request.setItems(List.of(line)); var merged = orders.create(request);
        Fixture mergedFixture = new Fixture(f.world(),f.reviewer(),f.request(),f.source(),merged.getId(),merged.getItems().getFirst().getId());
        approve(mergedFixture,finance.submit("PURCHASE",merged.getId()));
        List<UUID> fifo = db.queryForList("SELECT request_item_id FROM purchase_order_item_sources WHERE order_item_id=? ORDER BY line_no,id", UUID.class,mergedFixture.item());
        assertThat(fifo).hasSize(2);
        // Physical-source allocation already froze the 20:2 charged/gift ratio before closure.
        assertThat(number("SELECT alloc_qty FROM purchase_order_item_sources WHERE order_item_id=? AND request_item_id=?",mergedFixture.item(),fifo.getFirst())).isEqualByComparingTo("9.0909");
        assertThat(number("SELECT allocated_gift_qty FROM purchase_order_item_sources WHERE order_item_id=? AND request_item_id=?",mergedFixture.item(),fifo.getFirst())).isEqualByComparingTo("0.9091");
        String frozenSources=tableFacts("purchase_order_item_sources","order_item_id",mergedFixture.item());
        receipt(mergedFixture,"12","1");
        var preview = closure.preview("PURCHASE",merged.getId());
        var closing = closure.submit("PURCHASE",merged.getId(),new ClosureRequest("CLOSE_AND_REORDER","仅重购各来源未交部分",preview.fingerprint()));
        approve(mergedFixture,closing);
        UUID replacement = db.queryForObject("SELECT replacement_order_id FROM procurement_order_approval_cases WHERE id=?",UUID.class,closing.caseId());
        assertThat(number("SELECT ordered_qty FROM purchase_request_items WHERE id=?",fifo.getFirst())).isEqualByComparingTo("9.0909");
        assertThat(number("SELECT ordered_qty FROM purchase_request_items WHERE id=?",fifo.getLast())).isEqualByComparingTo("2.9091");
        assertThat(number("SELECT gift_ordered_qty FROM purchase_request_items WHERE id=?",fifo.getFirst())).isEqualByComparingTo("0.9091");
        assertThat(number("SELECT gift_ordered_qty FROM purchase_request_items WHERE id=?",fifo.getLast())).isEqualByComparingTo("0.0909");
        assertThat(number("SELECT COALESCE(SUM(source.alloc_qty),0) FROM purchase_order_item_sources source JOIN purchase_order_items item ON item.id=source.order_item_id WHERE item.order_id=? AND source.request_item_id=?",replacement,fifo.getLast())).isEqualByComparingTo("8");
        assertThat(number("SELECT COALESCE(SUM(source.allocated_gift_qty),0) FROM purchase_order_item_sources source JOIN purchase_order_items item ON item.id=source.order_item_id WHERE item.order_id=? AND source.request_item_id=?",replacement,f.source())).isEqualByComparingTo("1");
        assertThat(number("SELECT SUM(alloc_qty) FROM purchase_order_item_sources WHERE order_item_id=?",mergedFixture.item())).isEqualByComparingTo("20");
        assertThat(number("SELECT SUM(allocated_gift_qty) FROM purchase_order_item_sources WHERE order_item_id=?",mergedFixture.item())).isEqualByComparingTo("2");
        assertThat(tableFacts("purchase_order_item_sources","order_item_id",mergedFixture.item())).isEqualTo(frozenSources);
    }

    @Test void subcontractTerminationRetainsActualAtSupplierMaterialAndDoesNotPostFictitiousLoss() {
        var w = harness.seedWorld("closure-subcontract-"+UUID.randomUUID());
        UUID material = harness.ensureSubcontractDirectMaterial(w, w.goodsE());
        harness.receiveSubcontractMaterial(w, material, "10");
        var submitted = harness.submitLeafSubcontractForFinance(w, BigDecimal.TEN);
        harness.loginAs(submitted.reviewerUserId());
        harness.approvePendingFinance("SUBCONTRACT", submitted.orderId());
        harness.loginAs(w.superAdminUserId());
        UUID item = db.queryForObject("SELECT id FROM subcontract_order_items WHERE order_id=?", UUID.class, submitted.orderId());
        harness.drawAndIssueSubcontract(item, BigDecimal.TEN, "closure-material-"+item);
        BigDecimal custody = number("SELECT SUM(at_supplier_qty) FROM subcontract_material_issue_items WHERE order_item_id=? AND is_deleted=FALSE", item);
        assertThat(custody).isEqualByComparingTo("10");
        long wasteBefore = wasteCount(item);
        var preview = closure.preview("SUBCONTRACT", submitted.orderId());
        var pending = closure.submit("SUBCONTRACT", submitted.orderId(), new ClosureRequest("CLOSE", "加工商停工，材料另行追偿", preview.fingerprint()));
        harness.loginAs(submitted.reviewerUserId());
        finance.approveBatch(List.of(decision(pending)), null);
        harness.loginAs(w.superAdminUserId());
        assertThat(db.queryForObject("SELECT is_closed FROM subcontract_orders WHERE id=?", Boolean.class, submitted.orderId())).isTrue();
        assertThat(subcontractOrders.detail(submitted.orderId()).isCanReverse()).isFalse();
        assertThat(number("SELECT SUM(at_supplier_qty) FROM subcontract_material_issue_items WHERE order_item_id=? AND is_deleted=FALSE", item))
                .isEqualByComparingTo(custody);
        assertThat(wasteCount(item)).isEqualTo(wasteBefore);
        assertThat(db.queryForObject("SELECT status FROM inbound_expectations WHERE order_type='SUBCONTRACT' AND order_id=? ORDER BY created_at DESC LIMIT 1", String.class, submitted.orderId()))
                .isEqualTo("CLOSED");
        harness.loginAs(w.superAdminUserId());
        assertThatThrownBy(() -> harness.submitSubcontractDraw(item, BigDecimal.ONE, "closed-redraw-"+item)).isInstanceOf(ApiException.class);
        UUID issue = db.queryForObject("SELECT id FROM subcontract_material_issue_items WHERE order_item_id=? AND is_deleted=FALSE", UUID.class, item);
        var returned = new com.uten.imp.features.subcontract.material_return.dto.MaterialReturnSaveRequest();
        returned.setBillDate(BusinessTime.today()); returned.setSupplierId(w.supplierId()); returned.setWarehouseId(w.warehouseId());
        var returnedLine = new com.uten.imp.features.subcontract.material_return.dto.MaterialReturnItemLine();
        returnedLine.setGoodsId(material); returnedLine.setUnitId(w.unitId()); returnedLine.setUnitRate(BigDecimal.ONE);
        returnedLine.setQty(BigDecimal.ONE); returnedLine.setMaterialIssueItemId(issue);
        returnedLine.setOrderItemId(item); returnedLine.setParentGoodsId(w.goodsE()); returned.setItems(List.of(returnedLine));
        materialReturns.approve(materialReturns.create(returned).getId());
        assertThat(number("SELECT returned_qty FROM subcontract_material_issue_items WHERE id=?", issue)).isEqualByComparingTo("1");
        assertThat(db.queryForObject("SELECT is_closed FROM subcontract_orders WHERE id=?", Boolean.class, submitted.orderId())).isTrue();
    }

    @Test void subcontractReorderReleasesHeldAcceptedReturnAndKeepsOldMaterialAtTheOriginalSupplier() {
        var w = harness.seedWorld("closure-subcontract-reorder-"+UUID.randomUUID());
        UUID replacementSupplier = harness.seedWorld("closure-replacement-vendor-"+UUID.randomUUID()).supplierId();
        harness.loginAs(w.superAdminUserId());
        UUID material = harness.ensureSubcontractDirectMaterial(w,w.goodsE());
        harness.receiveSubcontractMaterial(w,material,"10");
        var application = new com.uten.imp.features.subcontract.application.dto.ApplicationSaveRequest();
        application.setBillDate(BusinessTime.today()); application.setSupplierId(w.supplierId()); application.setWarehouseId(w.warehouseId());
        var requested = new com.uten.imp.features.subcontract.application.dto.ApplicationItemLine();
        requested.setGoodsId(w.goodsE()); requested.setUnitId(w.unitId()); requested.setUnitRate(BigDecimal.ONE); requested.setQty(BigDecimal.TEN);
        application.setItems(List.of(requested)); var applied = subcontractApplications.create(application);
        // Issued upstream input, matching the existing source-FIFO fixture; all order writes use services.
        db.update("UPDATE subcontract_applications SET status=1 WHERE id=?",applied.getId());
        UUID source = applied.getItems().getFirst().getId();
        var request = new com.uten.imp.features.subcontract.order.dto.OrderSaveRequest();
        request.setBillDate(BusinessTime.today()); request.setDeliverDate(BusinessTime.today().plusDays(3));
        request.setSupplierId(w.supplierId()); request.setWarehouseId(w.warehouseId()); request.setCurrencyId(w.currencyId());
        request.setExchangeRate(BigDecimal.ONE); request.setTaxRate(BigDecimal.ZERO);
        request.setSettlementMethodId(db.queryForObject("SELECT id FROM settlement_methods WHERE status='使用' AND NOT is_deleted ORDER BY code LIMIT 1",UUID.class));
        var ordered = new com.uten.imp.features.subcontract.order.dto.OrderItemLine();
        ordered.setGoodsId(w.goodsE()); ordered.setUnitId(w.unitId()); ordered.setUnitRate(BigDecimal.ONE);
        ordered.setQty(BigDecimal.TEN); ordered.setPrice(BigDecimal.TEN); ordered.setAllowedLossPct(BigDecimal.ZERO); ordered.setApplicationItemId(source);
        request.setItems(List.of(ordered)); var original = subcontractOrders.create(request);
        UUID item = original.getItems().getFirst().getId();
        UUID reviewer = harness.createUserWithPerms(w,"closure-sc-review-"+UUID.randomUUID(),"finance_order_approval:view","finance_order_approval:approve");
        harness.loginAs(w.superAdminUserId()); finance.submit("SUBCONTRACT",original.getId());
        harness.loginAs(reviewer); harness.approvePendingFinance("SUBCONTRACT",original.getId());
        harness.loginAs(w.superAdminUserId()); harness.drawAndIssueSubcontract(item,BigDecimal.TEN,"closure-sc-original-"+item);
        var arrival = arrivals.register(new com.uten.imp.features.warehouse.inbound.ProcurementArrivalContracts.WarehouseArrivalRegisterRequest(
                "closure-sc-held-"+item,"SUBCONTRACT",BusinessTime.today(),w.supplierId(),w.warehouseId(),null,w.employeeId(),null,
                List.of(new com.uten.imp.features.warehouse.inbound.ProcurementArrivalContracts.WarehouseArrivalRegisterRequest.ArrivalLine(
                        w.goodsE(),new BigDecimal("4"),item,null,w.unitId(),BigDecimal.ONE,null,null,null,"CLOSE-SHELF")),true,true));
        UUID inspection = db.queryForObject("SELECT id FROM procurement_inspection_items WHERE receipt_type='SUBCONTRACT' AND receipt_id=?",UUID.class,arrival.receiptId());
        inspections.dispose("SUBCONTRACT",arrival.receiptId(),inspection,new com.uten.imp.features.warehouse.inbound.dto.InspectionDispositionRequest("PASS",null,"回厂件已合格，等待结束审批","closure-sc-pass-"+inspection));
        assertThat(number("SELECT COALESCE(SUM(qty),0) FROM stock_balances WHERE goods_id=? AND warehouse_id=?",w.goodsE(),w.warehouseId())).isZero();
        assertThat(db.queryForObject("SELECT COUNT(*) FROM subcontract_short_delivery_cases WHERE order_item_id=? AND status='PENDING_OWNER'",Long.class,item)).isEqualTo(1L);
        long wasteBefore = wasteCount(item);
        var preview = closure.preview("SUBCONTRACT",original.getId());
        assertThat(preview.items()).singleElement().satisfies(row -> assertThat(row.remainingQty()).isEqualByComparingTo("6"));
        var closing = closure.submit("SUBCONTRACT",original.getId(),new ClosureRequest("CLOSE_AND_REORDER","原加工商停工，保留在外材料责任，余量换厂",preview.fingerprint()));
        harness.loginAs(reviewer); finance.approveBatch(List.of(decision(closing)),null);
        harness.loginAs(w.superAdminUserId());
        assertThat(number("SELECT COALESCE(SUM(qty),0) FROM stock_balances WHERE goods_id=? AND warehouse_id=?",w.goodsE(),w.warehouseId())).isEqualByComparingTo("4");
        assertThat(db.queryForObject("SELECT COUNT(*) FROM subcontract_short_delivery_cases WHERE order_item_id=? AND status IN('PENDING_OWNER','WAITING_MORE')",Long.class,item)).isZero();
        assertThat(wasteCount(item)).isEqualTo(wasteBefore);
        assertThat(number("SELECT SUM(at_supplier_qty) FROM subcontract_material_issue_items WHERE order_item_id=? AND NOT is_deleted",item)).isEqualByComparingTo("10");
        assertThat(number("SELECT SUM(consumed_qty) FROM subcontract_material_issue_items WHERE order_item_id=? AND NOT is_deleted",item)).isEqualByComparingTo("4");
        assertThat(number("SELECT ordered_qty FROM subcontract_application_items WHERE id=?",source)).isEqualByComparingTo("4");
        UUID replacement = db.queryForObject("SELECT replacement_order_id FROM procurement_order_approval_cases WHERE id=?",UUID.class,closing.caseId());
        var detail = subcontractOrders.detail(replacement);
        assertThat(detail.getSupplierId()).isNull(); assertThat(detail.getStatus()).isEqualTo((short)0);
        assertThat(detail.getWarehouseId()).isEqualTo(w.warehouseId());
        assertThat(detail.getItems()).singleElement().satisfies(row -> assertThat(row.getQty()).isEqualByComparingTo("6"));
        assertThat(number("SELECT fn_subcontract_application_open_qty(?)",source)).isZero();
        harness.receiveSubcontractMaterial(w,material,"6");
        var replacementRequest = new com.uten.imp.features.subcontract.order.dto.OrderSaveRequest();
        replacementRequest.setBillDate(detail.getBillDate()); replacementRequest.setSupplierId(replacementSupplier); replacementRequest.setWarehouseId(w.warehouseId());
        replacementRequest.setCurrencyId(detail.getCurrencyId()); replacementRequest.setExchangeRate(detail.getExchangeRate()); replacementRequest.setTaxRate(detail.getTaxRate());
        replacementRequest.setSettlementMethodId(detail.getSettlementMethodId()); replacementRequest.setDeliverDate(detail.getDeliverDate());
        var replacementLine = new com.uten.imp.features.subcontract.order.dto.OrderItemLine();
        replacementLine.setGoodsId(w.goodsE()); replacementLine.setUnitId(w.unitId()); replacementLine.setUnitRate(BigDecimal.ONE);
        replacementLine.setQty(new BigDecimal("6")); replacementLine.setPrice(BigDecimal.TEN); replacementLine.setAllowedLossPct(BigDecimal.ZERO); replacementLine.setApplicationItemId(source);
        replacementRequest.setItems(List.of(replacementLine)); subcontractOrders.update(replacement,replacementRequest);
        finance.submit("SUBCONTRACT",replacement); harness.loginAs(reviewer); harness.approvePendingFinance("SUBCONTRACT",replacement);
        harness.loginAs(w.superAdminUserId());
        assertThat(subcontractOrders.detail(replacement).getSupplierId()).isEqualTo(replacementSupplier);
        assertThat(number("SELECT ordered_qty FROM subcontract_application_items WHERE id=?",source)).isEqualByComparingTo("10");
        assertThat(number("SELECT SUM(line.planned_qty) FROM subcontract_material_plan_items line JOIN subcontract_material_plans plan ON plan.id=line.plan_id WHERE plan.order_id=? AND NOT line.is_deleted AND NOT plan.is_deleted",replacement)).isEqualByComparingTo("6");
        assertThat(number("SELECT SUM(at_supplier_qty) FROM subcontract_material_issue_items WHERE order_item_id=? AND NOT is_deleted",item)).isEqualByComparingTo("10");
        assertThat(number("SELECT SUM(consumed_qty) FROM subcontract_material_issue_items WHERE order_item_id=? AND NOT is_deleted",item)).isEqualByComparingTo("4");
        assertThat(wasteCount(item)).isEqualTo(wasteBefore);
    }

    @Test void importedOrderWithUnknownUnitCannotStartEitherClosureLifecycleOrChangeRetainedFacts() {
        var w = harness.seedWorld("closure-legacy-"+UUID.randomUUID()); harness.loginAs(w.superAdminUserId());
        harness.loginAs(w.superAdminUserId()); UUID order=UUID.randomUUID(),item=UUID.randomUUID();
        int legacy=940000000+Math.floorMod(order.hashCode(),1000000);
        // Retained historical input with unknown conversion and zero counters; no trigger or source proof is bypassed.
        new TransactionTemplate(transactions).executeWithoutResult(ignored -> {
            tx.bind();
            String bill=numbers.nextNumber(com.uten.imp.common.docnumber.DocNumberPrefix.PURCHASE_ORDER);
            db.update("INSERT INTO purchase_orders(id,legacy_id,bill_no,bill_date,supplier_id,warehouse_id,maker_id,status,is_closed,exchange_rate) VALUES(?,?,?,CURRENT_DATE,?,?,?,1,FALSE,NULL)",
                    order,legacy,bill,w.supplierId(),w.warehouseId(),w.employeeId());
            db.update("INSERT INTO purchase_order_items(id,legacy_id,order_id,bill_no,bill_date,line_no,goods_id,unit_id,unit_rate,qty,received_qty,returned_qty,goods_code_snapshot,goods_name_snapshot,goods_snapshot_source,goods_snapshot_locked_at) SELECT ?,?,?,?,CURRENT_DATE,1,id,NULL,NULL,10,0,0,code,name,'LEGACY_IMPORT',now() FROM goods WHERE id=?",
                    item,legacy,order,bill,w.goodsD());
        });
        String beforeOrder=db.queryForObject("SELECT to_jsonb(o)::text FROM purchase_orders o WHERE id=?",String.class,order);
        String beforeItem=db.queryForObject("SELECT to_jsonb(i)::text FROM purchase_order_items i WHERE id=?",String.class,item);
        long approvalCases=db.queryForObject("SELECT COUNT(*) FROM procurement_order_approval_cases WHERE order_id=?",Long.class,order);
        assertThatThrownBy(() -> closure.preview("PURCHASE",order))
                .isInstanceOf(ApiException.class).hasMessageContaining("历史");
        for(String mode:List.of("CLOSE","CLOSE_AND_REORDER")) {
            assertThatThrownBy(() -> closure.submit("PURCHASE",order,new ClosureRequest(mode,"保留旧单原始事实","unused-readonly-fingerprint")))
                    .isInstanceOf(ApiException.class).hasMessageContaining("历史");
        }
        assertThat(db.queryForObject("SELECT to_jsonb(o)::text FROM purchase_orders o WHERE id=?",String.class,order)).isEqualTo(beforeOrder);
        assertThat(db.queryForObject("SELECT to_jsonb(i)::text FROM purchase_order_items i WHERE id=?",String.class,item)).isEqualTo(beforeItem);
        assertThat(db.queryForObject("SELECT COUNT(*) FROM procurement_order_approval_cases WHERE order_id=?",Long.class,order)).isEqualTo(approvalCases);
        assertThat(db.queryForObject("SELECT is_closed FROM purchase_orders WHERE id=?",Boolean.class,order)).isFalse();
        assertThat(db.queryForObject("SELECT unit_id FROM purchase_order_items WHERE id=?",UUID.class,item)).isNull();
        assertThat(number("SELECT unit_rate FROM purchase_order_items WHERE id=?",item)).isNull();
        assertThat(number("SELECT qty FROM purchase_order_items WHERE id=?",item)).isEqualByComparingTo("10");
    }

    private Fixture fixture(String label, String gift) {
        var w = harness.seedWorld(label+"-"+UUID.randomUUID());
        harness.loginAs(w.superAdminUserId());
        UUID reviewer = harness.createUserWithPerms(w, "close-review-"+UUID.randomUUID(),
                "finance_order_approval:view", "finance_order_approval:approve", "finance_order_approval:reject");
        harness.loginAs(w.superAdminUserId());
        var request = new com.uten.imp.features.purchase.request.dto.RequestSaveRequest();
        request.setBillDate(BusinessTime.today()); request.setWarehouseId(w.warehouseId());
        var source = new com.uten.imp.features.purchase.request.dto.RequestItemLine();
        source.setGoodsId(w.goodsD()); source.setUnitId(w.unitId()); source.setUnitRate(BigDecimal.ONE);
        source.setQty(new BigDecimal("10")); source.setGiftQty(new BigDecimal(gift)); request.setItems(List.of(source));
        var requested = requests.create(request); requests.approve(requested.getId());
        UUID sourceId = requested.getItems().getFirst().getId();
        var order = new com.uten.imp.features.purchase.order.dto.OrderSaveRequest();
        order.setBillDate(BusinessTime.today()); order.setSupplierId(w.supplierId()); order.setWarehouseId(w.warehouseId());
        order.setCurrencyId(db.queryForObject("SELECT id FROM currencies WHERE is_base_currency AND is_deleted=FALSE", UUID.class));
        order.setExchangeRate(BigDecimal.ONE); order.setTaxRate(BigDecimal.ZERO);
        order.setSettlementMethodId(db.queryForObject("SELECT id FROM settlement_methods WHERE status='使用' AND is_deleted=FALSE ORDER BY code LIMIT 1", UUID.class));
        var line = new com.uten.imp.features.purchase.order.dto.OrderItemLine();
        line.setGoodsId(w.goodsD()); line.setUnitId(w.unitId()); line.setUnitRate(BigDecimal.ONE);
        line.setQty(new BigDecimal("10")); line.setGiftQty(new BigDecimal(gift)); line.setPrice(BigDecimal.TEN); line.setRequestItemId(sourceId);
        order.setItems(List.of(line)); var created = orders.create(order);
        var initial = finance.submit("PURCHASE", created.getId());
        Fixture result = new Fixture(w, reviewer, requested.getId(), sourceId, created.getId(), created.getItems().getFirst().getId());
        approve(result, initial);
        return result;
    }

    private UUID receipt(Fixture f, String charged, String gift) {
        return receipt(f,charged,gift,true);
    }
    private UUID receipt(Fixture f, String charged, String gift,boolean pass) {
        harness.loginAs(f.world().superAdminUserId());
        var request = new com.uten.imp.features.purchase.receipt.dto.ReceiptSaveRequest();
        request.setBillDate(BusinessTime.today()); request.setSupplierId(f.world().supplierId()); request.setWarehouseId(f.world().warehouseId());
        var line = new com.uten.imp.features.purchase.receipt.dto.ReceiptItemLine();
        line.setGoodsId(f.world().goodsD()); line.setUnitId(f.world().unitId()); line.setUnitRate(BigDecimal.ONE);
        line.setQty(new BigDecimal(charged)); line.setGiftQty(new BigDecimal(gift)); line.setOrderItemId(f.item()); request.setItems(List.of(line));
        UUID id = receipts.create(request).getId(); receipts.approve(id);
        if(pass)passExistingIqc(f,id);
        return id;
    }

    private void approve(Fixture f, FinanceApproval pending) {
        harness.loginAs(f.reviewer()); finance.approveBatch(List.of(decision(pending)), null);
        harness.loginAs(f.world().superAdminUserId());
    }
    private void chooseReplacementSupplier(UUID replacement, UUID supplier) {
        var detail = orders.detail(replacement);
        var request = new com.uten.imp.features.purchase.order.dto.OrderSaveRequest();
        request.setBillDate(detail.getBillDate()); request.setSupplierId(supplier); request.setWarehouseId(detail.getWarehouseId());
        request.setCurrencyId(detail.getCurrencyId()); request.setExchangeRate(detail.getExchangeRate()); request.setTaxRate(detail.getTaxRate());
        request.setSettlementMethodId(detail.getSettlementMethodId()); request.setDeliverDate(detail.getDeliverDate()); request.setRemark(detail.getRemark());
        request.setItems(detail.getItems().stream().map(item -> {
            var line = new com.uten.imp.features.purchase.order.dto.OrderItemLine();
            line.setGoodsId(item.getGoodsId()); line.setColorId(item.getColorId()); line.setUnitId(item.getUnitId()); line.setUnitRate(item.getUnitRate());
            line.setQty(item.getQty()); line.setGiftQty(item.getGiftQty()); line.setPrice(item.getPrice());
            line.setRequestItemId(item.getRequestItemId());
            if (item.getSourceRequests()!=null && !item.getSourceRequests().isEmpty())
                line.setRequestItemIds(item.getSourceRequests().stream().map(com.uten.imp.features.purchase.order.dto.OrderItemDto.SourceRequestDoc::requestItemId).toList());
            line.setDeliverDate(item.getDeliverDate()); line.setAllowedOverReceiptPct(item.getAllowedOverReceiptPct());
            return line;
        }).toList());
        orders.update(replacement, request);
    }
    private BatchDecisionItem decision(FinanceApproval pending) {
        var claim = claims.claim("PROCUREMENT_FINANCE_APPROVE", pending.caseId().toString());
        return new BatchDecisionItem(pending.caseId(), pending.version(), claim.claimId());
    }
    private void assertOpen(UUID order) { assertThat(db.queryForObject("SELECT is_closed FROM purchase_orders WHERE id=?", Boolean.class, order)).isFalse(); }
    private String status(UUID order) { return db.queryForObject("SELECT status FROM inbound_expectations WHERE order_type='PURCHASE' AND order_id=? ORDER BY created_at DESC LIMIT 1", String.class, order); }
    private BigDecimal number(String sql, Object... args) { return db.queryForObject(sql, BigDecimal.class, args); }
    private long wasteCount(UUID item) {
        return db.queryForObject("SELECT COUNT(*) FROM subcontract_waste_items waste JOIN subcontract_material_issue_items issue ON issue.id=waste.material_issue_item_id WHERE issue.order_item_id=?", Long.class, item);
    }
    private void passExistingIqc(Fixture f, UUID receipt) {
        harness.loginAs(f.world().superAdminUserId());
        List<UUID> items = db.queryForList("SELECT id FROM procurement_inspection_items WHERE receipt_id=? ORDER BY quantity_tranche", UUID.class, receipt);
        for (UUID item : items) {
            if(number("SELECT received_base_qty-passed_base_qty-failed_base_qty FROM procurement_inspection_items WHERE id=?",item).signum()<=0)continue;
            inspections.dispose("PURCHASE", receipt, item,
                    new com.uten.imp.features.warehouse.inbound.dto.InspectionDispositionRequest("PASS", null, "终止前已经到货，先完成品质判定", "closure-pass-"+item));
        }
    }
    private void finishExistingIqc(Fixture f, UUID receipt) {
        passExistingIqc(f,receipt);
        List<UUID> items = db.queryForList("SELECT id FROM procurement_inspection_items WHERE receipt_id=? ORDER BY quantity_tranche", UUID.class, receipt);
        UUID keeper = org.springframework.test.util.ReflectionTestUtils.invokeMethod(harness, "createIqcWarehouseConfirmer", f.world(), "closure-keeper-"+receipt);
        harness.loginAs(keeper);
        for (UUID item : items) {
            var command = org.springframework.test.util.ReflectionTestUtils.<com.uten.imp.features.warehouse.inbound.ProcurementIqcStockInContracts.ConfirmRequest>invokeMethod(
                    harness, "latestIqcStockInRequest", "PURCHASE", receipt, item,
                    number("SELECT received_base_qty FROM procurement_inspection_items WHERE id=?", item), "closure-stock-"+item, "CLOSE-BIN");
            stockIn.confirm("PURCHASE", receipt, command);
        }
        harness.loginAs(f.world().superAdminUserId());
        org.springframework.test.util.ReflectionTestUtils.invokeMethod(harness, "drainCosts", f.world());
    }
    private String physicalFacts(UUID receipt) {
        return db.queryForObject("SELECT md5(COALESCE(string_agg(to_jsonb(item)::text,',' ORDER BY id),'')) FROM procurement_inspection_items item WHERE receipt_id=?", String.class, receipt);
    }
    private com.uten.imp.features.purchase.ret.dto.ReturnSaveRequest returnOne(Fixture f,UUID receipt) {
        var request=new com.uten.imp.features.purchase.ret.dto.ReturnSaveRequest();
        request.setBillDate(BusinessTime.today());request.setSupplierId(f.world().supplierId());request.setWarehouseId(f.world().warehouseId());
        var line=new com.uten.imp.features.purchase.ret.dto.ReturnItemLine();
        line.setGoodsId(f.world().goodsD());line.setUnitId(f.world().unitId());line.setUnitRate(BigDecimal.ONE);
        line.setQty(BigDecimal.ONE);line.setGiftQty(BigDecimal.ZERO);line.setOrderItemId(f.item());
        line.setReceiptItemId(receipts.detail(receipt).getItems().getFirst().getId());request.setItems(List.of(line));
        return request;
    }
    private String businessFacts(Fixture f) {
        return tableFacts("purchase_orders","id",f.order())+tableFacts("purchase_order_items","order_id",f.order())
                +tableFacts("purchase_request_items","id",f.source())+tableFacts("purchase_receipts","supplier_id",f.world().supplierId())
                +tableFacts("purchase_receipt_items","goods_id",f.world().goodsD())+tableFacts("purchase_returns","supplier_id",f.world().supplierId())
                +tableFacts("purchase_return_items","goods_id",f.world().goodsD())+tableFacts("procurement_inspection_items","goods_id",f.world().goodsD())
                +tableFacts("stock_balances","goods_id",f.world().goodsD())+tableFacts("stock_movements","goods_id",f.world().goodsD())
                +tableFacts("ar_ap_ledger","supplier_id",f.world().supplierId());
    }
    private String tableFacts(String table,String column,UUID id) {
        return db.queryForObject("SELECT COALESCE(jsonb_agg(to_jsonb(fact) ORDER BY fact.id),'[]'::jsonb)::text FROM "+table+" fact WHERE fact."+column+"=?",String.class,id);
    }
}
