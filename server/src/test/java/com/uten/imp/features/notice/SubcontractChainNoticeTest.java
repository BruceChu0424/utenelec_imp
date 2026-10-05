package com.uten.imp.features.notice;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.BusinessEventPublisher;
import com.uten.imp.application.port.FinanceReviewerEligibilityPort;
import com.uten.imp.application.port.SubcontractDrawRecheckPort;
import com.uten.imp.features.admin.workflow.SalesOrderFinanceConfirmerEligibility;
import com.uten.imp.features.auth.PermissionResolver;
import com.uten.imp.features.auth.model.UserAccount;
import com.uten.imp.features.auth.model.UserAccountRepository;
import com.uten.imp.features.rd_task.RdTaskService;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.ObjectProvider;
import org.springframework.jdbc.core.JdbcTemplate;

import java.math.BigDecimal;
import java.util.HashMap;
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
import static org.mockito.ArgumentMatchers.isNull;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.when;

/** ADR-143 委外领料通知: 可领料卡、领料待发料、撤回、发料回执与红冲。 */
class SubcontractChainNoticeTest {

    @Test
    void drawLifecycleOnlyAppendsOutboxEventsInsideBusinessTransactions() {
        UUID orderItemId = UUID.randomUUID();
        UUID issueId = UUID.randomUUID();
        BusinessEventPublisher outbox = mock(BusinessEventPublisher.class);
        NoticeService notice = mock(NoticeService.class);
        ChainNoticeService service = service(
                notice,
                mock(UserAccountRepository.class),
                mock(PermissionResolver.class),
                mock(JdbcTemplate.class),
                outbox);

        service.notifySubcontractDrawAvailable(orderItemId);
        service.resolveSubcontractDrawAvailable(orderItemId);
        service.notifySubcontractOutboundReady(issueId);
        service.notifySubcontractDrawWithdrawn(issueId);
        service.notifySubcontractDrawReturned(issueId, " 料损坏 ");
        service.notifySubcontractOutboundCompleted(issueId);
        service.notifySubcontractOutboundReversed(issueId);

        verify(outbox).publish(
                ChainNoticeService.EVENT_SUBCONTRACT_DRAW_AVAILABLE,
                "SUBCONTRACT_ORDER_ITEM",
                orderItemId,
                Map.of());
        verify(outbox).publish(
                ChainNoticeService.EVENT_SUBCONTRACT_DRAW_AVAILABLE_RESOLVED,
                "SUBCONTRACT_ORDER_ITEM",
                orderItemId,
                Map.of());
        // 草稿永不合并: 每张草稿只投递一次「待发料」。
        verify(outbox).publishOnce(
                ChainNoticeService.EVENT_SUBCONTRACT_OUTBOUND_READY,
                "SUBCONTRACT_MATERIAL_ISSUE",
                issueId,
                Map.of(),
                ChainNoticeService.EVENT_SUBCONTRACT_OUTBOUND_READY + ':' + issueId);
        verify(outbox).publish(
                ChainNoticeService.EVENT_SUBCONTRACT_DRAW_WITHDRAWN,
                "SUBCONTRACT_MATERIAL_ISSUE",
                issueId,
                Map.of());
        verify(outbox).publish(
                ChainNoticeService.EVENT_SUBCONTRACT_DRAW_RETURNED,
                "SUBCONTRACT_MATERIAL_ISSUE",
                issueId,
                Map.of("reason", "料损坏"));
        verify(outbox).publishOnce(
                ChainNoticeService.EVENT_SUBCONTRACT_OUTBOUND_COMPLETED,
                "SUBCONTRACT_MATERIAL_ISSUE",
                issueId,
                Map.of(),
                ChainNoticeService.EVENT_SUBCONTRACT_OUTBOUND_COMPLETED + ':' + issueId);
        verify(outbox).publishOnce(
                ChainNoticeService.EVENT_SUBCONTRACT_OUTBOUND_REVERSED,
                "SUBCONTRACT_MATERIAL_ISSUE",
                issueId,
                Map.of(),
                ChainNoticeService.EVENT_SUBCONTRACT_OUTBOUND_REVERSED + ':' + issueId);
        verifyNoInteractions(notice);
    }

    @Test
    void drawAvailableCardGoesOnlyToDrawHoldersWhoCanSeeTheOrder() {
        UUID orderItemId = UUID.randomUUID();
        UUID orderId = UUID.randomUUID();
        UUID makerEmployeeId = UUID.randomUUID();
        UUID drawerId = UUID.randomUUID();
        UUID viewAllId = UUID.randomUUID();
        UUID outsiderId = UUID.randomUUID();
        UUID viewOnlyId = UUID.randomUUID();
        JdbcTemplate jdbc = mock(JdbcTemplate.class);
        NoticeService notice = mock(NoticeService.class);
        UserAccountRepository users = mock(UserAccountRepository.class);
        PermissionResolver permissions = mock(PermissionResolver.class);
        Map<String, Object> task = new HashMap<>();
        task.put("order_id", orderId);
        // 单号里不能带 DRAW: 下面断言正文不出现内部分段代号, 单号本身会写进正文。
        task.put("order_bill_no", "WO-2026-001");
        task.put("maker_id", makerEmployeeId);
        task.put("goods_code", "FG-200");
        task.put("goods_name", "委外成品");
        task.put("unit_name", "个");
        task.put("drawable_qty", new BigDecimal("40.0000"));
        when(jdbc.queryForList(
                contains("fn_subcontract_draw_summary(order_item.id) summary"),
                eq(orderItemId))).thenReturn(List.of(task));
        UserAccount drawer = activeUser(drawerId);
        UserAccount viewAll = activeUser(viewAllId);
        UserAccount outsider = activeUser(outsiderId);
        UserAccount viewOnly = activeUser(viewOnlyId);
        when(users.findAll()).thenReturn(List.of(drawer, viewAll, outsider, viewOnly));
        for (UserAccount account : List.of(drawer, viewAll, outsider, viewOnly)) {
            when(users.findById(account.getId())).thenReturn(Optional.of(account));
        }
        Set<String> draw = Set.of("notice:read", "subcontract_order:view", "subcontract_order:draw");
        when(permissions.permsOf(drawer)).thenReturn(draw);
        when(permissions.permsOf(outsider)).thenReturn(draw);
        when(permissions.permsOf(viewAll)).thenReturn(Set.of(
                "notice:read", "subcontract_order:view", "subcontract_order:draw", "subcontract:view:all"));
        when(permissions.permsOf(viewOnly)).thenReturn(Set.of("notice:read", "subcontract_order:view"));
        // 订货单归属可见范围: 只有 drawer 是经手人(或被授权); outsider 看不到这张单。
        when(jdbc.queryForObject(contains("FROM user_data_scopes data_scope"), eq(Boolean.class),
                eq(drawerId), any(), any(), eq("subcontract"), any())).thenReturn(Boolean.TRUE);
        ChainNoticeService service = service(
                notice, users, permissions, jdbc, mock(BusinessEventPublisher.class));

        service.deliverOutboxEvent(
                ChainNoticeService.EVENT_SUBCONTRACT_DRAW_AVAILABLE,
                orderItemId,
                new ObjectMapper().createObjectNode());

        String route = "/operations/workbench/subcontract?segment=DRAW&orderItemId=" + orderItemId;
        verify(notice).resolveReviewNotices("SUBCONTRACT_ORDER_ITEM", orderItemId, "STATE_CHANGED");
        for (UUID recipient : List.of(drawerId, viewAllId)) {
            verify(notice).publishForUser(
                    eq(recipient),
                    eq("委外可领料：WO-2026-001 委外成品 可领 40 个"),
                    argThat(content -> content.contains("现在可领 40 个")
                            && content.contains("委外任务中心「领料」")
                            && !content.contains("DRAW")),
                    eq(ChainNoticeService.TYPE_TASK),
                    anyString(),
                    eq(route),
                    eq(ChainNoticeService.EVENT_SUBCONTRACT_DRAW_AVAILABLE),
                    eq("important"),
                    eq(orderItemId));
        }
        for (UUID excluded : List.of(outsiderId, viewOnlyId)) {
            verify(notice, never()).publishForUser(
                    eq(excluded), anyString(), anyString(), anyString(), anyString(),
                    anyString(), anyString(), anyString(), any(UUID.class));
        }
    }

    @Test
    void drawAvailableWithNothingDrawableOnlyResolvesTheCard() {
        UUID orderItemId = UUID.randomUUID();
        NoticeService notice = mock(NoticeService.class);
        ChainNoticeService service = service(
                notice,
                mock(UserAccountRepository.class),
                mock(PermissionResolver.class),
                mock(JdbcTemplate.class),
                mock(BusinessEventPublisher.class));

        service.deliverOutboxEvent(
                ChainNoticeService.EVENT_SUBCONTRACT_DRAW_AVAILABLE,
                orderItemId,
                new ObjectMapper().createObjectNode());
        service.deliverOutboxEvent(
                ChainNoticeService.EVENT_SUBCONTRACT_DRAW_AVAILABLE_RESOLVED,
                orderItemId,
                new ObjectMapper().createObjectNode());

        verify(notice).resolveReviewNotices("SUBCONTRACT_ORDER_ITEM", orderItemId, "NOT_DRAWABLE");
        verify(notice).resolveReviewNotices("SUBCONTRACT_ORDER_ITEM", orderItemId, "DRAW_HANDLED");
        verify(notice, never()).publishForUser(
                any(UUID.class), anyString(), anyString(), anyString(), anyString(),
                anyString(), anyString(), anyString(), any(UUID.class));
    }

    @Test
    @SuppressWarnings("unchecked")
    void drawRecheckIsDelegatedByMaterialOrByOrderItems() {
        UUID goodsId = UUID.randomUUID();
        UUID colorId = UUID.randomUUID();
        UUID first = UUID.randomUUID();
        UUID second = UUID.randomUUID();
        UUID aggregate = UUID.randomUUID();
        SubcontractDrawRecheckPort recheck = mock(SubcontractDrawRecheckPort.class);
        ObjectProvider<SubcontractDrawRecheckPort> provider = mock(ObjectProvider.class);
        when(provider.getIfAvailable()).thenReturn(recheck);
        ChainNoticeService service = service(
                mock(NoticeService.class),
                mock(UserAccountRepository.class),
                mock(PermissionResolver.class),
                mock(JdbcTemplate.class),
                mock(BusinessEventPublisher.class));
        service.setDrawRecheck(provider);
        ObjectMapper json = new ObjectMapper();

        service.deliverOutboxEvent(ChainNoticeService.EVENT_SUBCONTRACT_DRAW_RECHECK, goodsId,
                json.createObjectNode().put("goodsId", goodsId.toString()).put("colorId", colorId.toString()));
        var items = json.createObjectNode();
        items.putArray("orderItemIds").add(first.toString()).add(second.toString());
        service.deliverOutboxEvent(ChainNoticeService.EVENT_SUBCONTRACT_DRAW_RECHECK, null, items);
        service.deliverOutboxEvent(ChainNoticeService.EVENT_SUBCONTRACT_DRAW_RECHECK, aggregate,
                json.createObjectNode());

        verify(recheck).recheckForMaterial(goodsId, colorId);
        verify(recheck).recheckForOrderItems(List.of(first, second));
        verify(recheck).recheckForOrderItems(List.of(aggregate));
    }

    @Test
    void drawPendingCardGoesToWarehouseViewAndExecuteHolders() {
        UUID issueId = UUID.randomUUID();
        UUID warehouseId = UUID.randomUUID();
        UUID allowedId = UUID.randomUUID();
        UUID legacyHandleId = UUID.randomUUID();
        UUID noticeRevokedId = UUID.randomUUID();
        JdbcTemplate jdbc = mock(JdbcTemplate.class);
        NoticeService notice = mock(NoticeService.class);
        UserAccountRepository users = mock(UserAccountRepository.class);
        PermissionResolver permissions = mock(PermissionResolver.class);
        Map<String, Object> draft = new HashMap<>();
        draft.put("issue_bill_no", "SO-DRAW-001");
        draft.put("warehouse_id", warehouseId);
        draft.put("warehouse_name", "五金仓");
        draft.put("supplier_name", "甲委外");
        draft.put("submitter_name", "张三");
        draft.put("order_bill_no", "WO-DRAW-002");
        draft.put("material_kind_count", 2L);
        when(jdbc.queryForList(
                contains("COUNT(DISTINCT concat_ws"),
                eq(issueId))).thenReturn(List.of(draft));
        when(jdbc.queryForList(
                contains("WITH RECURSIVE subtree(id)"),
                eq(UUID.class),
                eq("SUB_WH"))).thenReturn(List.of(allowedId, legacyHandleId, noticeRevokedId));
        UserAccount allowed = activeUser(allowedId);
        UserAccount legacy = activeUser(legacyHandleId);
        UserAccount noticeRevoked = activeUser(noticeRevokedId);
        when(users.findById(allowedId)).thenReturn(Optional.of(allowed));
        when(users.findById(legacyHandleId)).thenReturn(Optional.of(legacy));
        when(users.findById(noticeRevokedId)).thenReturn(Optional.of(noticeRevoked));
        when(permissions.permsOf(allowed)).thenReturn(Set.of(
                "notice:read", "subcontract_outbound:view", "subcontract_outbound:execute"));
        when(permissions.permsOf(legacy)).thenReturn(Set.of(
                "notice:read", "subcontract_outbound:view", "subcontract_outbound:handle"));
        when(permissions.permsOf(noticeRevoked)).thenReturn(Set.of(
                "subcontract_outbound:view", "subcontract_outbound:execute"));
        ChainNoticeService service = service(
                notice, users, permissions, jdbc, mock(BusinessEventPublisher.class));

        service.deliverOutboxEvent(
                ChainNoticeService.EVENT_SUBCONTRACT_OUTBOUND_READY,
                issueId,
                new ObjectMapper().createObjectNode());

        verify(notice).resolveReviewNotices("SUBCONTRACT_MATERIAL_ISSUE", issueId, "PENDING_REFRESHED");
        verify(notice).publishForUser(
                eq(allowedId),
                eq("委外领料待发料：WO-DRAW-002 共 2 种物料"),
                argThat(content -> content.contains("出仓草稿 SO-DRAW-001")
                        && content.contains("发料仓库「五金仓」")
                        && content.contains("少发的部分下次领料自动补齐")),
                eq(ChainNoticeService.TYPE_TASK),
                anyString(),
                eq("/warehouse/subcontract-outbound/" + issueId),
                eq(ChainNoticeService.EVENT_SUBCONTRACT_OUTBOUND_READY),
                isNull(),
                eq(issueId));
        for (UUID excluded : List.of(legacyHandleId, noticeRevokedId)) {
            verify(notice, never()).publishForUser(
                    eq(excluded), anyString(), anyString(), anyString(), anyString(),
                    anyString(), anyString(), any(), any(UUID.class));
        }
    }

    @Test
    void withdrawingTheWholeDraftRetiresTheCardAndTellsTheWarehouse() {
        UUID issueId = UUID.randomUUID();
        UUID warehouseUserId = UUID.randomUUID();
        JdbcTemplate jdbc = mock(JdbcTemplate.class);
        NoticeService notice = mock(NoticeService.class);
        UserAccountRepository users = mock(UserAccountRepository.class);
        PermissionResolver permissions = mock(PermissionResolver.class);
        Map<String, Object> header = new HashMap<>();
        header.put("issue_bill_no", "SO-DRAW-003");
        header.put("warehouse_id", UUID.randomUUID());
        header.put("status", 0);
        header.put("order_bill_no", "WO-DRAW-003");
        when(jdbc.queryForList(
                contains("LIMIT 1) AS order_bill_no"),
                eq(issueId))).thenReturn(List.of(header));
        when(jdbc.queryForList(
                contains("WITH RECURSIVE subtree(id)"),
                eq(UUID.class),
                eq("SUB_WH"))).thenReturn(List.of(warehouseUserId));
        UserAccount warehouseUser = activeUser(warehouseUserId);
        when(users.findById(warehouseUserId)).thenReturn(Optional.of(warehouseUser));
        when(permissions.permsOf(warehouseUser)).thenReturn(Set.of(
                "notice:read", "subcontract_outbound:view"));
        ChainNoticeService service = service(
                notice, users, permissions, jdbc, mock(BusinessEventPublisher.class));

        service.deliverOutboxEvent(
                ChainNoticeService.EVENT_SUBCONTRACT_DRAW_WITHDRAWN,
                issueId,
                new ObjectMapper().createObjectNode());

        verify(notice).resolveReviewNotices("SUBCONTRACT_MATERIAL_ISSUE", issueId, "STATE_CHANGED");
        verify(notice).publishForUser(
                eq(warehouseUserId),
                eq("委外领料已撤回：SO-DRAW-003"),
                argThat(content -> content.contains("委外订货单 WO-DRAW-003")
                        && content.contains("不用再拣货")),
                eq(ChainNoticeService.TYPE_WORKFLOW),
                anyString(),
                eq("/warehouse/subcontract-outbound"),
                eq(ChainNoticeService.EVENT_SUBCONTRACT_DRAW_WITHDRAWN),
                eq("normal"));
    }

    @Test
    void warehouseReturningTheDraftRetiresTheCardAndTellsTheSubmitter() {
        UUID issueId = UUID.randomUUID();
        UUID submitterUserId = UUID.randomUUID();
        UUID orderItemId = UUID.randomUUID();
        JdbcTemplate jdbc = mock(JdbcTemplate.class);
        NoticeService notice = mock(NoticeService.class);
        UserAccountRepository users = mock(UserAccountRepository.class);
        Map<String, Object> header = new HashMap<>();
        header.put("issue_bill_no", "SO-DRAW-009");
        header.put("submitter_user_id", submitterUserId);
        header.put("warehouse_name", "原料仓");
        header.put("order_bill_no", "WO-DRAW-009");
        header.put("order_item_id", orderItemId.toString());
        when(jdbc.queryForList(
                contains("issue.created_by AS submitter_user_id"),
                eq(issueId))).thenReturn(List.of(header));
        UserAccount submitter = activeUser(submitterUserId);
        when(users.findById(submitterUserId)).thenReturn(Optional.of(submitter));
        ChainNoticeService service = service(
                notice, users, mock(PermissionResolver.class), jdbc, mock(BusinessEventPublisher.class));

        service.deliverOutboxEvent(
                ChainNoticeService.EVENT_SUBCONTRACT_DRAW_RETURNED,
                issueId,
                new ObjectMapper().createObjectNode().put("reason", "料损坏"));

        verify(notice).resolveReviewNotices("SUBCONTRACT_MATERIAL_ISSUE", issueId, "STATE_CHANGED");
        verify(notice).publishForUser(
                eq(submitterUserId),
                eq("仓库退回了领料：WO-DRAW-009"),
                argThat(content -> content.contains("仓库「原料仓」退回了委外订货单 WO-DRAW-009 的领料出仓单 SO-DRAW-009")
                        && content.contains("退回原因：料损坏")
                        && content.contains("重新领料")),
                eq(ChainNoticeService.TYPE_WORKFLOW),
                anyString(),
                eq("/operations/workbench/subcontract?segment=DRAW&orderItemId=" + orderItemId),
                eq(ChainNoticeService.EVENT_SUBCONTRACT_DRAW_RETURNED),
                eq("normal"));
    }

    @Test
    void outboundCompletedReportsDrawnSetsShortIssueAndExpectedReturn() {
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
        Map<String, Object> target = new HashMap<>();
        target.put("order_id", orderId);
        target.put("order_bill_no", "WO-OUT-001");
        target.put("maker_id", orderMakerEmployeeId);
        target.put("issue_bill_no", "SO-OUT-001");
        target.put("goods_code", "FG-300");
        target.put("goods_name", "委外成品");
        target.put("unit_name", "个");
        target.put("drawn_qty", new BigDecimal("40.0000"));
        target.put("returnable_qty", new BigDecimal("40.0000"));
        when(jdbc.queryForList(
                contains("summary.drawn_qty"),
                eq(issueId))).thenReturn(List.of(target));
        Map<String, Object> shortLine = new HashMap<>();
        shortLine.put("goods_code", "RM-B");
        shortLine.put("goods_name", "B 料");
        shortLine.put("unit_name", "个");
        shortLine.put("short_qty", new BigDecimal("20.0000"));
        when(jdbc.queryForList(
                contains("issue_item.warehouse_dropped_at IS NOT NULL"),
                eq(issueId))).thenReturn(List.of(shortLine));
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
        when(users.findByEmployeeId(orderMakerEmployeeId)).thenReturn(Optional.of(orderMaker));
        when(users.findById(orderMakerUserId)).thenReturn(Optional.of(orderMaker));
        when(users.findByEmployeeId(analysisMakerEmployeeId)).thenReturn(Optional.of(analysisMaker));
        when(users.findById(analysisMakerUserId)).thenReturn(Optional.of(analysisMaker));
        when(users.findById(warehouseUserId)).thenReturn(Optional.of(warehouseUser));
        when(permissions.permsOf(warehouseUser))
                .thenReturn(Set.of("notice:read", "warehouse_inbound:view"));
        ChainNoticeService service = service(
                notice, users, permissions, jdbc, mock(BusinessEventPublisher.class));

        service.deliverOutboxEvent(
                ChainNoticeService.EVENT_SUBCONTRACT_OUTBOUND_COMPLETED,
                issueId,
                new ObjectMapper().createObjectNode());

        verify(notice).resolveReviewNotices("SUBCONTRACT_MATERIAL_ISSUE", issueId, "ISSUED");
        verify(notice).publishForUser(
                eq(orderMakerUserId),
                eq("委外直属物料已发出：WO-OUT-001"),
                argThat(content -> content.contains("本次发出后累计已发齐 委外成品 40 个")
                        && content.contains("少发：B 料 20 个(下次领料自动补齐)")
                        && content.contains("回厂时登记的是委外件")
                        && !content.contains("基本单位")),
                eq(ChainNoticeService.TYPE_WORKFLOW),
                anyString(),
                eq("/subcontract/orders/" + orderId),
                eq(ChainNoticeService.EVENT_SUBCONTRACT_OUTBOUND_COMPLETED));
        verify(notice).publishForUser(
                eq(warehouseUserId),
                eq("委外预计回厂：WO-OUT-001"),
                argThat(content -> content.contains("委外商手里的料还能做成 委外成品 40 个")
                        && content.contains("不要按物料登记")),
                eq(ChainNoticeService.TYPE_TASK),
                anyString(),
                eq("/warehouse/inbound/expectations"),
                eq(ChainNoticeService.EVENT_SUBCONTRACT_OUTBOUND_COMPLETED));
        verify(notice).publishForUser(
                eq(analysisMakerUserId),
                eq("委外直属物料已发出：SO-OUT-001"),
                contains("等待委外加工、回厂收货和来料质检"),
                eq(ChainNoticeService.TYPE_WORKFLOW),
                anyString(),
                eq("/production/material-analyses/" + analysisId + "/summary"),
                eq(ChainNoticeService.EVENT_SUBCONTRACT_OUTBOUND_COMPLETED));
    }

    @Test
    void partialIssueWithoutACompleteSetDoesNotAnnounceExpectedReturn() {
        UUID issueId = UUID.randomUUID();
        UUID orderMakerEmployeeId = UUID.randomUUID();
        UUID orderMakerUserId = UUID.randomUUID();
        JdbcTemplate jdbc = mock(JdbcTemplate.class);
        NoticeService notice = mock(NoticeService.class);
        UserAccountRepository users = mock(UserAccountRepository.class);
        Map<String, Object> target = new HashMap<>();
        target.put("order_id", UUID.randomUUID());
        target.put("order_bill_no", "WO-OUT-002");
        target.put("maker_id", orderMakerEmployeeId);
        target.put("issue_bill_no", "SO-OUT-002");
        target.put("goods_code", "FG-301");
        target.put("goods_name", "委外成品二");
        target.put("unit_name", "个");
        target.put("drawn_qty", BigDecimal.ZERO);
        target.put("returnable_qty", BigDecimal.ZERO);
        when(jdbc.queryForList(
                contains("summary.drawn_qty"),
                eq(issueId))).thenReturn(List.of(target));
        UserAccount orderMaker = activeUser(orderMakerUserId);
        when(users.findByEmployeeId(orderMakerEmployeeId)).thenReturn(Optional.of(orderMaker));
        when(users.findById(orderMakerUserId)).thenReturn(Optional.of(orderMaker));
        ChainNoticeService service = service(
                notice, users, mock(PermissionResolver.class), jdbc, mock(BusinessEventPublisher.class));

        service.deliverOutboxEvent(
                ChainNoticeService.EVENT_SUBCONTRACT_OUTBOUND_COMPLETED,
                issueId,
                new ObjectMapper().createObjectNode());

        verify(notice).publishForUser(
                eq(orderMakerUserId),
                eq("委外直属物料已发出：WO-OUT-002"),
                contains("还没有发齐一整套委外件"),
                eq(ChainNoticeService.TYPE_WORKFLOW),
                anyString(),
                anyString(),
                eq(ChainNoticeService.EVENT_SUBCONTRACT_OUTBOUND_COMPLETED));
        verify(notice, never()).publishForUser(
                any(UUID.class), eq("委外预计回厂：WO-OUT-002"), anyString(), anyString(),
                anyString(), anyString(), anyString());
    }

    @Test
    void outboundReversedListsEveryMaterialAndWithdrawsExpectedReturn() {
        UUID issueId = UUID.randomUUID();
        UUID orderId = UUID.randomUUID();
        UUID makerEmployeeId = UUID.randomUUID();
        UUID makerUserId = UUID.randomUUID();
        UUID warehouseUserId = UUID.randomUUID();
        NoticeService notice = mock(NoticeService.class);
        UserAccountRepository users = mock(UserAccountRepository.class);
        PermissionResolver permissions = mock(PermissionResolver.class);
        JdbcTemplate jdbc = mock(JdbcTemplate.class);
        Map<String, Object> first = new HashMap<>();
        first.put("order_id", orderId);
        first.put("order_bill_no", "WO-REV-001");
        first.put("maker_id", makerEmployeeId);
        first.put("issue_bill_no", "SO-REV-001");
        first.put("goods_code", "RM-A");
        first.put("goods_name", "A 料");
        first.put("unit_name", "个");
        first.put("reversed_qty", new BigDecimal("3.0000"));
        Map<String, Object> second = new HashMap<>(first);
        second.put("goods_code", "RM-B");
        second.put("goods_name", "B 料");
        second.put("reversed_qty", new BigDecimal("6.0000"));
        when(jdbc.queryForList(
                argThat(sql -> sql.contains("FROM subcontract_material_issues issue")
                        && sql.contains("issue.status = -1")),
                eq(issueId))).thenReturn(List.of(first, second));
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
                notice, users, permissions, jdbc, mock(BusinessEventPublisher.class));

        service.deliverOutboxEvent(
                ChainNoticeService.EVENT_SUBCONTRACT_OUTBOUND_REVERSED,
                issueId,
                new ObjectMapper().createObjectNode());

        verify(notice).publishForUser(
                eq(makerUserId),
                eq("委外领料发出已红冲：WO-REV-001"),
                contains("撤销发出：A 料 3 个、B 料 6 个"),
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
        // V596 先入库后检统计也查 procurement_inspection_items——上面的宽匹配桩会
        // 同时命中它，返回缺 pre_stocked_lines 键的 Map 而 NPE；单独桩住这张「未走上架」的单。
        when(jdbc.queryForList(
                contains("pre_stocked_at IS NOT NULL"),
                eq("SUBCONTRACT"),
                eq(receiptId))).thenReturn(List.of(Map.of(
                        "pre_stocked_lines", 0L,
                        "failed_pre_stocked_lines", 0L)));
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
                eq("委外回厂来料质检已结案：WO-IQC-001"),
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
                eq("委外供给来料质检已结案：SIN-001"),
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
