package com.uten.imp.features.notice;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ObjectNode;
import com.uten.imp.application.port.BusinessEventPublisher;
import com.uten.imp.application.port.FinanceReviewerEligibilityPort;
import com.uten.imp.application.port.MaterialAnalysisBomRefreshPort;
import com.uten.imp.application.port.RdBomGapPort;
import com.uten.imp.features.auth.PermissionResolver;
import com.uten.imp.features.auth.model.UserAccount;
import com.uten.imp.features.auth.model.UserAccountRepository;
import com.uten.imp.features.rd_task.RdTaskService;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.ObjectProvider;
import org.springframework.jdbc.core.JdbcTemplate;

import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.contains;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.ArgumentMatchers.startsWith;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.when;

/**
 * ADR-143 §二.3 研发完善委外件 BOM 后的自动刷新：GOODS_BOM_UPDATED 的投递只给每张待刷新的物料分析排一条
 * MATERIAL_ANALYSIS_BOM_REFRESH，不在本投递里刷新；每条刷新事件自己刷新、失败抛出让 outbox 重试，
 * 刷新完才告诉等这张分析的人「物料分析已自动更新」。
 */
class BomUpdatedAnalysisRefreshNoticeTest {

    private final UUID goodsId = UUID.randomUUID();
    private final UUID refreshedAnalysis = UUID.randomUUID();
    private final UUID otherAnalysis = UUID.randomUUID();
    private final UUID orderId = UUID.randomUUID();
    private final UUID planner = UUID.randomUUID();
    private final UUID buyer = UUID.randomUUID();
    private final UUID otherPlanner = UUID.randomUUID();
    private final UUID plannerUser = UUID.randomUUID();
    private final UUID buyerUser = UUID.randomUUID();
    private final UUID otherPlannerUser = UUID.randomUUID();

    private JdbcTemplate jdbc;
    private NoticeService notice;
    private UserAccountRepository users;
    private BusinessEventPublisher outbox;
    private RdTaskService rdTasks;
    private MaterialAnalysisBomRefreshPort refresher;
    private ChainNoticeService service;

    @BeforeEach
    @SuppressWarnings("unchecked")
    void setUp() {
        jdbc = mock(JdbcTemplate.class);
        notice = mock(NoticeService.class);
        users = mock(UserAccountRepository.class);
        outbox = mock(BusinessEventPublisher.class);
        rdTasks = mock(RdTaskService.class);
        refresher = mock(MaterialAnalysisBomRefreshPort.class);
        service = new ChainNoticeService(notice, users, mock(PermissionResolver.class), jdbc, outbox, rdTasks,
                mock(FinanceReviewerEligibilityPort.class),
                mock(com.uten.imp.features.admin.workflow.SalesOrderFinanceConfirmerEligibility.class));
        ObjectProvider<MaterialAnalysisBomRefreshPort> provider = mock(ObjectProvider.class);
        when(provider.getIfAvailable()).thenReturn(refresher);
        service.setBomRefresh(provider);
        when(jdbc.queryForList(contains("FROM goods WHERE id = ?"), eq(goodsId)))
                .thenReturn(List.of(Map.of("label", "外壳(WK-1)")));
        account(planner, plannerUser);
        account(buyer, buyerUser);
        account(otherPlanner, otherPlannerUser);
    }

    @Test
    void bomUpdateOnlyQueuesOneRefreshPerAnalysisAndDefersThatAnalysisWaiters() {
        when(jdbc.queryForObject(contains("FROM goods_bom_items"), eq(Integer.class), eq(goodsId))).thenReturn(2);
        when(jdbc.queryForObject(contains("fn_subcontract_draw_edges"), eq(Boolean.class), eq(goodsId)))
                .thenReturn(true);
        when(rdTasks.openBomTaskWaiters(goodsId)).thenReturn(List.of(
                new RdTaskService.BomTaskWaiter(planner, RdBomGapPort.SOURCE_MATERIAL_ANALYSIS, refreshedAnalysis),
                new RdTaskService.BomTaskWaiter(buyer, RdBomGapPort.SOURCE_SUBCONTRACT_ORDER, orderId),
                new RdTaskService.BomTaskWaiter(otherPlanner, RdBomGapPort.SOURCE_MATERIAL_ANALYSIS, otherAnalysis)));
        when(rdTasks.resolveOpenBomTasksForGoods(eq(goodsId), anyString())).thenReturn(1);
        when(refresher.analysesAwaitingBomRefresh(goodsId)).thenReturn(List.of(refreshedAnalysis));

        service.deliverOutboxEvent(ChainNoticeService.EVENT_BOM_UPDATED, goodsId,
                new ObjectMapper().createObjectNode());

        verify(outbox).publishOnce(eq(ChainNoticeService.EVENT_MATERIAL_ANALYSIS_BOM_REFRESH),
                eq(ChainNoticeService.AGGREGATE_MATERIAL_ANALYSIS), eq(refreshedAnalysis),
                eq(Map.of("analysisId", refreshedAnalysis.toString(), "goodsId", goodsId.toString(),
                        "waiterEmployeeIds", List.of(planner.toString()))),
                startsWith(ChainNoticeService.EVENT_MATERIAL_ANALYSIS_BOM_REFRESH + ":" + refreshedAnalysis
                        + ":" + goodsId + ":"));
        verify(refresher, never()).refreshAnalysisAfterBomUpdated(any(), any());
        verify(rdTasks).resolveOpenBomTasksForGoods(eq(goodsId), anyString());
        // 等要刷新那张分析的人留给刷新事件通知；其余马上通知，文案不说物料分析已更新。
        verify(notice, never()).publishForUser(eq(plannerUser), anyString(), anyString(), anyString(),
                anyString(), anyString(), anyString());
        verify(notice).publishForUser(eq(buyerUser), eq("BOM 已完善：外壳(WK-1)"),
                eq("外壳(WK-1) 的 BOM 已完善，可以继续下达 / 下委外单。"), eq(ChainNoticeService.TYPE_TASK),
                anyString(), eq("/subcontract/orders/" + orderId), eq(ChainNoticeService.EVENT_BOM_UPDATED));
        verify(notice).publishForUser(eq(otherPlannerUser), eq("BOM 已完善：外壳(WK-1)"),
                eq("外壳(WK-1) 的 BOM 已完善，打开物料分析刷新后即可下达。"), eq(ChainNoticeService.TYPE_TASK),
                anyString(), eq("/production/material-analysis?analysisId=" + otherAnalysis),
                eq(ChainNoticeService.EVENT_BOM_UPDATED));
    }

    @Test
    void refreshEventRefreshesItsAnalysisThenTellsItsWaiters() {
        when(refresher.refreshAnalysisAfterBomUpdated(refreshedAnalysis, goodsId))
                .thenReturn(MaterialAnalysisBomRefreshPort.Outcome.REFRESHED);

        service.deliverOutboxEvent(ChainNoticeService.EVENT_MATERIAL_ANALYSIS_BOM_REFRESH, refreshedAnalysis,
                refreshPayload());

        verify(refresher).refreshAnalysisAfterBomUpdated(refreshedAnalysis, goodsId);
        verify(notice).publishForUser(eq(plannerUser), eq("BOM 已完善：外壳(WK-1)"),
                eq("外壳(WK-1) 的 BOM 已完善，物料分析已自动更新，可以下达。"), eq(ChainNoticeService.TYPE_TASK),
                anyString(), eq("/production/material-analysis?analysisId=" + refreshedAnalysis),
                eq(ChainNoticeService.EVENT_BOM_UPDATED));
    }

    @Test
    void refreshFailurePropagatesSoTheOutboxRetriesAndNobodyIsTold() {
        when(refresher.refreshAnalysisAfterBomUpdated(refreshedAnalysis, goodsId))
                .thenThrow(new IllegalStateException("lock timeout"));

        RuntimeException failure = assertThrows(RuntimeException.class, () -> service.deliverOutboxEvent(
                ChainNoticeService.EVENT_MATERIAL_ANALYSIS_BOM_REFRESH, refreshedAnalysis, refreshPayload()));

        assertEquals("lock timeout", failure.getMessage());
        verifyNoInteractions(notice);
    }

    @Test
    void analysisThatCannotBeRefreshedAutomaticallyAsksTheWaiterToRefreshIt() {
        when(refresher.refreshAnalysisAfterBomUpdated(refreshedAnalysis, goodsId))
                .thenReturn(MaterialAnalysisBomRefreshPort.Outcome.SKIPPED);

        service.deliverOutboxEvent(ChainNoticeService.EVENT_MATERIAL_ANALYSIS_BOM_REFRESH, refreshedAnalysis,
                refreshPayload());

        verify(notice).publishForUser(eq(plannerUser), eq("BOM 已完善：外壳(WK-1)"),
                eq("外壳(WK-1) 的 BOM 已完善，打开物料分析刷新后即可下达。"), eq(ChainNoticeService.TYPE_TASK),
                anyString(), eq("/production/material-analysis?analysisId=" + refreshedAnalysis),
                eq(ChainNoticeService.EVENT_BOM_UPDATED));
    }

    private ObjectNode refreshPayload() {
        ObjectNode payload = new ObjectMapper().createObjectNode()
                .put("analysisId", refreshedAnalysis.toString())
                .put("goodsId", goodsId.toString());
        payload.putArray("waiterEmployeeIds").add(planner.toString());
        return payload;
    }

    private void account(UUID employeeId, UUID userId) {
        UserAccount user = new UserAccount();
        user.setId(userId);
        user.setStatus("active");
        user.setDeleted(false);
        when(users.findByEmployeeId(employeeId)).thenReturn(Optional.of(user));
        when(users.findById(userId)).thenReturn(Optional.of(user));
    }
}
