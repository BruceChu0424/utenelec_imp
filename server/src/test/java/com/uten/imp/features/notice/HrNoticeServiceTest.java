package com.uten.imp.features.notice;

import com.uten.imp.features.auth.PermissionResolver;
import com.uten.imp.features.auth.model.UserAccount;
import com.uten.imp.features.auth.model.UserAccountRepository;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

import java.util.List;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.verifyNoMoreInteractions;
import static org.mockito.Mockito.when;

/**
 * HrNoticeService 契约（2026-09-10）：接收池解析（活跃账号 × notice:read × 职能权限，
 * 不限部门）、提交人/审核人排除、行动卡与目录聚合绑定、办结聚合、同事务失败传播。
 * NoticePermissionCandidateQuery 为 final 包内类，传 null 走 userRepo.findAll() 全量路径。
 */
class HrNoticeServiceTest {

    private NoticeService notices;
    private UserAccountRepository users;
    private PermissionResolver permissions;
    private HrNoticeService service;

    @BeforeEach
    void setUp() {
        notices = mock(NoticeService.class);
        users = mock(UserAccountRepository.class);
        permissions = mock(PermissionResolver.class);
        service = new HrNoticeService(notices, users, permissions, null);
    }

    @Test
    void audienceIsActiveEmployeeAccountsWithNoticeReadAndTheFunctionPermission() {
        UserAccount eligible = account(UUID.randomUUID(), "active", false,
                "notice:read", "expense:approve");
        UserAccount noNoticeRead = account(UUID.randomUUID(), "active", false,
                "expense:approve");
        UserAccount locked = account(UUID.randomUUID(), "locked", false,
                "notice:read", "expense:approve");
        UserAccount otherFunction = account(UUID.randomUUID(), "active", false,
                "notice:read", "expense:pay");
        UserAccount admin = account(UUID.randomUUID(), "active", true,
                "notice:read", "expense:approve", "expense:pay");
        UserAccount noEmployee = account(null, "active", false,
                "notice:read", "expense:approve");
        when(users.findAll()).thenReturn(List.of(
                eligible, noNoticeRead, locked, otherFunction, admin, noEmployee));
        UUID claimId = UUID.randomUUID();

        service.notifyExpenseClaimSubmitted(claimId, "张三", "100.00 元", UUID.randomUUID());

        verify(notices).publishForUser(eq(eligible.getId()), eq("报销单待审批"), anyString(),
                eq("task"), eq("财务"), eq("/expense/approval"),
                eq("EXPENSE_CLAIM_SUBMITTED"), eq("important"), eq(claimId));
        verify(notices).publishForUser(eq(admin.getId()), eq("报销单待审批"), anyString(),
                eq("task"), eq("财务"), eq("/expense/approval"),
                eq("EXPENSE_CLAIM_SUBMITTED"), eq("important"), eq(claimId));
        verifyNoMoreInteractions(notices);
    }

    @Test
    void submitterAndReviewerAreExcludedFromTheirOwnFollowUpCards() {
        UUID applicantEmployee = UUID.randomUUID();
        UserAccount applicant = account(applicantEmployee, "active", false,
                "notice:read", "expense:approve", "expense:pay", "payroll:publish",
                "suggestion:reply");
        UserAccount reviewer = account(UUID.randomUUID(), "active", false,
                "notice:read", "expense:approve", "expense:pay", "payroll:publish",
                "suggestion:reply");
        when(users.findAll()).thenReturn(List.of(applicant, reviewer));

        // 报销提交 / 审批通过：申请人本人不收审批卡与打款卡
        UUID claimId = UUID.randomUUID();
        service.notifyExpenseClaimSubmitted(claimId, "张三", "100.00 元", applicantEmployee);
        service.notifyExpenseClaimApproved(claimId, "张三", "100.00 元",
                applicant.getId(), applicantEmployee);
        verify(notices, never()).publishForUser(eq(applicant.getId()), eq("报销单待审批"),
                anyString(), anyString(), anyString(), anyString(), anyString(),
                anyString(), any(UUID.class));
        verify(notices, never()).publishForUser(eq(applicant.getId()), eq("报销单待打款"),
                anyString(), anyString(), anyString(), anyString(), anyString(),
                anyString(), any(UUID.class));
        verify(notices).publishForUser(eq(reviewer.getId()), eq("报销单待打款"), anyString(),
                eq("task"), eq("财务"), eq("/expense/approval"),
                eq("EXPENSE_CLAIM_PENDING_PAYMENT"), eq("important"), eq(claimId));
        // 申请人仍收普通回执（6 参重载，无聚合）
        verify(notices).publishForUser(eq(applicant.getId()), eq("报销单已审批通过"),
                anyString(), eq("approval"), eq("财务"), eq("/expense"));

        // 工资审核通过：审核人本人不收「待发布」卡
        UUID batchId = UUID.randomUUID();
        service.notifyPayrollBatchApproved(batchId, "2026-09", applicantEmployee);
        verify(notices, never()).publishForUser(eq(applicant.getId()), eq("工资批次待发布"),
                anyString(), anyString(), anyString(), anyString(), anyString(),
                anyString(), any(UUID.class));
        verify(notices).publishForUser(eq(reviewer.getId()), eq("工资批次待发布"), anyString(),
                eq("task"), eq("人事"), eq("/payroll/review"),
                eq("PAYROLL_BATCH_PENDING_PUBLISH"), eq("important"), eq(batchId));

        // 建议提交：提交人（按账号 id）不收回复卡
        UUID suggestionId = UUID.randomUUID();
        service.notifySuggestionSubmitted(suggestionId, applicant.getId(), "张三", "食堂加菜", false);
        verify(notices, never()).publishForUser(eq(applicant.getId()), eq("建议箱有新建议待回复"),
                anyString(), anyString(), anyString(), anyString(), anyString(),
                anyString(), any(UUID.class));
        verify(notices).publishForUser(eq(reviewer.getId()), eq("建议箱有新建议待回复"),
                eq("张三 提交了建议「食堂加菜」，请查看并回复。"),
                eq("task"), eq("人事"), eq("/suggestion"),
                eq("SUGGESTION_SUBMITTED"), eq("important"), eq(suggestionId));
    }

    @Test
    void anonymousSuggestionCardNeverExposesTheSubmitterName() {
        UserAccount replier = account(UUID.randomUUID(), "active", false,
                "notice:read", "suggestion:reply");
        when(users.findAll()).thenReturn(List.of(replier));
        UUID suggestionId = UUID.randomUUID();

        service.notifySuggestionSubmitted(suggestionId, UUID.randomUUID(), "张三", "减少加班", true);

        verify(notices).publishForUser(eq(replier.getId()), eq("建议箱有新建议待回复"),
                eq("一位员工（匿名） 提交了建议「减少加班」，请查看并回复。"),
                eq("task"), eq("人事"), eq("/suggestion"),
                eq("SUGGESTION_SUBMITTED"), eq("important"), eq(suggestionId));
    }

    @Test
    void visitorHostCardGoesOnlyToTheHostAccountAndHasItsOwnAggregate() {
        UUID hostEmployee = UUID.randomUUID();
        UserAccount host = account(hostEmployee, "active", false,
                "notice:read", "visitor:host-confirm");
        UserAccount otherHost = account(UUID.randomUUID(), "active", false,
                "notice:read", "visitor:host-confirm");
        when(users.findAll()).thenReturn(List.of(host, otherHost));
        UUID applicationId = UUID.randomUUID();

        service.notifyVisitorHostReviewRequired(applicationId, "李四", hostEmployee, "王五");

        verify(notices).publishForUser(eq(host.getId()), eq("访客待你确认接待"), anyString(),
                eq("task"), eq("人事"), eq("/my-visitors"),
                eq("VISITOR_HOST_CONFIRM_REQUIRED"), eq("important"), eq(applicationId));
        verifyNoMoreInteractions(notices);
        assertThat(ReviewNoticeCatalog.of("VISITOR_HOST_CONFIRM_REQUIRED"))
                .hasValueSatisfying(entry -> assertThat(entry.aggregateKind())
                        .isEqualTo("VISITOR_HOST_CONFIRM"));
        assertThat(ReviewNoticeCatalog.of("VISITOR_APPLY_SUBMITTED"))
                .hasValueSatisfying(entry -> assertThat(entry.aggregateKind())
                        .isEqualTo("VISITOR_APPLICATION"));
    }

    @Test
    void aggregateBindingsAndResolutionsMatchTheCatalog() {
        UUID id = UUID.randomUUID();
        UUID submitter = UUID.randomUUID();

        service.resolveVisitorHostConfirm(id, "HOST_CONFIRMED");
        service.resolveVisitorApplication(id, "APPROVED");
        service.resolveExpenseClaim(id, "WITHDRAWN");
        service.resolvePayrollBatch(id, "PUBLISHED");
        service.resolveProfileChangeBatch(id, "CANCELLED");
        service.notifySuggestionClosed(id, submitter, "食堂加菜", "resolved");
        service.notifySuggestionClosed(id, submitter, "食堂加菜", "rejected");
        service.notifySuggestionClosed(id, null, "食堂加菜", "resolved");

        verify(notices).resolveReviewNotices("VISITOR_HOST_CONFIRM", id, "HOST_CONFIRMED");
        verify(notices).resolveReviewNotices("VISITOR_APPLICATION", id, "APPROVED");
        verify(notices).resolveReviewNotices("EXPENSE_CLAIM", id, "WITHDRAWN");
        verify(notices).resolveReviewNotices("PAYROLL_BATCH", id, "PUBLISHED");
        verify(notices).resolveReviewNotices("PROFILE_CHANGE", id, "CANCELLED");
        verify(notices).resolveReviewNotices("SUGGESTION", id, "REJECTED");
        verify(notices, org.mockito.Mockito.times(2))
                .resolveReviewNotices("SUGGESTION", id, "RESOLVED");
        verify(notices).publishForUser(eq(submitter), eq("你的建议已采纳处理"), anyString(),
                eq("approval"), eq("人事"), eq("/suggestion/" + id));
        verify(notices).publishForUser(eq(submitter), eq("你的建议已答复"), anyString(),
                eq("approval"), eq("人事"), eq("/suggestion/" + id));
        verifyNoMoreInteractions(notices);

        // 事件 → 目录聚合与本服务办结用的聚合一致；报销审批卡带 EXPENSE_APPROVE 认领。
        assertThat(ReviewNoticeCatalog.of("EXPENSE_CLAIM_SUBMITTED"))
                .hasValueSatisfying(entry -> {
                    assertThat(entry.aggregateKind()).isEqualTo("EXPENSE_CLAIM");
                    assertThat(entry.claimTargetType()).isEqualTo("EXPENSE_APPROVE");
                });
        assertThat(ReviewNoticeCatalog.of("EXPENSE_CLAIM_PENDING_PAYMENT"))
                .hasValueSatisfying(entry -> assertThat(entry.aggregateKind())
                        .isEqualTo("EXPENSE_CLAIM"));
        assertThat(ReviewNoticeCatalog.of("PAYROLL_BATCH_PENDING_PUBLISH"))
                .hasValueSatisfying(entry -> assertThat(entry.aggregateKind())
                        .isEqualTo("PAYROLL_BATCH"));
        assertThat(ReviewNoticeCatalog.of("SUGGESTION_SUBMITTED"))
                .hasValueSatisfying(entry -> assertThat(entry.aggregateKind())
                        .isEqualTo("SUGGESTION"));
        assertThat(ReviewNoticeCatalog.of("PROFILE_CHANGE_SUBMITTED"))
                .hasValueSatisfying(entry -> assertThat(entry.aggregateKind())
                        .isEqualTo("PROFILE_CHANGE"));
        assertThat(ReviewNoticeAudience.eligible("PAYROLL_BATCH_PENDING_PUBLISH",
                Set.of("notice:read", "payroll:publish"), Set.of())).isTrue();
        assertThat(ReviewNoticeAudience.eligible("SUGGESTION_SUBMITTED",
                Set.of("notice:read", "suggestion:reply"), Set.of())).isTrue();
        assertThat(ReviewNoticeAudience.eligible("SUGGESTION_SUBMITTED",
                Set.of("notice:read", "suggestion:submit"), Set.of())).isFalse();
    }

    @Test
    void noticeFailuresPropagateSoTheBusinessTransactionRollsBackTogether() {
        UUID id = UUID.randomUUID();
        when(notices.resolveReviewNotices("EXPENSE_CLAIM", id, "WITHDRAWN"))
                .thenThrow(new IllegalStateException("notice write failed"));

        assertThatThrownBy(() -> service.resolveExpenseClaim(id, "WITHDRAWN"))
                .isInstanceOf(IllegalStateException.class)
                .hasMessage("notice write failed");
    }

    private UserAccount account(UUID employeeId, String status, boolean superAdmin,
                                String... perms) {
        UserAccount account = mock(UserAccount.class);
        UUID id = UUID.randomUUID();
        when(account.getId()).thenReturn(id);
        when(account.getEmployeeId()).thenReturn(employeeId);
        when(account.isDeleted()).thenReturn(false);
        when(account.getStatus()).thenReturn(status);
        when(account.isSuperAdmin()).thenReturn(superAdmin);
        when(users.findById(id)).thenReturn(Optional.of(account));
        when(permissions.permsOf(account)).thenReturn(Set.of(perms));
        return account;
    }
}
