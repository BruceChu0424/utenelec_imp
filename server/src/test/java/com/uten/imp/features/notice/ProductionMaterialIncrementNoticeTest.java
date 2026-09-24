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

import java.math.BigDecimal;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

class ProductionMaterialIncrementNoticeTest {
    private final NoticeService notices = mock(NoticeService.class);
    private final JdbcTemplate jdbc = mock(JdbcTemplate.class);
    private final UserAccountRepository accounts = mock(UserAccountRepository.class);
    private final PermissionResolver permissions = mock(PermissionResolver.class);
    private final ChainNoticeService service = new ChainNoticeService(notices, accounts, permissions, jdbc,
            mock(BusinessEventPublisher.class), mock(RdTaskService.class), mock(FinanceReviewerEligibilityPort.class),
            mock(SalesOrderFinanceConfirmerEligibility.class));
    private final UUID request = UUID.randomUUID(), submitter = UUID.randomUUID();

    @Test void onlyPlanningReviewersReceiveTheActionableRequest() {
        UUID planner = UUID.randomUUID(), viewer = UUID.randomUUID();
        row("PENDING");
        account(planner, Set.of("notice:read", "production_plan:approve"));
        account(viewer, Set.of("notice:read"));
        when(jdbc.queryForList(contains("candidate_employee"), eq(UUID.class), eq("SUB_PLAN")))
                .thenReturn(List.of(planner, viewer));
        service.deliverOutboxEvent("PRODUCTION_MATERIAL_INCREMENT_SUBMITTED", request, new ObjectMapper().createObjectNode());
        verify(notices).publishForUser(eq(planner), contains("待审批"), argThat(content -> content.contains("原料A") && content.contains("30")),
                eq("approval"), eq("系统"), eq("/production/material-increment-requests/" + request),
                eq("PRODUCTION_MATERIAL_INCREMENT_SUBMITTED"), eq("normal"), eq(request));
        verifyNoMoreInteractions(notices);
        assertThat(ReviewNoticeCatalog.of("PRODUCTION_MATERIAL_INCREMENT_SUBMITTED")).hasValueSatisfying(entry ->
                assertThat(entry.aggregateKind()).isEqualTo("PRODUCTION_MATERIAL_INCREMENT_REQUEST"));
    }

    @Test void approvedRequestCannotReceiveAnOutOfOrderPendingReminder() {
        row("APPROVED");
        service.deliverOutboxEvent("PRODUCTION_MATERIAL_INCREMENT_SUBMITTED", request, new ObjectMapper().createObjectNode());
        verifyNoInteractions(notices);
    }

    @Test void approvalResolvesThePlanningTodoAndDirectsRequesterToRealMaterialIssue() {
        row("APPROVED");
        account(submitter, Set.of("notice:read", "production_execution:view"));
        service.deliverOutboxEvent("PRODUCTION_MATERIAL_INCREMENT_APPROVED", request, new ObjectMapper().createObjectNode());
        verify(notices).resolveReviewNotices("PRODUCTION_MATERIAL_INCREMENT_REQUEST", request, "APPROVED");
        verify(notices).publishForUser(eq(submitter), contains("已批准"), contains("备料和领料进度"),
                eq("workflow"), eq("系统"), eq("/production/material-increment-requests/" + request),
                eq("PRODUCTION_MATERIAL_INCREMENT_APPROVED"), eq("normal"), eq(request));
    }

    private void row(String status) {
        when(jdbc.queryForList(contains("FROM production_material_increment_requests"), eq(request))).thenReturn(List.of(Map.of(
                "status", status, "submitted_by", submitter, "delta_qty", new BigDecimal("30"),
                "segment_code", "ZX-TEST", "goods_name", "原料A", "reason", "补充依据")));
    }

    @Test void cancelledAuthorizationDoesNotRegenerateAnApprovalNotice() {
        row("CANCELLED");
        account(submitter, Set.of("notice:read", "production_execution:view"));
        service.deliverOutboxEvent("PRODUCTION_MATERIAL_INCREMENT_APPROVED", request, new ObjectMapper().createObjectNode());
        verifyNoInteractions(notices);
        service.deliverOutboxEvent("PRODUCTION_MATERIAL_INCREMENT_CANCELLED", request, new ObjectMapper().createObjectNode());
        verify(notices).resolveReviewNotices("PRODUCTION_MATERIAL_INCREMENT_REQUEST", request, "CANCELLED");
        verify(notices).publishForUser(eq(submitter), contains("授权已撤销"), contains("历史实发、退料记录保留"),
                eq("workflow"), eq("系统"), eq("/production/material-increment-requests/" + request),
                eq("PRODUCTION_MATERIAL_INCREMENT_CANCELLED"), eq("normal"), eq(request));
    }

    private void account(UUID id, Set<String> grants) {
        UserAccount account = mock(UserAccount.class);
        when(account.isDeleted()).thenReturn(false);
        when(account.getStatus()).thenReturn("active");
        when(accounts.findById(id)).thenReturn(Optional.of(account));
        when(permissions.permsOf(account)).thenReturn(grants);
    }
}
