package com.uten.imp.features.notice;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.BusinessEventPublisher;
import com.uten.imp.application.port.FinanceReviewerEligibilityPort;
import com.uten.imp.features.admin.workflow.SalesOrderFinanceConfirmerEligibility;
import com.uten.imp.features.auth.PermissionResolver;
import com.uten.imp.features.auth.model.UserAccount;
import com.uten.imp.features.auth.model.UserAccountRepository;
import com.uten.imp.features.rbac.UserRoleRepository;
import com.uten.imp.features.rd_task.RdTaskService;
import org.junit.jupiter.api.Test;
import org.springframework.jdbc.core.JdbcTemplate;

import java.math.BigDecimal;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;

import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.argThat;
import static org.mockito.ArgumentMatchers.contains;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.when;

class ProcurementIqcRejectionNoticeTest {

    private static final ObjectMapper JSON = new ObjectMapper();
    private static final String NOTICE_READ = "notice:read";
    private static final String VIEW = "procurement_iqc_rejection:view";
    private static final String VIEW_ALL = "procurement_iqc_rejection:view_all";
    private static final String CONFIRM =
            "procurement_iqc_rejection:confirm_credit";
    private static final String RECORD_RETURN =
            "procurement_iqc_rejection:record_return";
    private static final String CLOSE =
            "procurement_iqc_rejection:close_no_credit";

    @Test
    void detectedProjectionTriggerIsExplicitlySilent() {
        NoticeService notice = mock(NoticeService.class);
        JdbcTemplate jdbc = mock(JdbcTemplate.class);
        ChainNoticeService service = service(
                notice,
                mock(UserAccountRepository.class),
                mock(PermissionResolver.class),
                jdbc);

        service.deliverOutboxEvent(
                ChainNoticeService.EVENT_PROCUREMENT_IQC_REJECTION_DETECTED,
                UUID.randomUUID(),
                JSON.createObjectNode());

        verifyNoInteractions(notice, jdbc);
    }

    @Test
    void openedIncludesReturnQueueWhileFinanceExceptionStaysFinanceScoped() {
        UUID caseId = UUID.randomUUID();
        UUID owner = UUID.randomUUID();
        UUID allCase = UUID.randomUUID();
        UUID confirmer = UUID.randomUUID();
        UUID closer = UUID.randomUUID();
        UUID returnOperator = UUID.randomUUID();
        UUID ordinaryViewer = UUID.randomUUID();
        UUID actionWithoutView = UUID.randomUUID();
        UUID confirmWithoutNotice = UUID.randomUUID();
        Fixture fixture = fixture(caseId, owner, Map.of(
                owner, Set.of(NOTICE_READ, VIEW),
                allCase, Set.of(NOTICE_READ, VIEW, VIEW_ALL),
                confirmer, Set.of(NOTICE_READ, VIEW, CONFIRM),
                closer, Set.of(NOTICE_READ, VIEW, CLOSE),
                returnOperator, Set.of(NOTICE_READ, VIEW, RECORD_RETURN),
                ordinaryViewer, Set.of(NOTICE_READ, VIEW),
                actionWithoutView, Set.of(NOTICE_READ, CONFIRM),
                confirmWithoutNotice, Set.of(CONFIRM)));

        String opened = ChainNoticeService.EVENT_PROCUREMENT_IQC_REJECTION_OPENED;
        fixture.service().deliverOutboxEvent(opened, caseId, JSON.createObjectNode());
        verifyRecipient(fixture.notice(), allCase, caseId, opened);
        verifyRecipient(fixture.notice(), confirmer, caseId, opened);
        verifyRecipient(fixture.notice(), closer, caseId, opened);
        verifyRecipient(fixture.notice(), returnOperator, caseId, opened);
        verifyRecipient(fixture.notice(), owner, caseId, opened);

        String financeException =
                ChainNoticeService.EVENT_PROCUREMENT_IQC_REJECTION_FINANCE_EXCEPTION;
        fixture.service().deliverOutboxEvent(
                financeException, caseId, JSON.createObjectNode());
        verifyRecipient(fixture.notice(), allCase, caseId, financeException);
        verifyRecipient(fixture.notice(), confirmer, caseId, financeException);
        verifyRecipient(fixture.notice(), closer, caseId, financeException);
        verifyNotRecipientForEvent(
                fixture.notice(), returnOperator, financeException);
        verifyNotRecipientForEvent(fixture.notice(), owner, financeException);
        verifyNotRecipient(fixture.notice(), ordinaryViewer);
        verifyNotRecipient(fixture.notice(), actionWithoutView);
        verifyNotRecipient(fixture.notice(), confirmWithoutNotice);
    }

    @Test
    void returnedTargetsOnlyCreditOrNoCreditDecisionUsersWithNoticeRead() {
        UUID caseId = UUID.randomUUID();
        UUID owner = UUID.randomUUID();
        UUID confirmer = UUID.randomUUID();
        UUID closer = UUID.randomUUID();
        UUID allCaseWithoutDecision = UUID.randomUUID();
        UUID closerWithoutNotice = UUID.randomUUID();
        Fixture fixture = fixture(caseId, owner, Map.of(
                owner, Set.of(NOTICE_READ, VIEW),
                confirmer, Set.of(NOTICE_READ, VIEW, CONFIRM),
                closer, Set.of(NOTICE_READ, VIEW, CLOSE),
                allCaseWithoutDecision, Set.of(NOTICE_READ, VIEW_ALL),
                closerWithoutNotice, Set.of(CLOSE)));

        fixture.service().deliverOutboxEvent(
                ChainNoticeService.EVENT_PROCUREMENT_IQC_REJECTION_RETURNED,
                caseId,
                JSON.createObjectNode());

        verifyRecipient(
                fixture.notice(),
                confirmer,
                caseId,
                ChainNoticeService.EVENT_PROCUREMENT_IQC_REJECTION_RETURNED);
        verifyRecipient(
                fixture.notice(),
                closer,
                caseId,
                ChainNoticeService.EVENT_PROCUREMENT_IQC_REJECTION_RETURNED);
        verifyRecipient(
                fixture.notice(),
                owner,
                caseId,
                ChainNoticeService.EVENT_PROCUREMENT_IQC_REJECTION_RETURNED);
        verifyNotRecipient(fixture.notice(), allCaseWithoutDecision);
        verifyNotRecipient(fixture.notice(), closerWithoutNotice);
    }

    @Test
    void terminalEventsReachViewAllAndReadableOwnerWithoutCommercialValues() {
        UUID caseId = UUID.randomUUID();
        UUID owner = UUID.randomUUID();
        UUID allCase = UUID.randomUUID();
        UUID unrelatedOrdinaryViewer = UUID.randomUUID();
        UUID actionOnly = UUID.randomUUID();
        Fixture fixture = fixture(caseId, owner, Map.of(
                owner, Set.of(NOTICE_READ, VIEW),
                allCase, Set.of(NOTICE_READ, VIEW_ALL),
                unrelatedOrdinaryViewer, Set.of(NOTICE_READ, VIEW),
                actionOnly, Set.of(NOTICE_READ, CONFIRM)));

        for (String event : List.of(
                ChainNoticeService.EVENT_PROCUREMENT_IQC_CREDIT_CONFIRMED,
                ChainNoticeService.EVENT_PROCUREMENT_IQC_REJECTION_NO_CREDIT,
                ChainNoticeService.EVENT_PROCUREMENT_IQC_REJECTION_REVERSED)) {
            fixture.service().deliverOutboxEvent(
                    event, caseId, JSON.createObjectNode());
            verifyRecipient(fixture.notice(), owner, caseId, event);
            verifyRecipient(fixture.notice(), allCase, caseId, event);
        }
        verifyNotRecipient(fixture.notice(), unrelatedOrdinaryViewer);
        verifyNotRecipient(fixture.notice(), actionOnly);
    }

    private static Fixture fixture(
            UUID caseId,
            UUID owner,
            Map<UUID, Set<String>> permissionsByUser) {
        NoticeService notice = mock(NoticeService.class);
        UserAccountRepository users = mock(UserAccountRepository.class);
        PermissionResolver permissions = mock(PermissionResolver.class);
        JdbcTemplate jdbc = mock(JdbcTemplate.class);
        when(jdbc.queryForList(
                contains("FROM procurement_iqc_rejection_cases rejection"),
                eq(caseId))).thenReturn(List.of(Map.of(
                        "receipt_type", "PURCHASE",
                        "receipt_bill_no", "CR-IQC-001",
                        "order_bill_no", "CG-IQC-001",
                        "status", "RETURN_RECORDED",
                        "owner_user_id", owner,
                        "failed_qty", new BigDecimal("2.5000"),
                        "goods_code", "WL-001",
                        "goods_name", "测试物料",
                        "unit_name", "件")));

        List<UserAccount> accounts = new ArrayList<>();
        for (Map.Entry<UUID, Set<String>> entry : permissionsByUser.entrySet()) {
            UserAccount account = activeUser(entry.getKey());
            accounts.add(account);
            when(users.findById(entry.getKey())).thenReturn(Optional.of(account));
            when(permissions.permsOf(account)).thenReturn(entry.getValue());
        }
        when(users.findAll()).thenReturn(accounts);
        return new Fixture(
                service(notice, users, permissions, jdbc),
                notice);
    }

    private static ChainNoticeService service(
            NoticeService notice,
            UserAccountRepository users,
            PermissionResolver permissions,
            JdbcTemplate jdbc) {
        return new ChainNoticeService(
                notice,
                users,
                permissions,
                mock(UserRoleRepository.class),
                jdbc,
                mock(BusinessEventPublisher.class),
                mock(RdTaskService.class),
                mock(FinanceReviewerEligibilityPort.class),
                mock(SalesOrderFinanceConfirmerEligibility.class));
    }

    private static void verifyRecipient(
            NoticeService notice,
            UUID userId,
            UUID caseId,
            String event) {
        verify(notice).publishForUser(
                eq(userId),
                anyString(),
                argThat(content -> content != null
                        && !content.contains("金额")
                        && !content.contains("单价")
                        && !content.contains("汇率")
                        && !content.contains("1200.00")),
                anyString(),
                anyString(),
                eq("/procurement/iqc-rejections/" + caseId),
                eq(event));
    }

    private static void verifyNotRecipient(
            NoticeService notice, UUID userId) {
        verify(notice, never()).publishForUser(
                eq(userId),
                anyString(),
                anyString(),
                anyString(),
                anyString(),
                anyString(),
                anyString());
    }

    private static void verifyNotRecipientForEvent(
            NoticeService notice, UUID userId, String event) {
        verify(notice, never()).publishForUser(
                eq(userId),
                anyString(),
                anyString(),
                anyString(),
                anyString(),
                anyString(),
                eq(event));
    }

    private static UserAccount activeUser(UUID id) {
        UserAccount user = new UserAccount();
        user.setId(id);
        user.setStatus("active");
        user.setDeleted(false);
        return user;
    }

    private record Fixture(
            ChainNoticeService service,
            NoticeService notice) {
    }
}
