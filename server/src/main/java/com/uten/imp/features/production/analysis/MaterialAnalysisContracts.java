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
            List<@NotBlank @Size(max = 64) String> actionGroupKeys,
            @Size(max = RequestLimits.DOCUMENT_LINES)
            List<@Valid SupplyQuantityInput> quantities) {
    }

    /**
     * 本次提交的指定数量（缺省 = 剩余缺口全量提交）。
     * actionGroupKey 与 materialLineId 二选一；服务端按操作组解析，
     * 数量必须大于 0 且不超过该组「缺口 − 在途任务」的实时余量。
     */
    public record SupplyQuantityInput(
            @Size(max = 64) String actionGroupKey,
            UUID materialLineId,
            @NotNull @DecimalMin(value = "0", inclusive = false)
            @Digits(integer = 14, fraction = 4) BigDecimal qty) {
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
            UUID teamDepartmentId,
            @Size(max = 200) String productNo) {

        /** Backwards-compatible constructor for preview callers without per-sheet scheduling. */
        public PlanQuantity(UUID analysisLineId, BigDecimal qty) {
            this(analysisLineId, qty, null, null, null, null, null, null, null);
        }

        /** Backwards-compatible constructor for callers using the original schedule sheet. */
        public PlanQuantity(
                UUID analysisLineId, BigDecimal qty,
                LocalDate billDate, LocalDate deliveryDate,
                UUID departmentId, String workshopName,
                UUID workerId, UUID teamDepartmentId) {
            this(analysisLineId, qty, billDate, deliveryDate, departmentId,
                    workshopName, workerId, teamDepartmentId, null);
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

    /**
     * 现货层借用（调货）：把同一分析内某条直接组件路径上已分配的合格现货
     * 覆盖量调拨给另一产品的同物料直接组件路径。只影响分析软分配与齐套
     * 投影，不写 stock_reservations、不动库存账本；正式预留后不可再调。
     */
    public record BorrowRequest(
            @NotNull @JsonAlias("expectedVersion") Long version,
            @NotBlank @Pattern(regexp = "(?i)[0-9a-f]{64}") String fingerprint,
            @NotBlank @Size(min = 8, max = 128) String idempotencyKey,
            @NotNull UUID fromMaterialLineId,
            @NotNull UUID toMaterialLineId,
            @NotNull @DecimalMin(value = "0.0001")
            @Digits(integer = 14, fraction = 4) BigDecimal qty,
            @NotBlank @Size(min = 2, max = 1000) String reason) {
    }

    /** 某条物料路径上的一笔有效借用投影（双向可见：借出方与借入方都能看到）。 */
    public record BorrowRef(
            UUID borrowId,
            String direction,
            BigDecimal qty,
            BigDecimal requestedQty,
            String counterpartProduct,
            String reason) {
    }
    /**
     * 跨物料分析让料：接受计划无需向来源计划“还料”；来源计划保留优先待补量，
     * 后续符合规则的采购、委外或自制合格供给按服务端顺序重新挂接。
     */
    public record CrossReallocationRequest(
            @NotNull Long sourceVersion,
            @NotBlank @Pattern(regexp = "(?i)[0-9a-f]{64}") String sourceFingerprint,
            @NotNull UUID sourceMaterialLineId,
            @NotNull UUID targetAnalysisId,
            @NotNull Long targetVersion,
            @NotBlank @Pattern(regexp = "(?i)[0-9a-f]{64}") String targetFingerprint,
            @NotNull UUID targetMaterialLineId,
            @NotNull @DecimalMin(value = "0.0001")
            @Digits(integer = 14, fraction = 4) BigDecimal qty,
            @NotBlank @Size(min = 2, max = 1000) String reason,
            @NotBlank @Size(min = 8, max = 128) String idempotencyKey) {
    }

    /** 撤销仍未正式占用的跨计划让料；双端 CAS 防止用旧快照夺回库存权益。 */
    public record CrossReallocationRevokeRequest(
            @NotNull Long sourceVersion,
            @NotBlank @Pattern(regexp = "(?i)[0-9a-f]{64}") String sourceFingerprint,
            @NotNull Long targetVersion,
            @NotBlank @Pattern(regexp = "(?i)[0-9a-f]{64}") String targetFingerprint,
            @NotBlank @Size(min = 2, max = 1000) String reason,
            @NotBlank @Size(min = 8, max = 128) String idempotencyKey) {
    }

    /** 服务端已按同仓、同物料维度、真实缺口和双端对象范围过滤的接受计划候选。 */
    public record CrossReallocationCandidate(
            UUID targetAnalysisId,
            long targetVersion,
            String targetFingerprint,
            UUID targetMaterialLineId,
            UUID warehouseId,
            String warehouseName,
            String analysisLabel,
            String productLabel,
            LocalDate deliveryDate,
            BigDecimal sourceLendableQty,
            BigDecimal shortageQty) {
    }

    /** 一次优先补齐来源；用于计划员解释“哪一批新供给补回了来源计划”。 */
    public record ReplenishmentRef(
            String sourceType,
            UUID sourceDocumentId,
            String sourceDocumentNo,
            BigDecimal qty,
            OffsetDateTime occurredAt) {
    }

    /** 跨计划让料在双方物料节点上的只读投影。 */
    public record CrossReallocationRef(
            UUID reallocationId,
            String direction,
            String status,
            UUID counterpartAnalysisId,
            long counterpartVersion,
            String counterpartFingerprint,
            UUID counterpartMaterialLineId,
            String counterpartAnalysisLabel,
            String counterpartProduct,
            BigDecimal qty,
            BigDecimal currentEffectiveQty,
            BigDecimal priorityFulfilledQty,
            BigDecimal priorityOpenQty,
            String reason,
            boolean canRevoke,
            String revokeBlockedReason,
            List<ReplenishmentRef> replenishmentRefs) {
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
            String parentGoodsName,
            String planExecutionStatus,
            UUID latestPlanId,
            String latestPlanNo) {
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
            BigDecimal exactPeggedQty,
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
            BigDecimal borrowedInQty,
            BigDecimal borrowedOutQty,
            List<BorrowRef> borrowRefs,
            List<String> notifiedTargets,
            BigDecimal crossReallocatedInQty,
            BigDecimal crossReallocatedOutQty,
            BigDecimal priorityPendingQty,
            BigDecimal priorityFulfilledQty,
            List<CrossReallocationRef> crossReallocationRefs,
            List<WarehouseBreakdown> warehouseBreakdown,
            List<DownstreamReference> downstreamReferences) {
    }

    public record WarehouseBreakdown(
            UUID warehouseId,
            String warehouseCode,
            String warehouseName,
            BigDecimal onHandQty,
            BigDecimal reservedQty,
            BigDecimal availableQty,
            BigDecimal ownPeggedQty) {
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

    /** 物料供给全链路进度（只读投影）：逐步状态 + 单号 + 时间。 */
    public record SupplyProgressView(
            String materialLineId,
            String goodsCode,
            String goodsName,
            String route,
            List<SupplyProgressStep> steps) {
    }

    /**
     * 进度一步：state ∈ DONE（已完成）/ CURRENT（进行中）/ WAITING（未开始）/
     * REJECTED（被驳回）；detail 为该步骤的补充说明（数量、待办提示）。
     * operatorName 为该步骤责任人姓名（提交人/采购人/审批人/收货人/下达人），无则 null。
     */
    public record SupplyProgressStep(
            String key,
            String label,
            String state,
            String detail,
            String docNo,
            String at,
            String operatorName) {
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
            List<UUID> drawIds,
            List<GeneratedDraw> drawDocuments) {
    }

    /** 随计划包自动生成的物料提货单（领料单 DRAW 草稿）：id + 可读单号。 */
    public record GeneratedDraw(UUID drawId, String billNo) {
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
