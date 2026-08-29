package com.uten.imp.features.production.mrp;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.production.fulfillment.ProductionExecutionSegment;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.sql.Date;
import java.time.LocalDate;
import java.util.Collections;
import java.util.List;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class ProductionExecutionPackageCommandStatusTest {

    @Test
    void rejectsFormalConfirmationForDraftPlanBeforeRequestValidation() {
        EntityManager em = mock(EntityManager.class);
        Query query = mock(Query.class);
        when(em.createNativeQuery(anyString())).thenReturn(query);
        when(query.setParameter(anyString(), any())).thenReturn(query);
        when(query.getResultList()).thenReturn(Collections.singletonList(
                new Object[]{"SJ-1", Date.valueOf(LocalDate.now()),
                        (short) 0, false, false, false}));
        TxSessionVars tx = mock(TxSessionVars.class);
        ProductionPlanningRequestValidator validator =
                mock(ProductionPlanningRequestValidator.class);
        ProductionExecutionPackageCommandService command =
                new ProductionExecutionPackageCommandService(
                        em, null, null, null, null, null, null, null,
                        null, null, null, null, null, tx, null, validator,
                        mock(com.uten.imp.features.notice.ChainNoticeService.class),
                        mock(com.uten.imp.application.port.PreplanAnalysisPegPort.class));

        assertThatThrownBy(() -> command.confirm(
                UUID.randomUUID(), new GeneratePlanningPackageRequest()))
                .isInstanceOf(ApiException.class)
                .satisfies(error -> assertThat(((ApiException) error).getCode())
                        .isEqualTo(ErrorCode.CONFLICT))
                .hasMessageContaining("仅已审核")
                .hasMessageContaining("预排草案");
        verify(validator, never()).validateCurrent(any(), any());
    }

    @Test
    void freezesOnlyEvidenceBackedReadyZeroMaterialSegments() {
        UUID analysisId = UUID.randomUUID();
        CompleteKitAllocator.ProductLine direct = zeroLine(
                ProductionExecutionSegment.ZERO_MATERIAL_REASON_DIRECT_MAKE,
                analysisId, null, null);
        CompleteKitAllocator.SegmentAllocation proposal =
                new CompleteKitAllocator.SegmentAllocation(
                        "zero-direct",
                        direct,
                        ProductionExecutionSegment.STATUS_READY,
                        new BigDecimal("10.0000"),
                        List.of());
        ProductionExecutionSegment segment =
                new ProductionExecutionSegment();

        ProductionExecutionPackageCommandService
                .freezeMaterialRequirementShape(segment, proposal);

        assertThat(segment.getMaterialRequirementMode()).isEqualTo(
                ProductionExecutionSegment.MATERIAL_REQUIREMENT_MODE_ZERO);
        assertThat(segment.getZeroMaterialReason()).isEqualTo(
                ProductionExecutionSegment.ZERO_MATERIAL_REASON_DIRECT_MAKE);
        assertThat(segment.getZeroMaterialAnalysisId()).isEqualTo(analysisId);
        assertThat(segment.getZeroMaterialExceptionReason()).isNull();
        assertThat(segment.getZeroMaterialAuthorizedBy()).isNull();

        // V423：PLAN_BOM_OVERRIDE 原因随计划级 BOM 例外机制一并下线，不再可创建。
        CompleteKitAllocator.ProductLine invalidOverride = zeroLine(
                ProductionExecutionSegment
                        .ZERO_MATERIAL_REASON_PLAN_BOM_OVERRIDE,
                analysisId, "例外批准", null);
        CompleteKitAllocator.SegmentAllocation invalidProposal =
                new CompleteKitAllocator.SegmentAllocation(
                        "zero-invalid",
                        invalidOverride,
                        ProductionExecutionSegment.STATUS_READY,
                        new BigDecimal("10.0000"),
                        List.of());
        assertThatThrownBy(() -> ProductionExecutionPackageCommandService
                .freezeMaterialRequirementShape(
                        new ProductionExecutionSegment(), invalidProposal))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("缺少可审计的合法原因");
    }

    private static CompleteKitAllocator.ProductLine zeroLine(
            String reason,
            UUID analysisId,
            String exceptionReason,
            UUID authorizedBy) {
        UUID sourceItemId = UUID.randomUUID();
        return new CompleteKitAllocator.ProductLine(
                sourceItemId,
                1,
                UUID.randomUUID(),
                null,
                UUID.randomUUID(),
                BigDecimal.ONE,
                new BigDecimal("10.0000"),
                LocalDate.of(2026, 8, 9),
                LocalDate.of(2026, 8, 10),
                null,
                null,
                null,
                "P-001",
                "Product",
                new CompleteKitAllocator.Priority(
                        LocalDate.of(2026, 8, 9), 1, sourceItemId),
                List.of(),
                "a".repeat(64),
                reason,
                analysisId,
                exceptionReason,
                authorizedBy);
    }
}
