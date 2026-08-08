package com.uten.imp.features.production.plan;

import com.uten.imp.common.docnumber.DocNumberService;
import com.uten.imp.common.util.EmployeeNameResolver;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.notice.ChainNoticeService;
import com.uten.imp.features.production.analysis.MaterialAnalysisService;
import com.uten.imp.features.production.mrp.MrpService;
import com.uten.imp.features.production.mrp.ProductionPlanningDraftService;
import com.uten.imp.features.production.plan.dto.PlanSaveRequest;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import jakarta.persistence.LockModeType;
import jakarta.persistence.Query;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.List;
import java.util.Optional;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyInt;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.atLeastOnce;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.times;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class ProductionPlanServiceTest {

    private ProductionPlanRepository planRepo;
    private ProductionPlanItemRepository itemRepo;
    private PlanOrderItemLinkRepository linkRepo;
    private MrpService mrpService;
    private ProductionPlanningDraftService planningDraftService;
    private SecurityContextCurrentUser currentUser;
    private EmployeeNameResolver nameResolver;
    private EntityManager em;
    private ChainNoticeService chainNotice;
    private MaterialAnalysisService materialAnalysisService;

    private Query allocationLock;
    private Query plannedIncrement;
    private Query historicalLinkCount;
    private Query recomputeClosed;
    private Query planItemLock;
    private Query stockDownstream;
    private Query purchaseDownstream;
    private Query subplanDownstream;
    private Query executionV1ParentLink;
    private Query unlinkOrderLock;
    private Query plannedDecrement;
    private Query analysisHeaderLock;
    private Query analysisPlanConsistency;

    private ProductionPlanService service;

    @BeforeEach
    void setUp() {
        planRepo = mock(ProductionPlanRepository.class);
        itemRepo = mock(ProductionPlanItemRepository.class);
        linkRepo = mock(PlanOrderItemLinkRepository.class);
        mrpService = mock(MrpService.class);
        planningDraftService = mock(ProductionPlanningDraftService.class);
        TxSessionVars tx = mock(TxSessionVars.class);
        currentUser = mock(SecurityContextCurrentUser.class);
        nameResolver = mock(EmployeeNameResolver.class);
        em = mock(EntityManager.class);
        DocNumberService docNumbers = mock(DocNumberService.class);
        chainNotice = mock(ChainNoticeService.class);
        materialAnalysisService = mock(MaterialAnalysisService.class);

        allocationLock = query();
        plannedIncrement = query();
        historicalLinkCount = query();
        recomputeClosed = query();
        planItemLock = query();
        stockDownstream = query();
        purchaseDownstream = query();
        subplanDownstream = query();
        executionV1ParentLink = query();
        unlinkOrderLock = query();
        plannedDecrement = query();
        analysisHeaderLock = query();
        analysisPlanConsistency = query();

        when(plannedIncrement.executeUpdate()).thenReturn(1);
        when(historicalLinkCount.getSingleResult()).thenReturn(0L);
        when(recomputeClosed.executeUpdate()).thenReturn(1);
        when(plannedDecrement.executeUpdate()).thenReturn(1);
        when(stockDownstream.getResultList()).thenReturn(List.of());
        when(purchaseDownstream.getResultList()).thenReturn(List.of());
        when(subplanDownstream.getResultList()).thenReturn(List.of());
        when(executionV1ParentLink.getResultList()).thenReturn(List.of());
        when(analysisHeaderLock.getResultList()).thenReturn(List.of());
        when(analysisPlanConsistency.getResultList()).thenReturn(List.of());
        when(mrpService.isPlanningWriteReady()).thenReturn(false);

        when(em.createNativeQuery(anyString())).thenAnswer(invocation -> {
            String sql = invocation.getArgument(0);
            if (sql.contains("SELECT COUNT(*)") && sql.contains("FROM plan_order_item_links")) {
                return historicalLinkCount;
            }
            if (sql.contains("JOIN sales_orders o") && sql.contains("FOR UPDATE OF o, i")) {
                return allocationLock;
            }
            if (sql.contains("SET planned_qty = COALESCE(planned_qty,0) + :a")) {
                return plannedIncrement;
            }
            if (sql.contains("UPDATE production_plans p SET is_closed")) {
                return recomputeClosed;
            }
            if (sql.contains("SELECT id, fqty, iqty")) {
                return planItemLock;
            }
            if (sql.contains("FROM plan_draw_links l")) {
                return stockDownstream;
            }
            if (sql.contains("FROM mrp_generations g")) {
                return purchaseDownstream;
            }
            if (sql.contains("FROM subplan_links link")
                    && sql.contains("link.source = 'EXECUTION_V1'")) {
                return executionV1ParentLink;
            }
            if (sql.contains("FROM subplan_links l")) {
                return subplanDownstream;
            }
            if (sql.contains("SELECT id, planned_qty") && sql.contains("FROM sales_order_items")) {
                return unlinkOrderLock;
            }
            if (sql.contains("SET planned_qty = COALESCE(planned_qty,0) - :a")) {
                return plannedDecrement;
            }
            if (sql.contains("FOR UPDATE OF analysis")) {
                return analysisHeaderLock;
            }
            if (sql.contains("analysis_link.submitted_qty")) {
                return analysisPlanConsistency;
            }
            throw new AssertionError("unexpected SQL: " + sql);
        });

        service = new ProductionPlanService(
                planRepo, itemRepo, linkRepo, mrpService, planningDraftService,
                tx, currentUser, nameResolver, em, docNumbers, chainNotice,
                mock(com.uten.imp.features.production.ProductionDocumentAccessPolicy.class),
                materialAnalysisService);
    }

    @Test
    void approveAnalysisPlanRejectsBomDriftBeforeChangingPlanOrSalesQuantities() {
        UUID analysisId = UUID.randomUUID();
        UUID analysisItemId = UUID.randomUUID();
        ProductionPlan plan = plan((short) 0);
        plan.setMaterialAnalysisId(analysisId);
        plan.setMaterialAnalysisItemId(analysisItemId);
        ProductionPlanItem item = item(plan, null, "4");
        arrangePlan(plan, List.of(item));
        when(analysisHeaderLock.getResultList()).thenReturn(
                java.util.Collections.singletonList(
                        new Object[]{analysisId, analysisItemId}));
        ApiException bomDrift = new ApiException(ErrorCode.CONFLICT, "BOM changed");
        org.mockito.Mockito.doThrow(bomDrift).when(materialAnalysisService)
                .requireCurrentBomSnapshot(analysisId, java.util.Set.of(analysisItemId));

        ApiException error = assertThrows(ApiException.class, () -> service.approve(plan.getId()));

        assertEquals(ErrorCode.CONFLICT, error.getCode());
        assertEquals((short) 0, plan.getStatus());
        verify(materialAnalysisService).requireCurrentBomSnapshot(
                analysisId, java.util.Set.of(analysisItemId));
        verify(planRepo, never()).save(plan);
        verify(plannedIncrement, never()).executeUpdate();
    }

    @Test
    void approveManualAllocationLocksHeaderAndLineAndUsesExactRemainingFormula() {
        UUID orderItemId = UUID.randomUUID();
        ProductionPlan plan = plan((short) 0);
        ProductionPlanItem item = item(plan, orderItemId, "5");
        arrangePlan(plan, List.of(item));
        when(linkRepo.findActiveByPlanItemIds(List.of(item.getId()))).thenReturn(List.of());
        when(allocationLock.getResultList()).thenReturn(java.util.Collections.singletonList(orderRow(
                orderItemId, item, (short) 1,
                false, false, false, false,
                "20", "4", "1", "2", "3", "10", "7", (short) 8)));
        when(currentUser.requireEmployeeId()).thenReturn(UUID.randomUUID());

        service.approve(plan.getId());

        assertEquals((short) 1, plan.getStatus());
        verify(plannedIncrement).setParameter("a", new BigDecimal("5"));
        verify(plannedIncrement).setParameter("st", (short) 3);
        verify(plannedIncrement).executeUpdate();
        verify(mrpService, never()).preview(any());
        ArgumentCaptor<PlanOrderItemLink> link = ArgumentCaptor.forClass(PlanOrderItemLink.class);
        verify(linkRepo).save(link.capture());
        assertEquals(orderItemId, link.getValue().getOrderItemId());
        assertEquals(0, new BigDecimal("5").compareTo(link.getValue().getAllocatedQty()));
        verify(planRepo, atLeastOnce()).save(plan);
        verify(planRepo).flush();
        verify(linkRepo).flush();
        verify(planningDraftService).applyActive(plan.getId());
        verify(chainNotice).notifyPlanScheduled(plan.getId(), false);
    }


    @Test
    void approvePropagatesDraftApplyFailureBeforeNotice() {
        UUID orderItemId = UUID.randomUUID();
        ProductionPlan plan = plan((short) 0);
        ProductionPlanItem item = item(plan, orderItemId, "5");
        arrangePlan(plan, List.of(item));
        when(linkRepo.findActiveByPlanItemIds(List.of(item.getId())))
                .thenReturn(List.of());
        when(allocationLock.getResultList()).thenReturn(
                java.util.Collections.singletonList(orderRow(
                        orderItemId, item, (short) 1,
                        false, false, false, false,
                        "20", "4", "1", "2", "3", "10", "7", (short) 8)));
        when(currentUser.requireEmployeeId()).thenReturn(UUID.randomUUID());
        when(planningDraftService.applyActive(plan.getId())).thenThrow(
                new ApiException(ErrorCode.CONFLICT, "draft apply failed"));

        ApiException error = assertThrows(
                ApiException.class, () -> service.approve(plan.getId()));

        assertEquals(ErrorCode.CONFLICT, error.getCode());
        org.mockito.InOrder order = org.mockito.Mockito.inOrder(
                planRepo, linkRepo, planningDraftService);
        order.verify(planRepo).flush();
        order.verify(linkRepo).flush();
        order.verify(planningDraftService).applyActive(plan.getId());
        verify(chainNotice, never()).notifyPlanScheduled(
                any(), org.mockito.ArgumentMatchers.anyBoolean());
    }

    @Test
    void approveRejectsClosedSalesOrderBeforeAnyPlannedQuantityWrite() {
        UUID orderItemId = UUID.randomUUID();
        ProductionPlan plan = plan((short) 0);
        ProductionPlanItem item = item(plan, orderItemId, "5");
        arrangePlan(plan, List.of(item));
        when(linkRepo.findActiveByPlanItemIds(List.of(item.getId()))).thenReturn(List.of());
        when(allocationLock.getResultList()).thenReturn(java.util.Collections.singletonList(orderRow(
                orderItemId, item, (short) 1,
                false, false, true, false,
                "20", "0", "0", "0", "0", "0", "0", (short) 2)));

        ApiException error = assertThrows(ApiException.class, () -> service.approve(plan.getId()));

        assertTrue(error.getMessage().contains("已关闭"));
        verify(plannedIncrement, never()).executeUpdate();
        verify(linkRepo, never()).save(any());
    }

    @Test
    void approveRejectsIdentityMismatchBeforeAnyPlannedQuantityWrite() {
        UUID orderItemId = UUID.randomUUID();
        ProductionPlan plan = plan((short) 0);
        ProductionPlanItem item = item(plan, orderItemId, "5");
        arrangePlan(plan, List.of(item));
        when(linkRepo.findActiveByPlanItemIds(List.of(item.getId()))).thenReturn(List.of());
        Object[] row = orderRow(
                orderItemId, item, (short) 1,
                false, false, false, false,
                "20", "0", "0", "0", "0", "0", "0", (short) 2);
        row[7] = UUID.randomUUID();
        when(allocationLock.getResultList()).thenReturn(java.util.Collections.singletonList(row));

        ApiException error = assertThrows(ApiException.class, () -> service.approve(plan.getId()));

        assertTrue(error.getMessage().contains("货品、颜色、单位或换算率不一致"));
        verify(plannedIncrement, never()).executeUpdate();
        verify(linkRepo, never()).save(any());
    }

    @Test
    void approveRejectsExpiredHistoricalSalesSourceInsteadOfDowngradingToInternalPlan() {
        ProductionPlan plan = plan((short) 0);
        ProductionPlanItem item = item(plan, null, "5");
        arrangePlan(plan, List.of(item));
        when(linkRepo.findActiveByPlanItemIds(List.of(item.getId()))).thenReturn(List.of());
        when(historicalLinkCount.getSingleResult()).thenReturn(1L);

        ApiException error = assertThrows(ApiException.class, () -> service.approve(plan.getId()));

        assertTrue(error.getMessage().contains("销售来源分摊已失效"));
        verify(allocationLock, never()).getResultList();
        verify(plannedIncrement, never()).executeUpdate();
    }
    @Test
    void approveAggregatesAllPrebuiltLinksBeforeFirstPlannedQuantityWrite() {
        UUID orderItemId = UUID.randomUUID();
        ProductionPlan plan = plan((short) 0);
        ProductionPlanItem first = item(plan, null, "6");
        ProductionPlanItem second = item(plan, null, "6");
        second.setProductNo("P-2");
        second.setGoodsId(first.getGoodsId());
        second.setColorId(first.getColorId());
        second.setUnitId(first.getUnitId());
        second.setUnitRate(first.getUnitRate());
        arrangePlan(plan, List.of(first, second));
        PlanOrderItemLink firstLink = link(first, orderItemId, "6");
        PlanOrderItemLink secondLink = link(second, orderItemId, "6");
        when(linkRepo.findActiveByPlanItemIds(List.of(first.getId()))).thenReturn(List.of(firstLink));
        when(linkRepo.findActiveByPlanItemIds(List.of(second.getId()))).thenReturn(List.of(secondLink));
        when(allocationLock.getResultList()).thenReturn(java.util.Collections.singletonList(orderRow(
                orderItemId, first, (short) 1,
                false, false, false, false,
                "10", "0", "0", "0", "0", "0", "0", (short) 2)));

        ApiException error = assertThrows(ApiException.class, () -> service.approve(plan.getId()));

        assertTrue(error.getMessage().contains("超过订单未满足需求"));
        verify(plannedIncrement, never()).executeUpdate();
        verify(em).refresh(firstLink);
        verify(em).refresh(secondLink);
    }

    @Test
    void reverseRejectsAnyNonZeroPlanItemProgressBeforeCheckingDownstream() {
        ProductionPlan plan = plan((short) 1);
        arrangePlan(plan, List.of());
        when(planItemLock.getResultList()).thenReturn(java.util.Collections.singletonList(
                new Object[]{UUID.randomUUID(), new BigDecimal("-1"), BigDecimal.ZERO}));

        ApiException error = assertThrows(ApiException.class, () -> service.reverse(plan.getId()));

        assertTrue(error.getMessage().contains("已有报工或完工入库"));
        verify(stockDownstream, never()).getResultList();
        verify(linkRepo, never()).findActiveByPlanItemIds(any());
    }

    @Test
    void reverseRejectsActiveWarehouseDocumentBeforeUnlink() {
        ProductionPlan plan = reversiblePlan();
        when(stockDownstream.getResultList()).thenReturn(java.util.Collections.singletonList(
                new Object[]{UUID.randomUUID(), "DRAW", "SL-1"}));

        ApiException error = assertThrows(ApiException.class, () -> service.reverse(plan.getId()));

        assertTrue(error.getMessage().contains("领料单或成品入库单"));
        verify(linkRepo, never()).findActiveByPlanItemIds(any());
    }

    @Test
    void reverseRejectsActivePurchaseRequestBeforeUnlink() {
        ProductionPlan plan = reversiblePlan();
        when(purchaseDownstream.getResultList()).thenReturn(java.util.Collections.singletonList(
                new Object[]{UUID.randomUUID(), "PR-1"}));

        ApiException error = assertThrows(ApiException.class, () -> service.reverse(plan.getId()));

        assertTrue(error.getMessage().contains("采购申请"));
        verify(linkRepo, never()).findActiveByPlanItemIds(any());
    }

    @Test
    void reverseRejectsActiveSubplanBeforeUnlink() {
        ProductionPlan plan = reversiblePlan();
        when(subplanDownstream.getResultList()).thenReturn(java.util.Collections.singletonList(
                new Object[]{UUID.randomUUID(), "SP-1"}));

        ApiException error = assertThrows(ApiException.class, () -> service.reverse(plan.getId()));

        assertTrue(error.getMessage().contains("子计划"));
        verify(linkRepo, never()).findActiveByPlanItemIds(any());
    }

    @Test
    void genericDeleteAndReverseRejectExecutionV1SubplanBeforeMutation() {
        ProductionPlan draft = plan((short) 0);
        ProductionPlan approved = plan((short) 1);
        arrangePlan(draft, List.of());
        arrangePlan(approved, List.of());
        when(executionV1ParentLink.getResultList()).thenReturn(
                java.util.Collections.singletonList(UUID.randomUUID()));

        ApiException deleteError = assertThrows(
                ApiException.class, () -> service.delete(draft.getId()));
        ApiException reverseError = assertThrows(
                ApiException.class, () -> service.reverse(approved.getId()));

        assertTrue(deleteError.getMessage().contains("父计划的计划包"));
        assertTrue(reverseError.getMessage().contains("父计划的计划包"));
        verify(planRepo, never()).save(draft);
        verify(planRepo, never()).save(approved);
        verify(planItemLock, never()).getResultList();
    }

    @Test
    void reverseUnlinksOnlyAfterAllGuardsAndRollsBackPlannedQuantityExactly() {
        UUID orderItemId = UUID.randomUUID();
        ProductionPlan plan = plan((short) 1);
        ProductionPlanItem item = item(plan, orderItemId, "5");
        arrangePlan(plan, List.of(item));
        when(planItemLock.getResultList()).thenReturn(java.util.Collections.singletonList(
                new Object[]{item.getId(), BigDecimal.ZERO, BigDecimal.ZERO}));
        PlanOrderItemLink link = link(item, orderItemId, "5");
        when(linkRepo.findActiveByPlanItemIds(List.of(item.getId()))).thenReturn(List.of(link));
        when(unlinkOrderLock.getResultList()).thenReturn(java.util.Collections.singletonList(
                new Object[]{orderItemId, new BigDecimal("5")}));

        service.reverse(plan.getId());

        assertEquals((short) -1, plan.getStatus());
        assertTrue(link.isDeleted());
        verify(em).lock(link, LockModeType.PESSIMISTIC_WRITE);
        verify(em).refresh(link);
        verify(plannedDecrement).setParameter("a", new BigDecimal("5"));
        verify(plannedDecrement).setParameter("id", orderItemId);
        verify(plannedDecrement).executeUpdate();
        verify(linkRepo).save(link);
    }

    @Test
    void updateAndDeleteUseDirectPessimisticFindBeforeStatusCheck() {
        ProductionPlan plan = plan((short) 1);
        when(em.find(ProductionPlan.class, plan.getId(), LockModeType.PESSIMISTIC_WRITE))
                .thenReturn(plan);

        assertThrows(ApiException.class,
                () -> service.update(plan.getId(), mock(PlanSaveRequest.class)));
        assertThrows(ApiException.class, () -> service.delete(plan.getId()));

        verify(em, times(2)).find(
                ProductionPlan.class, plan.getId(), LockModeType.PESSIMISTIC_WRITE);
    }

    private ProductionPlan reversiblePlan() {
        ProductionPlan plan = plan((short) 1);
        UUID itemId = UUID.randomUUID();
        arrangePlan(plan, List.of());
        when(planItemLock.getResultList()).thenReturn(java.util.Collections.singletonList(
                new Object[]{itemId, BigDecimal.ZERO, BigDecimal.ZERO}));
        return plan;
    }

    private void arrangePlan(ProductionPlan plan, List<ProductionPlanItem> items) {
        when(em.find(ProductionPlan.class, plan.getId(), LockModeType.PESSIMISTIC_WRITE))
                .thenReturn(plan);
        when(planRepo.findById(plan.getId())).thenReturn(Optional.of(plan));
        when(itemRepo.findByPlanIdOrderByLineNoAsc(plan.getId())).thenReturn(items);
    }

    private static ProductionPlan plan(short status) {
        ProductionPlan plan = new ProductionPlan();
        plan.setBillNo("PP-TEST");
        plan.setBillDate(LocalDate.of(2026, 7, 31));
        plan.setStatus(status);
        return plan;
    }

    private static ProductionPlanItem item(
            ProductionPlan plan, UUID orderItemId, String qty) {
        ProductionPlanItem item = new ProductionPlanItem();
        item.setPlanId(plan.getId());
        item.setBillNo(plan.getBillNo());
        item.setBillDate(plan.getBillDate());
        item.setLineNo(1);
        item.setProductNo("P-1");
        item.setGoodsId(UUID.randomUUID());
        item.setColorId(UUID.randomUUID());
        item.setUnitId(UUID.randomUUID());
        item.setUnitRate(BigDecimal.ONE);
        item.setQty(new BigDecimal(qty));
        item.setSalesOrderItemId(orderItemId);
        return item;
    }

    private static PlanOrderItemLink link(
            ProductionPlanItem item, UUID orderItemId, String qty) {
        PlanOrderItemLink link = new PlanOrderItemLink();
        link.setPlanItemId(item.getId());
        link.setOrderItemId(orderItemId);
        link.setAllocatedQty(new BigDecimal(qty));
        link.setProducedQty(BigDecimal.ZERO);
        link.setInboundQty(BigDecimal.ZERO);
        return link;
    }

    private static Object[] orderRow(
            UUID orderItemId,
            ProductionPlanItem item,
            short orderStatus,
            boolean stopped,
            boolean orderDeleted,
            boolean closed,
            boolean itemDeleted,
            String qty,
            String shipped,
            String returned,
            String flag,
            String reserved,
            String planned,
            String produced,
            short chainStatus) {
        return new Object[]{
                orderItemId, UUID.randomUUID(), orderStatus,
                stopped, orderDeleted, closed, itemDeleted,
                item.getGoodsId(), item.getColorId(), item.getUnitId(), item.getUnitRate(),
                new BigDecimal(qty), new BigDecimal(shipped), new BigDecimal(returned),
                new BigDecimal(flag), new BigDecimal(reserved), new BigDecimal(planned),
                new BigDecimal(produced), chainStatus
        };
    }

    private static Query query() {
        Query query = mock(Query.class);
        when(query.setParameter(anyString(), any())).thenReturn(query);
        when(query.setMaxResults(anyInt())).thenReturn(query);
        return query;
    }
}
