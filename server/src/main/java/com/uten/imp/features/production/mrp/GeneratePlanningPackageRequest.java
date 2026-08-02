package com.uten.imp.features.production.mrp;

import com.uten.imp.common.validation.RequestLimits;
import jakarta.validation.Valid;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Pattern;
import jakarta.validation.constraints.Size;
import lombok.Getter;
import lombok.Setter;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.List;
import java.util.UUID;

/**
 * 一键生成计划包请求。子计划与可选采购申请在一个本地事务内提交，避免只生成一半。
 */
@Getter
@Setter
public class GeneratePlanningPackageRequest {

    @NotNull
    private UUID warehouseId;

    @NotBlank
    @Size(min = 8, max = 128)
    private String idempotencyKey;

    @NotBlank
    @Pattern(regexp = "(?i)[0-9a-f]{64}")
    private String previewFingerprint;

    @Valid
    @Size(max = RequestLimits.DOCUMENT_LINES)
    private List<GenerateSubplansRequest.Line> items = List.of();

    @Valid
    @Size(max = RequestLimits.DOCUMENT_LINES)
    private List<MaterialRoute> routes = List.of();
    @Valid
    @Size(max = RequestLimits.DOCUMENT_LINES)
    private List<ExecutionSegment> segments = List.of();


    /** 为 true 时同时按采购总净缺口生成采购申请；没有外购净缺口时返回 null。 */
    private boolean generatePurchaseRequest;
    @Getter
    @Setter
    public static class MaterialRoute {
        @NotNull
        private UUID goodsId;
        private UUID colorId;
        @NotBlank
        @Pattern(regexp = "BUY|SUBCONTRACT")
        private String supplyRoute;
    }

    @Getter
    @Setter
    public static class ExecutionSegment {
        @NotBlank
        @Size(max = 128)
        private String clientSegmentKey;

        @NotNull
        private UUID sourcePlanItemId;

        @NotBlank
        @Pattern(regexp = "READY|WAITING")
        private String requestedStatus;

        /**
         * Explicit user hold. A normal shortage-suggested WAITING segment keeps
         * this false so an authoritative receipt may promote it later.
         */
        private boolean deferUntilManualRelease;

        @NotNull
        private BigDecimal plannedQty;

        private UUID workshopDepartmentId;
        private UUID teamDepartmentId;
        private UUID responsibleEmployeeId;
        private LocalDate planBeginDate;
        private LocalDate planEndDate;

        @NotBlank
        @Pattern(regexp = "(?i)[0-9a-f]{64}")
        private String bomFingerprint;
}
    }
