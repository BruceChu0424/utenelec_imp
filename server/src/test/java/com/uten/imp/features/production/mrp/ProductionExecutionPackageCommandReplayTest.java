package com.uten.imp.features.production.mrp;

import com.uten.imp.features.production.fulfillment.ProductionFulfillmentLedgerService;
import com.uten.imp.features.production.fulfillment.ProductionPlanningPackage;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;

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
                        em, null, ledger, null, null, null, null, null,
                        null, null, null, null, null,
                        mock(TxSessionVars.class), null, validator,
                        mock(com.uten.imp.features.notice.ChainNoticeService.class),
                        mock(com.uten.imp.application.port.PreplanAnalysisPegPort.class),
                        org.mockito.Mockito.mock(com.uten.imp.features.production.plan.ProductionPlanMutationFootprintService.class, org.mockito.Mockito.RETURNS_DEEP_STUBS)));
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
        verify(validator).validateRequestShape(request);
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

    private static Query query() {
        Query query = mock(Query.class);
        when(query.setParameter(anyString(), any())).thenReturn(query);
        return query;
    }
}
