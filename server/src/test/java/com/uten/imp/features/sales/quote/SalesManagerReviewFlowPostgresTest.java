package com.uten.imp.features.sales.quote;

import com.uten.imp.testsupport.FixtureDatabaseProperties;

import com.uten.imp.application.port.SalesMasterLearningPort;
import com.uten.imp.application.port.SalesLearningReceiptPort;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.auth.PermissionResolver;
import com.uten.imp.features.common.taskclaim.TaskClaimService;
import com.uten.imp.features.documents.DocumentDraftCountController;
import com.uten.imp.features.sales.SalesAiIntakeRequest;
import com.uten.imp.features.sales.intake.SalesIntakeUsedEvent;
import com.uten.imp.features.sales.order.SalesOrderFinanceConfirmService;
import com.uten.imp.features.sales.order.SalesOrderService;
import com.uten.imp.features.sales.order.dto.OrderDetail;
import com.uten.imp.features.sales.order.dto.OrderItemDto;
import com.uten.imp.features.sales.order.dto.OrderItemLine;
import com.uten.imp.features.sales.order.dto.OrderSaveRequest;
import com.uten.imp.features.sales.quote.dto.QuoteActionRequest;
import com.uten.imp.features.sales.quote.dto.QuoteDetail;
import com.uten.imp.features.sales.quote.dto.QuoteFinanceDecisionRequest;
import com.uten.imp.features.sales.quote.dto.QuoteFinanceEditRequest;
import com.uten.imp.features.sales.quote.dto.QuoteFinanceReviewDto;
import com.uten.imp.features.sales.quote.dto.QuoteItemDto;
import com.uten.imp.features.sales.quote.dto.QuoteItemLine;
import com.uten.imp.features.sales.quote.dto.QuoteQueryFilter;
import com.uten.imp.features.sales.quote.dto.QuoteSaveRequest;
import com.uten.imp.security.AuthUser;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.mockito.ArgumentCaptor;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.context.bean.override.mockito.MockitoBean;
import org.springframework.test.context.event.ApplicationEvents;
import org.springframework.test.context.event.RecordApplicationEvents;
import org.testcontainers.postgresql.PostgreSQLContainer;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.atomic.AtomicInteger;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.atLeastOnce;
import static org.mockito.Mockito.clearInvocations;
import static org.mockito.Mockito.doAnswer;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;

/**
 * ADR-134 报价核价流程(真实 PostgreSQL, 切换销售/财务/无资格账号走完整服务栈):
 * 报价单价权威、提交/撤回/退回/确认/重新核价、财务读范围、认领与修订号、确认前阻断、转订货单带折扣并锁定、
 * 看不到价格的人保存、学习出口与识别采用事件、分段计数/草稿计数/徽章。
 */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
@SpringBootTest(
        webEnvironment = SpringBootTest.WebEnvironment.MOCK,
        properties = {
                "spring.profiles.active=dev",
                "uten.audit.retention.enabled=false",
                "uten.reporting.materialized-view-refresh.enabled=false",
                "uten.features.goods-owner-scope-enabled=false",
                "uten.jwt.secret=quote-finance-harness-jwt-secret-0123456789-tst",
                "uten.crypto.pgp-master-key=quote-finance-harness-pgp-key-test-only-0123",
                "uten.crypto.hmac-key=quote-finance-harness-hmac-key-test-only",
                "uten.bootstrap.admin-login=quote-finance-bootstrap-admin-test",
                "uten.bootstrap.admin-password=QuoteFinanceAdminPass-1!"
        })
@RecordApplicationEvents
class SalesManagerReviewFlowPostgresTest {

    private static final PostgreSQLContainer POSTGRES =
            new PostgreSQLContainer("postgres:16-alpine")
                    .withDatabaseName("uten_imp")
                    .withUsername("fixture_admin")
                    .withPassword("uten");

    @DynamicPropertySource
    static void registerDataSource(DynamicPropertyRegistry registry) {
        POSTGRES.start();
        FixtureDatabaseProperties.bindSameRole(registry, POSTGRES::getJdbcUrl,
                POSTGRES::getUsername, POSTGRES::getPassword);
    }

    @Autowired private com.uten.imp.features.sales.SalesManagerReviewService managers;
    @Autowired private com.uten.imp.features.sales.SalesManagerReviewController managerController;
    @Autowired private com.uten.imp.features.notice.NoticeService noticeService;
    private static final List<String> MANAGER_PERMS = List.of("sales_quote_manager:view","sales_quote_manager:confirm","sales_quote_manager:reject","sales_quote_manager:reverse",
            "sales_order_manager:view","sales_order_manager:confirm","sales_order_manager:reject","sales_order_manager:reverse","notice:read");
    private static final String MANAGER_QUOTE="SALES_QUOTE_MANAGER_REVIEW", MANAGER_ORDER="SALES_ORDER_MANAGER_REVIEW";

    private static final String CLAIM = SalesQuoteFinanceClaimTargetLocks.TARGET_TYPE;
    private static final AtomicInteger SEQ = new AtomicInteger();
    private static final List<String> SALES_PERMS = List.of(
            "sales_quote:view", "sales_quote:create", "sales_quote:edit", "sales_quote:delete",
            "sales_quote:convert", "sales_quote:reverse",
            "sales_order:view", "sales_order:create", "sales_order:edit", "sales_order:delete", "sales_order:approve",
            "sales_order:change_qty", "sales_order:cancel", "sales_order:stop", "sales_order:reverse", "notice:read");

    @Autowired private JdbcTemplate jdbc;
    @Autowired private PermissionResolver permissionResolver;
    @Autowired private SalesQuoteService quotes;
    @Autowired private SalesQuoteFinanceService finance;
    @Autowired private SalesOrderService orders;
    @Autowired private SalesOrderFinanceConfirmService orderFinance;
    @Autowired private TaskClaimService claims;
    @Autowired private DocumentDraftCountController documentCounts;
    @Autowired private ApplicationEvents events;
    @Autowired private com.uten.imp.common.columns.BusinessColumnService businessColumns;
    @Autowired private SalesLearningReceiptPort learningReceipts;

    /** 学习出口由主档包实现; 这里替换成可核对入参的替身(ADR-134: 保存事务内调用一次)。 */
    @MockitoBean private SalesMasterLearningPort learning;

    @AfterEach
    void clearAuth() {
        SecurityContextHolder.clearContext();
    }


    private UUID manager() { return user("mgr-"+UUID.randomUUID(),department("MGR-"+SEQ.incrementAndGet()),MANAGER_PERMS); }
    private QuoteDetail submitted(Fixture f) {
        loginAs(f.sales());
        var draft=quotes.create(quoteRequest(f.client(),line(goods("负责人链路货品",BigDecimal.TEN),"5",null,"0.9",null)));
        return quotes.submit(draft.getId(),new QuoteActionRequest(draft.getReviewRevision()));
    }
    private void approveQuote(UUID id,UUID manager) {
        loginAs(manager); var review=finance.managerReview(id);
        var claim=claims.claim(MANAGER_QUOTE,id.toString());
        finance.confirmManager(id,new QuoteFinanceDecisionRequest(review.reviewRevision(),claim.claimId(),"核对通过"));
    }
    private OrderDetail submittedOrder(Fixture f) {
        loginAs(f.sales());
        OrderSaveRequest request=new OrderSaveRequest(); request.setBillDate(LocalDate.now()); request.setClientId(f.client());
        request.setCurrencyId(baseCurrency()); request.setShipmentPolicy("ALLOW_PARTIAL");
        UUID goods=goods("订货负责人链路",BigDecimal.TEN);
        OrderItemLine line=new OrderItemLine(); line.setGoodsId(goods); line.setUnitId(unitOf(goods));
        line.setUnitRate(BigDecimal.ONE); line.setQty(new BigDecimal("5")); line.setDiscount(BigDecimal.ONE);
        request.setItems(List.of(line));
        var order=orders.create(request); return orders.approve(order.getId());
    }
    private long revision(UUID id) { return jdbc.queryForObject("SELECT finance_review_revision FROM sales_orders WHERE id=?",Long.class,id); }
    private void approveOrder(UUID id,UUID manager) {
        loginAs(manager); var claim=claims.claim(MANAGER_ORDER,id.toString());
        managers.confirmOrder(id,new SalesOrderFinanceConfirmService.FinanceConfirmRequest("已核对",revision(id),claim.claimId()));
    }

    @Test void combinedQueueUsesActualDocumentKindsAndFiltersBeforePagination() {
        Fixture f=fixture("queue-headers"); UUID manager=manager();
        var order=submittedOrder(f); var quote=submitted(f);
        loginAs(manager);
        var rows=managers.list("all","PENDING","",1,100,Map.of("billNo",order.getBillNo()));
        assertThat(rows.getTotal()).isEqualTo(1);
        assertThat(rows.getItems()).singleElement().satisfies(task -> {
            assertThat(task.kind()).isEqualTo("order");
            assertThat(task.state()).isEqualTo("PENDING");
            assertThat(task.totalOriginal()).isEqualByComparingTo("50");
        });
        assertThat(managers.list("all","PENDING","",2,1,Map.of("billNo",order.getBillNo())).getItems())
                .extracting(com.uten.imp.features.sales.SalesManagerReviewService.Task::id).containsExactly(order.getId());
        assertThat(managers.list("all","PENDING","",1,20,Map.of("billNo",order.getBillNo(),"amount",">50")).getTotal()).isZero();
        assertThat(managers.list("all","PENDING","",1,20,Map.of("billNo",quote.getBillNo(),"kind","报价单")).getItems())
                .extracting(com.uten.imp.features.sales.SalesManagerReviewService.Task::kind).containsExactly("quote");
        assertThat(managers.list("all","HISTORY",order.getBillNo(),1,20).getTotal()).isZero();
        approveOrder(order.getId(),manager);
        assertThat(managers.list("all","HISTORY",order.getBillNo(),1,20).getItems())
                .extracting(com.uten.imp.features.sales.SalesManagerReviewService.Task::state).containsExactly("APPROVED");
        UUID orderOnly=user("order-only-"+SEQ.incrementAndGet(),department("ORDER-ONLY-"+SEQ.incrementAndGet()),List.of("sales_order_manager:view"));
        loginAs(orderOnly);
        assertThat(managers.list("all","PENDING",quote.getBillNo(),1,20).getTotal()).isZero();
    }

    @Test void pendingReviewWithReservedStockRemainsInProgressUntilFinanceApproval() {
        Fixture f=fixture("queue-in-progress"); var order=submittedOrder(f);
        // The stage must not depend on whether stock happens to be available at submission.
        jdbc.update("UPDATE sales_order_items SET reserved_qty=qty WHERE order_id=?",order.getId());
        loginAs(f.sales());
        var rows=orders.progress(1,20,"IN_PROGRESS",order.getBillNo(),null,null,null,null,null);
        assertThat(rows.getItems()).singleElement().satisfies(row -> {
            assertThat(row.stage()).isEqualTo("PENDING");
            assertThat(row.managerReviewState()).isEqualTo("PENDING");
        });
        assertThat(orders.progress(1,20,"READY_TO_SHIP",order.getBillNo(),null,null,null,null,null).getTotal()).isZero();
    }

    @Test void staleApplicationSubmissionCannotLeaveNewOrderOutsideManagerGate() {
        Fixture f=fixture("stale-submitter"); var order=submittedOrder(f);
        jdbc.update("UPDATE sales_orders SET status=0,manager_review_state='NOT_REQUIRED' WHERE id=?",order.getId());
        jdbc.update("UPDATE sales_orders SET status=1 WHERE id=?",order.getId());
        assertThat(jdbc.queryForObject("SELECT manager_review_state FROM sales_orders WHERE id=?",String.class,order.getId())).isEqualTo("PENDING");
        loginAs(f.finance());
        assertConflict(() -> orderFinance.review(order.getId()));
    }

    @Test void missingOrderDecisionInputsAreValidationFailuresWithoutMutationOrLeaseReuse() {
        Fixture f=fixture("manager-order-inputs"); UUID manager=manager(); var order=submittedOrder(f);
        loginAs(manager); var claim=claims.claim(MANAGER_ORDER,order.getId().toString());
        long reviewed=revision(order.getId());
        String before=jdbc.queryForObject("SELECT to_jsonb(o)::text FROM sales_orders o WHERE id=?",String.class,order.getId());
        assertCode(() -> managers.confirmOrder(order.getId(),null),ErrorCode.VALIDATION_FAILED);
        assertCode(() -> managers.confirmOrder(order.getId(),new SalesOrderFinanceConfirmService.FinanceConfirmRequest(null,null,claim.claimId())),ErrorCode.VALIDATION_FAILED);
        assertCode(() -> managers.confirmOrder(order.getId(),new SalesOrderFinanceConfirmService.FinanceConfirmRequest(null,reviewed,null)),ErrorCode.VALIDATION_FAILED);
        assertCode(() -> managers.rejectOrder(order.getId(),null),ErrorCode.VALIDATION_FAILED);
        for (String reason : java.util.Arrays.asList(null,"","  "))
            assertCode(() -> managers.rejectOrder(order.getId(),new SalesOrderFinanceConfirmService.FinanceRejectRequest(reason,reviewed,claim.claimId())),ErrorCode.VALIDATION_FAILED);
        assertCode(() -> managers.rejectOrder(order.getId(),new SalesOrderFinanceConfirmService.FinanceRejectRequest("请核对",null,claim.claimId())),ErrorCode.VALIDATION_FAILED);
        assertCode(() -> managers.rejectOrder(order.getId(),new SalesOrderFinanceConfirmService.FinanceRejectRequest("请核对",reviewed,null)),ErrorCode.VALIDATION_FAILED);
        assertConflict(() -> managers.confirmOrder(order.getId(),new SalesOrderFinanceConfirmService.FinanceConfirmRequest(null,reviewed+1,claim.claimId())));
        assertConflict(() -> managers.rejectOrder(order.getId(),new SalesOrderFinanceConfirmService.FinanceRejectRequest("旧租约",reviewed,UUID.randomUUID())));
        assertThat(jdbc.queryForObject("SELECT to_jsonb(o)::text FROM sales_orders o WHERE id=?",String.class,order.getId())).isEqualTo(before);
        assertThat(jdbc.queryForObject("SELECT count(*) FROM sales_order_manager_review_events WHERE order_id=?",Long.class,order.getId())).isZero();
        assertThat(jdbc.queryForObject("SELECT released_at IS NULL FROM task_claims WHERE id=?",Boolean.class,claim.claimId())).isTrue();
        // Omitting the generation must not let an old page borrow a fresh lease held by the same user.
        claims.release(MANAGER_ORDER,order.getId().toString()); var renewed=claims.claim(MANAGER_ORDER,order.getId().toString());
        assertCode(() -> managers.confirmOrder(order.getId(),new SalesOrderFinanceConfirmService.FinanceConfirmRequest(null,reviewed,null)),ErrorCode.VALIDATION_FAILED);
        assertConflict(() -> managers.confirmOrder(order.getId(),new SalesOrderFinanceConfirmService.FinanceConfirmRequest(null,reviewed,claim.claimId())));
        managers.confirmOrder(order.getId(),new SalesOrderFinanceConfirmService.FinanceConfirmRequest(null,reviewed,renewed.claimId()));
        assertThat(revision(order.getId())).isEqualTo(reviewed+1);
        assertCode(() -> managers.reverseOrder(order.getId(),null),ErrorCode.VALIDATION_FAILED);
        assertCode(() -> managers.reverseOrder(order.getId(),new com.uten.imp.features.sales.SalesManagerReviewService.ReverseRequest(null,reviewed+1,"重新核对")),ErrorCode.VALIDATION_FAILED);
        assertCode(() -> managers.reverseOrder(order.getId(),new com.uten.imp.features.sales.SalesManagerReviewService.ReverseRequest(UUID.randomUUID(),null,"重新核对")),ErrorCode.VALIDATION_FAILED);
        for (String reason : java.util.Arrays.asList(null,"","  "))
            assertCode(() -> managers.reverseOrder(order.getId(),new com.uten.imp.features.sales.SalesManagerReviewService.ReverseRequest(UUID.randomUUID(),reviewed+1,reason)),ErrorCode.VALIDATION_FAILED);
        assertThat(revision(order.getId())).isEqualTo(reviewed+1);
        assertThat(orderFinance.managerReview(order.getId()).financeConfirmed()).isTrue();
    }

    @Test void managerBatchRequiresEveryOriginalRevisionAndLeaseBeforeAnyDecision() {
        Fixture f=fixture("manager-batch-inputs"); UUID manager=manager(); var first=submittedOrder(f);var second=submittedOrder(f);
        loginAs(manager);var a=claims.claim(MANAGER_ORDER,first.getId().toString());var b=claims.claim(MANAGER_ORDER,second.getId().toString());
        var ids=List.of(first.getId(),second.getId());var versions=Map.of(first.getId(),revision(first.getId()),second.getId(),revision(second.getId()));
        var leases=Map.of(first.getId(),a.claimId(),second.getId(),b.claimId());
        assertCode(() -> managers.confirmOrders(null),ErrorCode.VALIDATION_FAILED);
        assertCode(() -> managers.confirmOrders(new SalesOrderFinanceConfirmService.FinanceBatchConfirmRequest(ids,null,null,leases)),ErrorCode.VALIDATION_FAILED);
        assertCode(() -> managers.confirmOrders(new SalesOrderFinanceConfirmService.FinanceBatchConfirmRequest(ids,null,versions,null)),ErrorCode.VALIDATION_FAILED);
        assertCode(() -> managers.confirmOrders(new SalesOrderFinanceConfirmService.FinanceBatchConfirmRequest(ids,null,versions,Map.of(first.getId(),a.claimId()))),ErrorCode.VALIDATION_FAILED);
        assertThat(jdbc.queryForList("SELECT manager_review_state FROM sales_orders WHERE id IN (?,?)",String.class,first.getId(),second.getId())).containsOnly("PENDING");
        assertThat(jdbc.queryForObject("SELECT count(*) FROM sales_order_manager_review_events WHERE order_id IN (?,?)",Long.class,first.getId(),second.getId())).isZero();
        managers.confirmOrders(new SalesOrderFinanceConfirmService.FinanceBatchConfirmRequest(ids,null,versions,leases));
        assertThat(jdbc.queryForList("SELECT manager_review_state FROM sales_orders WHERE id IN (?,?)",String.class,first.getId(),second.getId())).containsOnly("APPROVED");
    }

    @Test void quoteManagerAndFinanceRejectIncompleteInputsAndRetainExactLeaseGeneration() {
        Fixture f=fixture("manager-quote-inputs"); UUID manager=manager();var quote=submitted(f);
        loginAs(manager);var managerClaim=claims.claim(MANAGER_QUOTE,quote.getId().toString());
        assertQuoteInputFailures(quote.getId(),quote.getReviewRevision(),managerClaim.claimId(),true);
        approveQuote(quote.getId(),manager);
        loginAs(f.finance());var review=finance.review(quote.getId());var financeClaim=claims.claim(CLAIM,quote.getId().toString());
        assertQuoteInputFailures(quote.getId(),review.reviewRevision(),financeClaim.claimId(),false);
        claims.release(CLAIM,quote.getId().toString());var renewed=claims.claim(CLAIM,quote.getId().toString());
        assertCode(() -> finance.confirm(quote.getId(),new QuoteFinanceDecisionRequest(review.reviewRevision(),null,null)),ErrorCode.VALIDATION_FAILED);
        assertConflict(() -> finance.confirm(quote.getId(),new QuoteFinanceDecisionRequest(review.reviewRevision(),financeClaim.claimId(),null)));
        finance.confirm(quote.getId(),new QuoteFinanceDecisionRequest(review.reviewRevision(),renewed.claimId(),null));
        assertCode(() -> finance.reopen(quote.getId(),null),ErrorCode.VALIDATION_FAILED);
        assertCode(() -> finance.reopen(quote.getId(),new QuoteActionRequest(null)),ErrorCode.VALIDATION_FAILED);
        assertThat(finance.review(quote.getId()).status()).isEqualTo((short)1);
    }

    private void assertQuoteInputFailures(UUID id,int revision,UUID lease,boolean manager) {
        java.util.function.Consumer<QuoteFinanceDecisionRequest> confirm=req->{if(manager)finance.confirmManager(id,req);else finance.confirm(id,req);};
        java.util.function.Consumer<QuoteFinanceDecisionRequest> reject=req->{if(manager)finance.rejectManager(id,req);else finance.returnToSales(id,req);};
        java.util.function.Consumer<QuoteFinanceEditRequest> edit=req->{if(manager)finance.editManager(id,req);else finance.edit(id,req);};
        String before=jdbc.queryForObject("SELECT to_jsonb(q)::text FROM sales_quotes q WHERE id=?",String.class,id);
        assertCode(() -> confirm.accept(null),ErrorCode.VALIDATION_FAILED);
        assertCode(() -> reject.accept(null),ErrorCode.VALIDATION_FAILED);
        assertCode(() -> edit.accept(null),ErrorCode.VALIDATION_FAILED);
        assertCode(() -> confirm.accept(new QuoteFinanceDecisionRequest(null,lease,null)),ErrorCode.VALIDATION_FAILED);
        assertCode(() -> confirm.accept(new QuoteFinanceDecisionRequest(revision,null,null)),ErrorCode.VALIDATION_FAILED);
        assertCode(() -> reject.accept(new QuoteFinanceDecisionRequest(null,lease,"请核对")),ErrorCode.VALIDATION_FAILED);
        assertCode(() -> reject.accept(new QuoteFinanceDecisionRequest(revision,null,"请核对")),ErrorCode.VALIDATION_FAILED);
        for(String reason:java.util.Arrays.asList(null,"","  "))
            assertCode(() -> reject.accept(new QuoteFinanceDecisionRequest(revision,lease,reason)),ErrorCode.VALIDATION_FAILED);
        assertCode(() -> edit.accept(new QuoteFinanceEditRequest(null,lease,null,null,null,List.of())),ErrorCode.VALIDATION_FAILED);
        assertCode(() -> edit.accept(new QuoteFinanceEditRequest(revision,null,null,null,null,List.of())),ErrorCode.VALIDATION_FAILED);
        assertCode(() -> edit.accept(new QuoteFinanceEditRequest(revision,lease,null,null,null,java.util.Arrays.asList((QuoteFinanceEditRequest.Line)null))),ErrorCode.VALIDATION_FAILED);
        assertCode(() -> edit.accept(new QuoteFinanceEditRequest(revision,lease,null,null,null,List.of(new QuoteFinanceEditRequest.Line(null,null,BigDecimal.ONE,null,null)))),ErrorCode.VALIDATION_FAILED);
        assertConflict(() -> confirm.accept(new QuoteFinanceDecisionRequest(revision+1,lease,null)));
        assertConflict(() -> reject.accept(new QuoteFinanceDecisionRequest(revision,UUID.randomUUID(),"旧租约")));
        assertThat(jdbc.queryForObject("SELECT to_jsonb(q)::text FROM sales_quotes q WHERE id=?",String.class,id)).isEqualTo(before);
        assertThat(jdbc.queryForObject("SELECT released_at IS NULL FROM task_claims WHERE id=?",Boolean.class,lease)).isTrue();
        if(manager) {
            assertCode(() -> finance.reopenManager(id,null),ErrorCode.VALIDATION_FAILED);
            assertCode(() -> finance.reopenManager(id,new QuoteActionRequest(null)),ErrorCode.VALIDATION_FAILED);
        }
    }

    @Test void quoteMustPassManagementBeforeAnyFinanceDecisionOrClaim() {
        Fixture f=fixture("manager-gate"); UUID manager=manager(); var quote=submitted(f);
        assertThat(quote.getManagerReview().getState()).isEqualTo("PENDING");
        loginAs(f.finance());
        assertNotFound(() -> finance.review(quote.getId()));
        assertConflict(() -> claims.claim(CLAIM,quote.getId().toString()));
        assertConflict(() -> finance.confirm(quote.getId(),new QuoteFinanceDecisionRequest(quote.getReviewRevision(),UUID.randomUUID(),null)));
        assertThat(finance.list("pending",quote.getBillNo(),1,20).getTotal()).isZero();
        approveQuote(quote.getId(),manager);
        assertThat(managers.list("quote","APPROVED",quote.getBillNo(),1,20).getTotal()).isEqualTo(1);
        assertThat(managerController.quote(quote.getId())).containsEntry("reviewStage","SALES_MANAGER")
                .containsEntry("reviewStatusBucket","APPROVED").doesNotContainKeys("financeConfirmedAt","financeActions","status");
        assertThat(jdbc.queryForObject("SELECT finance_confirmed_at IS NULL FROM sales_quotes WHERE id=?",Boolean.class,quote.getId())).isTrue();
        loginAs(f.finance()); var review=finance.review(quote.getId()); var claim=claims.claim(CLAIM,quote.getId().toString());
        var confirmed=finance.confirm(quote.getId(),new QuoteFinanceDecisionRequest(review.reviewRevision(),claim.claimId(),null));
        assertThat(confirmed.status()).isEqualTo((short)1);
        loginAs(f.sales()); var order=acceptAndConvert(quote.getId()); orders.update(order.getId(),orderRequest(order)); orders.approve(order.getId());
        assertThat(orders.detail(order.getId()).getManagerReview().pending()).isTrue();
        loginAs(f.finance()); assertConflict(() -> claims.claim("SALES_ORDER_FINANCE_CONFIRM",order.getId().toString()));
        assertThat(orderFinance.pending(1,20,false,order.getBillNo()).getTotal()).isZero();
        approveOrder(order.getId(),manager);
        loginAs(f.finance()); var orderClaim=claims.claim("SALES_ORDER_FINANCE_CONFIRM",order.getId().toString());
        orderFinance.confirm(order.getId(),new SalesOrderFinanceConfirmService.FinanceConfirmRequest(null,revision(order.getId()),orderClaim.claimId()));
        assertThat(jdbc.queryForObject("SELECT finance_confirmed FROM sales_orders WHERE id=?",Boolean.class,order.getId())).isTrue();
        loginAs(manager); assertConflict(() -> managers.reverseOrder(order.getId(),new com.uten.imp.features.sales.SalesManagerReviewService.ReverseRequest(UUID.randomUUID(),revision(order.getId()),"撤回")));
    }

    @Test void quoteRejectWithdrawResubmitAndReverseKeepSeparateAuditAndClaims() {
        Fixture f=fixture("manager-return"); UUID manager=manager(); var quote=submitted(f);
        loginAs(manager); var claim=claims.claim(MANAGER_QUOTE,quote.getId().toString());
        loginAs(f.sales()); assertConflict(() -> quotes.withdraw(quote.getId(),new QuoteActionRequest(quote.getReviewRevision())));
        loginAs(manager); var rejected=finance.rejectManager(quote.getId(),new QuoteFinanceDecisionRequest(quote.getReviewRevision(),claim.claimId(),"请核对数量"));
        assertThat(rejected.status()).isZero();
        assertThat(jdbc.queryForObject("SELECT finance_returned_at IS NULL FROM sales_quotes WHERE id=?",Boolean.class,quote.getId())).isTrue();
        assertThat(jdbc.queryForObject("SELECT count(*) FROM notices WHERE aggregate_id=? AND audience_user_id=? AND source_event='SALES_QUOTE_MANAGER_REJECTED' AND resolved_at IS NULL",
                Long.class,quote.getId(),f.sales())).isEqualTo(1);
        loginAs(f.sales());
        assertThat(noticeService.list(false)).anyMatch(notice ->
                "SALES_QUOTE_MANAGER_REJECTED".equals(notice.sourceEvent()) && quote.getId().toString().equals(notice.aggregateId()));
        loginAs(f.sales()); var next=quotes.submit(quote.getId(),new QuoteActionRequest(rejected.reviewRevision()));
        assertThat(jdbc.queryForObject("SELECT count(*) FROM notices WHERE aggregate_id=? AND source_event='SALES_QUOTE_MANAGER_REJECTED' AND resolved_at IS NULL",
                Long.class,quote.getId())).isZero();
        assertThat(next.getManagerReview().pending()).isTrue();
        approveQuote(quote.getId(),manager);
        loginAs(f.finance()); var financeClaim=claims.claim(CLAIM,quote.getId().toString());
        loginAs(manager); var reviewed=finance.managerReview(quote.getId());
        assertConflict(() -> finance.reopenManager(quote.getId(),new QuoteActionRequest(reviewed.reviewRevision())));
        loginAs(f.finance()); claims.release(CLAIM,quote.getId().toString());
        loginAs(manager); finance.reopenManager(quote.getId(),new QuoteActionRequest(reviewed.reviewRevision()));
        assertThat(jdbc.queryForList("SELECT action FROM sales_quote_revision_logs WHERE quote_id=? ORDER BY revision",String.class,quote.getId()))
                .containsSubsequence("SUBMIT","MANAGER_REJECT","SUBMIT","MANAGER_CONFIRM","MANAGER_REVERSE");
        loginAs(f.finance()); assertConflict(() -> finance.confirm(quote.getId(),new QuoteFinanceDecisionRequest(reviewed.reviewRevision(),financeClaim.claimId(),null)));
    }

    @Test void independentPermissionsAndLiveRevocationDoNotFallBackToFinanceAuthority() {
        Fixture f=fixture("manager-permissions"); var quote=submitted(f);
        UUID readOnly=user("mgr-read-"+SEQ.incrementAndGet(),department("MR-"+SEQ.incrementAndGet()),List.of("sales_quote_manager:view"));
        loginAs(readOnly); assertThat(finance.managerReview(quote.getId()).financeActions()).isEmpty();
        assertThatThrownBy(() -> claims.claim(MANAGER_QUOTE,quote.getId().toString())).isInstanceOf(ApiException.class);
        UUID rejectOnly=user("mgr-reject-"+SEQ.incrementAndGet(),department("MJ-"+SEQ.incrementAndGet()),List.of("sales_quote_manager:view","sales_quote_manager:reject"));
        loginAs(rejectOnly); assertThat(finance.managerReview(quote.getId()).financeActions()).containsExactly("return");
        var claim=claims.claim(MANAGER_QUOTE,quote.getId().toString());
        assertThatThrownBy(() -> finance.confirmManager(quote.getId(),new QuoteFinanceDecisionRequest(quote.getReviewRevision(),claim.claimId(),null)))
                .isInstanceOf(org.springframework.security.access.AccessDeniedException.class);
        jdbc.update("DELETE FROM user_permission_overrides WHERE user_id=?",rejectOnly);
        assertForbidden(() -> finance.rejectManager(quote.getId(),new QuoteFinanceDecisionRequest(quote.getReviewRevision(),claim.claimId(),"旧权限页面")));
        assertThat(jdbc.queryForObject("SELECT manager_review_state FROM sales_quotes WHERE id=?",String.class,quote.getId())).isEqualTo("PENDING");
    }

    @Test void orderAmendmentInvalidatesThePreviousApprovalAndRejectedOrdersReturnThroughSales() {
        Fixture f=fixture("manager-amend"); UUID manager=manager(); var order=submittedOrder(f);
        approveOrder(order.getId(),manager); long approvedRevision=revision(order.getId());
        loginAs(f.sales()); var req=orderRequest(orders.detail(order.getId())); req.getItems().getFirst().setQty(new BigDecimal("7"));
        var changed=orders.update(order.getId(),req);
        assertThat(changed.getManagerReview().pending()).isTrue();
        loginAs(f.finance()); assertConflict(() -> orderFinance.confirm(order.getId(),new SalesOrderFinanceConfirmService.FinanceConfirmRequest(null,approvedRevision,null)));
        loginAs(manager); var claim=claims.claim(MANAGER_ORDER,order.getId().toString());
        managers.rejectOrder(order.getId(),new SalesOrderFinanceConfirmService.FinanceRejectRequest("数量有误",revision(order.getId()),claim.claimId()));
        loginAs(f.sales()); var rejected=orders.detail(order.getId());
        var revised=orders.update(order.getId(),orderRequest(rejected)); assertThat(revised.getStatus()).isZero();
        orders.approve(order.getId());
        assertThat(orders.detail(order.getId()).getManagerReview().pending()).isTrue();
        assertThat(jdbc.queryForObject("SELECT count(*) FROM sales_order_manager_review_events WHERE order_id=?",Long.class,order.getId())).isEqualTo(2);
    }

    @Test void batchApprovalRollsBackEveryOrderWhenOneVersionIsStale() {
        Fixture f=fixture("manager-batch"); UUID manager=manager(); var first=submittedOrder(f); var second=submittedOrder(f);
        loginAs(manager); var a=claims.claim(MANAGER_ORDER,first.getId().toString()); var b=claims.claim(MANAGER_ORDER,second.getId().toString());
        var ids=List.of(first.getId(),second.getId());
        var leases=Map.of(first.getId(),a.claimId(),second.getId(),b.claimId());
        assertConflict(() -> managers.confirmOrders(new SalesOrderFinanceConfirmService.FinanceBatchConfirmRequest(ids,null,
                Map.of(first.getId(),revision(first.getId()),second.getId(),revision(second.getId())+1),leases)));
        assertThat(jdbc.queryForList("SELECT manager_review_state FROM sales_orders WHERE id IN (?,?)",String.class,first.getId(),second.getId())).containsOnly("PENDING");
        managers.confirmOrders(new SalesOrderFinanceConfirmService.FinanceBatchConfirmRequest(ids,"全部核对",
                Map.of(first.getId(),revision(first.getId()),second.getId(),revision(second.getId())),leases));
        assertThat(jdbc.queryForList("SELECT manager_review_state FROM sales_orders WHERE id IN (?,?)",String.class,first.getId(),second.getId())).containsOnly("APPROVED");
        assertThat(jdbc.queryForList("SELECT finance_confirmed FROM sales_orders WHERE id IN (?,?)",Boolean.class,first.getId(),second.getId())).containsOnly(false);
    }

    @Test void databaseAndReminderPredicatesEnforceTheSameStageBoundary() {
        Fixture f=fixture("manager-db-notice"); UUID manager=manager(); var quote=submitted(f);
        loginAs(manager);
        String event="SALES_QUOTE_PENDING_MANAGER_REVIEW";
        String permissions=String.join(",",currentPermissions());
        assertThat(jdbc.queryForObject("SELECT fn_notice_business_action_visible(?,?,?,?,?,?,?,?,?,?)",Boolean.class,
                manager,event,"SALES_QUOTE_MANAGER",quote.getId(),"/sales/manager-review/quotes/"+quote.getId(),
                permissions,event,event,"{}","{}")).isTrue();
        assertThatThrownBy(() -> jdbc.update("UPDATE sales_quotes SET status=1,finance_confirmed_at=now() WHERE id=?",quote.getId()))
                .isInstanceOf(org.springframework.dao.DataIntegrityViolationException.class);
        approveQuote(quote.getId(),manager);
        assertThat(jdbc.queryForObject("SELECT fn_notice_business_action_visible(?,?,?,?,?,?,?,?,?,?)",Boolean.class,
                manager,event,"SALES_QUOTE_MANAGER",quote.getId(),"/sales/manager-review/quotes/"+quote.getId(),
                permissions,event,event,"{}","{}")).isFalse();
        assertThat(jdbc.queryForObject("SELECT count(*) FROM notices WHERE aggregate_id=? AND source_event=? AND resolved_at IS NULL",Long.class,quote.getId(),event)).isZero();
        var order=submittedOrder(f);
        assertThatThrownBy(() -> jdbc.update("UPDATE sales_orders SET finance_confirmed=true WHERE id=?",order.getId()))
                .isInstanceOf(org.springframework.dao.DataIntegrityViolationException.class);
        assertThat(orders.progress(1,20,"OPEN",order.getBillNo(),null,null,null,null,null).getItems())
                .extracting(com.uten.imp.features.sales.order.dto.OrderProgressRow::managerReviewState).containsExactly("PENDING");
    }

    @Test void managerPricingRetainsItsOwnProvenanceAndFinanceStillMustConfirm() {
        Fixture f=fixture("manager-price"); UUID manager=manager();
        loginAs(f.sales()); UUID goods=goods("负责人直接定价",null);
        var q=quotes.create(quoteRequest(f.client(),line(goods,"2",null,"1","12")));
        quotes.submit(q.getId(),new QuoteActionRequest(q.getReviewRevision()));
        loginAs(manager); var review=finance.managerReview(q.getId()); var claim=claims.claim(MANAGER_QUOTE,q.getId().toString());
        assertConflict(() -> finance.confirmManager(q.getId(),new QuoteFinanceDecisionRequest(review.reviewRevision(),claim.claimId(),null)));
        var priced=finance.editManager(q.getId(),new QuoteFinanceEditRequest(review.reviewRevision(),claim.claimId(),null,null,"保存的负责人备注",List.of(
                new QuoteFinanceEditRequest.Line(review.lines().getFirst().itemId(),null,new BigDecimal("12"),null,null))));
        assertThat(priced.lines().getFirst().priceSource()).isEqualTo("MANAGER");
        assertThat(jdbc.queryForObject("SELECT finance_price_by IS NULL AND manager_price_by=? FROM sales_quote_items WHERE quote_id=?",Boolean.class,employeeOf(manager),q.getId())).isTrue();
        finance.confirmManager(q.getId(),new QuoteFinanceDecisionRequest(priced.reviewRevision(),claim.claimId(),null));
        assertThat(finance.managerReview(q.getId()).financeRemark()).isEqualTo("保存的负责人备注");
        loginAs(f.finance()); var fin=finance.review(q.getId()); var fc=claims.claim(CLAIM,q.getId().toString());
        finance.confirm(q.getId(),new QuoteFinanceDecisionRequest(fin.reviewRevision(),fc.claimId(),null));
        assertThat(jdbc.queryForObject("SELECT total_original FROM sales_quotes WHERE id=?",BigDecimal.class,q.getId())).isEqualByComparingTo("24");
    }

    @Test void simultaneousManagersCanProduceOnlyOneApproval() throws Exception {
        Fixture f=fixture("manager-race"); UUID first=manager(),second=manager(); var quote=submitted(f);
        var start=new java.util.concurrent.CountDownLatch(1);
        try (var executor=java.util.concurrent.Executors.newFixedThreadPool(2)) {
            List<java.util.concurrent.Future<Boolean>> results=new ArrayList<>();
            for(UUID actor:List.of(first,second)) results.add(executor.submit(() -> {
                start.await(); loginAs(actor);
                try {
                    var claim=claims.claim(MANAGER_QUOTE,quote.getId().toString());
                    finance.confirmManager(quote.getId(),new QuoteFinanceDecisionRequest(quote.getReviewRevision(),claim.claimId(),null));
                    return true;
                } catch(ApiException conflict) { assertThat(conflict.getCode()).isEqualTo(ErrorCode.CONFLICT); return false; }
                finally { SecurityContextHolder.clearContext(); }
            }));
            start.countDown(); int successes=0;
            for(var result:results) if(result.get(30,java.util.concurrent.TimeUnit.SECONDS)) successes++;
            assertThat(successes).isEqualTo(1);
        }
        assertThat(jdbc.queryForObject("SELECT count(*) FROM sales_quote_revision_logs WHERE quote_id=? AND action='MANAGER_CONFIRM'",Long.class,quote.getId())).isEqualTo(1);
    }

    @Test void financeRejectionAndManagerReversalRequireTheCorrectReturnPath() {
        Fixture f=fixture("manager-fin-return"); UUID manager=manager(); var order=submittedOrder(f);
        approveOrder(order.getId(),manager); loginAs(f.finance());
        var claim=claims.claim("SALES_ORDER_FINANCE_CONFIRM",order.getId().toString()); long reviewed=revision(order.getId());
        loginAs(manager);
        assertConflict(() -> managers.reverseOrder(order.getId(),new com.uten.imp.features.sales.SalesManagerReviewService.ReverseRequest(UUID.randomUUID(),reviewed,"重新核对")));
        loginAs(f.finance());
        orderFinance.reject(order.getId(),new SalesOrderFinanceConfirmService.FinanceRejectRequest("付款条件需调整",reviewed,claim.claimId()));
        loginAs(f.sales()); var revised=orders.update(order.getId(),orderRequest(orders.detail(order.getId())));
        assertThat(revised.getStatus()).isZero(); orders.approve(order.getId());
        approveOrder(order.getId(),manager);
        managers.reverseOrder(order.getId(),new com.uten.imp.features.sales.SalesManagerReviewService.ReverseRequest(UUID.randomUUID(),revision(order.getId()),"负责人再次核对"));
        assertThat(managers.counts().get("order")).isGreaterThanOrEqualTo(1);
        assertThat(orderFinance.managerReview(order.getId()).managerHistory()).extracting(com.uten.imp.features.sales.order.dto.OrderProgressTimelineEvent::code)
                .contains("MANAGER_APPROVED","MANAGER_REVERSED","MANAGER_PENDING");
        loginAs(f.finance()); assertConflict(() -> orderFinance.confirm(order.getId(),new SalesOrderFinanceConfirmService.FinanceConfirmRequest(null,reviewed,claim.claimId())));
    }

    @Test void reversalHasAnImmutableRequestIdentityAndCannotReplayOrOverwriteADecision() {
        Fixture f=fixture("manager-reverse-receipt"); UUID manager=manager(); var order=submittedOrder(f);
        approveOrder(order.getId(),manager);
        long reviewed=revision(order.getId()); UUID decisionId=UUID.randomUUID();
        var request=new com.uten.imp.features.sales.SalesManagerReviewService.ReverseRequest(decisionId,reviewed,"重新核对交期");
        assertConflict(() -> managers.reverseOrder(order.getId(),
                new com.uten.imp.features.sales.SalesManagerReviewService.ReverseRequest(UUID.randomUUID(),reviewed+1,"错误版本")));
        // Treat the successful response as lost: the next GET must independently prove this exact write.
        managers.reverseOrder(order.getId(),request);
        @SuppressWarnings("unchecked") var decisions=(List<com.uten.imp.features.sales.SalesManagerReviewProjection.Decision>)managerController.order(order.getId()).get("managerDecisions");
        assertThat(decisions).filteredOn(d -> d.decisionId().equals(decisionId)).singleElement().satisfies(decision -> {
            assertThat(decision.revision()).isEqualTo(reviewed+1);
            assertThat(decision.action()).isEqualTo("REVERSED");
            assertThat(decision.actorId()).isEqualTo(employeeOf(manager));
            assertThat(decision.reason()).isEqualTo("重新核对交期");
        });
        assertConflict(() -> managers.reverseOrder(order.getId(),request));
        approveOrder(order.getId(),manager);
        long approved=revision(order.getId());
        // Even after a new approval, reusing another request's identity atomically rolls back the reversal.
        assertConflict(() -> managers.reverseOrder(order.getId(),
                new com.uten.imp.features.sales.SalesManagerReviewService.ReverseRequest(decisionId,approved,"不同原因")));
        assertThat(revision(order.getId())).isEqualTo(approved);
        assertThat(orderFinance.managerReview(order.getId()).financeConfirmed()).isTrue();
        assertThat(jdbc.queryForObject("SELECT count(*) FROM sales_order_manager_review_events WHERE id=?",Long.class,decisionId)).isEqualTo(1);
        assertThatThrownBy(() -> jdbc.update("UPDATE sales_order_manager_review_events SET reason='覆写' WHERE id=?",decisionId))
                .isInstanceOf(org.springframework.dao.DataAccessException.class);
    }

    @Test void quantityChangesAfterFinanceApprovalMustReturnToManagement() {
        Fixture f=fixture("manager-quantity"); UUID manager=manager(); var order=submittedOrder(f);
        approveOrder(order.getId(),manager); loginAs(f.finance());
        var claim=claims.claim("SALES_ORDER_FINANCE_CONFIRM",order.getId().toString());
        orderFinance.confirm(order.getId(),new SalesOrderFinanceConfirmService.FinanceConfirmRequest(null,revision(order.getId()),claim.claimId()));
        loginAs(f.sales());
        var request=new com.uten.imp.features.sales.order.dto.OrderChangeQtyRequest();
        var line=new com.uten.imp.features.sales.order.dto.OrderChangeQtyRequest.Line();
        line.setOrderItemId(order.getItems().getFirst().getId()); line.setNewQty(new BigDecimal("8")); request.setItems(List.of(line));
        var amended=orders.changeQty(order.getId(),request);
        assertThat(amended.getManagerReview().pending()).isTrue();
        assertThat(amended.isFinanceConfirmed()).isFalse();
        loginAs(f.finance()); assertConflict(() -> claims.claim("SALES_ORDER_FINANCE_CONFIRM",order.getId().toString()));
    }

    @Test void newlyAuthorizedReviewersReceiveCentralPopupsAndCompletionWithdrawsThem() {
        Fixture f=fixture("manager-popup"); UUID first=manager(); var quote=submitted(f); var order=submittedOrder(f);
        UUID later=manager();
        UUID viewer=user("manager-view-"+SEQ.incrementAndGet(),department("MV-"+SEQ.incrementAndGet()),
                List.of("notice:read","sales_quote_manager:view","sales_order_manager:view"));
        loginAs(viewer);
        assertThat(noticeService.pendingReviews()).noneMatch(n -> n.sourceEvent().contains("MANAGER_REVIEW"));
        loginAs(later);
        var pending=noticeService.pendingReviews();
        assertThat(pending).anyMatch(n -> n.aggregateId().equals(quote.getId().toString()) && n.interactive()
                && n.sourceEvent().equals("SALES_QUOTE_PENDING_MANAGER_REVIEW") && n.actionRoute().startsWith("/sales/manager-review/quotes/"));
        assertThat(pending).anyMatch(n -> n.aggregateId().equals(order.getId().toString()) && n.interactive()
                && n.sourceEvent().equals("SALES_ORDER_PENDING_MANAGER_REVIEW"));
        noticeService.pendingReviews();
        assertThat(jdbc.queryForObject("SELECT count(*) FROM notices WHERE audience_user_id=? AND aggregate_id=? AND source_event='SALES_QUOTE_PENDING_MANAGER_REVIEW' AND resolved_at IS NULL",Long.class,later,quote.getId())).isEqualTo(1);
        var lease=claims.claim(MANAGER_ORDER,order.getId().toString());
        loginAs(first); var firstPending=noticeService.pendingReviews();
        var orderNotice=firstPending.stream().filter(n -> n.aggregateId().equals(order.getId().toString())).findFirst().orElseThrow();
        assertThat(noticeService.pendingReviewStatus(List.of(UUID.fromString(orderNotice.id())))).singleElement()
                .satisfies(status -> assertThat(status.claimedByName()).isNotBlank());
        loginAs(later); managers.confirmOrder(order.getId(),new SalesOrderFinanceConfirmService.FinanceConfirmRequest(null,revision(order.getId()),lease.claimId()));
        approveQuote(quote.getId(),later);
        loginAs(first);
        assertThat(noticeService.pendingReviews()).noneMatch(n -> n.aggregateId().equals(quote.getId().toString()) || n.aggregateId().equals(order.getId().toString()));
        loginAs(later);
        assertThat(noticeService.pendingReviews()).noneMatch(n -> n.aggregateId().equals(quote.getId().toString()) || n.aggregateId().equals(order.getId().toString()));
    }

    @Test void withdrawnAndCancelledDocumentsDoNotPretendToBePendingManagerWork() {
        Fixture f=fixture("manager-terminal"); UUID manager=manager(); var quote=submitted(f);
        quotes.withdraw(quote.getId(),new QuoteActionRequest(quote.getReviewRevision()));
        var order=submittedOrder(f); orders.cancel(order.getId());
        loginAs(manager);
        var quoteReview=finance.managerReview(quote.getId());
        assertThat(quoteReview.statusBucket()).isEqualTo("DRAFT");
        assertThat(quoteReview.financeActions()).isEmpty();
        var orderReview=orderFinance.managerReview(order.getId());
        assertThat(orderReview.readOnlyReason()).contains("中止");
        assertThat(orderReview.managerReversible()).isFalse();
        assertThat(managers.list("order","PENDING",order.getBillNo(),1,20).getTotal()).isZero();
    }

    @Test void upgradeMovesOnlyLivePendingWorkAndRetainsOldFinanceDecisionsAndClaimHistory() throws Exception {
        Fixture f=fixture("manager-upgrade");
        var pending=submitted(f); var closed=submitted(f); var past=submitted(f);
        var pendingOrder=submittedOrder(f); var pastOrder=submittedOrder(f); var rejectedOrder=submittedOrder(f);
        jdbc.update("UPDATE sales_quotes SET manager_review_state='NOT_REQUIRED',is_closed=(id=?) WHERE id IN (?,?,?)",
                closed.getId(),pending.getId(),closed.getId(),past.getId());
        jdbc.update("UPDATE sales_orders SET manager_review_state='NOT_REQUIRED' WHERE id IN (?,?,?)",pendingOrder.getId(),pastOrder.getId(),rejectedOrder.getId());
        loginAs(f.finance());
        var pastClaim=claims.claim(CLAIM,past.getId().toString());
        finance.confirm(past.getId(),new QuoteFinanceDecisionRequest(past.getReviewRevision(),pastClaim.claimId(),null));
        var pastOrderClaim=claims.claim("SALES_ORDER_FINANCE_CONFIRM",pastOrder.getId().toString());
        orderFinance.confirm(pastOrder.getId(),new SalesOrderFinanceConfirmService.FinanceConfirmRequest(null,revision(pastOrder.getId()),pastOrderClaim.claimId()));
        var rejectedLease=claims.claim("SALES_ORDER_FINANCE_CONFIRM",rejectedOrder.getId().toString());
        orderFinance.reject(rejectedOrder.getId(),new SalesOrderFinanceConfirmService.FinanceRejectRequest("旧退回待修订",revision(rejectedOrder.getId()),rejectedLease.claimId()));
        String previousQuoteAt=jdbc.queryForObject("SELECT finance_confirmed_at::text FROM sales_quotes WHERE id=?",String.class,past.getId());
        String previousOrderAt=jdbc.queryForObject("SELECT finance_confirmed_at::text FROM sales_orders WHERE id=?",String.class,pastOrder.getId());
        var quoteLease=claims.claim(CLAIM,pending.getId().toString());
        var orderLease=claims.claim("SALES_ORDER_FINANCE_CONFIRM",pendingOrder.getId().toString());
        var quoteNotice=noticeService.publishForUser(f.finance(),"旧报价待财审","待办","approval","系统","/finance/quote-review/"+pending.getId(),
                "SALES_QUOTE_PENDING_FINANCE_REVIEW","normal",pending.getId());
        var orderNotice=noticeService.publishForUser(f.finance(),"旧订货待财审","待办","approval","系统","/finance/sales-order-confirmations/"+pendingOrder.getId(),
                "SALES_ORDER_PENDING_FINANCE_CONFIRM","normal",pendingOrder.getId());
        // Execute the exact migration predicates, scoped to these fixture IDs so other test scenarios remain independent.
        String migration=java.nio.file.Files.readString(java.nio.file.Path.of("src/main/resources/db/migration/V978__sales_manager_review_before_finance.sql"));
        jdbc.update(migrationStatement(migration,"UPDATE sales_quotes SET manager_review_state")+" AND id IN (?,?,?)",pending.getId(),closed.getId(),past.getId());
        jdbc.update(migrationStatement(migration,"UPDATE sales_orders SET manager_review_state")+" AND id IN (?,?,?)",pendingOrder.getId(),pastOrder.getId(),rejectedOrder.getId());
        jdbc.update(migrationStatement(migration,"UPDATE task_claims SET")+" AND id IN (?,?)",quoteLease.claimId(),orderLease.claimId());
        jdbc.update(migrationStatement(migration,"UPDATE notices SET resolved_at")+" AND id IN (?,?)",quoteNotice.getId(),orderNotice.getId());
        assertThat(jdbc.queryForObject("SELECT manager_review_state FROM sales_quotes WHERE id=?",String.class,pending.getId())).isEqualTo("PENDING");
        assertThat(jdbc.queryForObject("SELECT manager_review_state FROM sales_orders WHERE id=?",String.class,pendingOrder.getId())).isEqualTo("PENDING");
        assertThat(jdbc.queryForList("SELECT manager_review_state FROM sales_quotes WHERE id IN (?,?)",String.class,closed.getId(),past.getId())).containsOnly("NOT_REQUIRED");
        assertThat(jdbc.queryForObject("SELECT manager_review_state='NOT_REQUIRED' AND finance_rejected FROM sales_orders WHERE id=?",Boolean.class,rejectedOrder.getId())).isTrue();
        assertThat(jdbc.queryForObject("SELECT finance_confirmed_at::text FROM sales_quotes WHERE id=?",String.class,past.getId())).isEqualTo(previousQuoteAt);
        assertThat(jdbc.queryForObject("SELECT finance_confirmed_at::text FROM sales_orders WHERE id=?",String.class,pastOrder.getId())).isEqualTo(previousOrderAt);
        assertThat(jdbc.queryForObject("SELECT count(*) FROM task_claims WHERE id IN (?,?) AND released_at IS NOT NULL AND release_reason='workflow_changed'",Long.class,quoteLease.claimId(),orderLease.claimId())).isEqualTo(2);
        assertThat(jdbc.queryForObject("SELECT count(*) FROM notices WHERE id IN (?,?) AND resolved_at IS NOT NULL",Long.class,quoteNotice.getId(),orderNotice.getId())).isEqualTo(2);
    }

    private static String migrationStatement(String migration,String prefix) {
        int start=migration.indexOf(prefix);
        if(start<0) throw new IllegalArgumentException("Missing migration statement: "+prefix);
        return migration.substring(start,migration.indexOf(';',start));
    }

    private record Fixture(UUID sales, UUID masked, UUID finance, UUID outsider,
                           UUID client, UUID maskedClient) {
    }

    private Fixture fixture(String tag) {
        baseCurrency();
        String suffix = tag + SEQ.incrementAndGet();
        UUID salesDept = department("QS-" + suffix);
        UUID outsiderDept = department("QO-" + suffix);
        grantDepartment(outsiderDept, "sales_quote_finance:view", "sales_quote_finance:confirm", "sales_quote:view");
        UUID financeDept = jdbc.queryForObject(
                "SELECT id FROM departments WHERE code = 'DEPT_FIN' AND is_deleted = FALSE LIMIT 1", UUID.class);
        List<String> salesPerms = new ArrayList<>(SALES_PERMS);
        salesPerms.add("sales_order:price:view");
        UUID sales = user("qs-" + suffix, salesDept, salesPerms);
        UUID masked = user("qm-" + suffix, salesDept, SALES_PERMS);
        UUID financeUser = user("qf-" + suffix, financeDept, List.of(
                "sales_quote_finance:view", "sales_quote_finance:confirm", "sales_quote_finance:reject", "sales_quote_finance:reverse", "sales_quote:view",
                "sales_order_finance:view", "sales_order_finance:confirm", "sales_order:view", "notice:read"));
        UUID outsider = user("qx-" + suffix, outsiderDept, List.of("notice:read"));
        return new Fixture(sales, masked, financeUser, outsider,
                client("QC-" + suffix, employeeOf(sales)), client("QM-" + suffix, employeeOf(masked)));
    }

    private UUID department(String code) {
        UUID id = UUID.randomUUID();
        jdbc.update("insert into departments(id, code, name, level) values (?, ?, ?, '一级部门')",
                id, code, "报价核价测试部门-" + code);
        return id;
    }

    private void grantDepartment(UUID departmentId, String... codes) {
        for (String code : codes) {
            jdbc.update("""
                    insert into department_permissions(department_id, permission_id)
                    select ?, p.id from permissions p where p.code = ?
                    """, departmentId, code);
        }
    }

    private UUID user(String login, UUID departmentId, List<String> perms) {
        UUID employee = UUID.randomUUID();
        UUID user = UUID.randomUUID();
        jdbc.update("""
                insert into employees(id, code, full_name, id_type, department_id, hire_date, status, employment_type)
                values (?, ?, ?, '其他', ?, DATE '2026-01-01', 'active', 'regular')
                """, employee, "EMP-" + login, "员工-" + login, departmentId);
        jdbc.update("""
                insert into users(id, employee_id, login_account, password_hash, must_change_password, is_super_admin, status)
                values (?, ?, ?, 'x', false, false, 'active')
                """, user, employee, login);
        for (String code : perms) {
            int granted = jdbc.update("""
                    WITH actor AS (SELECT set_config('app.actor_id',(SELECT id::text FROM users WHERE is_super_admin AND NOT is_deleted LIMIT 1),true))
                    insert into user_permission_overrides(user_id, permission_id, effect)
                    select ?, p.id, 'grant' from permissions p CROSS JOIN actor where p.code = ?
                    """, user, code);
            assertThat(granted).as("permission %s exists", code).isEqualTo(1);
        }
        return user;
    }

    private UUID client(String code, UUID ownerEmployee) {
        UUID id = UUID.randomUUID();
        jdbc.update("""
                insert into clients(id, code, name, status, code_sequence, owner_employee_id)
                values (?, ?, ?, '使用', (select coalesce(max(code_sequence), 0) + 1 from clients), ?)
                """, id, code, "报价核价测试客户-" + code, ownerEmployee);
        return id;
    }

    private UUID goods(String name, BigDecimal price) {
        UUID unit = UUID.randomUUID();
        String tag = UUID.randomUUID().toString().substring(0, 8);
        jdbc.update("insert into units(id, code, name, status) values (?, ?, '个', '使用')", unit, "U-Q-" + tag);
        UUID id = UUID.randomUUID();
        jdbc.update("""
                insert into goods(id, code, name, source_type, status, unit_id, price, code_sequence)
                values (?, ?, ?, '自制', '使用', ?, ?, (select coalesce(max(code_sequence), 0) + 1 from goods))
                """, id, "G-Q-" + tag, name + "-" + tag, unit, price);
        return id;
    }

    private UUID unitOf(UUID goods) {
        return jdbc.queryForObject("SELECT unit_id FROM goods WHERE id = ?", UUID.class, goods);
    }

    private UUID employeeOf(UUID user) {
        return jdbc.queryForObject("SELECT employee_id FROM users WHERE id = ?", UUID.class, user);
    }

    private UUID baseCurrency() {
        List<UUID> base = jdbc.queryForList("""
                SELECT id FROM currencies WHERE is_base_currency AND status = '使用' AND NOT is_deleted
                """, UUID.class);
        if (!base.isEmpty()) return base.getFirst();
        UUID id = UUID.randomUUID();
        jdbc.update("""
                insert into currencies(id, code, name, exchange_rate, status, is_base_currency)
                values (?, 'CNY-QT', '人民币', 1, '使用', TRUE)
                """, id);
        return id;
    }

    /** 美元币种资料(任何写法: 美元/美金/USD)一律设成给定的财务参考汇率; 没有就新建一条。 */
    private void ensureUsd(String rate) {
        baseCurrency();
        int updated = jdbc.update("""
                UPDATE currencies SET exchange_rate = ?, status = '使用'
                WHERE NOT is_deleted AND NOT is_base_currency
                  AND (name IN ('美元', '美金') OR upper(code) IN ('USD', 'US$'))
                """, new BigDecimal(rate));
        if (updated == 0) {
            jdbc.update("""
                    insert into currencies(id, code, name, exchange_rate, status)
                    values (?, 'USD-QT', '美元', ?, '使用')
                    """, UUID.randomUUID(), new BigDecimal(rate));
        }
    }

    private List<BigDecimal> storedDiscounts(UUID quoteId) {
        return jdbc.queryForList(
                "SELECT discount FROM sales_quote_items WHERE quote_id = ? ORDER BY line_no", BigDecimal.class, quoteId);
    }

    private long pendingQuoteReviews(Fixture f) {
        UUID previous = currentUserId();
        loginAs(f.finance());
        long count = finance.pendingCount().get("pending");
        if (previous != null) loginAs(previous);
        return count;
    }

    private void loginAs(UUID userId) {
        Map<String, Object> u = jdbc.queryForMap(
                "SELECT employee_id, login_account, is_super_admin FROM users WHERE id = ?", userId);
        UUID employeeId = (UUID) u.get("employee_id");
        boolean superAdmin = Boolean.TRUE.equals(u.get("is_super_admin"));
        PermissionResolver.AuthorizationSnapshot snapshot =
                permissionResolver.authorizationSnapshot(userId, employeeId, superAdmin);
        AuthUser authUser = new AuthUser(userId, employeeId, (String) u.get("login_account"),
                snapshot.permissions(), false, true, superAdmin);
        SecurityContextHolder.getContext().setAuthentication(
                new UsernamePasswordAuthenticationToken(authUser, null, authUser.getAuthorities()));
    }

    private UUID currentUserId() {
        var auth = SecurityContextHolder.getContext().getAuthentication();
        return auth != null && auth.getPrincipal() instanceof AuthUser user ? user.getId() : null;
    }

    private java.util.Set<String> currentPermissions() {
        return ((AuthUser) SecurityContextHolder.getContext().getAuthentication().getPrincipal()).getPermissions();
    }

    private static QuoteSaveRequest quoteRequest(UUID clientId, QuoteItemLine... lines) {
        QuoteSaveRequest request = new QuoteSaveRequest();
        request.setBillDate(LocalDate.of(2026, 9, 27));
        request.setClientId(clientId);
        request.setItems(new ArrayList<>(List.of(lines)));
        return request;
    }

    private QuoteItemLine line(UUID goods, String qty, String previewPrice, String discount, String clientPrice) {
        QuoteItemLine line = new QuoteItemLine();
        line.setGoodsId(goods);
        line.setUnitId(unitOf(goods));
        line.setUnitRate(BigDecimal.ONE);
        line.setQty(new BigDecimal(qty));
        line.setPrice(previewPrice == null ? null : new BigDecimal(previewPrice));
        line.setDiscount(discount == null ? null : new BigDecimal(discount));
        line.setClientPrice(clientPrice == null ? null : new BigDecimal(clientPrice));
        return line;
    }

    /** 按已保存详情重建保存请求(带行 id, 价格留空), 表头沿用原请求。 */
    private static QuoteSaveRequest copy(QuoteDetail detail, QuoteSaveRequest header) {
        QuoteSaveRequest request = new QuoteSaveRequest();
        request.setExpectedRevision(detail.getReviewRevision());
        request.setBillDate(header.getBillDate());
        request.setClientId(header.getClientId());
        request.setContractNo(header.getContractNo());
        request.setClientFileCurrency(header.getClientFileCurrency());
        request.setSellerId(header.getSellerId());
        request.setDeliverDate(header.getDeliverDate());
        List<QuoteItemLine> lines = new ArrayList<>();
        for (QuoteItemDto item : detail.getItems()) {
            QuoteItemLine line = new QuoteItemLine();
            line.setId(item.getId());
            line.setGoodsId(item.getGoodsId());
            line.setUnitId(item.getUnitId());
            line.setUnitRate(item.getUnitRate());
            line.setQty(item.getQty());
            line.setDiscount(item.getDiscount());
            line.setClientPrice(item.getClientPrice());
            line.setRemark(item.getRemark());
            lines.add(line);
        }
        request.setItems(lines);
        return request;
    }

    private OrderDetail acceptAndConvert(UUID id) {
        QuoteDetail current = quotes.detail(id);
        QuoteDetail accepted = quotes.customerConfirm(id, new QuoteActionRequest(current.getReviewRevision()));
        return quotes.convertToOrder(id, new QuoteActionRequest(accepted.getReviewRevision()));
    }

    private static OrderSaveRequest orderRequest(OrderDetail order) {
        OrderSaveRequest request = new OrderSaveRequest();
        request.setBillDate(order.getBillDate());
        request.setClientId(order.getClientId());
        request.setCurrencyId(order.getCurrencyId());
        request.setSellerId(order.getSellerId());
        request.setDeliverDate(order.getDeliverDate());
        request.setContractNo(order.getContractNo());
        request.setClientFileCurrency(order.getClientFileCurrency());
        request.setShipmentPolicy("ALLOW_PARTIAL");
        List<OrderItemLine> lines = new ArrayList<>();
        for (OrderItemDto item : order.getItems()) {
            OrderItemLine line = new OrderItemLine();
            line.setId(item.getId());
            line.setGoodsId(item.getGoodsId());
            line.setUnitId(item.getUnitId());
            line.setUnitRate(item.getUnitRate());
            line.setQty(item.getQty());
            line.setDiscount(item.getDiscount());
            line.setClientPrice(item.getClientPrice());
            line.setClientModel(item.getClientModel());
            line.setClientGoodsName(item.getClientGoodsName());
            lines.add(line);
        }
        request.setItems(lines);
        return request;
    }

    private static QuoteFinanceEditRequest edit(int revision, UUID claimId, List<QuoteFinanceEditRequest.Line> lines) {
        return new QuoteFinanceEditRequest(revision, claimId, null, null, null, lines);
    }

    private static void assertConflict(Runnable action) {
        assertCode(action, ErrorCode.CONFLICT);
    }

    private static void assertForbidden(Runnable action) {
        assertCode(action, ErrorCode.FORBIDDEN);
    }

    private static void assertNotFound(Runnable action) {
        assertCode(action, ErrorCode.NOT_FOUND);
    }

    private static void assertBusiness(Runnable action) {
        assertCode(action, ErrorCode.BUSINESS);
    }

    private static void assertCode(Runnable action, ErrorCode code) {
        assertThatThrownBy(action::run)
                .isInstanceOf(ApiException.class)
                .extracting(error -> ((ApiException) error).getCode())
                .isEqualTo(code);
    }

}
