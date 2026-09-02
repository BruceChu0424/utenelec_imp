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
import static org.mockito.Mockito.when;

class SubcontractChainNoticeTest {

    @Test
    void coreSubcontractHandoffsUseStableIdempotentOutboxKeys() {
        UUID preparationItemId = UUID.randomUUID();
        UUID readyItemId = UUID.randomUUID();
        UUID issueId = UUID.randomUUID();
        BusinessEventPublisher outbox = mock(BusinessEventPublisher.class);
        ChainNoticeService service = service(
                mock(NoticeService.class),
                mock(UserAccountRepository.class),
                mock(PermissionResolver.class),
                mock(JdbcTemplate.class),
                outbox);

        service.notifySubcontractPreparationRequired(preparationItemId);
        service.notifySubcontractOutboundReady(readyItemId);
        service.notifySubcontractOutboundCompleted(issueId);
        service.notifySubcontractOutboundReversed(issueId);

        verify(outbox).publishOnce(
                ChainNoticeService.EVENT_SUBCONTRACT_PREPARATION_REQUIRED,
                "SUBCONTRACT_MATERIAL_PLAN_ITEM",
                preparationItemId,
                Map.of(),
                ChainNoticeService.EVENT_SUBCONTRACT_PREPARATION_REQUIRED
                        + ':' + preparationItemId);
        verify(outbox).publishOnce(
                ChainNoticeService.EVENT_SUBCONTRACT_OUTBOUND_READY,
                "SUBCONTRACT_MATERIAL_PLAN_ITEM",
                readyItemId,
                Map.of(),
                ChainNoticeService.EVENT_SUBCONTRACT_OUTBOUND_READY
                        + ':' + readyItemId);
        verify(outbox).publishOnce(
                ChainNoticeService.EVENT_SUBCONTRACT_OUTBOUND_COMPLETED,
                "SUBCONTRACT_MATERIAL_ISSUE",
                issueId,
                Map.of(),
                ChainNoticeService.EVENT_SUBCONTRACT_OUTBOUND_COMPLETED
                        + ':' + issueId);
        verify(outbox).publishOnce(
                ChainNoticeService.EVENT_SUBCONTRACT_OUTBOUND_REVERSED,
                "SUBCONTRACT_MATERIAL_ISSUE",
                issueId,
                Map.of(),
                ChainNoticeService.EVENT_SUBCONTRACT_OUTBOUND_REVERSED
                        + ':' + issueId);
    }

    @Test
    void preparationTargetsOnlyEligiblePlanAndProductionUsersAndMaker() {
        UUID planItemId = UUID.randomUUID();
        UUID orderId = UUID.randomUUID();
        UUID makerEmployeeId = UUID.randomUUID();
        UUID makerUserId = UUID.randomUUID();
        UUID plannerId = UUID.randomUUID();
        UUID productionId = UUID.randomUUID();
        UUID oldProductionOnlyId = UUID.randomUUID();
        UUID preparationViewOnlyId = UUID.randomUUID();
        JdbcTemplate jdbc = mock(JdbcTemplate.class);
        NoticeService notice = mock(NoticeService.class);
        UserAccountRepository users = mock(UserAccountRepository.class);
        PermissionResolver permissions = mock(PermissionResolver.class);
        when(jdbc.queryForList(
                contains("item.preparation_status = 'ACTION_REQUIRED'"),
                eq(planItemId))).thenReturn(List.of(Map.of(
                        "plan_id", UUID.randomUUID(),
                        "order_id", orderId,
                        "order_bill_no", "WO-PREP-001",
                        "maker_id", makerEmployeeId,
                        "planned_qty", new BigDecimal("6.0000"),
                        "goods_code", "FG-001",
                        "goods_name", "委外目标件")));
        when(jdbc.queryForList(
                contains("WITH RECURSIVE subtree(id)"),
                eq(UUID.class),
                eq("SUB_PLAN"))).thenReturn(List.of(
                        plannerId, oldProductionOnlyId, preparationViewOnlyId));
        when(jdbc.queryForList(
                contains("WITH RECURSIVE subtree(id)"),
                eq(UUID.class),
                eq("DEPT_PROD"))).thenReturn(List.of(productionId));
        UserAccount planner = activeUser(plannerId);
        UserAccount production = activeUser(productionId);
        UserAccount oldProductionOnly = activeUser(oldProductionOnlyId);
        UserAccount preparationViewOnly = activeUser(preparationViewOnlyId);
        UserAccount maker = activeUser(makerUserId);
        when(users.findById(plannerId)).thenReturn(Optional.of(planner));
        when(users.findById(productionId)).thenReturn(Optional.of(production));
        when(users.findById(oldProductionOnlyId))
                .thenReturn(Optional.of(oldProductionOnly));
        when(users.findById(preparationViewOnlyId))
                .thenReturn(Optional.of(preparationViewOnly));
        when(users.findByEmployeeId(makerEmployeeId))
                .thenReturn(Optional.of(maker));
        when(users.findById(makerUserId)).thenReturn(Optional.of(maker));
        when(permissions.permsOf(planner)).thenReturn(Set.of(
                "notice:read",
                "subcontract_preparation:view",
                "subcontract_preparation:start"));
        when(permissions.permsOf(production)).thenReturn(Set.of(
                "notice:read",
                "subcontract_preparation:view",
                "subcontract_preparation:start"));
        when(permissions.permsOf(oldProductionOnly)).thenReturn(Set.of(
                "notice:read",
                "production_material_analysis:view",
                "production_material_analysis:create"));
        when(permissions.permsOf(preparationViewOnly)).thenReturn(Set.of(
                "notice:read", "subcontract_preparation:view"));
        ChainNoticeService service = service(
                notice, users, permissions, jdbc,
                mock(BusinessEventPublisher.class));

        service.deliverOutboxEvent(
                ChainNoticeService.EVENT_SUBCONTRACT_PREPARATION_REQUIRED,
                planItemId,
                new ObjectMapper().createObjectNode());

        String taskRoute = "/subcontract/preparations?planItemId=" + planItemId;
        verify(notice).publishForUser(
                eq(plannerId),
                eq("待启动委外前置自制：WO-PREP-001"),
                contains("allowedActions"),
                eq(ChainNoticeService.TYPE_TASK),
                anyString(),
                eq(taskRoute),
                eq(ChainNoticeService.EVENT_SUBCONTRACT_PREPARATION_REQUIRED));
        verify(notice).publishForUser(
                eq(productionId),
                eq("待启动委外前置自制：WO-PREP-001"),
                contains("allowedActions"),
                eq(ChainNoticeService.TYPE_TASK),
                anyString(),
                eq(taskRoute),
                eq(ChainNoticeService.EVENT_SUBCONTRACT_PREPARATION_REQUIRED));
        verify(notice).publishForUser(
                eq(makerUserId),
                eq("委外前置自制待安排：WO-PREP-001"),
                contains("仅作进度提醒"),
                eq(ChainNoticeService.TYPE_WORKFLOW),
                anyString(),
                eq("/subcontract/orders/" + orderId),
                eq(ChainNoticeService.EVENT_SUBCONTRACT_PREPARATION_REQUIRED));
        verify(notice, never()).publishForUser(
                eq(oldProductionOnlyId), anyString(), anyString(), anyString(),
                anyString(), anyString(), anyString());
        verify(notice, never()).publishForUser(
                eq(preparationViewOnlyId), anyString(), anyString(), anyString(),
                anyString(), anyString(), anyString());
    }

    @Test
    void prepareShortageTargetsEligiblePlanAndProductionUsersAndMaker() {
        UUID planItemId = UUID.randomUUID();
        UUID orderId = UUID.randomUUID();
        UUID makerEmployeeId = UUID.randomUUID();
        UUID makerUserId = UUID.randomUUID();
        UUID plannerId = UUID.randomUUID();
        UUID productionId = UUID.randomUUID();
        UUID preparationViewOnlyId = UUID.randomUUID();
        JdbcTemplate jdbc = mock(JdbcTemplate.class);
        NoticeService notice = mock(NoticeService.class);
        UserAccountRepository users = mock(UserAccountRepository.class);
        PermissionResolver permissions = mock(PermissionResolver.class);
        when(jdbc.queryForList(
                contains("item.preparation_status = 'ACTION_REQUIRED'"),
                eq(planItemId))).thenReturn(List.of(Map.of(
                        "plan_id", UUID.randomUUID(),
                        "order_id", orderId,
                        "order_bill_no", "WO-SHORT-001",
                        "maker_id", makerEmployeeId,
                        "planned_qty", new BigDecimal("4.0000"),
                        "goods_code", "FG-002",
                        "goods_name", "缺口目标件")));
        when(jdbc.queryForList(
                contains("WITH RECURSIVE subtree(id)"),
                eq(UUID.class),
                eq("SUB_PLAN"))).thenReturn(List.of(plannerId, preparationViewOnlyId));
        when(jdbc.queryForList(
                contains("WITH RECURSIVE subtree(id)"),
                eq(UUID.class),
                eq("DEPT_PROD"))).thenReturn(List.of(productionId));
        UserAccount planner = activeUser(plannerId);
        UserAccount production = activeUser(productionId);
        UserAccount preparationViewOnly = activeUser(preparationViewOnlyId);
        UserAccount maker = activeUser(makerUserId);
        when(users.findById(plannerId)).thenReturn(Optional.of(planner));
        when(users.findById(productionId)).thenReturn(Optional.of(production));
        when(users.findById(preparationViewOnlyId))
                .thenReturn(Optional.of(preparationViewOnly));
        when(users.findByEmployeeId(makerEmployeeId))
                .thenReturn(Optional.of(maker));
        when(users.findById(makerUserId)).thenReturn(Optional.of(maker));
        when(permissions.permsOf(planner)).thenReturn(Set.of(
                "notice:read",
                "subcontract_preparation:view",
                "subcontract_preparation:start"));
        when(permissions.permsOf(production)).thenReturn(Set.of(
                "notice:read",
                "subcontract_preparation:view",
                "subcontract_preparation:start"));
        when(permissions.permsOf(preparationViewOnly)).thenReturn(Set.of(
                "notice:read", "subcontract_preparation:view"));
        ChainNoticeService service = service(
                notice, users, permissions, jdbc,
                mock(BusinessEventPublisher.class));

        service.deliverOutboxEvent(
                ChainNoticeService.EVENT_SUBCONTRACT_PREPARE_SHORTAGE,
                planItemId,
                new ObjectMapper().createObjectNode());

        String taskRoute = "/subcontract/preparations?planItemId=" + planItemId;
        verify(notice).publishForUser(
                eq(plannerId),
                eq("待补产委外缺口：WO-SHORT-001"),
                contains("缺口 4(基本单位)"),
                eq(ChainNoticeService.TYPE_TASK),
                anyString(),
                eq(taskRoute),
                eq(ChainNoticeService.EVENT_SUBCONTRACT_PREPARE_SHORTAGE));
        verify(notice).publishForUser(
                eq(productionId),
                eq("待补产委外缺口：WO-SHORT-001"),
                contains("现货部分已另行通知仓库直接出仓"),
                eq(ChainNoticeService.TYPE_TASK),
                anyString(),
                eq(taskRoute),
                eq(ChainNoticeService.EVENT_SUBCONTRACT_PREPARE_SHORTAGE));
        verify(notice).publishForUser(
                eq(makerUserId),
                eq("委外目标件存在生产缺口：WO-SHORT-001"),
                contains("仅作进度提醒"),
                eq(ChainNoticeService.TYPE_WORKFLOW),
                anyString(),
                eq("/subcontract/orders/" + orderId),
                eq(ChainNoticeService.EVENT_SUBCONTRACT_PREPARE_SHORTAGE));
        verify(notice, never()).publishForUser(
                eq(preparationViewOnlyId), anyString(), anyString(), anyString(),
                anyString(), anyString(), anyString());
    }

    @Test
    void readyTargetsWarehouseViewAndExecuteAndNotLegacyHandle() {
        UUID planItemId = UUID.randomUUID();
        UUID planId = UUID.randomUUID();
        UUID orderId = UUID.randomUUID();
        UUID makerEmployeeId = UUID.randomUUID();
        UUID makerUserId = UUID.randomUUID();
        UUID allowedId = UUID.randomUUID();
        UUID legacyHandleId = UUID.randomUUID();
        UUID noticeRevokedId = UUID.randomUUID();
        JdbcTemplate jdbc = mock(JdbcTemplate.class);
        NoticeService notice = mock(NoticeService.class);
        UserAccountRepository users = mock(UserAccountRepository.class);
        PermissionResolver permissions = mock(PermissionResolver.class);
        when(jdbc.queryForList(
                contains("item.preparation_status = 'READY_OUTBOUND'"),
                eq(planItemId))).thenReturn(List.of(Map.of(
                        "plan_id", planId,
                        "order_id", orderId,
                        "order_bill_no", "WO-READY-001",
                        "maker_id", makerEmployeeId,
                        "planned_qty", new BigDecimal("10"),
                        "prepared_qty", new BigDecimal("10"),
                        "issued_qty", new BigDecimal("2"),
                        "goods_code", "FG-002",
                        "goods_name", "可出仓件")));
        when(jdbc.queryForList(
                contains("WITH RECURSIVE subtree(id)"),
                eq(UUID.class),
                eq("SUB_WH"))).thenReturn(List.of(
                        allowedId, legacyHandleId, noticeRevokedId));
        UserAccount allowed = activeUser(allowedId);
        UserAccount legacy = activeUser(legacyHandleId);
        UserAccount maker = activeUser(makerUserId);
        UserAccount noticeRevoked = activeUser(noticeRevokedId);
        when(users.findById(allowedId)).thenReturn(Optional.of(allowed));
        when(users.findById(legacyHandleId)).thenReturn(Optional.of(legacy));
        when(users.findById(noticeRevokedId)).thenReturn(Optional.of(noticeRevoked));
        when(users.findByEmployeeId(makerEmployeeId))
                .thenReturn(Optional.of(maker));
        when(users.findById(makerUserId)).thenReturn(Optional.of(maker));
        when(permissions.permsOf(allowed)).thenReturn(Set.of(
                "notice:read", "subcontract_outbound:view", "subcontract_outbound:execute"));
        when(permissions.permsOf(legacy)).thenReturn(Set.of(
                "notice:read", "subcontract_outbound:view", "subcontract_outbound:handle"));
        when(permissions.permsOf(noticeRevoked)).thenReturn(Set.of(
                "subcontract_outbound:view", "subcontract_outbound:execute"));
        ChainNoticeService service = service(
                notice, users, permissions, jdbc,
                mock(BusinessEventPublisher.class));

        service.deliverOutboxEvent(
                ChainNoticeService.EVENT_SUBCONTRACT_OUTBOUND_READY,
                planItemId,
                new ObjectMapper().createObjectNode());

        verify(notice).publishForUser(
                eq(allowedId),
                eq("待执行委外目标件出仓：WO-READY-001"),
                contains("当前可出仓 8"),
                eq(ChainNoticeService.TYPE_TASK),
                anyString(),
                eq("/warehouse/subcontract-outbound/" + planId),
                eq(ChainNoticeService.EVENT_SUBCONTRACT_OUTBOUND_READY));
        verify(notice).publishForUser(
                eq(makerUserId),
                eq("委外目标件已可出仓：WO-READY-001"),
                contains("不代表目标件已经出仓"),
                eq(ChainNoticeService.TYPE_WORKFLOW),
                anyString(),
                eq("/subcontract/orders/" + orderId),
                eq(ChainNoticeService.EVENT_SUBCONTRACT_OUTBOUND_READY));
        verify(notice, never()).publishForUser(
                eq(legacyHandleId), anyString(), anyString(), anyString(),
                anyString(), anyString(), anyString());
        verify(notice, never()).publishForUser(
                eq(noticeRevokedId), anyString(), anyString(), anyString(),
                anyString(), anyString(), anyString());
    }

    @Test
    void outboundCompletedNotifiesOrderMakerAndLinkedAnalysisMakerOnly() {
        UUID issueId = UUID.randomUUID();
        UUID orderId = UUID.randomUUID();
        UUID analysisId = UUID.randomUUID();
        UUID orderMakerEmployeeId = UUID.randomUUID();
        UUID orderMakerUserId = UUID.randomUUID();
        UUID analysisMakerEmployeeId = UUID.randomUUID();
        UUID analysisMakerUserId = UUID.randomUUID();
        UUID warehouseUserId = UUID.randomUUID();
        JdbcTemplate jdbc = mock(JdbcTemplate.class);
        NoticeService notice = mock(NoticeService.class);
        UserAccountRepository users = mock(UserAccountRepository.class);
        PermissionResolver permissions = mock(PermissionResolver.class);
        when(jdbc.queryForList(
                contains("SUM(issue_item.qty"),
                eq(issueId))).thenReturn(List.of(Map.of(
                        "order_id", orderId,
                        "order_bill_no", "WO-OUT-001",
                        "maker_id", orderMakerEmployeeId,
                        "issue_bill_no", "SO-OUT-001",
                        "issued_base_qty", new BigDecimal("4"),
                        "first_goods", "FG-003 出仓件",
                        "goods_count", 1L)));
        when(jdbc.queryForList(
                argThat(sql -> sql.contains("FROM subcontract_material_issues issue")
                        && sql.contains("preplan_supply_action_allocations allocation")),
                eq(issueId))).thenReturn(List.of(Map.of(
                        "analysis_id", analysisId,
                        "maker_id", analysisMakerEmployeeId,
                        "issue_bill_no", "SO-OUT-001")));
        when(jdbc.queryForList(
                contains("WITH RECURSIVE subtree(id)"),
                eq(UUID.class),
                eq("SUB_WH"))).thenReturn(List.of(warehouseUserId));
        UserAccount orderMaker = activeUser(orderMakerUserId);
        UserAccount analysisMaker = activeUser(analysisMakerUserId);
        UserAccount warehouseUser = activeUser(warehouseUserId);
        when(users.findByEmployeeId(orderMakerEmployeeId))
                .thenReturn(Optional.of(orderMaker));
        when(users.findById(orderMakerUserId))
                .thenReturn(Optional.of(orderMaker));
        when(users.findByEmployeeId(analysisMakerEmployeeId))
                .thenReturn(Optional.of(analysisMaker));
        when(users.findById(analysisMakerUserId))
                .thenReturn(Optional.of(analysisMaker));
        when(users.findById(warehouseUserId))
                .thenReturn(Optional.of(warehouseUser));
        when(permissions.permsOf(warehouseUser))
                .thenReturn(Set.of("notice:read", "warehouse_inbound:view"));
        ChainNoticeService service = service(
                notice, users, permissions, jdbc,
                mock(BusinessEventPublisher.class));

        service.deliverOutboxEvent(
                ChainNoticeService.EVENT_SUBCONTRACT_OUTBOUND_COMPLETED,
                issueId,
                new ObjectMapper().createObjectNode());

        verify(notice).publishForUser(
                eq(orderMakerUserId),
                eq("委外目标件已出仓：WO-OUT-001"),
                contains("通知不代表已回厂或品质已结案"),
                eq(ChainNoticeService.TYPE_WORKFLOW),
                anyString(),
                eq("/subcontract/orders/" + orderId),
                eq(ChainNoticeService.EVENT_SUBCONTRACT_OUTBOUND_COMPLETED));
        verify(notice).publishForUser(
                eq(analysisMakerUserId),
                eq("委外供给已出仓：SO-OUT-001"),
                contains("等待委外加工、回厂收货和 IQC"),
                eq(ChainNoticeService.TYPE_WORKFLOW),
                anyString(),
                eq("/production/material-analyses/" + analysisId + "/summary"),
                eq(ChainNoticeService.EVENT_SUBCONTRACT_OUTBOUND_COMPLETED));
        verify(notice).publishForUser(
                eq(warehouseUserId),
                eq("委外预计回厂：WO-OUT-001"),
                contains("本批已真实出仓 4"),
                eq(ChainNoticeService.TYPE_TASK),
                anyString(),
                eq("/warehouse/inbound/expectations"),
                eq(ChainNoticeService.EVENT_SUBCONTRACT_OUTBOUND_COMPLETED));
    }

    @Test
    void outboundReversedWithdrawsTheWarehouseExpectedReturnNotice() {
        UUID issueId = UUID.randomUUID();
        UUID orderId = UUID.randomUUID();
        UUID makerEmployeeId = UUID.randomUUID();
        UUID makerUserId = UUID.randomUUID();
        UUID warehouseUserId = UUID.randomUUID();
        NoticeService notice = mock(NoticeService.class);
        UserAccountRepository users = mock(UserAccountRepository.class);
        PermissionResolver permissions = mock(PermissionResolver.class);
        JdbcTemplate jdbc = mock(JdbcTemplate.class);
        when(jdbc.queryForList(
                argThat(sql -> sql.contains("FROM subcontract_material_issues issue")
                        && sql.contains("issue.status = -1")),
                eq(issueId))).thenReturn(List.of(Map.of(
                        "order_id", orderId,
                        "order_bill_no", "WO-REV-001",
                        "maker_id", makerEmployeeId,
                        "issue_bill_no", "SO-REV-001",
                        "reversed_base_qty", new BigDecimal("3"))));
        when(jdbc.queryForList(
                contains("WITH RECURSIVE subtree(id)"),
                eq(UUID.class),
                eq("SUB_WH"))).thenReturn(List.of(warehouseUserId));
        UserAccount maker = activeUser(makerUserId);
        UserAccount warehouse = activeUser(warehouseUserId);
        when(users.findByEmployeeId(makerEmployeeId)).thenReturn(Optional.of(maker));
        when(users.findById(makerUserId)).thenReturn(Optional.of(maker));
        when(users.findById(warehouseUserId)).thenReturn(Optional.of(warehouse));
        when(permissions.permsOf(warehouse))
                .thenReturn(Set.of("notice:read", "warehouse_inbound:view"));
        ChainNoticeService service = service(
                notice, users, permissions, jdbc,
                mock(BusinessEventPublisher.class));

        service.deliverOutboxEvent(
                ChainNoticeService.EVENT_SUBCONTRACT_OUTBOUND_REVERSED,
                issueId,
                new ObjectMapper().createObjectNode());

        verify(notice).publishForUser(
                eq(makerUserId),
                eq("委外目标件出仓已红冲：WO-REV-001"),
                contains("本批目标件出仓 3"),
                eq(ChainNoticeService.TYPE_URGENT),
                anyString(),
                eq("/subcontract/orders/" + orderId),
                eq(ChainNoticeService.EVENT_SUBCONTRACT_OUTBOUND_REVERSED));
        verify(notice).publishForUser(
                eq(warehouseUserId),
                eq("委外预计回厂已撤回：WO-REV-001"),
                contains("请刷新预计到货任务中心"),
                eq(ChainNoticeService.TYPE_URGENT),
                anyString(),
                eq("/warehouse/inbound/expectations"),
                eq(ChainNoticeService.EVENT_SUBCONTRACT_OUTBOUND_REVERSED));
    }

    @Test
    void subcontractIqcResolutionReturnsPassFailToOrderAndAnalysisMakers() {
        UUID receiptId = UUID.randomUUID();
        UUID orderId = UUID.randomUUID();
        UUID analysisId = UUID.randomUUID();
        UUID warehouseUserId = UUID.randomUUID();
        UUID orderMakerEmployeeId = UUID.randomUUID();
        UUID orderMakerUserId = UUID.randomUUID();
        UUID analysisMakerEmployeeId = UUID.randomUUID();
        UUID analysisMakerUserId = UUID.randomUUID();
        JdbcTemplate jdbc = mock(JdbcTemplate.class);
        NoticeService notice = mock(NoticeService.class);
        UserAccountRepository users = mock(UserAccountRepository.class);
        PermissionResolver permissions = mock(PermissionResolver.class);
        when(jdbc.queryForList(
                contains("FROM subcontract_receipts receipt"),
                eq(receiptId))).thenReturn(List.of(Map.of(
                        "bill_no", "SIN-001",
                        "supplier_name", "不应泄露的委外商",
                        "warehouse_name", "成品仓")));
        when(jdbc.queryForList(
                contains("FROM procurement_inspection_items"),
                eq("SUBCONTRACT"),
                eq(receiptId))).thenReturn(List.of(Map.of(
                        "passed", new BigDecimal("3"),
                        "failed", new BigDecimal("1"))));
        when(jdbc.queryForList(
                contains("WITH RECURSIVE subtree(id)"),
                eq(UUID.class),
                eq("SUB_WH"))).thenReturn(List.of(warehouseUserId));
        when(jdbc.queryForList(
                contains("SELECT DISTINCT order_header.id AS order_id"),
                eq(receiptId))).thenReturn(List.of(Map.of(
                        "order_id", orderId,
                        "order_bill_no", "WO-IQC-001",
                        "maker_id", orderMakerEmployeeId)));
        when(jdbc.queryForList(
                argThat(sql -> sql.contains("FROM subcontract_receipt_items receipt_item")
                        && sql.contains("preplan_supply_action_allocations allocation")),
                eq(receiptId))).thenReturn(List.of(Map.of(
                        "analysis_id", analysisId,
                        "maker_id", analysisMakerEmployeeId)));
        UserAccount warehouse = activeUser(warehouseUserId);
        UserAccount orderMaker = activeUser(orderMakerUserId);
        UserAccount analysisMaker = activeUser(analysisMakerUserId);
        when(users.findById(warehouseUserId)).thenReturn(Optional.of(warehouse));
        when(users.findByEmployeeId(orderMakerEmployeeId))
                .thenReturn(Optional.of(orderMaker));
        when(users.findById(orderMakerUserId))
                .thenReturn(Optional.of(orderMaker));
        when(users.findByEmployeeId(analysisMakerEmployeeId))
                .thenReturn(Optional.of(analysisMaker));
        when(users.findById(analysisMakerUserId))
                .thenReturn(Optional.of(analysisMaker));
        when(permissions.permsOf(warehouse)).thenReturn(Set.of(
                "notice:read", "warehouse_iqc_stock_in:view"));
        ChainNoticeService service = service(
                notice, users, permissions, jdbc,
                mock(BusinessEventPublisher.class));

        service.deliverOutboxEvent(
                ChainNoticeService.EVENT_IQC_RESOLVED,
                receiptId,
                new ObjectMapper().createObjectNode()
                        .put("receiptType", "SUBCONTRACT"));

        verify(notice).publishForUser(
                eq(warehouseUserId),
                eq("品质检验已结案（含不合格）：SIN-001"),
                contains("合格量是否已经进入可用库存"),
                eq(ChainNoticeService.TYPE_WORKFLOW),
                anyString(),
                eq("/warehouse/iqc-stock-ins/SUBCONTRACT/" + receiptId),
                eq(ChainNoticeService.EVENT_IQC_RESOLVED));
        verify(notice).publishForUser(
                eq(orderMakerUserId),
                eq("委外回厂 IQC 已结案：WO-IQC-001"),
                argThat(text -> text.contains("同时存在不合格量")
                        && text.contains("仓库确认后才进入可用库存")
                        && !text.contains("不应泄露的委外商")
                        && !text.contains("金额")),
                eq(ChainNoticeService.TYPE_URGENT),
                anyString(),
                eq("/subcontract/orders/" + orderId),
                eq(ChainNoticeService.EVENT_IQC_RESOLVED));
        verify(notice).publishForUser(
                eq(analysisMakerUserId),
                eq("委外供给 IQC 已结案：SIN-001"),
                contains("复核不合格量"),
                eq(ChainNoticeService.TYPE_URGENT),
                anyString(),
                eq("/production/material-analyses/" + analysisId + "/summary"),
                eq(ChainNoticeService.EVENT_IQC_RESOLVED));
    }

    private static ChainNoticeService service(
            NoticeService notice,
            UserAccountRepository users,
            PermissionResolver permissions,
            JdbcTemplate jdbc,
            BusinessEventPublisher outbox) {
        return new ChainNoticeService(
                notice,
                users,
                permissions,
                mock(UserRoleRepository.class),
                jdbc,
                outbox,
                mock(RdTaskService.class),
                mock(FinanceReviewerEligibilityPort.class),
                mock(SalesOrderFinanceConfirmerEligibility.class));
    }

    private static UserAccount activeUser(UUID userId) {
        UserAccount user = new UserAccount();
        user.setId(userId);
        user.setStatus("active");
        user.setDeleted(false);
        return user;
    }
}
