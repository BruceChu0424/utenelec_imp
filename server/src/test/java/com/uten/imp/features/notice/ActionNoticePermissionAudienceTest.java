package com.uten.imp.features.notice;

import com.uten.imp.application.port.BusinessEventPublisher;
import com.uten.imp.application.port.FinanceReviewerEligibilityPort;
import com.uten.imp.features.admin.workflow.SalesOrderFinanceConfirmerEligibility;
import com.uten.imp.features.auth.PermissionResolver;
import com.uten.imp.features.auth.model.UserAccount;
import com.uten.imp.features.auth.model.UserAccountRepository;
import com.uten.imp.features.rd_task.RdTaskService;
import org.junit.jupiter.api.Test;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.test.util.ReflectionTestUtils;

import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

class ActionNoticePermissionAudienceTest {
    private final NoticeService notices = mock(NoticeService.class);
    private final UserAccountRepository users = mock(UserAccountRepository.class);
    private final PermissionResolver permissions = mock(PermissionResolver.class);
    private final JdbcTemplate jdbc = mock(JdbcTemplate.class);
    private final ChainNoticeService chain = new ChainNoticeService(notices, users, permissions, jdbc,
            mock(BusinessEventPublisher.class), mock(RdTaskService.class),
            mock(FinanceReviewerEligibilityPort.class), mock(SalesOrderFinanceConfirmerEligibility.class));

    @Test
    void qualityHandlersOutsideTheQualityDepartmentReceiveWorkAndRevocationRemovesThem() {
        UserAccount authorized = account();
        UserAccount viewer = account();
        UserAccount disabled = account();
        disabled.setStatus("disabled");
        when(users.findAll()).thenReturn(List.of(authorized, viewer, disabled));
        when(jdbc.queryForList(contains("active_action_recipients"), eq(UUID.class), anyString()))
                .thenReturn(List.of(authorized.getId()));
        when(permissions.grantedPermsOf(authorized)).thenReturn(Set.of(
                "notice:read", "procurement_inspection:view", "procurement_inspection:handle"));
        when(permissions.grantedPermsOf(viewer)).thenReturn(Set.of("notice:read", "procurement_inspection:view"));

        assertThat(qualityRecipients()).containsExactly(authorized.getId());
        when(permissions.grantedPermsOf(authorized)).thenReturn(Set.of("notice:read", "procurement_inspection:view"));
        assertThat(qualityRecipients()).isEmpty();
        verify(jdbc).queryForList(argThat(sql -> sql.contains("employee.status IN ('active','probation','onLeave')")
                && sql.contains("NOT employee.is_deleted") && !sql.contains("department")), eq(UUID.class), anyString());
    }

    @Test
    void bomGapReachesAnAuthorizedMaintainerOutsideEngineeringButNotAReadOnlyFollower() {
        UUID taskId = UUID.randomUUID();
        UserAccount maintainer = account();
        UserAccount viewer = account();
        when(users.findAll()).thenReturn(List.of(maintainer, viewer));
        when(jdbc.queryForList(contains("active_action_recipients"), eq(UUID.class), anyString()))
                .thenReturn(List.of(maintainer.getId()));
        when(users.findById(maintainer.getId())).thenReturn(java.util.Optional.of(maintainer));
        when(permissions.grantedPermsOf(maintainer)).thenReturn(Set.of("notice:read", "rd_task:view", "goods:bom:edit"));
        when(permissions.grantedPermsOf(viewer)).thenReturn(Set.of("notice:read", "rd_task:view"));
        when(jdbc.queryForList(contains("FROM rd_tasks r"), eq(taskId))).thenReturn(List.of(Map.of(
                "goods_code", "PART-01", "goods_name", "委外件", "source_doc_no", "WO-01")));

        chain.deliverOutboxEvent(ChainNoticeService.EVENT_RD_TASK_FORWARDED, taskId,
                new com.fasterxml.jackson.databind.ObjectMapper().createObjectNode());

        verify(notices).publishForUser(eq(maintainer.getId()), contains("请完善 BOM"), contains("直属物料"),
                eq("task"), eq("系统"), eq("/rd/tasks"), eq(ChainNoticeService.EVENT_RD_TASK_FORWARDED));
        verify(notices, never()).publishForUser(eq(viewer.getId()), anyString(), anyString(),
                anyString(), anyString(), anyString(), any());
        verify(jdbc, never()).queryForList(contains("WITH RECURSIVE subtree"), eq(UUID.class), any());
    }

    private List<UUID> qualityRecipients() {
        return ReflectionTestUtils.invokeMethod(chain, "qualityInspectionViewerUserIds");
    }

    @Test
    void shipmentReviewRequiresItsPageAndEitherCurrentDecisionPermissionAndStopsAfterViewRevocation() {
        UUID shipment = UUID.randomUUID();
        UserAccount reviewer = account();
        when(users.findAll()).thenReturn(List.of(reviewer));
        when(users.findById(reviewer.getId())).thenReturn(java.util.Optional.of(reviewer));
        when(jdbc.queryForList(contains("active_action_recipients"), eq(UUID.class), anyString()))
                .thenReturn(List.of(reviewer.getId()));
        when(jdbc.queryForList(contains("SELECT bill_no"), eq(shipment)))
                .thenReturn(List.of(Map.of("bill_no", "SH-PERMISSION")));
        var payload = new com.fasterxml.jackson.databind.ObjectMapper().createObjectNode();
        for (String action : List.of("sales_shipment_finance:approve", "sales_shipment_finance:reject")) {
            when(permissions.grantedPermsOf(reviewer)).thenReturn(Set.of("notice:read", action));
            chain.deliverOutboxEvent(ChainNoticeService.EVENT_SHIPMENT_PENDING_FINANCE, shipment, payload);
            verifyNoInteractions(notices);

            when(permissions.grantedPermsOf(reviewer)).thenReturn(Set.of("notice:read", "sales_shipment_finance:view", action));
            chain.deliverOutboxEvent(ChainNoticeService.EVENT_SHIPMENT_PENDING_FINANCE, shipment, payload);
            verify(notices).publishForUser(eq(reviewer.getId()), contains("待出货财务审核"), anyString(),
                    eq("approval"), eq("系统"), eq("/sales/shipments/" + shipment),
                    eq(ChainNoticeService.EVENT_SHIPMENT_PENDING_FINANCE), eq("normal"), eq(shipment));
            clearInvocations(notices);

            when(permissions.grantedPermsOf(reviewer)).thenReturn(Set.of("notice:read", action));
            chain.deliverOutboxEvent(ChainNoticeService.EVENT_SHIPMENT_PENDING_FINANCE, shipment, payload);
            verifyNoInteractions(notices);
        }
    }

    private UserAccount account() {
        UserAccount account = new UserAccount();
        account.setId(UUID.randomUUID());
        account.setEmployeeId(UUID.randomUUID());
        account.setStatus("active");
        return account;
    }
}
