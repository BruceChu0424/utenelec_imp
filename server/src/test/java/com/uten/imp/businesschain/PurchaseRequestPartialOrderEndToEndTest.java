package com.uten.imp.businesschain;

import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.common.taskclaim.TaskClaimService;
import com.uten.imp.features.operations.workbench.FulfillmentWorkbenchPage;
import com.uten.imp.features.finance.procurement.ProcurementFinanceApprovalService;
import com.uten.imp.features.finance.procurement.ProcurementApprovalContracts.BatchDecisionItem;
import com.uten.imp.features.finance.procurement.ProcurementApprovalContracts.FinanceApproval;
import com.uten.imp.features.purchase.order.PurchaseOrderService;
import com.uten.imp.features.purchase.order.dto.OrderDetail;
import com.uten.imp.features.purchase.order.dto.OrderItemLine;
import com.uten.imp.features.purchase.order.dto.OrderSaveRequest;
import com.uten.imp.features.purchase.request.PurchaseRequestService;
import com.uten.imp.features.purchase.request.dto.RequestItemDto;
import com.uten.imp.features.purchase.request.dto.RequestItemLine;
import com.uten.imp.features.purchase.request.dto.RequestSaveRequest;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;

import java.math.BigDecimal;
import java.util.List;
import java.util.Objects;
import java.util.UUID;
import java.util.stream.Collectors;

import static org.assertj.core.api.Assertions.*;

/** Actual approved request -> partial orders -> finance decisions, with no synthetic ordered quantities. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
@SpringBootTest(webEnvironment=SpringBootTest.WebEnvironment.MOCK,properties={
        "spring.profiles.active=dev","uten.audit.retention.enabled=false","uten.reporting.materialized-view-refresh.enabled=false",
        "uten.features.goods-owner-scope-enabled=false","uten.storage.uploads-enabled=true",
        "uten.storage.malware-scan.provider=test-only","uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only",
        "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789","uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only",
        "uten.bootstrap.admin-login=full-chain-bootstrap-admin-test","uten.bootstrap.admin-password=HarnessAdminPass-1!"})
class PurchaseRequestPartialOrderEndToEndTest {
    @DynamicPropertySource static void database(DynamicPropertyRegistry registry) { FullChainEndToEndTest.registerDataSource(registry); }
    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    @Autowired PurchaseRequestService requests;
    @Autowired PurchaseOrderService orders;
    @Autowired ProcurementFinanceApprovalService finance;
    @Autowired TaskClaimService claims;
    @Autowired com.uten.imp.features.operations.workbench.FulfillmentWorkbenchQueryService workbench;
    @Autowired com.uten.imp.features.subcontract.application.SubcontractApplicationService subcontractApplications;
    @Autowired com.uten.imp.features.subcontract.order.SubcontractOrderService subcontractOrders;
    @Autowired com.uten.imp.features.documents.DocumentStatusCountQueryService documentCounts;
    @Autowired org.springframework.transaction.PlatformTransactionManager transactions;
    private FullChainEndToEndTest harness;
    @BeforeEach void prepare() { harness=new FullChainEndToEndTest();beans.autowireBean(harness); }
    @AfterEach void clearSecurity() { SecurityContextHolder.clearContext(); }

    @Test
    void applicantAndPartialCommitmentsStayConsistentAcrossDetailAndDecomposition() {
        Fixture f=fixture("partial-detail");
        var detail=requests.detail(f.request());
        assertThat(detail.getApplicantId()).isEqualTo(f.applicant());
        assertThat(detail.getApplicantName()).isEqualTo("分批申请人-partial-detail");
        assertThat(detail.getMakerId()).isEqualTo(f.world().employeeId()).isNotEqualTo(f.applicant());
        assertBalances(f,f.first(),"2","3","5");
        assertBalances(f,f.second(),"0","0","4");
        assertThat(requests.decompositionPreview(List.of(f.first(),f.first()))).hasSize(1);

        // Selecting just one line and a partial quantity does not copy the whole request.
        OrderDetail partial=createOrder(f,List.of(orderLine(f,f.first(),"2")));
        assertThat(partial.getItems()).hasSize(1);
        assertThat(partial.getItems().getFirst().getQty()).isEqualByComparingTo("2");
        assertThat(partial.getItems().getFirst().getRequestItemId()).isEqualTo(f.first());
        assertBalances(f,f.first(),"2","3","5"); // unsubmitted draft is not a financial commitment
        submit(f,partial.getId());
        assertBalances(f,f.first(),"2","5","3");
        assertBalances(f,f.second(),"0","0","4");
        assertThat(db.queryForList("SELECT request_item_id FROM purchase_order_item_sources WHERE order_item_id=?",UUID.class,
                partial.getItems().getFirst().getId())).containsExactly(f.first());
        assertThatThrownBy(()->finance.submit("PURCHASE",partial.getId())).isInstanceOf(ApiException.class);
        assertThat(db.queryForObject("SELECT count(*) FROM procurement_order_approval_cases WHERE order_id=? AND status='PENDING'",Integer.class,partial.getId())).isEqualTo(1);
        assertBalances(f,f.first(),"2","5","3");

        // A later batch explicitly chooses both lines with independent quantities.
        OrderDetail selected=createOrder(f,List.of(orderLine(f,f.first(),"1"),orderLine(f,f.second(),"2")));
        assertThat(selected.getItems()).hasSize(2);
        submit(f,selected.getId());
        assertBalances(f,f.first(),"2","6","2");
        assertBalances(f,f.second(),"0","2","2");
        assertThat(db.queryForObject("SELECT qty FROM purchase_request_items WHERE id=?",BigDecimal.class,f.first())).isEqualByComparingTo("10");
    }

    @Test
    void rejectionResubmissionRetainTheOriginalCommitmentWhileReversalRestoresOnlyItsOwnQuantity() {
        Fixture f=fixture("partial-restore");
        reject(f,f.pendingOrder(),"本批先暂停采购");
        assertBalances(f,f.first(),"2","3","5");
        assertBalances(f,f.second(),"0","0","4");
        harness.loginAs(f.world().superAdminUserId());
        orders.reverse(f.approvedOrder());
        assertBalances(f,f.first(),"0","3","7");
        assertThatThrownBy(()->orders.reverse(f.approvedOrder())).isInstanceOf(ApiException.class);
        assertBalances(f,f.first(),"0","3","7");

        FinanceApproval secondAttempt=submit(f,f.pendingOrder());
        assertThat(secondAttempt.attempt()).isEqualTo(2);
        assertBalances(f,f.first(),"0","3","7");
        harness.loginAs(f.reviewer());
        BatchDecisionItem decision=decision(secondAttempt);
        finance.approveBatch(List.of(decision),"按本次申请分批采购");
        harness.loginAs(f.world().superAdminUserId());
        assertBalances(f,f.first(),"3","0","7");
        harness.loginAs(f.reviewer());
        assertThatThrownBy(()->finance.approveBatch(List.of(decision),"重复请求")).isInstanceOf(ApiException.class);
        harness.loginAs(f.world().superAdminUserId());
        assertBalances(f,f.first(),"3","0","7");
        orders.reverse(f.pendingOrder());
        assertBalances(f,f.first(),"0","0","10");
        assertThat(db.queryForObject("SELECT count(*) FROM procurement_order_approval_cases WHERE order_id=?",Integer.class,f.pendingOrder())).isEqualTo(2);
    }

    @Test
    void explicitOverbuyKeepsActualQuantityAndRemainingFloorWhileInvalidBatchRollsBack() {
        Fixture f=fixture("partial-overbuy");
        long before=orderCount(f);
        for(String invalid:List.of("0","-1")) {
            assertThatThrownBy(()->createOrder(f,List.of(orderLine(f,f.second(),"1"),orderLine(f,f.first(),invalid))))
                    .isInstanceOf(ApiException.class)
                    .satisfies(error->assertThat(((ApiException)error).getCode())
                            .isEqualTo(com.uten.imp.common.web.ErrorCode.VALIDATION_FAILED))
                    .hasMessage(invalid.equals("0")?"计价量和赠品量不能同时为零":"计价数量不合法");
            assertThat(orderCount(f)).isEqualTo(before);
            assertBalances(f,f.first(),"2","3","5");
            assertBalances(f,f.second(),"0","0","4");
        }
        // Existing explicit overbuy policy is intentional: do not truncate 6 to the remaining 5.
        OrderDetail overbuy=createOrder(f,List.of(orderLine(f,f.first(),"6")));
        submit(f,overbuy.getId());
        assertBalances(f,f.first(),"2","9","0");
        assertThat(overbuy.getItems().getFirst().getQty()).isEqualByComparingTo("6");
        approve(f,overbuy.getId());
        assertBalances(f,f.first(),"8","3","0");
        assertThat(db.queryForObject("SELECT alloc_qty FROM purchase_order_item_sources WHERE order_item_id=?",BigDecimal.class,
                overbuy.getItems().getFirst().getId())).isEqualByComparingTo("6");
        reject(f,f.pendingOrder(),"取消未批准批次");
        assertBalances(f,f.first(),"8","3","0");
        orders.cancel(f.pendingOrder());
        assertBalances(f,f.first(),"8","0","2");
        orders.reverse(overbuy.getId());
        assertBalances(f,f.first(),"2","0","8");
    }

    @Test
    void returnedMultiMaterialBatchKeepsOneCorrectionDocumentWithSeparateMaterialRowsAndEditingReleasesOnlyTheReducedShares() {
        Fixture f=fixture("returned-multi");
        OrderDetail returned=createOrder(f,List.of(orderLine(f,f.first(),"5"),orderLine(f,f.second(),"4")));
        submit(f,returned.getId());
        reject(f,returned.getId(),"请核对本批条款");
        assertBalances(f,f.first(),"2","8","0");
        assertBalances(f,f.second(),"0","4","0");
        assertRequestOpen(f,"0");
        assertReturnedOrderMaterialRows(returned);
        var allRunning=workbench.query("PURCHASE","IN_PROGRESS","","",null,null,1,100);
        assertThat(allRunning.items()).hasSize(Math.toIntExact(allRunning.total()));
        long runningDocuments=allRunning.items().stream().map(row->row.actionDocId()).distinct().count();
        assertThat(workbench.countInProgress("PURCHASE")).isEqualTo(runningDocuments);
        assertThat(allRunning.summary().statusCounts().get("IN_PROGRESS")).isEqualTo(runningDocuments);
        assertThat(workbench.countPending("PURCHASE")).isEqualTo(db.queryForObject("""
                SELECT COUNT(DISTINCT action_doc_id) FROM v_procurement_decomposition_tasks
                WHERE department='PURCHASE' AND open_qty>0 AND task_status IN ('WAITING_ORDER','FINANCE_REJECTED')
                """,Long.class));

        // Revising the original order must see its own old shares as released inside the transaction.
        orders.update(returned.getId(),orderRequest(f,List.of(orderLine(f,f.first(),"2"),orderLine(f,f.second(),"1"))));
        assertBalances(f,f.first(),"2","5","3");
        assertBalances(f,f.second(),"0","1","3");
        assertRequestOpen(f,"6");
        FinanceApproval next=submit(f,returned.getId());
        assertThat(next.attempt()).isEqualTo(2);
        assertBalances(f,f.first(),"2","5","3");
        assertThatThrownBy(()->finance.submit("PURCHASE",returned.getId())).isInstanceOf(ApiException.class);
        assertBalances(f,f.first(),"2","5","3");
        reject(f,returned.getId(),"再次核对");
        assertBalances(f,f.first(),"2","5","3");
        assertBalances(f,f.second(),"0","1","3"); // two rejected attempts never double count
        assertReturnedOrderMaterialRows(orders.detail(returned.getId()));
        orders.cancel(returned.getId());
        assertBalances(f,f.first(),"2","3","5");
        assertBalances(f,f.second(),"0","0","4");
        assertThat(workbench.query("PURCHASE","IN_PROGRESS",returned.getBillNo(),"",null,null,1,20).total()).isZero();
    }

    @Test
    void deletingAReturnedOrderAndCancelingAPendingOrderReleaseTheirSharesWithoutLosingTheRequest() {
        Fixture f=fixture("returned-delete");
        OrderDetail returned=createOrder(f,List.of(orderLine(f,f.second(),"4")));
        submit(f,returned.getId());reject(f,returned.getId(),"本单不再订购");
        assertBalances(f,f.second(),"0","4","0");
        orders.delete(returned.getId());
        assertBalances(f,f.second(),"0","0","4");
        assertThat(workbench.query("PURCHASE","IN_PROGRESS",returned.getBillNo(),"",null,null,1,20).total()).isZero();
        orders.cancel(f.pendingOrder());
        assertBalances(f,f.first(),"2","0","8");
        assertRequestOpen(f,"12");
        assertThat(db.queryForObject("SELECT status FROM procurement_order_approval_cases WHERE order_id=? ORDER BY attempt DESC LIMIT 1",String.class,f.pendingOrder())).isEqualTo("CANCELED");
    }

    @Test
    void returnedPaidAndGiftSharesRetainPhysicalDemandAndCancelSymmetrically() {
        Fixture f=fixture("returned-gift");
        var line=orderLine(f,f.first(),"4");line.setGiftQty(BigDecimal.ONE);
        OrderDetail returned=createOrder(f,List.of(line));
        submit(f,returned.getId());reject(f,returned.getId(),"核对赠品条款");
        var item=requests.detail(f.request()).getItems().stream().filter(row->row.getId().equals(f.first())).findFirst().orElseThrow();
        assertThat(item.getPendingQty()).isEqualByComparingTo("7");
        assertThat(item.getPendingGiftQty()).isEqualByComparingTo("1");
        assertThat(item.getPhysicalRemainingQty()).isZero();
        assertRequestOpen(f,"4");
        submit(f,returned.getId());
        reject(f,returned.getId(),"再次核对赠品");
        assertThat(requests.detail(f.request()).getItems().getFirst().getPendingGiftQty()).isEqualByComparingTo("1");
        orders.cancel(returned.getId());
        assertBalances(f,f.first(),"2","3","5");
        assertThat(requests.detail(f.request()).getItems().getFirst().getPendingGiftQty()).isZero();
    }

    @Test
    void subcontractReturnedSharesUseTheSameBalanceInPreviewWorkbenchAndKitAvailability() {
        var world=harness.seedWorld("returned-subcontract");harness.loginAs(world.superAdminUserId());
        UUID material=harness.ensureSubcontractDirectMaterial(world,world.goodsE());
        harness.receiveSubcontractMaterial(world,material,"20");
        var applicationRequest=new com.uten.imp.features.subcontract.application.dto.ApplicationSaveRequest();
        applicationRequest.setBillDate(BusinessTime.today());applicationRequest.setWarehouseId(world.warehouseId());
        applicationRequest.setSupplierId(world.supplierId());applicationRequest.setApplicantId(world.employeeId());
        var source=new com.uten.imp.features.subcontract.application.dto.ApplicationItemLine();
        source.setGoodsId(world.goodsE());source.setUnitId(world.unitId());source.setUnitRate(BigDecimal.ONE);source.setQty(BigDecimal.TEN);
        applicationRequest.setItems(List.of(source));
        var application=subcontractApplications.create(applicationRequest);
        // A standalone previously issued application is the fixture's upstream boundary.
        db.update("UPDATE subcontract_applications SET status=1 WHERE id=?",application.getId());
        UUID sourceId=application.getItems().getFirst().getId();
        UUID reviewer=harness.createUserWithPerms(world,"REV-returned-subcontract","finance_order_approval:view","finance_order_approval:approve","finance_order_approval:reject");
        harness.loginAs(world.superAdminUserId());
        var request=subcontractOrderRequest(world,sourceId,"6");
        var order=subcontractOrders.create(request);
        assertSubcontractOpen(sourceId,"10"); // ordinary unsubmitted draft keeps its prior contract
        var first=finance.submit("SUBCONTRACT",order.getId());
        assertSubcontractOpen(sourceId,"4");
        rejectSubcontract(world,reviewer,first);
        assertSubcontractOpen(sourceId,"4");
        assertThat(subcontractApplications.decompositionPreview(List.of(sourceId)).getFirst().pendingQty()).isEqualByComparingTo("6");
        assertThat(workbench.query("SUBCONTRACT","IN_PROGRESS",order.getBillNo(),"",null,null,1,20).items())
                .extracting(com.uten.imp.features.operations.workbench.FulfillmentTaskRow::taskStatus).containsExactly("FINANCE_REJECTED");
        subcontractOrders.update(order.getId(),subcontractOrderRequest(world,sourceId,"3"));
        assertSubcontractOpen(sourceId,"7");
        var next=finance.submit("SUBCONTRACT",order.getId());assertThat(next.attempt()).isEqualTo(2);
        assertSubcontractOpen(sourceId,"7");
        rejectSubcontract(world,reviewer,next);
        assertSubcontractOpen(sourceId,"7");
        assertThat(subcontractApplications.decompositionPreview(List.of(sourceId)).getFirst().pendingQty()).isEqualByComparingTo("3");
        subcontractOrders.delete(order.getId());
        assertSubcontractOpen(sourceId,"10");
        assertThat(workbench.query("SUBCONTRACT","IN_PROGRESS",order.getBillNo(),"",null,null,1,20).total()).isZero();
    }

    @Test
    void approvedQuantityReviewShowsTheLatestFinanceTaskWithoutChangingApprovedSupplyOrDuplicatingRows() {
        Fixture f=fixture("approved-review-display");
        UUID order=f.approvedOrder();
        UUID item=orders.detail(order).getItems().getFirst().getId();
        long expectations=db.queryForObject("SELECT COUNT(*) FROM inbound_expectations WHERE order_type='PURCHASE' AND order_id=?",Long.class,order);
        orders.changeQty(order,new com.uten.imp.features.finance.procurement.ProcurementApprovalContracts.OrderQtyChangeRequest(
                List.of(new com.uten.imp.features.finance.procurement.ProcurementApprovalContracts.OrderQtyChangeItem(item,BigDecimal.ONE))));
        assertBalances(f,f.first(),"1","3","6");
        assertApprovedReviewStage(order,"ORDER_PENDING_APPROVAL","FINANCE_REVIEW_PENDING");
        long pendingBefore=workbench.countPending("PURCHASE");
        reject(f,order,"改量需要再次核对");
        assertApprovedReviewStage(order,"FINANCE_REJECTED","FINANCE_REVIEW_REJECTED");
        assertBalances(f,f.first(),"1","3","6");
        assertThat(orders.detail(order).getStatus()).isEqualTo((short)1);
        assertThat(workbench.countPending("PURCHASE")).isEqualTo(pendingBefore+1);

        // Resubmission of an effective amendment uses its existing controlled quantity path.
        orders.changeQty(order,new com.uten.imp.features.finance.procurement.ProcurementApprovalContracts.OrderQtyChangeRequest(
                List.of(new com.uten.imp.features.finance.procurement.ProcurementApprovalContracts.OrderQtyChangeItem(item,new BigDecimal("2")))));
        assertApprovedReviewStage(order,"ORDER_PENDING_APPROVAL","FINANCE_REVIEW_PENDING");
        assertThat(workbench.countPending("PURCHASE")).isEqualTo(pendingBefore);
        approve(f,order);
        assertApprovedReviewStage(order,"FINANCE_APPROVED","FINANCE_APPROVED");
        assertBalances(f,f.first(),"2","3","5");
        assertThat(db.queryForObject("SELECT COUNT(*) FROM inbound_expectations WHERE order_type='PURCHASE' AND order_id=?",Long.class,order)).isEqualTo(expectations);
    }

    @Test
    void physicalClosureDoesNotHideOrAgeOutAnUnfinishedFinancialQuantityReview() {
        Fixture f=fixture("closed-review-display");UUID order=f.approvedOrder();
        UUID item=orders.detail(order).getItems().getFirst().getId();
        UUID receipt=org.springframework.test.util.ReflectionTestUtils.invokeMethod(harness,"receiveIntoQuarantine",
                f.world(),f.world().goodsD(),item,"1","NORMAL");
        org.springframework.test.util.ReflectionTestUtils.invokeMethod(harness,"passAndStockPurchase",f.world(),receipt,"1");
        assertThat(orders.detail(order).isClosed()).isFalse();
        orders.changeQty(order,new com.uten.imp.features.finance.procurement.ProcurementApprovalContracts.OrderQtyChangeRequest(
                List.of(new com.uten.imp.features.finance.procurement.ProcurementApprovalContracts.OrderQtyChangeItem(item,BigDecimal.ONE))));
        assertThat(orders.detail(order).isClosed()).isTrue();
        assertApprovedReviewStage(order,"ORDER_PENDING_APPROVAL","FINANCE_REVIEW_PENDING");
        assertBalances(f,f.first(),"1","3","6");
        // Age only header metadata in this isolated fixture; source, quantity and closure facts stay exact.
        new org.springframework.transaction.support.TransactionTemplate(transactions).execute(status->{
            db.execute("SET LOCAL session_replication_role=replica");
            db.update("UPDATE purchase_orders SET created_at=CURRENT_DATE-INTERVAL '90 days',updated_at=CURRENT_DATE-INTERVAL '90 days' WHERE id=?",order);
            return null;
        });
        assertApprovedReviewStage(order,"ORDER_PENDING_APPROVAL","FINANCE_REVIEW_PENDING");
        long pendingBefore=workbench.countPending("PURCHASE");
        long rejectedBefore=documentCounts.financeRejectedCounts().get("purchaseOrder");
        reject(f,order,"实物已结案仍须核对改量");
        assertApprovedReviewStage(order,"FINANCE_REJECTED","FINANCE_REVIEW_REJECTED");
        assertThat(workbench.countPending("PURCHASE")).isEqualTo(pendingBefore+1);
        assertThat(documentCounts.financeRejectedCounts().get("purchaseOrder")).isEqualTo(rejectedBefore+1);
        assertThat(orders.detail(order).isClosed()).isTrue();
        assertBalances(f,f.first(),"1","3","6");
        assertThat(orders.list(new com.uten.imp.features.purchase.order.dto.OrderQueryFilter(null,null,null,null,null,null,"REJECTED",orders.detail(order).getBillNo()),1,20,null,null).getTotal()).isEqualTo(1);

        // The quantity amendment is effective; finish its physical receipt while finance still reviews it.
        orders.changeQty(order,new com.uten.imp.features.finance.procurement.ProcurementApprovalContracts.OrderQtyChangeRequest(
                List.of(new com.uten.imp.features.finance.procurement.ProcurementApprovalContracts.OrderQtyChangeItem(item,new BigDecimal("2")))));
        assertApprovedReviewStage(order,"ORDER_PENDING_APPROVAL","FINANCE_REVIEW_PENDING");
        UUID finalReceipt=org.springframework.test.util.ReflectionTestUtils.invokeMethod(harness,"receiveIntoQuarantine",
                f.world(),f.world().goodsD(),item,"1","NORMAL");
        org.springframework.test.util.ReflectionTestUtils.invokeMethod(harness,"passAndStockPurchase",f.world(),finalReceipt,"1");
        assertThat(orders.detail(order).isClosed()).isTrue();
        assertApprovedReviewStage(order,"ORDER_PENDING_APPROVAL","FINANCE_REVIEW_PENDING");
        var documentActive = new com.uten.imp.features.purchase.order.dto.OrderQueryFilter(null,null,null,null,null,null,"IN_PROGRESS",orders.detail(order).getBillNo());
        assertThat(orders.list(documentActive,1,1,null,null).getTotal()).isEqualTo(1);
        assertThat(orders.facets(documentActive).get("billNo")).hasSize(1);
        approve(f,order);
        assertThat(orders.list(documentActive,1,1,null,null).getTotal()).isZero();
        assertThat(orders.facets(documentActive).get("billNo")).isEmpty();
        assertThat(orders.detail(order).isClosed()).isTrue();
        assertThat(workbench.query("PURCHASE","IN_PROGRESS",orders.detail(order).getBillNo(),"",null,null,1,20).total()).isZero();
        assertThat(workbench.query("PURCHASE","COMPLETED",orders.detail(order).getBillNo(),"",null,null,1,20).items())
                .extracting(com.uten.imp.features.operations.workbench.FulfillmentTaskRow::taskStatus).containsExactly("COMPLETED");
        assertThat(documentCounts.financeRejectedCounts().get("purchaseOrder")).isEqualTo(rejectedBefore);
        assertBalances(f,f.first(),"2","3","5");
    }

    @Test
    void documentLifecycleUsesServerPaginationAndFacetsAndKeepsClosedFinancialReviewsActive() {
        Fixture f = fixture("doc-lifecycle");
        var active = new com.uten.imp.features.purchase.order.dto.OrderQueryFilter(
                null, f.world().supplierId(), null, null, null, null, "IN_PROGRESS");
        var first = orders.list(active, 1, 1, "billNo", "asc");
        var second = orders.list(active, 2, 1, "billNo", "asc");
        assertThat(first.getTotal()).isEqualTo(2);
        assertThat(first.getTotalPages()).isEqualTo(2);
        assertThat(second.getTotal()).isEqualTo(2);
        assertThat(first.getItems().getFirst().getId()).isNotEqualTo(second.getItems().getFirst().getId());
        assertThat(orders.facets(active).get("billNo")).hasSize(2);

        UUID item = orders.detail(f.approvedOrder()).getItems().getFirst().getId();
        UUID receipt = org.springframework.test.util.ReflectionTestUtils.invokeMethod(harness, "receiveIntoQuarantine",
                f.world(), f.world().goodsD(), item, "2", "NORMAL");
        org.springframework.test.util.ReflectionTestUtils.invokeMethod(harness, "passAndStockPurchase", f.world(), receipt, "2");
        assertThat(orders.detail(f.approvedOrder()).isClosed()).isTrue();
        assertThat(orders.list(active, 1, 1, "billNo", "asc").getTotal()).isEqualTo(1);
        assertThat(orders.list(active, 1, 1, "billNo", "asc").getItems()).extracting(row -> row.getId()).containsExactly(f.pendingOrder());
        assertThat(orders.facets(active).get("billNo")).extracting(row -> row.get("value"))
                .containsExactly(orders.detail(f.pendingOrder()).getBillNo());
        var history = new com.uten.imp.features.purchase.order.dto.OrderQueryFilter(
                null, f.world().supplierId(), null, null, null, null, null);
        assertThat(orders.list(history, 1, 1, "billNo", "asc").getTotal()).isEqualTo(2);

        var openRequests = new com.uten.imp.features.purchase.request.dto.RequestQueryFilter(
                null, null, (short) 1, null, null, requests.detail(f.request()).getBillNo()).withClosed(false);
        assertThat(requests.list(openRequests, 1, 1, null, null).getTotal()).isEqualTo(1);
        approve(f, f.pendingOrder());
        var remaining = createOrder(f, List.of(orderLine(f, f.first(), "5"), orderLine(f, f.second(), "4")));
        submit(f, remaining.getId());
        approve(f, remaining.getId());
        assertThat(requests.detail(f.request()).isClosed()).isTrue();
        assertThat(requests.list(openRequests, 1, 1, null, null).getTotal()).isZero();
        assertThat(requests.facets(openRequests).get("billNo")).isEmpty();
        assertThat(requests.list(openRequests.withClosed(null), 1, 1, null, null).getTotal()).isEqualTo(1);
    }

    @Test
    void stoppedSalesOrdersAndTerminalProductionPlansLeaveWorkingListsButStayTraceable() {
        var world = harness.seedWorld("lifecycle-plans-sales");
        harness.loginAs(world.superAdminUserId());
        var sales = beans.getBean(com.uten.imp.features.sales.order.SalesOrderService.class);
        UUID ongoing = harness.createApprovedOrder(world, world.goodsA(), "10", "100");
        UUID stopped = harness.createApprovedOrder(world, world.goodsA(), "10", "100");
        sales.toggleStopped(stopped, true);
        var salesActive = new com.uten.imp.features.sales.order.dto.OrderQueryFilter(
                null, world.clientId(), null, null, null, null, null, null, "pending");
        assertThat(sales.list(salesActive, 1, 1, null, null).getTotal()).isEqualTo(1);
        assertThat(sales.list(salesActive, 1, 1, null, null).getItems()).extracting(row -> row.getId()).containsExactly(ongoing);
        assertThat(sales.facets(salesActive).get("billNo")).hasSize(1);
        var salesHistory = new com.uten.imp.features.sales.order.dto.OrderQueryFilter(
                null, world.clientId(), null, null, null, null, null, null, null);
        assertThat(sales.list(salesHistory, 1, 1, null, null).getTotal()).isEqualTo(2);

        var plans = beans.getBean(com.uten.imp.features.production.plan.ProductionPlanService.class);
        var numbers = beans.getBean(com.uten.imp.common.docnumber.DocNumberService.class);
        String workshop = "生命周期隔离车间-" + world.departmentId();
        UUID activePlan = null;
        UUID stoppedPlan = null;
        for (int kind = 0; kind < 5; kind++) {
            UUID id = UUID.randomUUID();
            if (kind == 0) activePlan = id;
            if (kind == 2) stoppedPlan = id;
            String bill = numbers.nextNumber(com.uten.imp.common.docnumber.DocNumberPrefix.PRODUCTION_PLAN);
            db.update("""
                    INSERT INTO production_plans(id,bill_no,bill_date,department_id,workshop_name,status,
                                                 is_closed,is_stopped,is_canceled,maker_id,created_by)
                    VALUES(?,?,?,?,?,?,?,?,?,?,?)
                    """, id, bill, BusinessTime.today(), world.departmentId(), workshop,
                    kind == 4 ? -1 : 1, kind == 1, kind == 2, kind == 3, world.employeeId(), world.superAdminUserId());
        }
        var activeRows = plans.progress(false, "billDate", 1, 1, null, workshop, null, null);
        assertThat(activeRows.getTotal()).isEqualTo(1);
        assertThat(activeRows.getItems().getFirst().planId()).isEqualTo(activePlan);
        var historyRows = plans.progress(true, "billDate", 1, 10, null, workshop, null, null);
        assertThat(historyRows.getTotal()).isEqualTo(4);
        assertThat(historyRows.getItems()).filteredOn(row -> row.stopped()).hasSize(1)
                .allSatisfy(row -> assertThat(row.closed()).isFalse());
        assertThat(historyRows.getItems()).filteredOn(row -> row.canceled()).hasSize(1);
        assertThat(historyRows.getItems()).filteredOn(row -> row.status() == -1).hasSize(1);
        assertThat(plans.progressSummary(true, null, workshop, null, null).get("count")).isEqualTo(4L);
        var activeDocuments = new com.uten.imp.features.production.plan.dto.PlanQueryFilter(
                null, world.departmentId(), (short) 1, null, null, null, "ACTIVE");
        assertThat(plans.list(activeDocuments,1,1,null,null).getTotal()).isEqualTo(1);
    }

    private void assertApprovedReviewStage(UUID order,String task,String display) {
        var page=workbench.query("PURCHASE","IN_PROGRESS",orders.detail(order).getBillNo(),"",null,null,1,20);
        assertThat(page.total()).isEqualTo(1);assertThat(page.items()).hasSize(1);
        assertThat(page.items().getFirst().taskStatus()).isEqualTo(task);
        assertThat(page.items().getFirst().displayStage()).isEqualTo(display);
        assertThat(page.items().getFirst().actionDocStatus()).isEqualTo("1");
    }

    private com.uten.imp.features.subcontract.order.dto.OrderSaveRequest subcontractOrderRequest(FullChainEndToEndTest.World world,UUID source,String quantity) {
        var request=new com.uten.imp.features.subcontract.order.dto.OrderSaveRequest();
        request.setBillDate(BusinessTime.today());request.setSupplierId(world.supplierId());request.setWarehouseId(world.warehouseId());
        request.setCurrencyId(world.currencyId());request.setExchangeRate(BigDecimal.ONE);request.setTaxRate(BigDecimal.ZERO);
        request.setSettlementMethodId(db.queryForObject("SELECT id FROM settlement_methods WHERE status='使用' AND NOT is_deleted ORDER BY code LIMIT 1",UUID.class));
        var line=new com.uten.imp.features.subcontract.order.dto.OrderItemLine();line.setGoodsId(world.goodsE());
        line.setApplicationItemId(source);line.setUnitId(world.unitId());line.setUnitRate(BigDecimal.ONE);
        line.setQty(new BigDecimal(quantity));line.setPrice(BigDecimal.TEN);request.setItems(List.of(line));return request;
    }
    private void rejectSubcontract(FullChainEndToEndTest.World world,UUID reviewer,FinanceApproval approval) {
        harness.loginAs(reviewer);finance.rejectBatch(List.of(decision(approval)),"核对原单后重提");harness.loginAs(world.superAdminUserId());
    }
    private void assertSubcontractOpen(UUID source,String expected) {
        assertThat(db.queryForObject("SELECT fn_subcontract_application_open_qty(?)",BigDecimal.class,source)).isEqualByComparingTo(expected);
        assertThat(db.queryForObject("SELECT open_qty FROM v_procurement_decomposition_tasks WHERE action_doc_type='SUBCONTRACT_APPLICATION' AND action_item_id=?",BigDecimal.class,source)).isEqualByComparingTo(expected);
        assertThat(subcontractApplications.decompositionPreview(List.of(source)).getFirst().remainingQty()).isEqualByComparingTo(expected);
    }

    private Fixture fixture(String tag) {
        var world=harness.seedWorld(tag);harness.loginAs(world.superAdminUserId());
        UUID applicant=UUID.randomUUID();
        db.update("""
                INSERT INTO employees(id,code,full_name,id_type,department_id,hire_date,status,employment_type)
                VALUES (?,?,?,'其他',?,CURRENT_DATE,'active','regular')
                """,applicant,"APP-"+tag,"分批申请人-"+tag,world.departmentId());
        UUID reviewer=harness.createUserWithPerms(world,"REV-"+tag,"finance_order_approval:view","finance_order_approval:approve","finance_order_approval:reject");
        var request=new RequestSaveRequest();request.setBillDate(BusinessTime.today());request.setWarehouseId(world.warehouseId());
        request.setDepartmentId(world.departmentId());request.setApplicantId(applicant);
        request.setItems(List.of(requestLine(world,world.goodsD(),"10"),requestLine(world,world.goodsE(),"4")));
        var created=requests.create(request);requests.approve(created.getId());
        UUID first=created.getItems().getFirst().getId(),second=created.getItems().get(1).getId();
        var initial=new Fixture(world,applicant,reviewer,created.getId(),first,second,null,null);
        UUID approved=createOrder(initial,List.of(orderLine(initial,first,"2"))).getId();
        submit(initial,approved);approve(initial,approved);
        UUID pending=createOrder(initial,List.of(orderLine(initial,first,"3"))).getId();submit(initial,pending);
        return new Fixture(world,applicant,reviewer,created.getId(),first,second,approved,pending);
    }
    private RequestItemLine requestLine(FullChainEndToEndTest.World world,UUID goods,String qty) {
        var line=new RequestItemLine();line.setGoodsId(goods);line.setUnitId(world.unitId());line.setUnitRate(BigDecimal.ONE);line.setQty(new BigDecimal(qty));return line;
    }
    private OrderItemLine orderLine(Fixture f,UUID source,String qty) {
        RequestItemDto item=requests.detail(f.request()).getItems().stream().filter(row->row.getId().equals(source)).findFirst().orElseThrow();
        var line=new OrderItemLine();line.setGoodsId(item.getGoodsId());line.setUnitId(item.getUnitId());line.setUnitRate(item.getUnitRate());
        line.setRequestItemId(source);line.setQty(new BigDecimal(qty));line.setPrice(new BigDecimal("50"));
        return line;
    }
    private OrderDetail createOrder(Fixture f,List<OrderItemLine> lines) {
        harness.loginAs(f.world().superAdminUserId());
        var result=orders.createBatch(orderRequest(f,lines));assertThat(result).hasSize(1);return result.getFirst();
    }
    private OrderSaveRequest orderRequest(Fixture f,List<OrderItemLine> lines) {
        var request=new OrderSaveRequest();request.setBillDate(BusinessTime.today());request.setSupplierId(f.world().supplierId());
        request.setWarehouseId(f.world().warehouseId());request.setCurrencyId(f.world().currencyId());request.setExchangeRate(BigDecimal.ONE);request.setTaxRate(BigDecimal.ZERO);
        request.setSettlementMethodId(db.queryForObject("SELECT id FROM settlement_methods WHERE status='使用' AND NOT is_deleted ORDER BY code LIMIT 1",UUID.class));
        request.setItems(lines);return request;
    }
    private FinanceApproval submit(Fixture f,UUID order) {harness.loginAs(f.world().superAdminUserId());return finance.submit("PURCHASE",order);}
    private void approve(Fixture f,UUID order) {harness.loginAs(f.reviewer());harness.approvePendingFinance("PURCHASE",order);harness.loginAs(f.world().superAdminUserId());}
    private BatchDecisionItem decision(FinanceApproval approval) {
        var claim=claims.claim("PROCUREMENT_FINANCE_APPROVE",approval.caseId().toString());
        return new BatchDecisionItem(approval.caseId(),approval.version(),claim.claimId());
    }
    private void reject(Fixture f,UUID order,String reason) {
        harness.loginAs(f.reviewer());
        var raw=db.queryForObject("SELECT id,version FROM procurement_order_approval_cases WHERE order_type='PURCHASE' AND order_id=? AND status='PENDING'",
                (rs,row)->new BatchDecisionItem(rs.getObject(1,UUID.class),rs.getLong(2)),order);
        var claim=claims.claim("PROCUREMENT_FINANCE_APPROVE",raw.caseId().toString());
        finance.rejectBatch(List.of(new BatchDecisionItem(raw.caseId(),raw.expectedVersion(),claim.claimId())),reason);
        harness.loginAs(f.world().superAdminUserId());
    }
    private void assertBalances(Fixture f,UUID source,String ordered,String pending,String remaining) {
        var row=requests.detail(f.request()).getItems().stream().filter(item->item.getId().equals(source)).findFirst().orElseThrow();
        assertThat(row.getOrderedQty()).isEqualByComparingTo(ordered);assertThat(row.getPendingQty()).isEqualByComparingTo(pending);assertThat(row.getRemainingQty()).isEqualByComparingTo(remaining);
        if(new BigDecimal(remaining).signum()>0) {
            var preview=requests.decompositionPreview(List.of(source)).getFirst();
            assertThat(preview.orderedQty()).isEqualByComparingTo(ordered);assertThat(preview.pendingQty()).isEqualByComparingTo(pending);assertThat(preview.remainingQty()).isEqualByComparingTo(remaining);
            assertThat(preview.requestedQty()).isEqualByComparingTo(row.getQty());
        } else assertThatThrownBy(()->requests.decompositionPreview(List.of(source))).isInstanceOf(ApiException.class).hasMessageContaining("无可分解数量");
    }
    private long orderCount(Fixture f) {return db.queryForObject("SELECT count(*) FROM purchase_orders WHERE supplier_id=?",Long.class,f.world().supplierId());}
    private void assertReturnedOrderMaterialRows(OrderDetail expected) {
        var expectedItems=expected.getItems().stream().collect(Collectors.toMap(item->item.getId(),item->item));
        FulfillmentWorkbenchPage page=workbench.query("PURCHASE","IN_PROGRESS",expected.getBillNo(),"",null,null,1,20);
        assertThat(page.total()).isEqualTo(expectedItems.size());
        assertThat(page.items()).hasSize(expectedItems.size());
        assertThat(page.items().stream().map(row->row.actionDocItemId()).toList())
                .containsExactlyInAnyOrderElementsOf(expectedItems.keySet());
        for(var row:page.items()) {
            var item=Objects.requireNonNull(expectedItems.get(row.actionDocItemId()));
            BigDecimal physical=item.getQty().add(Objects.requireNonNullElse(item.getGiftQty(),BigDecimal.ZERO));
            assertThat(row.actionDocType()).isEqualTo("PURCHASE_ORDER");
            assertThat(row.actionDocId()).isEqualTo(expected.getId());
            assertThat(row.actionDocNo()).isEqualTo(expected.getBillNo());
            assertThat(row.goodsId()).isEqualTo(item.getGoodsId());
            assertThat(row.taskStatus()).isEqualTo("FINANCE_REJECTED");
            assertThat(row.goodsCount()).isEqualTo(1);
            assertThat(row.actionItemIds()).containsExactly(item.getId().toString());
            assertThat(row.requiredQty()).isEqualByComparingTo(physical);
            assertThat(row.allocatedQty()).isEqualByComparingTo(physical);
            assertThat(row.fulfilledQty()).isEqualByComparingTo(BigDecimal.ZERO);
            assertThat(row.openQty()).isEqualByComparingTo(physical);
        }
        assertThat(page.summary().statusCounts().get("IN_PROGRESS")).isEqualTo(1L);
    }
    private void assertRequestOpen(Fixture f,String remaining) {
        assertThat(db.queryForObject("SELECT COALESCE(SUM(open_qty),0) FROM v_procurement_decomposition_tasks WHERE action_doc_type='PURCHASE_REQUEST' AND action_doc_id=?",BigDecimal.class,f.request())).isEqualByComparingTo(remaining);
        var request=requests.detail(f.request());
        var expectedItems=request.getItems().stream().filter(item->item.getPhysicalRemainingQty().signum()>0)
                .collect(Collectors.toMap(item->item.getId(),item->item));
        var page=workbench.query("PURCHASE","WAITING_ORDER",request.getBillNo(),"",null,null,1,20);
        assertThat(page.total()).isEqualTo(expectedItems.size());
        assertThat(page.items()).hasSize(expectedItems.size());
        assertThat(page.items().stream().map(row->row.actionDocItemId()).toList())
                .containsExactlyInAnyOrderElementsOf(expectedItems.keySet());
        for(var row:page.items()) {
            var item=Objects.requireNonNull(expectedItems.get(row.actionDocItemId()));
            assertThat(row.actionDocType()).isEqualTo("PURCHASE_REQUEST");
            assertThat(row.actionDocId()).isEqualTo(f.request());
            assertThat(row.goodsId()).isEqualTo(item.getGoodsId());
            assertThat(row.actionItemIds()).containsExactly(item.getId().toString());
            assertThat(row.openQty()).isEqualByComparingTo(item.getPhysicalRemainingQty());
        }
    }
    private record Fixture(FullChainEndToEndTest.World world,UUID applicant,UUID reviewer,UUID request,UUID first,UUID second,UUID approvedOrder,UUID pendingOrder) {}
}
