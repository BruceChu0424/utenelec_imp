package com.uten.imp.features.production.mrp;

import com.uten.imp.features.production.fulfillment.ProductionFulfillmentLedgerService;
import com.uten.imp.features.production.fulfillment.ProductionPlanningPackage;
import com.uten.imp.features.production.fulfillment.ProductionExecutionSegment;
import com.uten.imp.features.production.fulfillment.ProductionExecutionSegmentRepository;
import com.uten.imp.features.production.fulfillment.ProductionMaterialDemand;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import jakarta.persistence.TypedQuery;
import org.junit.jupiter.api.Test;
import org.springframework.test.util.ReflectionTestUtils;

import java.sql.Date;
import java.time.LocalDate;
import java.util.Collections;
import java.util.List;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.doReturn;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.inOrder;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.spy;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class ProductionExecutionPackageCommandReplayTest {

    @Test
    void idempotentReplaySkipsCurrentFingerprintValidation() {
        UUID planId = UUID.randomUUID();
        UUID packageId = UUID.randomUUID();
        EntityManager em = mock(EntityManager.class);
        Query planLock = query();
        when(planLock.getResultList()).thenReturn(Collections.singletonList(
                new Object[]{"SJ-1", Date.valueOf(LocalDate.now()),
                        (short) 1, false, false, false,
                        // V298：lockPlan 第 7 列 material_analysis_id（null=非分析来源计划）
                        null}));
        Query legacyPackage = query();
        when(legacyPackage.getSingleResult()).thenReturn(false);
        when(legacyPackage.getResultList()).thenReturn(List.of(packageId));
        when(em.createNativeQuery(anyString())).thenAnswer(invocation -> {
            String sql = invocation.getArgument(0);
            return sql.contains("FROM production_plans")
                    ? planLock
                    : legacyPackage;
        });
        ProductionFulfillmentLedgerService ledger =
                mock(ProductionFulfillmentLedgerService.class);
        ProductionPlanningPackage planningPackage =
                new ProductionPlanningPackage();
        planningPackage.setId(packageId);
        planningPackage.setPlanId(planId);
        when(ledger.beginConfirmation(any(), any(), anyString(),
                anyString(), anyString())).thenReturn(
                        new ProductionFulfillmentLedgerService.BeginConfirmation(
                                planningPackage, true));
        ProductionPlanningRequestValidator validator =
                mock(ProductionPlanningRequestValidator.class);
        ProductionExecutionPackageCommandService command = spy(
                new ProductionExecutionPackageCommandService(
                        em, null, ledger, null, null, null, null, null, null,
                        null, null, null, null, null,
                        mock(TxSessionVars.class), null, validator,
                        mock(com.uten.imp.features.notice.ChainNoticeService.class),
                        mock(com.uten.imp.application.port.PreplanAnalysisPegPort.class),
                        org.mockito.Mockito.mock(com.uten.imp.features.production.plan.ProductionPlanMutationFootprintService.class, org.mockito.Mockito.RETURNS_DEEP_STUBS), null));
        PlanningPackageResult replay = new PlanningPackageResult(
                packageId, ProductionPlanningPackage.STATUS_CONFIRMED, true,
                List.of(), null, null, null, List.of(), List.of());
        doReturn(replay).when(command).replay(planningPackage);
        GeneratePlanningPackageRequest request =
                new GeneratePlanningPackageRequest();
        request.setWarehouseId(UUID.randomUUID());
        request.setIdempotencyKey("replay-key-0001");
        request.setPreviewFingerprint("a".repeat(64));

        PlanningPackageResult result = command.confirm(planId, request);

        assertThat(result).isSameAs(replay);
        var order = inOrder(validator, ledger, command);
        order.verify(validator).validateRequestStructure(request);
        order.verify(ledger).beginConfirmation(any(), any(), anyString(), anyString(), anyString());
        order.verify(command).replay(planningPackage);
        verify(validator, never()).validateRequestShape(any());
        verify(validator, never()).validateCurrent(any(), any());
    }

    @Test
    void requestHashIncludesManualDeferIntent() {
        GeneratePlanningPackageRequest request =
                new GeneratePlanningPackageRequest();
        request.setWarehouseId(UUID.randomUUID());
        GeneratePlanningPackageRequest.ExecutionSegment segment =
                new GeneratePlanningPackageRequest.ExecutionSegment();
        segment.setClientSegmentKey("segment-1");
        segment.setSourcePlanItemId(UUID.randomUUID());
        segment.setRequestedStatus("WAITING");
        segment.setPlannedQty(java.math.BigDecimal.ONE);
        segment.setBomFingerprint("a".repeat(64));
        request.setSegments(List.of(segment));

        String automatic =
                ProductionExecutionPackageCommandService.requestHash(request);
        segment.setDeferUntilManualRelease(true);
        String deferred =
                ProductionExecutionPackageCommandService.requestHash(request);

        assertThat(deferred).isNotEqualTo(automatic);
    }

    @Test
    void freshAnalysisResultReadsActualReservationsAndEveryDrawWithoutReloadingKnownAbsentSupply() {
        ResultFixture fixture = resultFixture();
        PlanningPackageResult result = ReflectionTestUtils.invokeMethod(fixture.command(),
                "readCurrentResult", fixture.planningPackage(), List.of(fixture.segment()), false, true);

        assertThat(result.replayed()).isFalse();
        assertThat(result.subplans()).isEmpty();
        assertThat(result.subcontractApplication()).isNull();
        assertThat(result.drawDocuments()).extracting(MrpGenerateResult::requestBillNo)
                .containsExactly("LL-1", "LL-2");
        var shown = result.executionSegments().getFirst();
        assertThat(shown.status()).isEqualTo("READY");
        assertThat(shown.materials().getFirst().stockAllocatedQty()).isEqualByComparingTo("3");
        assertThat(shown.materials().getFirst().shortageQty()).isEqualByComparingTo("2");
        verify(fixture.segments(), never()).findByPackageIdAndDeletedFalseOrderBySegmentNoAsc(any());
        verify(fixture.em(), never()).createNativeQuery(org.mockito.ArgumentMatchers.contains("'SUBPLAN'"));
        verify(fixture.em(), never()).createNativeQuery(org.mockito.ArgumentMatchers.contains("'SUBCONTRACT_APPLICATION'"));
    }

    @Test
    void replayStillLoadsHistoricalSupplyDocumentsAndCurrentSegments() {
        ResultFixture fixture = resultFixture();
        PlanningPackageResult result = fixture.command().replay(fixture.planningPackage());

        assertThat(result.replayed()).isTrue();
        assertThat(result.subplans()).extracting(GenerateSubplansRequest.Created::billNo).containsExactly("SJ-old");
        assertThat(result.subcontractApplication().requestBillNo()).isEqualTo("WW-old");
        assertThat(result.drawDocuments()).hasSize(2);
        assertThat(result.executionSegments().getFirst().materials().getFirst().stockAllocatedQty()).isEqualByComparingTo("3");
        verify(fixture.segments()).findByPackageIdAndDeletedFalseOrderBySegmentNoAsc(fixture.planningPackage().getId());
    }

    private record ResultFixture(ProductionExecutionPackageCommandService command, EntityManager em,
                                 ProductionExecutionSegmentRepository segments,
                                 ProductionPlanningPackage planningPackage, ProductionExecutionSegment segment) { }

    @SuppressWarnings("unchecked")
    private static ResultFixture resultFixture() {
        var em = mock(EntityManager.class);
        var segmentRepo = mock(ProductionExecutionSegmentRepository.class);
        var command = mock(ProductionExecutionPackageCommandService.class, org.mockito.Mockito.CALLS_REAL_METHODS);
        ReflectionTestUtils.setField(command, "em", em);
        ReflectionTestUtils.setField(command, "segmentRepo", segmentRepo);
        var planningPackage = new ProductionPlanningPackage();
        planningPackage.setId(UUID.randomUUID());
        planningPackage.setStatus(ProductionPlanningPackage.STATUS_CONFIRMED);
        var segment = new ProductionExecutionSegment();
        segment.setId(UUID.randomUUID());
        segment.setStatus("READY");
        segment.setSegmentCode("ZX-test");
        segment.setPlannedQty(java.math.BigDecimal.ONE);
        when(segmentRepo.findByPackageIdAndDeletedFalseOrderBySegmentNoAsc(planningPackage.getId())).thenReturn(List.of(segment));
        var demand = new ProductionMaterialDemand();
        demand.setId(UUID.randomUUID());
        demand.setExecutionSegmentId(segment.getId());
        demand.setGoodsId(UUID.randomUUID());
        demand.setRequiredQty(new java.math.BigDecimal("5"));
        TypedQuery<ProductionMaterialDemand> demandQuery = mock(TypedQuery.class);
        when(demandQuery.setParameter(anyString(), any())).thenReturn(demandQuery);
        when(demandQuery.getResultList()).thenReturn(List.of(demand));
        when(em.createQuery(anyString(), org.mockito.ArgumentMatchers.eq(ProductionMaterialDemand.class))).thenReturn(demandQuery);
        when(em.createNativeQuery(anyString())).thenAnswer(call -> {
            String sql = call.getArgument(0);
            Query query = query();
            List<Object[]> rows;
            if (sql.contains("FROM stock_reservations")) {
                rows = Collections.singletonList(new Object[]{demand.getId(), new java.math.BigDecimal("3")});
            } else if (sql.contains("'SUBCONTRACT_APPLICATION'")) {
                rows = Collections.singletonList(new Object[]{UUID.randomUUID(), "WW-old", 1L});
            } else if (sql.contains("'SUBPLAN'")) {
                rows = Collections.singletonList(new Object[]{UUID.randomUUID(), "SJ-old", 1L, "workshop"});
            } else {
                assertThat(sql).contains("h.document_type = 'DRAW'");
                rows = List.of(new Object[]{segment.getId(), UUID.randomUUID(), "LL-1", 1L},
                        new Object[]{segment.getId(), UUID.randomUUID(), "LL-2", 1L});
            }
            when(query.getResultList()).thenReturn(rows);
            return query;
        });
        return new ResultFixture(command, em, segmentRepo, planningPackage, segment);
    }

    private static Query query() {
        Query query = mock(Query.class);
        when(query.setParameter(anyString(), any())).thenReturn(query);
        return query;
    }
}
