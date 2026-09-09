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

import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.argThat;
import static org.mockito.ArgumentMatchers.contains;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.when;
import static org.mockito.Mockito.times;
import static org.mockito.Mockito.clearInvocations;
import static org.mockito.Mockito.mockingDetails;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;

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
    void thousandCandidateAudienceResolvesOncePerUserAndRechecksNextEvent() {
        var users = mock(UserAccountRepository.class);
        var permissions = mock(PermissionResolver.class);
        var accounts = new ArrayList<UserAccount>();
        for (int index = 0; index < 1000; index++) {
            var account = activeUser(UUID.randomUUID());
            accounts.add(account);
            when(users.findById(account.getId())).thenReturn(Optional.of(account));
            when(permissions.permsOf(account)).thenReturn(Set.of(NOTICE_READ, VIEW, CONFIRM));
        }
        when(users.findAll()).thenReturn(accounts);
        var service = service(mock(NoticeService.class), users, permissions, mock(JdbcTemplate.class));
        Set<UUID> first = org.springframework.test.util.ReflectionTestUtils.invokeMethod(
                service, "userIdsWithIqcViewAndAnyPermission", (Object) new String[]{CONFIRM});
        assertEquals(1000, first.size());
        assertEquals(1000, mockingDetails(permissions).getInvocations().size(),
                "旧的两轮判断调用 2000 次；同一事件必须只完整解析 1000 次");
        verify(users, never()).findById(any());

        // Offboard/disabled and deleted accounts remain excluded before permission lookup,
        // even if their stale account object still carries the super-admin flag.
        accounts.get(0).setSuperAdmin(true); accounts.get(0).setStatus("disabled");
        accounts.get(1).setSuperAdmin(true); accounts.get(1).setDeleted(true);
        when(permissions.permsOf(accounts.get(2))).thenReturn(Set.of(NOTICE_READ, VIEW));
        when(permissions.permsOf(accounts.get(3))).thenReturn(Set.of(NOTICE_READ, CONFIRM));
        clearInvocations(users, permissions);
        Set<UUID> next = org.springframework.test.util.ReflectionTestUtils.invokeMethod(
                service, "userIdsWithIqcViewAndAnyPermission", (Object) new String[]{CONFIRM});
        assertEquals(996, next.size());
        for (int index = 0; index < 4; index++) assertFalse(next.contains(accounts.get(index).getId()));
        verify(permissions, never()).permsOf(accounts.get(0));
        verify(permissions, never()).permsOf(accounts.get(1));
        verify(permissions, times(1)).permsOf(accounts.get(2));
        assertEquals(998, mockingDetails(permissions).getInvocations().size());
    }

    @Test
    void administratorCatalogIsSharedOnlyInsideCurrentAudienceResolution() {
        var users = mock(UserAccountRepository.class);
        var permissions = mock(PermissionResolver.class);
        var accounts = new ArrayList<UserAccount>();
        for (int index = 0; index < 164; index++) {
            var account = activeUser(UUID.randomUUID()); account.setSuperAdmin(true); accounts.add(account);
        }
        when(users.findAll()).thenReturn(accounts);
        when(permissions.permsOf(any())).thenReturn(Set.of(NOTICE_READ, VIEW, CONFIRM));
        var service = service(mock(NoticeService.class), users, permissions, mock(JdbcTemplate.class));
        Set<UUID> first = org.springframework.test.util.ReflectionTestUtils.invokeMethod(
                service, "userIdsWithIqcViewAndAnyPermission", (Object) new String[]{CONFIRM});
        assertEquals(164, first.size());
        verify(permissions, times(1)).permsOf(any());
        when(permissions.permsOf(any())).thenReturn(Set.of(NOTICE_READ, VIEW));
        Set<UUID> next = org.springframework.test.util.ReflectionTestUtils.invokeMethod(
                service, "userIdsWithIqcViewAndAnyPermission", (Object) new String[]{CONFIRM});
        assertEquals(Set.of(), next);
        verify(permissions, times(2)).permsOf(any());
    }

    @Test
    void positiveCandidatesStillRequireCurrentPageActionAndAccountState() {
        var users = mock(UserAccountRepository.class);
        var permissions = mock(PermissionResolver.class);
        var query = mock(NoticePermissionCandidateQuery.class);
        var eligible = activeUser(UUID.randomUUID());
        var revoked = activeUser(UUID.randomUUID());
        var disabled = activeUser(UUID.randomUUID()); disabled.setStatus("disabled"); disabled.setSuperAdmin(true);
        var lateGrant = activeUser(UUID.randomUUID());
        var initialIds = Set.of(eligible.getId(), revoked.getId(), disabled.getId());
        when(query.possibleUsers(Set.of(CONFIRM))).thenReturn(Optional.of(initialIds));
        when(users.findAllById(initialIds)).thenReturn(List.of(eligible, revoked, disabled));
        when(permissions.permsOf(eligible)).thenReturn(Set.of(NOTICE_READ, VIEW, CONFIRM));
        when(permissions.permsOf(revoked)).thenReturn(Set.of(NOTICE_READ, VIEW));
        var service = new ChainNoticeService(mock(NoticeService.class), users, permissions,
                mock(UserRoleRepository.class), mock(JdbcTemplate.class), mock(BusinessEventPublisher.class),
                mock(RdTaskService.class), mock(FinanceReviewerEligibilityPort.class),
                mock(SalesOrderFinanceConfirmerEligibility.class), query);
        Set<UUID> first = org.springframework.test.util.ReflectionTestUtils.invokeMethod(
                service, "userIdsWithIqcViewAndAnyPermission", (Object)new String[]{CONFIRM});
        assertEquals(Set.of(eligible.getId()), first);
        verify(users, never()).findAll();
        verify(permissions, never()).permsOf(disabled);
        when(query.possibleUsers(Set.of(CONFIRM))).thenReturn(Optional.of(Set.of(lateGrant.getId())));
        when(users.findAllById(Set.of(lateGrant.getId()))).thenReturn(List.of(lateGrant));
        when(permissions.permsOf(lateGrant)).thenReturn(Set.of(NOTICE_READ, VIEW, CONFIRM));
        Set<UUID> next = org.springframework.test.util.ReflectionTestUtils.invokeMethod(
                service, "userIdsWithIqcViewAndAnyPermission", (Object)new String[]{CONFIRM});
        assertEquals(Set.of(lateGrant.getId()), next, "each dispatch must re-read newly granted candidates");
    }

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
        // 行动卡事件（OPENED/RETURNED）走 9 参聚合重载（绑定拒收 case）；
        // 其余（财务异常/终态）走 7 参普通定向通知。
        boolean actionable =
                ChainNoticeService.EVENT_PROCUREMENT_IQC_REJECTION_OPENED.equals(event)
                || ChainNoticeService.EVENT_PROCUREMENT_IQC_REJECTION_RETURNED.equals(
                    event);
        if (actionable) {
            verify(notice).publishForUser(
                    eq(userId),
                    anyString(),
                    iqcContentMatcher(),
                    anyString(),
                    anyString(),
                    eq("/procurement/iqc-rejections/" + caseId),
                    eq(event),
                    any(),
                    any());
        } else {
            verify(notice).publishForUser(
                    eq(userId),
                    anyString(),
                    iqcContentMatcher(),
                    anyString(),
                    anyString(),
                    eq("/procurement/iqc-rejections/" + caseId),
                    eq(event));
        }
    }

    private static String iqcContentMatcher() {
        return org.mockito.ArgumentMatchers.argThat(content -> content != null
                && !content.contains("金额")
                && !content.contains("单价")
                && !content.contains("汇率")
                && !content.contains("1200.00"));
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
                anyString(),
                any(),
                any());
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
