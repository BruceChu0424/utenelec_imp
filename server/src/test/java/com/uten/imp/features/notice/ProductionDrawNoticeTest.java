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

import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;

import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.contains;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.ArgumentMatchers.isNull;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class ProductionDrawNoticeTest {

    @Test
    void pendingAndIssuedEventsUseDocumentAndIssueScopedDedupeKeys() {
        UUID drawId = UUID.randomUUID();
        BusinessEventPublisher outbox = mock(BusinessEventPublisher.class);
        ChainNoticeService service = service(
                mock(NoticeService.class),
                mock(UserAccountRepository.class),
                mock(PermissionResolver.class),
                mock(JdbcTemplate.class),
                outbox);

        service.notifyProductionDrawPending(drawId);
        service.notifyProductionDrawIssued(drawId, "draw-issue-key-0001");

        verify(outbox).publishOnce(
                ChainNoticeService.EVENT_PRODUCTION_DRAW_PENDING,
                "STOCK_DOCUMENT",
                drawId,
                Map.of(),
                ChainNoticeService.EVENT_PRODUCTION_DRAW_PENDING + ':' + drawId);
        verify(outbox).publishOnce(
                ChainNoticeService.EVENT_PRODUCTION_DRAW_ISSUED,
                "STOCK_DOCUMENT",
                drawId,
                Map.of(),
                ChainNoticeService.EVENT_PRODUCTION_DRAW_ISSUED + ':' + drawId
                        + ":draw-issue-key-0001");
    }

    @Test
    void finishedInboundReversalUsesTheSourceDocumentAsItsDedupeScope() {
        UUID sourceId = UUID.randomUUID();
        UUID replacementId = UUID.randomUUID();
        BusinessEventPublisher outbox = mock(BusinessEventPublisher.class);
        ChainNoticeService service = service(
                mock(NoticeService.class),
                mock(UserAccountRepository.class),
                mock(PermissionResolver.class),
                mock(JdbcTemplate.class),
                outbox);

        service.notifyFinishedInboundReversed(sourceId, replacementId);

        verify(outbox).publishOnce(
                ChainNoticeService.EVENT_FINISHED_INBOUND_REVERSED,
                "STOCK_DOCUMENT",
                sourceId,
                Map.of("replacementStockDocId", replacementId.toString()),
                ChainNoticeService.EVENT_FINISHED_INBOUND_REVERSED
                        + ':' + sourceId);
    }

    @Test
    void pendingDrawTargetsOnlyActiveWarehouseUsersWithAnActionPermission() {
        UUID drawId = UUID.randomUUID();
        UUID allowedId = UUID.randomUUID();
        UUID revokedId = UUID.randomUUID();
        UUID inactiveId = UUID.randomUUID();
        JdbcTemplate jdbc = mock(JdbcTemplate.class);
        NoticeService notices = mock(NoticeService.class);
        UserAccountRepository users = mock(UserAccountRepository.class);
        PermissionResolver permissions = mock(PermissionResolver.class);
        UserAccount allowed = active(allowedId);
        UserAccount revoked = active(revokedId);
        UserAccount inactive = active(inactiveId);
        inactive.setStatus("disabled");

        when(jdbc.queryForList(
                contains("FROM stock_documents stock"),
                eq(drawId))).thenReturn(List.of(Map.of(
                        "bill_no", "SL-001",
                        "plan_no", "SJ-001",
                        "warehouse_name", "原材料仓",
                        "department_name", "装配一车间",
                        "line_count", 2L)));
        when(jdbc.queryForList(
                contains("WITH RECURSIVE subtree"),
                eq(UUID.class),
                eq("SUB_WH"))).thenReturn(List.of(allowedId, revokedId, inactiveId));
        when(users.findById(allowedId)).thenReturn(Optional.of(allowed));
        when(users.findById(revokedId)).thenReturn(Optional.of(revoked));
        when(users.findById(inactiveId)).thenReturn(Optional.of(inactive));
        when(permissions.permsOf(allowed)).thenReturn(Set.of(
                "stock_doc:view", "stock_doc:approve", "stock_doc:issue"));
        when(permissions.permsOf(revoked)).thenReturn(Set.of());

        ChainNoticeService service = service(
                notices, users, permissions, jdbc,
                mock(BusinessEventPublisher.class));
        service.deliverOutboxEvent(
                ChainNoticeService.EVENT_PRODUCTION_DRAW_PENDING,
                drawId,
                new ObjectMapper().createObjectNode());

        // 2026-09-05 起为居中行动卡：aggregate 绑定 (STOCK_DOCUMENT, drawId)，
        // 实际出库后办结撤回。
        verify(notices).publishForUser(
                eq(allowedId),
                eq("待处理生产领料：SL-001"),
                contains("首次出库会在同一事务完成审核与本次扣账"),
                eq(ChainNoticeService.TYPE_TASK),
                anyString(),
                eq("/warehouse/DRAW/" + drawId),
                eq(ChainNoticeService.EVENT_PRODUCTION_DRAW_PENDING),
                isNull(),
                eq(drawId));
        verify(notices, never()).publishForUser(
                eq(revokedId), anyString(), anyString(), anyString(),
                anyString(), anyString(), anyString());
        verify(notices, never()).publishForUser(
                eq(inactiveId), anyString(), anyString(), anyString(),
                anyString(), anyString(), anyString());
    }

    @Test
    void issuedDrawTargetsOnlyTheExactWorkshopTaskAudience() {
        UUID drawId = UUID.randomUUID();
        UUID segmentId = UUID.randomUUID();
        UUID workshopId = UUID.randomUUID();
        UUID responsibleEmployeeId = UUID.randomUUID();
        UUID workshopUserId = UUID.randomUUID();
        JdbcTemplate jdbc = mock(JdbcTemplate.class);
        NoticeService notices = mock(NoticeService.class);
        UserAccountRepository users = mock(UserAccountRepository.class);
        PermissionResolver permissions = mock(PermissionResolver.class);
        UserAccount workshopUser = active(workshopUserId);

        when(jdbc.queryForList(
                contains("FROM stock_documents stock"),
                eq(drawId))).thenReturn(List.of(Map.of(
                        "bill_no", "SL-002",
                        "plan_no", "SJ-002",
                        "warehouse_name", "原材料仓")));
        when(jdbc.queryForList(
                contains("production_planning_package_document_items mapping"),
                eq(UUID.class),
                eq(drawId))).thenReturn(List.of(segmentId));
        when(jdbc.queryForList(
                contains("FOR UPDATE"),
                eq(UUID.class),
                eq(segmentId))).thenReturn(List.of(segmentId));
        when(jdbc.queryForList(
                contains("FROM v_production_execution_workbench_segments task"),
                eq(segmentId))).thenReturn(List.of(Map.ofEntries(
                        Map.entry("segment_id", segmentId),
                        Map.entry("segment_code", "SEG-002"),
                        Map.entry("plan_no", "SJ-002"),
                        Map.entry("product_code", "P-002"),
                        Map.entry("product_name", "测试产品"),
                        Map.entry("product_color_name", "蓝色"),
                        Map.entry("product_unit_name", "件"),
                        Map.entry("planned_qty", new java.math.BigDecimal("10")),
                        Map.entry("segment_status", "READY"),
                        Map.entry("material_status", "KIT_READY"),
                        Map.entry("preparation_status", "PREPARED"),
                        Map.entry("issued", true),
                        Map.entry("reportable", true),
                        Map.entry("workshop_department_id", workshopId),
                        Map.entry("workshop_name", "装配一车间"),
                        Map.entry("responsible_employee_id", responsibleEmployeeId),
                        Map.entry("responsible_employee_name", "车间负责人"))));
        when(jdbc.queryForList(
                contains("WITH RECURSIVE workshop_tree(id)"),
                eq(UUID.class),
                eq(workshopId),
                eq(responsibleEmployeeId))).thenReturn(List.of(workshopUserId));
        when(users.findById(workshopUserId))
                .thenReturn(Optional.of(workshopUser));
        when(permissions.permsOf(workshopUser)).thenReturn(Set.of(
                "notice:read", "production_execution:view"));

        ChainNoticeService service = service(
                notices, users, permissions, jdbc,
                mock(BusinessEventPublisher.class));
        service.deliverOutboxEvent(
                ChainNoticeService.EVENT_PRODUCTION_DRAW_ISSUED,
                drawId,
                new ObjectMapper().createObjectNode());

        verify(notices).publishForUser(
                eq(workshopUserId),
                eq("备料完毕·可报工：SEG-002"),
                contains("当前状态：备料完毕，可直接报工"),
                eq(ChainNoticeService.TYPE_TASK),
                anyString(),
                eq("/production/workshop-tasks"),
                eq(ChainNoticeService.EVENT_PRODUCTION_WORKSHOP_TASK_ACTION_REQUIRED),
                eq("important"),
                eq(segmentId));
    }

    @Test
    void rejectedFinishedInboundTargetsMakerAndActionableSupervisorsOnly() {
        UUID stockDocId = UUID.randomUUID();
        UUID reportId = UUID.randomUUID();
        UUID makerId = UUID.randomUUID();
        UUID supervisorId = UUID.randomUUID();
        UUID readOnlyId = UUID.randomUUID();
        JdbcTemplate jdbc = mock(JdbcTemplate.class);
        NoticeService notices = mock(NoticeService.class);
        UserAccountRepository users = mock(UserAccountRepository.class);
        PermissionResolver permissions = mock(PermissionResolver.class);
        UserAccount maker = active(makerId);
        UserAccount supervisor = active(supervisorId);
        UserAccount readOnly = active(readOnlyId);

        when(jdbc.queryForList(
                contains("FROM stock_documents stock"),
                eq(stockDocId))).thenReturn(List.of(Map.of(
                        "bill_no", "CJ-REJECT-001",
                        "plan_no", "SJ-001",
                        "source_daily_report_id", reportId,
                        "source_doc_no", "BR-001",
                        "report_maker_user_id", makerId)));
        when(jdbc.queryForList(
                contains("WITH RECURSIVE subtree"),
                eq(UUID.class),
                eq("DEPT_PROD"))).thenReturn(List.of(supervisorId, readOnlyId));
        when(jdbc.queryForList(
                contains("WITH RECURSIVE subtree"),
                eq(UUID.class),
                eq("SUB_PLAN"))).thenReturn(List.of());
        when(users.findById(makerId)).thenReturn(Optional.of(maker));
        when(users.findById(supervisorId)).thenReturn(Optional.of(supervisor));
        when(users.findById(readOnlyId)).thenReturn(Optional.of(readOnly));
        when(permissions.permsOf(supervisor)).thenReturn(Set.of(
                "production_daily_report:approve"));
        when(permissions.permsOf(readOnly)).thenReturn(Set.of(
                "production_daily_report:view"));

        ChainNoticeService service = service(
                notices, users, permissions, jdbc,
                mock(BusinessEventPublisher.class));
        service.deliverOutboxEvent(
                ChainNoticeService.EVENT_FINISHED_INBOUND_REJECTED,
                stockDocId,
                new ObjectMapper().createObjectNode().put(
                        "reason", "整批未交接"));

        verify(notices).publishForUser(
                eq(makerId),
                eq("成品入库被仓库拒收：CJ-REJECT-001"),
                contains("整批未交接"),
                eq(ChainNoticeService.TYPE_URGENT),
                anyString(),
                eq("/production/daily-reports/" + reportId),
                eq(ChainNoticeService.EVENT_FINISHED_INBOUND_REJECTED));
        verify(notices).publishForUser(
                eq(supervisorId),
                eq("成品入库被仓库拒收：CJ-REJECT-001"),
                contains("整批未交接"),
                eq(ChainNoticeService.TYPE_URGENT),
                anyString(),
                eq("/production/daily-reports/" + reportId),
                eq(ChainNoticeService.EVENT_FINISHED_INBOUND_REJECTED),
                eq("normal"));
        verify(notices, never()).publishForUser(
                eq(readOnlyId), anyString(), anyString(), anyString(),
                anyString(), anyString(), anyString());
    }

    private static ChainNoticeService service(
            NoticeService notices,
            UserAccountRepository users,
            PermissionResolver permissions,
            JdbcTemplate jdbc,
            BusinessEventPublisher outbox) {
        return new ChainNoticeService(
                notices,
                users,
                permissions,
                mock(UserRoleRepository.class),
                jdbc,
                outbox,
                mock(RdTaskService.class),
                mock(FinanceReviewerEligibilityPort.class),
                mock(SalesOrderFinanceConfirmerEligibility.class));
    }

    private static UserAccount active(UUID id) {
        UserAccount account = new UserAccount();
        account.setId(id);
        account.setStatus("active");
        account.setDeleted(false);
        return account;
    }
}
