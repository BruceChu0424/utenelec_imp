package com.uten.imp.features.notice;

import com.uten.imp.application.port.BusinessEventPublisher;
import com.uten.imp.application.port.FinanceReviewerEligibilityPort;
import com.uten.imp.features.admin.workflow.SalesOrderFinanceConfirmerEligibility;
import com.uten.imp.features.auth.PermissionResolver;
import com.uten.imp.features.auth.model.UserAccount;
import com.uten.imp.features.auth.model.UserAccountRepository;
import com.uten.imp.features.rbac.UserRoleRepository;
import com.uten.imp.features.rd_task.RdTaskService;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;
import org.springframework.jdbc.core.JdbcTemplate;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.doReturn;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class ChainNoticeProductionWorkshopScopeTest {

    @Test
    void workshopRecipientsRequireViewAndCurrentActionPermissions() {
        NoticeService notices = mock(NoticeService.class);
        UserAccountRepository users = mock(UserAccountRepository.class);
        PermissionResolver permissions = mock(PermissionResolver.class);
        JdbcTemplate jdbc = mock(JdbcTemplate.class);
        ChainNoticeService service = service(notices, users, permissions, jdbc);
        UUID workshopId = UUID.randomUUID();
        UUID responsibleId = UUID.randomUUID();
        UUID eligibleId = UUID.randomUUID();
        UUID noNoticeId = UUID.randomUUID();
        UUID noTaskId = UUID.randomUUID();
        doReturn(List.of(eligibleId, noNoticeId, noTaskId))
                .when(jdbc)
                .queryForList(
                        anyString(), eq(UUID.class), any(), any());

        UserAccount eligible = activeAccount();
        UserAccount noNotice = activeAccount();
        UserAccount noTask = activeAccount();
        when(users.findById(eligibleId)).thenReturn(Optional.of(eligible));
        when(users.findById(noNoticeId)).thenReturn(Optional.of(noNotice));
        when(users.findById(noTaskId)).thenReturn(Optional.of(noTask));
        when(permissions.permsOf(eligible)).thenReturn(
                Set.of("notice:read", "production_execution:view", "production_execution:start"));
        when(permissions.permsOf(noNotice)).thenReturn(
                Set.of("production_execution:view"));
        when(permissions.permsOf(noTask)).thenReturn(Set.of("notice:read"));

        assertThat(service.workshopRecipientUserIds(
                workshopId, responsibleId)).containsExactly(eligibleId);

        ArgumentCaptor<String> sql = ArgumentCaptor.forClass(String.class);
        verify(jdbc).queryForList(
                sql.capture(), eq(UUID.class), eq(workshopId), eq(responsibleId));
        assertThat(sql.getValue())
                .contains("employee_secondary_departments")
                .contains("department.manager_id")
                .contains("employee.status IN");
    }

    @Test
    void workshopTaskCatalogIsInteractiveAndCanResolveBySegment() {
        NoticeService notices = mock(NoticeService.class);
        ChainNoticeService service = service(
                notices,
                mock(UserAccountRepository.class),
                mock(PermissionResolver.class),
                mock(JdbcTemplate.class));
        UUID segmentId = UUID.randomUUID();
        when(notices.resolveReviewNotices(
                "PRODUCTION_EXECUTION_SEGMENT",
                segmentId,
                "REPORT_STARTED")).thenReturn(1);

        assertThat(ReviewNoticeCatalog.of(
                ChainNoticeService.EVENT_PRODUCTION_WORKSHOP_TASK_ACTION_REQUIRED))
                .hasValueSatisfying(entry -> {
                    assertThat(entry.aggregateKind())
                            .isEqualTo("PRODUCTION_EXECUTION_SEGMENT");
                    assertThat(entry.claimTargetType()).isNull();
                });
        assertThat(service.resolveProductionWorkshopTasks(
                List.of(segmentId), "REPORT_STARTED")).isEqualTo(1);
        verify(notices).resolveReviewNotices(
                "PRODUCTION_EXECUTION_SEGMENT",
                segmentId,
                "REPORT_STARTED");
    }

    @Test
    void workshopTaskCardIsResolvedOnStartAndOnFinishedInboundCompletion()
            throws Exception {
        // ① 开工办结：applyTransition 在 START 成功后按段 resolve（reason STARTED）。
        Path segmentDirect = Path.of(
                "src/main/java/com/uten/imp/features/production/execution/"
                        + "ProductionExecutionSegmentService.java");
        Path segmentFallback = Path.of("server").resolve(segmentDirect);
        String segmentSource = Files.readString(
                Files.exists(segmentDirect) ? segmentDirect : segmentFallback,
                StandardCharsets.UTF_8);
        String applyTransition = slice(
                segmentSource,
                "private ExecutionSegmentView applyTransition(",
                "private void updateStatus(");
        assertThat(applyTransition)
                .contains("ACTION_START.equals(transition.action())")
                .contains("chainNotice.resolveProductionWorkshopTasks(")
                .contains("\"STARTED\"");

        // ② 完工兜底：完工入库投递先按本单已 COMPLETED 的段 resolve（reason COMPLETED）。
        Path chainDirect = Path.of(
                "src/main/java/com/uten/imp/features/notice/"
                        + "ChainNoticeService.java");
        Path chainFallback = Path.of("server").resolve(chainDirect);
        String chain = Files.readString(
                Files.exists(chainDirect) ? chainDirect : chainFallback,
                StandardCharsets.UTF_8);
        String finishedInbound = slice(
                chain,
                "private void deliverFinishedInbound(",
                "private void notifyFullyProducedReadyToShip(");
        assertThat(finishedInbound)
                .contains("resolveProductionWorkshopTasks(")
                .contains("completedSegmentsOfFinishedInbound(stockDocId)")
                .contains("\"COMPLETED\"");

        // ③ 段查询只认 COMPLETED 且未删的段（红冲回 IN_PROGRESS 的段不误撤）。
        JdbcTemplate jdbc = mock(JdbcTemplate.class);
        ChainNoticeService service = service(
                mock(NoticeService.class),
                mock(UserAccountRepository.class),
                mock(PermissionResolver.class),
                jdbc);
        UUID stockDocId = UUID.randomUUID();
        UUID completedId = UUID.randomUUID();
        doReturn(List.of(completedId))
                .when(jdbc)
                .queryForList(anyString(), eq(UUID.class), eq(stockDocId));

        assertThat(service.completedSegmentsOfFinishedInbound(stockDocId))
                .containsExactly(completedId);
        assertThat(service.completedSegmentsOfFinishedInbound(null)).isEmpty();
        ArgumentCaptor<String> sql = ArgumentCaptor.forClass(String.class);
        verify(jdbc).queryForList(sql.capture(), eq(UUID.class), eq(stockDocId));
        assertThat(sql.getValue())
                .contains("stock_document_items")
                .contains("segment.status = 'COMPLETED'")
                .contains("segment.is_deleted = FALSE")
                .contains("item.execution_segment_id IS NOT NULL");
    }

    @Test
    void productionPlanReadyAndDrawEventsUseOnlyExactWorkshopDelivery()
            throws Exception {
        Path direct = Path.of(
                "src/main/java/com/uten/imp/features/notice/"
                        + "ChainNoticeService.java");
        Path fallback = Path.of("server").resolve(direct);
        String source = Files.readString(
                Files.exists(direct) ? direct : fallback,
                StandardCharsets.UTF_8);
        String issued = slice(
                source,
                "public void notifyProductionDrawIssued(",
                "public void notifyProductionDrawIssueReversed(");
        String reversed = slice(
                source,
                "public void notifyProductionDrawIssueReversed(",
                "public void notifyIqcPendingForQuality(");
        String ready = slice(
                source,
                "public void notifyExecutionSegmentReady(",
                "static String executionReadySourceLabel(");

        assertThat(source)
                .contains("publishWorkshopTasksForPlan(")
                .contains("生产计划已审核下达");
        assertThat(issued)
                .contains("publishWorkshopTasksForDraw(")
                .contains("true)")
                .doesNotContain("stock.issue_status = 2")
                .doesNotContain("DEPT_PROD")
                .doesNotContain("SUB_PLAN")
                .doesNotContain("/production/schedule");
        assertThat(reversed)
                .contains("publishWorkshopTasksForDraw(")
                .doesNotContain("DEPT_PROD")
                .doesNotContain("SUB_PLAN")
                .doesNotContain("/production/schedule");
        assertThat(ready)
                .contains("publishWorkshopTask(")
                .doesNotContain("notifyRoles(")
                .doesNotContain("请安排派工");
    }

    @Test
    void workshopAssignmentRebuildsTheTaskCardThroughExactWorkshopDelivery()
            throws Exception {
        // ① 源码契约：assign() 在车间/负责人变化后补发车间任务卡；清空车间
        // 则办结残留弹窗（计划下达时车间为空的段，首张通知只能靠这里补发）。
        Path direct = Path.of(
                "src/main/java/com/uten/imp/features/production/execution/"
                        + "ProductionExecutionSegmentService.java");
        Path fallback = Path.of("server").resolve(direct);
        String source = Files.readString(
                Files.exists(direct) ? direct : fallback,
                StandardCharsets.UTF_8);
        String assign = slice(
                source,
                "public ExecutionSegmentView assign(",
                "Releases an explicit USER_DEFER decision");
        assertThat(assign)
                .contains("chainNotice.notifyExecutionSegmentWorkshopAssigned(")
                .contains("chainNotice.resolveProductionWorkshopTasks(");

        // ② 事件路由：WORKSHOP_ASSIGNED 与 READY/STARTED 同为车间任务卡事件，
        // outbox 派发不落空。
        Path chainDirect = Path.of(
                "src/main/java/com/uten/imp/features/notice/"
                        + "ChainNoticeService.java");
        Path chainFallback = Path.of("server").resolve(chainDirect);
        String chain = Files.readString(
                Files.exists(chainDirect) ? chainDirect : chainFallback,
                StandardCharsets.UTF_8);
        assertThat(chain)
                .contains("\"PRODUCTION_SEGMENT_WORKSHOP_ASSIGNED\"")
                .contains("case EVENT_SEGMENT_WORKSHOP_ASSIGNED ->");

        // ③ 投递口径：与 READY 完全同路（publishWorkshopTask → 精确车间收件人，
        // 不广播部门、不进旧派工话术）。
        String assigned = slice(
                chain,
                "public void notifyExecutionSegmentWorkshopAssigned(",
                "private void publishWorkshopTasksForPlan(");
        assertThat(assigned)
                .contains("publishWorkshopTask(")
                .doesNotContain("notifyRoles(")
                .doesNotContain("DEPT_PROD")
                .doesNotContain("SUB_PLAN")
                .doesNotContain("请安排派工");
    }

    private static ChainNoticeService service(
            NoticeService notices,
            UserAccountRepository users,
            PermissionResolver permissions,
            JdbcTemplate jdbc) {
        return new ChainNoticeService(
                notices,
                users,
                permissions,
                mock(UserRoleRepository.class),
                jdbc,
                mock(BusinessEventPublisher.class),
                mock(RdTaskService.class),
                mock(FinanceReviewerEligibilityPort.class),
                mock(SalesOrderFinanceConfirmerEligibility.class));
    }

    private static UserAccount activeAccount() {
        UserAccount account = mock(UserAccount.class);
        when(account.isDeleted()).thenReturn(false);
        when(account.getStatus()).thenReturn("active");
        return account;
    }

    private static String slice(
            String source, String startMarker, String endMarker) {
        int start = source.indexOf(startMarker);
        int end = source.indexOf(endMarker, start + startMarker.length());
        assertThat(start).isGreaterThanOrEqualTo(0);
        assertThat(end).isGreaterThan(start);
        return source.substring(start, end);
    }
}
