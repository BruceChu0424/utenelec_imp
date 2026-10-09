package com.uten.imp.features.notice;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.BusinessEventPublisher;
import com.uten.imp.application.port.FinanceReviewerEligibilityPort;
import com.uten.imp.features.admin.workflow.SalesOrderFinanceConfirmerEligibility;
import com.uten.imp.features.auth.PermissionResolver;
import com.uten.imp.features.auth.model.UserAccount;
import com.uten.imp.features.auth.model.UserAccountRepository;
import com.uten.imp.features.rd_task.RdTaskService;
import org.junit.jupiter.api.Test;
import org.springframework.jdbc.core.JdbcTemplate;

import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;

import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

class SalesOrderReviewNoticeLifecycleTest {
    @Test void cancellationClosesExistingCardsInTheBusinessTransactionBeforeOutboxDelivery() {
        var f = new Fixture();
        f.service.notifyOrderCanceled(f.order);
        var calls = inOrder(f.notices, f.outbox);
        calls.verify(f.notices).resolveReviewNotices("SALES_ORDER", f.order, "CANCELLED");
        calls.verify(f.outbox).publish(ChainNoticeService.EVENT_ORDER_CANCELED, "SALES_ORDER", f.order, Map.of());
    }

    @Test void delayedApprovalEventCannotRecreateCardsAfterCancellationOrRequotation() {
        var f = new Fixture();
        f.pending = false;
        f.deliver(ChainNoticeService.EVENT_ORDER_PENDING_FINANCE);
        verifyNoInteractions(f.notices, f.reviewers);
    }

    @Test void delayedCancellationDoesNotCloseAResumedOrdersCurrentReview() {
        var f = new Fixture();
        f.terminated = false;
        f.deliver(ChainNoticeService.EVENT_ORDER_CANCELED);
        verifyNoInteractions(f.notices);
    }

    @Test void delayedFinanceApprovalCannotCreatePlanningCardsForATerminatedOrder() {
        var f = new Fixture();
        f.deliver(ChainNoticeService.EVENT_ORDER_FINANCE_CONFIRMED);
        verifyNoInteractions(f.notices);
        verify(f.jdbc, never()).queryForList(contains("SELECT bill_no, owner_employee_id, seller_id"), eq(f.order));
    }

    @Test void financeConfirmationGivesTheOrderOwnerAReceiptThatCatchUpNeverRepeats() {
        var f = new Fixture();
        f.confirmed = true;
        f.deliver(ChainNoticeService.EVENT_ORDER_FINANCE_CONFIRMED);
        verify(f.notices).publishForUser(eq(f.userId), anyString(), anyString(),
                eq(ChainNoticeService.TYPE_WORKFLOW), anyString(),
                eq("/sales/orders/" + f.order), eq(ChainNoticeService.EVENT_ORDER_FINANCE_CONFIRMED));
        // V825 补发复核走独立事件，不得重发销售回执（同一确认只收一条）。
        f.deliver(ChainNoticeService.EVENT_SALES_PLANNING_CATCH_UP);
        verify(f.notices, times(1)).publishForUser(eq(f.userId), anyString(), anyString(),
                eq(ChainNoticeService.TYPE_WORKFLOW), anyString(),
                eq("/sales/orders/" + f.order), eq(ChainNoticeService.EVENT_ORDER_FINANCE_CONFIRMED));
    }

    @Test void pendingEventsKeepOneActiveCardPerReviewerButCanNotifyAfterPreviousCardWasResolved() {
        var f = new Fixture();
        f.deliver(ChainNoticeService.EVENT_ORDER_PENDING_FINANCE);
        f.deliver(ChainNoticeService.EVENT_ORDER_PENDING_FINANCE);
        f.verifyApprovalCount(1);
        f.hasPendingCard = false;
        f.deliver(ChainNoticeService.EVENT_ORDER_PENDING_FINANCE);
        f.verifyApprovalCount(2);
    }

    @Test void deliveredCancellationAlsoClearsHistoricalPendingCards() {
        var f = new Fixture();
        f.terminated = true;
        f.deliver(ChainNoticeService.EVENT_ORDER_CANCELED);
        verify(f.notices).resolveReviewNotices("SALES_ORDER", f.order, "CANCELLED");
    }

    private static final class Fixture {
        final UUID order = UUID.randomUUID(), employee = UUID.randomUUID(), userId = UUID.randomUUID();
        final JdbcTemplate jdbc = mock(JdbcTemplate.class);
        final NoticeService notices = mock(NoticeService.class);
        final BusinessEventPublisher outbox = mock(BusinessEventPublisher.class);
        final SalesOrderFinanceConfirmerEligibility reviewers = mock(SalesOrderFinanceConfirmerEligibility.class);
        final ChainNoticeService service;
        boolean pending = true, terminated, hasPendingCard, confirmed;

        Fixture() {
            var users = mock(UserAccountRepository.class);
            var permissions = mock(PermissionResolver.class);
            var user = new UserAccount(); user.setId(userId); user.setStatus("active"); user.setDeleted(false);
            when(users.findByEmployeeId(employee)).thenReturn(Optional.of(user));
            when(users.findById(userId)).thenReturn(Optional.of(user));
            when(permissions.grantedPermsOf(user)).thenReturn(Set.of("notice:read"));
            when(reviewers.eligibleUserIds()).thenReturn(List.of(userId));
            when(jdbc.queryForList(contains("AND finance_confirmed = ? AND NOT finance_rejected"), eq(order), eq(false)))
                    .thenAnswer(call -> pending ? List.of(Map.of("id", order)) : List.of());
            when(jdbc.queryForList(contains("AND finance_confirmed = ? AND NOT finance_rejected"), eq(order), eq(true)))
                    .thenAnswer(call -> confirmed ? List.of(Map.of("id", order)) : List.of());
            when(jdbc.queryForList(contains("AND (is_deleted OR status = -1 OR is_stopped"), eq(order)))
                    .thenAnswer(call -> terminated ? List.of(Map.of("id", order)) : List.of());
            when(jdbc.queryForList(contains("SELECT bill_no, owner_employee_id, seller_id"), eq(order)))
                    .thenReturn(List.of(Map.of("bill_no", "XD-REVIEW", "owner_employee_id", employee)));
            when(jdbc.queryForObject(contains("SELECT finance_review_revision"), eq(Long.class), eq(order)))
                    .thenReturn(0L);
            when(jdbc.queryForObject(contains("SELECT EXISTS(SELECT 1 FROM notices"), eq(Boolean.class),
                    eq(order), eq(ChainNoticeService.EVENT_ORDER_PENDING_FINANCE), eq(userId)))
                    .thenAnswer(call -> hasPendingCard);
            when(notices.publishForUser(eq(userId), anyString(), anyString(), eq(ChainNoticeService.TYPE_APPROVAL),
                    anyString(), anyString(), eq(ChainNoticeService.EVENT_ORDER_PENDING_FINANCE), isNull(), eq(order)))
                    .thenAnswer(call -> { hasPendingCard = true; return null; });
            service = new ChainNoticeService(notices, users, permissions, jdbc, outbox,
                    mock(RdTaskService.class), mock(FinanceReviewerEligibilityPort.class), reviewers);
            // 真实 Spring 上下文由 setter 注入；单测给「无初始接手需求」桩，
            // 让确认事件投递停在销售回执之后、不进计划接手分支。
            var planningSources = mock(com.uten.imp.application.port.SalesPlanningNoticeReadPort.class);
            when(planningSources.needsInitialHandoff(any())).thenReturn(false);
            service.setPlanningSources(planningSources);
        }

        void deliver(String event) { service.deliverOutboxEvent(event, order, new ObjectMapper().createObjectNode()); }

        void verifyApprovalCount(int expected) {
            verify(notices, times(expected)).publishForUser(eq(userId), anyString(), anyString(),
                    eq(ChainNoticeService.TYPE_APPROVAL), anyString(), anyString(),
                    eq(ChainNoticeService.EVENT_ORDER_PENDING_FINANCE), isNull(), eq(order));
        }
    }
}
