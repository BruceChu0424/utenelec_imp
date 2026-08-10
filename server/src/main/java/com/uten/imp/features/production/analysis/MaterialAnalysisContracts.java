package com.uten.imp.features.production.analysis;

import com.fasterxml.jackson.annotation.JsonAlias;
import com.uten.imp.common.validation.RequestLimits;
import jakarta.validation.Valid;
import jakarta.validation.constraints.DecimalMin;
import jakarta.validation.constraints.Digits;
import jakarta.validation.constraints.Max;
import jakarta.validation.constraints.Min;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotEmpty;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Pattern;
import jakarta.validation.constraints.Size;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.util.List;
import java.util.UUID;

/** Stable HTTP contract for the persistent pre-plan material-analysis aggregate. */
public final class MaterialAnalysisContracts {

    private MaterialAnalysisContracts() {
    }

    public record PreviewRequest(
            UUID analysisId,
            Long version,
            @Pattern(regexp = "(?i)[0-9a-f]{64}") String fingerprint,
            @NotNull UUID warehouseId,
            @NotBlank @Size(min = 8, max = 128) String idempotencyKey,
            @NotEmpty @Size(max = RequestLimits.DOCUMENT_LINES)
            @JsonAlias("sources") List<@Valid PreviewItem> items) {
    }

    public record PreviewItem(
            String sourceType,
            UUID salesOrderItemId,
            UUID goodsId,
            UUID colorId,
            UUID unitId,
            @Size(max = 200) String sourceRef,
            @Size(max = 1000) String sourceReason,
            LocalDate deliveryDate,
            @NotNull @DecimalMin(value = "0.0001")
            @Digits(integer = 14, fraction = 4) BigDecimal requestedQty) {
    }

    public record RouteRequest(
            @NotNull @JsonAlias("expectedVersion") Long version,
            @NotBlank @Pattern(regexp = "(?i)[0-9a-f]{64}") String fingerprint,
            @NotBlank @Size(min = 8, max = 128) String idempotencyKey,
            @NotEmpty @Size(max = RequestLimits.DOCUMENT_LINES)
            List<@Valid RouteDecision> decisions) {
    }

    public record RouteDecision(
            UUID materialLineId,
            @Size(max = 64) String actionGroupKey,
            @NotBlank @Pattern(regexp = "BUY|MAKE|SUBCONTRACT") String route,
            @Size(max = 1000) String reason) {
    }

    public record AllocationPriorityRequest(
            @NotNull @JsonAlias("expectedVersion") Long version,
            @NotBlank @Pattern(regexp = "(?i)[0-9a-f]{64}") String fingerprint,
            @NotBlank @Size(min = 8, max = 128) String idempotencyKey,
            @NotEmpty @Size(max = RequestLimits.DOCUMENT_LINES)
            List<@Valid AllocationPriorityItem> items) {
    }

    public record AllocationPriorityItem(
            @NotNull UUID analysisLineId,
            @Min(1) @Max(RequestLimits.DOCUMENT_LINES) int priority) {
    }

    public record NotifyRequest(
            @NotNull @JsonAlias("expectedVersion") Long version,
            @NotBlank @Pattern(regexp = "(?i)[0-9a-f]{64}") String fingerprint,
            @NotBlank @Size(min = 8, max = 128) String idempotencyKey,
            @Pattern(regexp = "BUY|MAKE|SUBCONTRACT") String target,
            @Size(max = RequestLimits.DOCUMENT_LINES)
            List<@NotNull UUID> materialLineIds,
            @Size(max = RequestLimits.DOCUMENT_LINES)
            List<@NotBlank @Size(max = 64) String> actionGroupKeys) {
    }

    public record PlanPreviewRequest(
            @NotNull @JsonAlias("expectedVersion") Long version,
            @NotBlank @Pattern(regexp = "(?i)[0-9a-f]{64}") String fingerprint,
            @NotNull UUID warehouseId,
            @NotEmpty @Size(max = RequestLimits.DOCUMENT_LINES)
            List<@Valid PlanQuantity> items,
            @Size(max = RequestLimits.DOCUMENT_LINES)
            List<@Valid RouteDecision> routes,
            @Size(max = RequestLimits.DOCUMENT_LINES)
            List<@Valid BomOverride> bomOverrides) {
    }

    public record PlanQuantity(
            @NotNull UUID analysisLineId,
            @NotNull @DecimalMin(value = "0.0001")
            @Digits(integer = 14, fraction = 4) BigDecimal qty,
            LocalDate billDate,
            LocalDate deliveryDate,
            UUID departmentId,
            @Size(max = 250) String workshopName,
            UUID workerId,
            UUID teamDepartmentId) {

        /** Backwards-compatible constructor for preview callers without per-sheet scheduling. */
        public PlanQuantity(UUID analysisLineId, BigDecimal qty) {
            this(analysisLineId, qty, null, null, null, null, null, null);
        }
    }

    public record GeneratePlanRequest(
            @NotNull @JsonAlias("expectedVersion") Long version,
            @NotBlank @Pattern(regexp = "(?i)[0-9a-f]{64}") String fingerprint,
            @NotBlank @Pattern(regexp = "(?i)[0-9a-f]{64}") String previewFingerprint,
            @NotBlank @Size(min = 8, max = 128) String idempotencyKey,
            @NotNull UUID warehouseId,
            @NotNull LocalDate billDate,
            LocalDate deliveryDate,
            UUID departmentId,
            @Size(max = 250) String workshopName,
            UUID workerId,
            boolean approveNow,
            @NotEmpty @Size(max = RequestLimits.DOCUMENT_LINES)
            List<@Valid PlanQuantity> items,
            @Size(max = RequestLimits.DOCUMENT_LINES)
            List<@Valid RouteDecision> routes,
            @Size(max = RequestLimits.DOCUMENT_LINES)
            List<@Valid BomOverride> bomOverrides) {
    }

    public record BomOverride(
            @NotNull UUID analysisLineId,
            @NotBlank @Size(max = 1000) String reason) {
    }

    public record CancelRequest(
            @NotNull @JsonAlias("expectedVersion") Long version,
            @NotBlank @Pattern(regexp = "(?i)[0-9a-f]{64}") String fingerprint,
            @NotBlank @Size(min = 8, max = 128) String idempotencyKey,
            @NotBlank @Size(min = 2, max = 1000) String reason) {
    }

    public record AnalysisView(
            UUID analysisId,
            String status,
            long version,
            String fingerprint,
            String analysisFingerprint,
            UUID warehouseId,
            OffsetDateTime analyzedAt,
            List<ProductView> products,
            List<MaterialView> flatMaterials,
            List<WarehouseView> warehouses,
            List<SupplyActionView> supplyActions,
            List<String> allowedActions) {
    }

    public record ProductView(
            UUID analysisLineId,
            String sourceType,
            String sourceRef,
            String sourceReason,
            UUID salesOrderItemId,
            UUID salesOrderId,
            String salesOrderNo,
            LocalDate orderDate,
            LocalDate deliveryDate,
            String clientName,
            UUID goodsId,
            String goodsCode,
            String goodsName,
            String spec,
            UUID colorId,
            String colorName,
            UUID unitId,
            String unitName,
            BigDecimal unitRate,
            BigDecimal requestedQty,
            BigDecimal submittedQty,
            BigDecimal approvedQty,
            BigDecimal remainingQty,
            int allocationPriority,
            BigDecimal readyNowQty,
            BigDecimal readyByDateQty,
            BigDecimal readyStartQty,
            BigDecimal readyFinishQty,
            BigDecimal readyShipQty,
            BigDecimal readinessRatio,
            String productionBomPolicy,
            boolean missingBom,
            boolean bomOverrideRequired,
            UUID parentAnalysisLineId,
            String parentGoodsName) {
    }

    public record AnalysisListItem(
            UUID analysisId,
            String status,
            long version,
            String fingerprint,
            UUID warehouseId,
            String warehouseCode,
            String warehouseName,
            OffsetDateTime analyzedAt,
            OffsetDateTime updatedAt,
            UUID makerId,
            String makerName,
            int sourceCount,
            List<String> sourceTypes,
            List<String> sourceRefs,
            List<String> productLabels,
            BigDecimal requestedQty,
            BigDecimal submittedQty,
            BigDecimal approvedQty,
            BigDecimal remainingQty,
            BigDecimal readyNowQty,
            BigDecimal readyByDateQty) {
    }

    public record MaterialView(
            UUID materialLineId,
            UUID analysisLineId,
            String nodeKey,
            String actionGroupKey,
            String materialKey,
            UUID goodsId,
            String goodsCode,
            String goodsName,
            String spec,
            UUID colorId,
            String colorName,
            UUID unitId,
            String unitName,
            int level,
            List<String> path,
            String parentNodeKey,
            UUID parentGoodsId,
            String parentLabel,
            String controlStage,
            String consumptionBasis,
            BigDecimal basisOutputQty,
            boolean allowPartialPackage,
            boolean hardGate,
            BigDecimal bomQty,
            BigDecimal parentPerProductQty,
            BigDecimal perProductQty,
            BigDecimal requiredQty,
            BigDecimal availableQty,
            BigDecimal allocatedAvailableQty,
            BigDecimal reservedQty,
            BigDecimal safetyStockQty,
            BigDecimal inboundQty,
            BigDecimal shortageQty,
            LocalDate expectedReadyDate,
            String sourceSuggestion,
            String sourceConfirmed,
            boolean routeConfirmed,
            String routeReason,
            String productionBomPolicy,
            boolean hasActiveBom,
            boolean actionable,
            boolean lowerLevelPending,
            List<String> notifiedTargets,
            List<WarehouseBreakdown> warehouseBreakdown,
            List<DownstreamReference> downstreamReferences) {
    }

    public record WarehouseBreakdown(
            UUID warehouseId,
            String warehouseCode,
            String warehouseName,
            BigDecimal onHandQty,
            BigDecimal reservedQty,
            BigDecimal availableQty) {
    }

    public record WarehouseView(
            UUID warehouseId,
            String warehouseCode,
            String warehouseName,
            boolean selected) {
    }

    public record DownstreamReference(
            UUID actionId,
            String route,
            String status,
            String documentType,
            UUID documentId,
            String documentNo,
            BigDecimal allocatedQty) {
    }

    public record SupplyActionView(
            UUID actionId,
            String actionGroupKey,
            int generation,
            UUID predecessorActionId,
            String route,
            String status,
            UUID goodsId,
            UUID colorId,
            UUID unitId,
            BigDecimal requestedQty,
            LocalDate needDate,
            String documentType,
            UUID documentId,
            String documentNo) {
    }

    public record NotifyResult(
            UUID analysisId,
            long version,
            String fingerprint,
            boolean replayed,
            List<SupplyActionView> actions) {
    }

    public record PlanPreview(
            UUID analysisId,
            long version,
            String fingerprint,
            String analysisFingerprint,
            String previewFingerprint,
            UUID warehouseId,
            OffsetDateTime calculatedAt,
            boolean allReady,
            List<PlanPreviewItem> items,
            List<PlanDraftPreview> plans,
            List<String> allowedActions) {
    }

    public record PlanPreviewItem(
            UUID analysisLineId,
            BigDecimal requestedQty,
            BigDecimal readyNowQty,
            BigDecimal selectedQty,
            boolean canGenerate,
            String reason) {
    }

    public record PlanDraftPreview(
            String clientPlanKey,
            UUID productGoodsId,
            BigDecimal qty,
            BigDecimal readyNowQty,
            String segmentStatus,
            List<PlanMaterialPreview> materials) {
    }

    public record PlanMaterialPreview(
            UUID materialLineId,
            BigDecimal requiredQty,
            BigDecimal availableQty,
            BigDecimal allocatedQty,
            BigDecimal shortageQty,
            String route) {
    }

    public record GenerateResult(
            AnalysisView analysis,
            boolean replayed,
            List<GeneratedPlan> plans) {
    }

    public record GeneratedPlan(
            UUID planId,
            String planNo,
            String status,
            UUID planningDraftId,
            UUID packageId,
            List<UUID> segmentIds,
            List<UUID> drawIds) {
    }

    public record SalesCandidatePage(
            List<SalesCandidateOrder> items,
            int page,
            int size,
            long total,
            int totalPages) {
    }

    public record SalesCandidateOrder(
            UUID orderId,
            String orderNo,
            LocalDate orderDate,
            LocalDate deliveryDate,
            String clientName,
            List<SalesCandidateLine> lines) {
    }

    public record SalesCandidateLine(
            UUID salesOrderItemId,
            Integer lineNo,
            UUID goodsId,
            String goodsCode,
            String goodsName,
            String spec,
            UUID colorId,
            String colorName,
            UUID unitId,
            String unitName,
            BigDecimal orderedQty,
            BigDecimal approvedPlannedQty,
            BigDecimal submittedPlanQty,
            BigDecimal remainingQty,
            LocalDate deliveryDate,
            String productionBomPolicy,
            UUID analysisId,
            String analysisStatus,
            Long analysisVersion) {
    }
}
