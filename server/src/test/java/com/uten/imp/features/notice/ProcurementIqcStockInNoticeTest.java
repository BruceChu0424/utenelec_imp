package com.uten.imp.features.notice;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.BusinessEventPublisher;
import com.uten.imp.application.port.FinanceReviewerEligibilityPort;
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

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.contains;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.ArgumentMatchers.isNull;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.when;

class ProcurementIqcStockInNoticeTest {

    @Test
    void allFailResolutionNeverClaimsOrRoutesToAWarehouseStockInTask() {
        assertThat(ChainNoticeService.hasWarehouseIqcStockInTask(BigDecimal.ZERO))
                .isFalse();
        assertThat(ChainNoticeService.subcontractIqcResolutionMessage(
                "EJ-FAIL-001", BigDecimal.ZERO, new BigDecimal("10")))
                .contains("未形成合格量")
                .contains("不会生成仓库待入库任务")
                .doesNotContain("存在合格量");
    }

    @Test
    void mixedResolutionKeepsQualityAndWarehouseFactsSeparate() {
        assertThat(ChainNoticeService.hasWarehouseIqcStockInTask(
                new BigDecimal("6"))).isTrue();
        assertThat(ChainNoticeService.subcontractIqcResolutionMessage(
                "EJ-MIXED-001", new BigDecimal("6"), new BigDecimal("4")))
                .contains("存在合格量")
                .contains("同时存在不合格量")
                .contains("经仓库确认后才进入可用库存");
    }

    @Test
    void pendingReleaseUsesWarehouseDeepLinkAndRequiresNoticePlusPageView() {
        UUID passEventId = UUID.randomUUID();
        UUID receiptId = UUID.randomUUID();
        UUID eligibleId = UUID.randomUUID();
        UUID noticeOnlyId = UUID.randomUUID();
        UUID viewOnlyId = UUID.randomUUID();
        JdbcTemplate jdbc = mock(JdbcTemplate.class);
        NoticeService notice = mock(NoticeService.class);
        UserAccountRepository users = mock(UserAccountRepository.class);
        PermissionResolver permissions = mock(PermissionResolver.class);

        when(jdbc.queryForList(
                contains("FROM procurement_inspection_events event"),
                eq("PURCHASE"), eq(receiptId), eq(passEventId)))
                .thenReturn(List.of(Map.of(
                        "bill_no", "CJ-001",
                        "supplier_name", "供应商甲",
                        "warehouse_name", "原料仓",
                        "goods_code", "G-001",
                        "goods_name", "测试货品",
                        "unit_name", "个",
                        "remaining_qty", new BigDecimal("6.0000"))));
        when(jdbc.queryForList(
                contains("WITH RECURSIVE subtree"),
                eq(UUID.class), eq("SUB_WH")))
                .thenReturn(List.of(eligibleId, noticeOnlyId, viewOnlyId));

        UserAccount eligible = activeUser(eligibleId);
        UserAccount noticeOnly = activeUser(noticeOnlyId);
        UserAccount viewOnly = activeUser(viewOnlyId);
        when(users.findById(eligibleId)).thenReturn(Optional.of(eligible));
        when(users.findById(noticeOnlyId)).thenReturn(Optional.of(noticeOnly));
        when(users.findById(viewOnlyId)).thenReturn(Optional.of(viewOnly));
        when(permissions.permsOf(eligible)).thenReturn(Set.of(
                "notice:read", "warehouse_iqc_stock_in:view"));
        when(permissions.permsOf(noticeOnly)).thenReturn(Set.of("notice:read"));
        when(permissions.permsOf(viewOnly)).thenReturn(Set.of(
                "warehouse_iqc_stock_in:view"));

        ChainNoticeService service = service(notice, users, permissions, jdbc);
        service.deliverOutboxEvent(
                ChainNoticeService.EVENT_IQC_STOCK_IN_PENDING,
                passEventId,
                new ObjectMapper().createObjectNode()
                        .put("receiptType", "PURCHASE")
                        .put("receiptId", receiptId.toString()));

        // 2026-09-05 起为居中行动卡：显式 aggregate（passEventId），仓库确认
        // 入库后按 (PROCUREMENT_INSPECTION_PASS, passEventId) 办结撤回。
        verify(notice).publishForUser(
                eq(eligibleId),
                eq("品质已放行，待仓库入库：CJ-001"),
                contains("确认前不会增加可用库存"),
                eq(ChainNoticeService.TYPE_TASK),
                anyString(),
                eq("/warehouse/iqc-stock-ins/PURCHASE/" + receiptId),
                eq(ChainNoticeService.EVENT_IQC_STOCK_IN_PENDING),
                isNull(),
                eq(passEventId));
        verify(notice, never()).publishForUser(
                eq(noticeOnlyId), anyString(), anyString(), anyString(),
                anyString(), anyString(), anyString());
        verify(notice, never()).publishForUser(
                eq(viewOnlyId), anyString(), anyString(), anyString(),
                anyString(), anyString(), anyString());
    }

    @Test
    void alreadyStockedReleaseDropsQueuedNotification() {
        UUID passEventId = UUID.randomUUID();
        UUID receiptId = UUID.randomUUID();
        JdbcTemplate jdbc = mock(JdbcTemplate.class);
        NoticeService notice = mock(NoticeService.class);
        when(jdbc.queryForList(
                contains("FROM procurement_inspection_events event"),
                eq("PURCHASE"), eq(receiptId), eq(passEventId)))
                .thenReturn(List.of(Map.of(
                        "bill_no", "CJ-002",
                        "remaining_qty", BigDecimal.ZERO)));

        ChainNoticeService service = service(
                notice,
                mock(UserAccountRepository.class),
                mock(PermissionResolver.class),
                jdbc);
        service.deliverOutboxEvent(
                ChainNoticeService.EVENT_IQC_STOCK_IN_PENDING,
                passEventId,
                new ObjectMapper().createObjectNode()
                        .put("receiptType", "PURCHASE")
                        .put("receiptId", receiptId.toString()));

        verifyNoInteractions(notice);
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
                mock(com.uten.imp.features.admin.workflow
                        .SalesOrderFinanceConfirmerEligibility.class));
    }

    private static UserAccount activeUser(UUID userId) {
        UserAccount user = new UserAccount();
        user.setId(userId);
        user.setStatus("active");
        user.setDeleted(false);
        return user;
    }
}
