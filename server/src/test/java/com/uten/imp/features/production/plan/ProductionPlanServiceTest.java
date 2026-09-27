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
import jakarta.persistence.TypedQuery;
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
import static org.mockito.ArgumentMatchers.eq;
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
    private ProductionPlanMutationFootprintService mutationFootprint;

    private Query allocationLock;
    private Query plannedIncrement;
    private TypedQuery<PlanOrderItemLink> approvalLinks;
    private Query recomputeClosed;
    private Query planItemLock;
    private Query stockDownstream;
    private Query purchaseDownstream;
    private Query subplanDownstream;
    private Query executionV1ParentLink;
    private Query unlinkOrderLock;
    private Query plannedDecrement;
    private Query analysisPlanConsistency;
    private Query analysisSubmittedQty;
    private Query salesTrace;
    private Query dailyTrace;
    private Query materialTrace;
    private Query purchaseTrace;
    private Query subcontractTrace;

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
        ProductionProductNoAllocator productNos = mock(ProductionProductNoAllocator.class);
        chainNotice = mock(ChainNoticeService.class);
        materialAnalysisService = mock(MaterialAnalysisService.class);
        mutationFootprint = mock(ProductionPlanMutationFootprintService.class);

        allocationLock = query();
        plannedIncrement = query();
        approvalLinks = mock(TypedQuery.class);
        when(approvalLinks.setParameter(anyString(),any())).thenReturn(approvalLinks);
        when(approvalLinks.getResultList()).thenReturn(List.of());
        when(em.createQuery(anyString(),eq(PlanOrderItemLink.class))).thenReturn(approvalLinks);
        recomputeClosed = query();
        planItemLock = query();
        stockDownstream = query();
        purchaseDownstream = query();
        subplanDownstream = query();
        executionV1ParentLink = query();
        unlinkOrderLock = query();
        plannedDecrement = query();
        analysisPlanConsistency = query();
        analysisSubmittedQty = query();
        salesTrace = query();
        dailyTrace = query();
        materialTrace = query();
        purchaseTrace = query();
        subcontractTrace = query();

        when(plannedIncrement.executeUpdate()).thenReturn(1);
        when(recomputeClosed.executeUpdate()).thenReturn(1);
        when(plannedDecrement.executeUpdate()).thenReturn(1);
        when(stockDownstream.getResultList()).thenReturn(List.of());
        when(purchaseDownstream.getResultList()).thenReturn(List.of());
        when(subplanDownstream.getResultList()).thenReturn(List.of());
        when(executionV1ParentLink.getResultList()).thenReturn(List.of());
        when(analysisPlanConsistency.getResultList()).thenReturn(List.of());
        // V588：审核分摊按分析 link 的 submitted_qty（手工计划返回空表 → 按整行数量分摊）。
        when(analysisSubmittedQty.getResultList()).thenReturn(List.of());
        when(salesTrace.getResultList()).thenReturn(List.of());
        when(dailyTrace.getResultList()).thenReturn(List.of());
        when(materialTrace.getResultList()).thenReturn(List.of());
        when(purchaseTrace.getResultList()).thenReturn(List.of());
        when(subcontractTrace.getResultList()).thenReturn(List.of());
        when(mrpService.isPlanningWriteReady()).thenReturn(false);

        when(em.createNativeQuery(anyString())).thenAnswer(invocation -> {
            String sql = invocation.getArgument(0);
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
            if (sql.contains("SELECT plan_item.id, link.submitted_qty")) {
                return analysisSubmittedQty;
            }
            if (sql.contains("analysis_link.submitted_qty")) {
                return analysisPlanConsistency;
            }
            if (sql.contains("FROM plan_order_item_links l")
                    && sql.contains("SELECT source.id, source.bill_no")) {
                return salesTrace;
            }
            if (sql.contains("FROM stock_documents sd")
                    && sql.contains("sd.doc_type IN ('DRAW', 'RETURN')")) {
                return materialTrace;
            }
            if (sql.contains("FROM purchase_request_plan_allocations allocation")) {
                return purchaseTrace;
            }
            if (sql.contains("JOIN subcontract_applications application")) {
                return subcontractTrace;
            }
            if (sql.contains("FROM production_daily_report_items pdri")) {
                return dailyTrace;
            }
            throw new AssertionError("unexpected SQL: " + sql);
        });

        service = new ProductionPlanService(
                planRepo, itemRepo, linkRepo, mrpService, planningDraftService,
                tx, currentUser, nameResolver, em, docNumbers, productNos, chainNotice,
                 mock(com.uten.imp.features.production.ProductionDocumentAccessPolicy.class),
                 materialAnalysisService, mutationFootprint);
    }

    @Test
    void analysisCommandReadsActualQuantitiesWithoutLoadingUnrelatedTraceProjections() {
        ProductionPlan plan = plan((short) 0);
        plan.setMaterialAnalysisId(UUID.randomUUID());
        arrangePlan(plan, List.of(item(plan, null, "2.25"), item(plan, null, "7.75")));
        var result = service.readForAnalysis(plan.getId());
        assertEquals(plan.getId(), result.id());
        assertEquals("PP-TEST", result.billNo());
        assertEquals(0, new BigDecimal("10").compareTo(result.plannedQty()));
        verify(em, never()).createNativeQuery(anyString());
    }

    @Test
    void lightweightApprovalReturnsItsActualAppliedPackageWithoutASecondRead() {
        ProductionPlan plan = plan((short) 0);
        plan.setMaterialAnalysisId(UUID.randomUUID());plan.setMaterialAnalysisItemId(UUID.randomUUID());
        ProductionPlanItem item = item(plan, null, "5");
        arrangePlan(plan, List.of(item));analysisProof(plan,item,false);
        var applied = mock(com.uten.imp.features.production.mrp.PlanningPackageResult.class);
        when(planningDraftService.applyActive(plan.getId())).thenReturn(Optional.of(applied));
        when(currentUser.requireEmployeeId()).thenReturn(UUID.randomUUID());
        assertTrue(service.approveForAnalysis(plan.getId()).orElseThrow() == applied);
        assertEquals((short) 1, plan.getStatus());
        verify(planningDraftService).applyActive(plan.getId());
        verify(chainNotice).notifyPlanScheduled(plan.getId(), false);
    }

    @Test
    void firstAnalysisApprovalKeepsGraphValidationButCannotClaimVerifiedMaterialBeforeFormalDemandExists() {
        ProductionPlan plan=plan((short)0);
        plan.setMaterialAnalysisId(UUID.randomUUID());plan.setMaterialAnalysisItemId(UUID.randomUUID());
        ProductionPlanItem item=item(plan,null,"5");arrangePlan(plan,List.of(item));
        analysisProof(plan,item,false);
        when(mrpService.isPlanningWriteReady()).thenReturn(true);
        service.approveForAnalysis(plan.getId());
        verify(mrpService).validatePlanBomGraph(plan.getId());
        verify(mrpService,never()).preview(any());
        verify(analysisSubmittedQty,never()).getResultList();
        verify(itemRepo,times(1)).findByPlanIdOrderByLineNoAsc(plan.getId());
        verify(em).refresh(plan,LockModeType.PESSIMISTIC_WRITE);
        verify(planningDraftService).applyActive(plan.getId());
        verify(chainNotice).notifyPlanScheduled(plan.getId(),false);
        var statements=ArgumentCaptor.forClass(String.class);verify(em,atLeastOnce()).createNativeQuery(statements.capture());
        assertEquals(1,statements.getAllValues().stream().filter(sql->sql.contains("analysis_link.submitted_qty")).count());
        assertTrue(statements.getAllValues().stream().anyMatch(sql->sql.contains("FOR UPDATE OF analysis, ai, analysis_link, plan_item")));
        assertTrue(statements.getAllValues().stream().noneMatch(sql->sql.contains("SELECT analysis.id, plan.material_analysis_item_id")));
    }

    @Test
    void anExistingFormalDemandRetainsTheFullMaterialDecision() {
        ProductionPlan plan=plan((short)0);
        plan.setMaterialAnalysisId(UUID.randomUUID());plan.setMaterialAnalysisItemId(UUID.randomUUID());
        ProductionPlanItem item=item(plan,null,"5");arrangePlan(plan,List.of(item));analysisProof(plan,item,true);
        when(mrpService.isPlanningWriteReady()).thenReturn(true);
        when(mrpService.preview(plan.getId())).thenReturn(List.of());
        service.approveForAnalysis(plan.getId());
        verify(mrpService).preview(plan.getId());
        verify(mrpService,never()).validatePlanBomGraph(any());
        verify(planningDraftService).applyActive(plan.getId());
    }

    @Test
    void unallocatedAnalysisStillRejectsCyclicOrTooDeepBomBeforeApplyingAnyPackage() {
        ProductionPlan plan=plan((short)0);
        plan.setMaterialAnalysisId(UUID.randomUUID());plan.setMaterialAnalysisItemId(UUID.randomUUID());
        ProductionPlanItem item=item(plan,null,"5");arrangePlan(plan,List.of(item));analysisProof(plan,item,false);
        org.mockito.Mockito.doThrow(new ApiException(ErrorCode.CONFLICT,"BOM结构存在循环"))
                .when(mrpService).validatePlanBomGraph(plan.getId());
        assertThrows(ApiException.class,()->service.approveForAnalysis(plan.getId()));
        verify(planningDraftService,never()).applyActive(any());
        verify(chainNotice,never()).notifyPlanScheduled(any(),any(boolean.class));
    }

    @Test
    void unallocatedAnalysisStillRejectsAnInvalidOpenPurchaseUnitBeforeApplyingAnyPackage() {
        ProductionPlan plan=plan((short)0);
        plan.setMaterialAnalysisId(UUID.randomUUID());plan.setMaterialAnalysisItemId(UUID.randomUUID());
        ProductionPlanItem item=item(plan,null,"5");arrangePlan(plan,List.of(item));analysisProof(plan,item,false);
        org.mockito.Mockito.doThrow(new ApiException(ErrorCode.CONFLICT,"未完成采购行的单位或换算率无效"))
                .when(mrpService).validatePlanBomGraph(plan.getId());
        ApiException failure=assertThrows(ApiException.class,()->service.approveForAnalysis(plan.getId()));
        assertTrue(failure.getMessage().contains("未完成采购行"));
        verify(planningDraftService,never()).applyActive(any());
        verify(chainNotice,never()).notifyPlanScheduled(any(),any(boolean.class));
    }

    private void analysisProof(ProductionPlan plan,ProductionPlanItem item,boolean formal) {
        when(analysisPlanConsistency.getResultList()).thenReturn(java.util.Collections.singletonList(new Object[]{
                plan.getMaterialAnalysisId(),plan.getMaterialAnalysisItemId(),item.getGoodsId(),item.getColorId(),item.getUnitId(),
                BigDecimal.ONE,item.getSalesOrderItemId(),item.getGoodsId(),item.getColorId(),item.getUnitId(),BigDecimal.ONE,
                item.getSalesOrderItemId(),item.getQty(),item.getQty(),"SUBMITTED",item.getQty(),BigDecimal.ZERO,formal,"AGGREGATE_MAKE"}));
    }

    @Test
    void lightweightApprovalStillRejectsBomDriftBeforeAnyBusinessWrite() {
        UUID analysisId = UUID.randomUUID(), sourceId = UUID.randomUUID();
        ProductionPlan plan = plan((short) 0);
        plan.setMaterialAnalysisId(analysisId);
        plan.setMaterialAnalysisItemId(sourceId);
        ProductionPlanItem item=item(plan,null,"4");
        arrangePlan(plan,List.of(item));analysisProof(plan,item,false);
        org.mockito.Mockito.doThrow(new ApiException(ErrorCode.CONFLICT, "BOM changed"))
                .when(materialAnalysisService).requireCurrentBomSnapshot(analysisId, java.util.Set.of(sourceId));
        assertThrows(ApiException.class, () -> service.approveForAnalysis(plan.getId()));
        assertEquals((short) 0, plan.getStatus());
        verify(planRepo, never()).save(plan);
        verify(plannedIncrement, never()).executeUpdate();
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
        analysisProof(plan,item,false);
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
        PlanOrderItemLink retired=link(item,UUID.randomUUID(),"5");retired.setDeleted(true);
        when(approvalLinks.getResultList()).thenReturn(List.of(retired));

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
        when(approvalLinks.getResultList()).thenReturn(List.of(firstLink,secondLink));
        when(allocationLock.getResultList()).thenReturn(java.util.Collections.singletonList(orderRow(
                orderItemId, first, (short) 1,
                false, false, false, false,
                "10", "0", "0", "0", "0", "0", "0", (short) 2)));

        ApiException error = assertThrows(ApiException.class, () -> service.approve(plan.getId()));

        assertTrue(error.getMessage().contains("超过订单未满足需求"));
        verify(plannedIncrement, never()).executeUpdate();
        verify(em).refresh(firstLink);
        verify(em).refresh(secondLink);
        verify(approvalLinks,times(1)).getResultList();
        verify(approvalLinks).setParameter("itemIds",List.of(first.getId(),second.getId()));
    }

    @Test
    void internalItemsReadActiveAndRetiredLinksOnceForTheWholePlan() {
        ProductionPlan plan=plan((short)0);List<ProductionPlanItem> items=new java.util.ArrayList<>();
        for(int index=0;index<100;index++)items.add(item(plan,null,"1"));
        List<?> allocations=org.springframework.test.util.ReflectionTestUtils.invokeMethod(service,"collectAllocations",items,java.util.Map.of());
        assertTrue(allocations.isEmpty());verify(approvalLinks,times(1)).getResultList();
        verify(approvalLinks).setParameter("itemIds",items.stream().map(ProductionPlanItem::getId).toList());
        verify(em,never()).createNativeQuery(anyString());
    }

    @Test
    void aReturnedLinkForAnotherPlanItemCannotDisappearFromTheBatchedRead() {
        ProductionPlan plan=plan((short)0);ProductionPlanItem selected=item(plan,null,"1"),other=item(plan,null,"1");
        when(approvalLinks.getResultList()).thenReturn(List.of(link(other,UUID.randomUUID(),"1")));
        ApiException failure=assertThrows(ApiException.class,()->org.springframework.test.util.ReflectionTestUtils
                .invokeMethod(service,"collectAllocations",List.of(selected),java.util.Map.of()));
        assertTrue(failure.getMessage().contains("不属于当前计划明细"));
        verify(plannedIncrement,never()).executeUpdate();
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
    void updateAndDeleteRefreshTheAlreadyPrelockedPlanBeforeStatusCheck() {
        ProductionPlan plan = plan((short) 1);
        when(em.find(ProductionPlan.class, plan.getId()))
                .thenReturn(plan);

        assertThrows(ApiException.class,
                () -> service.update(plan.getId(), mock(PlanSaveRequest.class)));
        assertThrows(ApiException.class, () -> service.delete(plan.getId()));

        verify(em, times(2)).find(ProductionPlan.class, plan.getId());
        verify(em, times(2)).refresh(plan, LockModeType.PESSIMISTIC_WRITE);
    }

    @Test
    void approveAnalysisPlanAcquiresSharedSourceAndInventoryPrefixBeforePlanRow() {
        UUID analysisId = UUID.randomUUID();
        ProductionPlan plan = plan((short) 1);
        plan.setMaterialAnalysisId(analysisId);
        arrangePlan(plan, List.of());

        assertThrows(ApiException.class, () -> service.approve(plan.getId()));

        org.mockito.InOrder order = org.mockito.Mockito.inOrder(mutationFootprint, em);
        order.verify(mutationFootprint).lockPlan(plan.getId(), List.of());
        order.verify(em).find(ProductionPlan.class, plan.getId());
        order.verify(em).refresh(plan, LockModeType.PESSIMISTIC_WRITE);
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
        when(em.find(ProductionPlan.class, plan.getId()))
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
                new BigDecimal(produced), chainStatus,
                // V294：服务端新增 o.finance_confirmed（row[19]）复核，
                // 夹具默认财务已确认，不改变既有用例语义。
                true
        };
    }

    private static Query query() {
        Query query = mock(Query.class);
        when(query.setParameter(anyString(), any())).thenReturn(query);
        when(query.setMaxResults(anyInt())).thenReturn(query);
        return query;
    }
}
