package com.uten.imp.features.production.analysis;

import com.fasterxml.jackson.annotation.JsonAlias;
import com.fasterxml.jackson.annotation.JsonProperty;
import com.uten.imp.common.validation.RequestLimits;
// 预览请求要在 List<@Valid ...> 上逐行级联校验；type-use 注解不能加在带限定名的
// 嵌套类型上, 所以这里把嵌套的行记录单独 import 一次, 好写成简单名。
import com.uten.imp.features.production.analysis.MaterialAnalysisContracts.IssueWorkshopPlansRequest.IssuePlanLine;
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
import java.util.Map;
import java.util.UUID;

/** Stable HTTP contract for the persistent pre-plan material-analysis aggregate. */
public final class MaterialAnalysisContracts {

    private MaterialAnalysisContracts() {
    }

    public static final String REQUIREMENT_STATE_ACTIVE = "ACTIVE";
    public static final String REQUIREMENT_STATE_DELEGATED_TO_MAKE_CHILD =
            "DELEGATED_TO_MAKE_CHILD";
    public static final String REQUIREMENT_STATE_DELEGATED_TO_SUBCONTRACT_PREPARATION =
            "DELEGATED_TO_SUBCONTRACT_PREPARATION";
    public static final String REQUIREMENT_STATE_INACTIVE_PARENT_COVERED =
            "INACTIVE_PARENT_COVERED";
    public static final String REQUIREMENT_STATE_INACTIVE_PARENT_ROUTE =
            "INACTIVE_PARENT_ROUTE";
    public static final String REQUIREMENT_STATE_INACTIVE_REFERENCE =
            "INACTIVE_REFERENCE";
    public static final String REQUIREMENT_STATE_TRANSFERRED_TO_PLAN =
            "TRANSFERRED_TO_PLAN";
    public static final String REQUIREMENT_STATE_INACTIVE = "INACTIVE";

    public record PreviewRequest(
            UUID analysisId,
            Long version,
            @Pattern(regexp = "(?i)[0-9a-f]{64}") String fingerprint,
            @NotNull UUID warehouseId,
            @Size(max = 100) List<@NotNull UUID> warehouseIds,
            @NotBlank @Size(min = 8, max = 128) String idempotencyKey,
            @NotEmpty @Size(max = RequestLimits.DOCUMENT_LINES)
            @JsonAlias("sources") List<@Valid PreviewItem> items) {
        /** Old clients and internal callers send only the primary warehouse. */
        public PreviewRequest(
                UUID analysisId,
                Long version,
                String fingerprint,
                UUID warehouseId,
                String idempotencyKey,
                List<PreviewItem> items) {
            this(analysisId, version, fingerprint, warehouseId,
                    warehouseId == null ? List.of() : List.of(warehouseId),
                    idempotencyKey, items);
        }
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
     * qty is exact demand and must not exceed the live gap after open supply.
     * Optional publicExtraQty is a separate public replenishment slice and never
     * increases the action allocation or the origin analysis entitlement.
     * MAKE 在显式 delegated_qty 落地前必须等于全部实时余量，正式计划批量
     * 由 child 创建后的 PlanQuantity 单独确认。
     */
    /**
     * 本次下达数量（ADR-099 数量单一口径）：{@code qty} 是这一次要下达的总量——
     * 不超过「还需安排」的部分归本需求，超出的部分由服务端记为公共备货（需超量
     * 下达权限）；服务端还会先自动认领同主仓公共在途，只为余下部分新下单。
     */
    public record SupplyQuantityInput(
            @Size(max = 64) String actionGroupKey,
            UUID materialLineId,
            @NotNull @DecimalMin(value = "0")
            @Digits(integer = 14, fraction = 4) BigDecimal qty,
            @DecimalMin(value = "0") @Digits(integer = 14, fraction = 4)
            BigDecimal safetyReplenishmentQty) {
    }

    public record ClaimSharedFutureRequest(
            @NotNull @JsonAlias("expectedVersion") Long version,
            @NotBlank @Pattern(regexp = "(?i)[0-9a-f]{64}") String fingerprint,
            @NotBlank @Size(min = 8, max = 128) String idempotencyKey,
            @NotEmpty @Size(max = RequestLimits.DOCUMENT_LINES)
            List<@NotBlank @Size(max = 64) String> actionGroupKeys,
            @Size(max = RequestLimits.DOCUMENT_LINES) List<@NotNull @Valid SharedFutureClaimQuantity> quantities,
            boolean allowLateSupply) {
        public ClaimSharedFutureRequest(Long version,String fingerprint,String idempotencyKey,List<String> actionGroupKeys) {
            this(version,fingerprint,idempotencyKey,actionGroupKeys,List.of(),false);
        }
        public ClaimSharedFutureRequest(Long version,String fingerprint,String idempotencyKey,List<String> actionGroupKeys,
                List<SharedFutureClaimQuantity> quantities) {
            this(version,fingerprint,idempotencyKey,actionGroupKeys,quantities,false);
        }
    }

    public record SharedFutureClaimQuantity(
            @NotBlank @Size(max=64) String actionGroupKey,
            @NotNull @DecimalMin("0.0001") @Digits(integer=14,fraction=4) BigDecimal qty,
            UUID sourceActionId) {
    }

    /**
     * 下达车间（ADR-071，2026-09-05 重构）：所有自制行（顶层产品 / 自制候选 /
     * 委外先自制候选 / 已有子件）一视同仁，单次调用原子完成「候选先建子件任务
     * → 按行内数量/车间/负责人生成生产计划 → 有审核权限同事务审核下达」。
     * 物料齐不齐不再由计划侧判断：计划照常创建，缺料批次进入 WAITING，由车间
     * 侧执行段在齐套后自动提升 READY。
     */
    public record IssueWorkshopPlansRequest(
            @NotNull @JsonAlias("expectedVersion") Long version,
            @NotBlank @Pattern(regexp = "(?i)[0-9a-f]{64}") String fingerprint,
            @NotBlank @Size(min = 8, max = 128) String idempotencyKey,
            @NotNull UUID warehouseId,
            @NotNull LocalDate billDate,
            LocalDate deliveryDate,
            boolean approveNow,
            @NotEmpty @Size(max = RequestLimits.DOCUMENT_LINES)
            List<@Valid IssuePlanLine> lines) {

        /** 每行二选一：候选物料行 materialLineId（先建子件任务）或已有产品行 analysisLineId。 */
        public record IssuePlanLine(
                UUID materialLineId,
                UUID analysisLineId,
                @NotNull @DecimalMin(value = "0.0001")
                @Digits(integer = 14, fraction = 4) BigDecimal qty,
                LocalDate billDate,
                LocalDate deliveryDate,
                UUID departmentId,
                @Size(max = 250) String workshopName,
                UUID workerId,
                UUID teamDepartmentId,
                @Size(max = 200) String productNo,
                /**
                 * ADR-099：明确声明「本行是对剩余需求已为 0 的锚点再追加一批纯公共备货
                 * 产出」。不声明时需求已全部转入计划的行照旧 409——重复点击、过期候选
                 * 不能悄悄多建一张计划。
                 */
                Boolean publicSurplusOnly) {

            public IssuePlanLine(UUID materialLineId, UUID analysisLineId, BigDecimal qty,
                    LocalDate billDate, LocalDate deliveryDate, UUID departmentId,
                    String workshopName, UUID workerId, UUID teamDepartmentId, String productNo) {
                this(materialLineId, analysisLineId, qty, billDate, deliveryDate, departmentId,
                        workshopName, workerId, teamDepartmentId, productNo, null);
            }

            public IssuePlanLine(UUID analysisLineId, BigDecimal qty) {
                this(null, analysisLineId, qty, null, null, null, null, null, null, null, null);
            }
        }
    }

    /**
     * 「父件 + 下层一起下单」整页的重算请求(ADR-099 修订，2026-09-21 第五轮)。
     *
     * <p>{@link #lines()} 是树顶那一行的真实下达意图(服务端真跑一遍再整体回滚)，
     * {@link #typedOutputs()} 是层级表上<b>每一行</b>输入框里的数量——服务端按它把
     * 各自节点的计划产出量补齐，于是任意一层改量都能把它的子层、孙层一路带大。
     * 两者都可以为空一边：只改中间层(或父件已提交过的重试)时 lines 为空；
     * 刚进页、下层还没填时 typedOutputs 为空。</p>
     */
    public record PreviewIssuePlansRequest(
            @NotNull @JsonAlias("expectedVersion") Long version,
            @NotBlank @Pattern(regexp = "(?i)[0-9a-f]{64}") String fingerprint,
            @NotBlank @Size(min = 8, max = 128) String idempotencyKey,
            @NotNull UUID warehouseId,
            @NotNull LocalDate billDate,
            LocalDate deliveryDate,
            boolean approveNow,
            @Size(max = RequestLimits.DOCUMENT_LINES)
            List<@Valid IssuePlanLine> lines,
            @Size(max = RequestLimits.DOCUMENT_LINES)
            List<@Valid TypedOutput> typedOutputs) {

        public PreviewIssuePlansRequest {
            lines = lines == null ? List.of() : lines;
            typedOutputs = typedOutputs == null ? List.of() : typedOutputs;
        }

        /** 层级表里某一行填的本批数量(键 = 该行的物料行 id)。 */
        public record TypedOutput(
                @NotNull UUID materialLineId,
                @NotNull @DecimalMin(value = "0.0000")
                @Digits(integer = 14, fraction = 4) BigDecimal qty) {}

        IssueWorkshopPlansRequest toIssueRequest() {
            return new IssueWorkshopPlansRequest(version, fingerprint, idempotencyKey, warehouseId,
                    billDate, deliveryDate, approveNow, lines);
        }
    }

    /** 生成计划时的逐行排产输入（分析行 + 数量 + 车间/负责人）。 */
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

        /** Backwards-compatible constructor for callers without per-sheet scheduling. */
        public PlanQuantity(UUID analysisLineId, BigDecimal qty) {
            this(analysisLineId, qty, null, null, null, null, null, null, null);
        }
    }

    /**
     * 取消分析 / 撤回供给任务 / 撤回根产品交接共用的请求体。
     * <p>原因选填(2026-09-22 用户口径「取消分析的原因不用必填」)：留空落审计时记
     * {@link #DEFAULT_REASON}；填了就去首尾空白后至少 2 字——与库级 CHECK
     * (production_material_analysis_cancel_chk / preplan_supply_action_cancel_chk 的
     * length(btrim(cancellation_reason)) >= 2)同口径, 由 {@code @Pattern} 在入口挡住,
     * 不让 1 个字的原因走到库里变成 500。所有消费方一律取 {@link #effectiveReason()}。
     */
    public record CancelRequest(
            @NotNull @JsonAlias("expectedVersion") Long version,
            @NotBlank @Pattern(regexp = "(?i)[0-9a-f]{64}") String fingerprint,
            @NotBlank @Size(min = 8, max = 128) String idempotencyKey,
            @Size(max = 1000)
            @Pattern(regexp = "(?s)\\s*|\\s*\\S.*\\S\\s*", message = "原因留空或至少 2 个字")
            String reason) {

        public static final String DEFAULT_REASON = "未填写原因";

        /** 落库 / 进指纹 / 写审计用的原因：空白 → {@link #DEFAULT_REASON}，否则去首尾空白。 */
        public String effectiveReason() {
            String trimmed = reason == null ? "" : reason.strip();
            return trimmed.isEmpty() ? DEFAULT_REASON : trimmed;
        }
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
            @Size(max = 1000) String reason,
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

    /** 缺料分析反向查询可让料来源；仓库为计划范围，实物仍属于原始叶仓 lot。 */
    public record CrossReallocationSourceCandidate(
            UUID sourceAnalysisId,
            long sourceVersion,
            String sourceFingerprint,
            UUID sourceMaterialLineId,
            UUID warehouseId,
            String warehouseName,
            String analysisLabel,
            String productLabel,
            LocalDate deliveryDate,
            BigDecimal sourceLendableQty,
            BigDecimal shortageQty) {
    }

    /** Read-only follow-up for the original donor; opening it never orders supply. */
    public record CrossReallocationReplenishmentView(
            UUID reallocationId,
            AnalysisView sourceAnalysis,
            UUID sourceMaterialLineId,
            UUID targetAnalysisId,
            BigDecimal transferredQty,
            BigDecimal priorityPendingQty,
            BigDecimal remainingSupplementQty,
            BigDecimal defaultQty,
            String route,
            List<String> allowedRoutes,
            String operation,
            boolean canOverSupply,
            boolean requiresPreparation,
            UUID existingChildAnalysisLineId,
            BigDecimal safetyReplenishmentQty,
            String blockedReason) {
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
            List<ReplenishmentRef> replenishmentRefs,
            String createdByName,
            OffsetDateTime createdAt) {
    }


    public record AnalysisView(
            UUID analysisId,
            String status,
            long version,
            String fingerprint,
            String analysisFingerprint,
            UUID warehouseId,
            List<UUID> warehouseIds,
            OffsetDateTime analyzedAt,
            List<ProductView> products,
            List<MaterialView> flatMaterials,
            List<WarehouseView> warehouses,
            List<SupplyActionView> supplyActions,
            List<String> allowedActions,
            boolean fqcReplenishmentOnly,
            UUID fqcRecoveryAuthorizationId,
            Map<UUID, String> planningBlockedReasons,
            /**
             * 本次刷新（POST /preview）因主档/BOM 事实变更而被清空的人工确认路线条数；
             * 只在刷新响应上非零，详情/命令响应恒为 0。前端据此提示
             * 「N 条路线因主档变更需重新确认」，让静默清空可见。
             */
            int routeResetCount) {
        public AnalysisView {
            planningBlockedReasons = Map.copyOf(planningBlockedReasons);
        }

        public AnalysisView(UUID analysisId, String status, long version,
                String fingerprint, String analysisFingerprint, UUID warehouseId,
                List<UUID> warehouseIds, OffsetDateTime analyzedAt,
                List<ProductView> products, List<MaterialView> flatMaterials,
                List<WarehouseView> warehouses, List<SupplyActionView> supplyActions,
                List<String> allowedActions, boolean fqcReplenishmentOnly,
                UUID fqcRecoveryAuthorizationId,
                Map<UUID, String> planningBlockedReasons) {
            this(analysisId, status, version, fingerprint, analysisFingerprint,
                    warehouseId, warehouseIds, analyzedAt, products, flatMaterials,
                    warehouses, supplyActions, allowedActions, fqcReplenishmentOnly,
                    fqcRecoveryAuthorizationId, planningBlockedReasons, 0);
        }

        public AnalysisView(UUID analysisId, String status, long version,
                String fingerprint, String analysisFingerprint, UUID warehouseId,
                List<UUID> warehouseIds, OffsetDateTime analyzedAt,
                List<ProductView> products, List<MaterialView> flatMaterials,
                List<WarehouseView> warehouses, List<SupplyActionView> supplyActions,
                List<String> allowedActions, boolean fqcReplenishmentOnly,
                UUID fqcRecoveryAuthorizationId) {
            this(analysisId, status, version, fingerprint, analysisFingerprint,
                    warehouseId, warehouseIds, analyzedAt, products, flatMaterials,
                    warehouses, supplyActions, allowedActions, fqcReplenishmentOnly,
                    fqcRecoveryAuthorizationId, Map.of());
        }

        /** 刷新入口专用：把本次被清空的确认路线数挂到响应上，其余字段不变。 */
        public AnalysisView withRouteResetCount(int count) {
            return count == routeResetCount ? this : new AnalysisView(
                    analysisId, status, version, fingerprint, analysisFingerprint,
                    warehouseId, warehouseIds, analyzedAt, products, flatMaterials,
                    warehouses, supplyActions, allowedActions, fqcReplenishmentOnly,
                    fqcRecoveryAuthorizationId, planningBlockedReasons, count);
        }
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
            boolean canSchedule,
            BigDecimal maxSchedulableQty,
            String scheduleBlockedReason,
            BigDecimal readyNowQty,
            BigDecimal readyByDateQty,
            BigDecimal readyStartQty,
            BigDecimal readyFinishQty,
            BigDecimal readyShipQty,
            BigDecimal readinessRatio,
            boolean hasProductionMaterialChildren,
            UUID parentAnalysisLineId,
            String parentGoodsName,
            String planExecutionStatus,
            UUID latestPlanId,
            String latestPlanNo,
            BigDecimal planExecutionPlannedQty,
            BigDecimal planExecutionInboundQty,
            BigDecimal planExecutionProgressRatio,
            BigDecimal planExecutionReportedQty,
            boolean planExecutionZeroMaterial,
            String planExecutionWorkshopName,
            String planExecutionResponsibleName,
            UUID rootMaterialLineId,
            /**
             * V587 货品主档的「所属仓库」(这批货平时归哪个仓管)。
             * 既不是单据落点仓，也不是本次分析的范围仓 (warehouseIds)；未登记为 null。
             */
            UUID owningWarehouseId,
            String owningWarehouseName,
            /**
             * V590 货品主档的「归属生产车间」：最近一次排产确认/车间改派学习回写。
             */
            UUID owningWorkshopId,
            String owningWorkshopName,
            /** ADR-099：已下达且仍有效的计划总量(归需求份 + 公共备货产出份)。 */
            BigDecimal issuedPlanQty,
            /**
             * ADR-099：剩余需求已为 0 但仍可再下一批纯公共备货产出(V577 合法形态)——
             * 用户口径「父层级那里还是可以追加下单, 多下的属于公共的」。
             */
            boolean canIssueSurplus) {
        public ProductView(
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
            boolean canSchedule,
            BigDecimal maxSchedulableQty,
            String scheduleBlockedReason,
            BigDecimal readyNowQty,
            BigDecimal readyByDateQty,
            BigDecimal readyStartQty,
            BigDecimal readyFinishQty,
            BigDecimal readyShipQty,
            BigDecimal readinessRatio,
            boolean hasProductionMaterialChildren,
            UUID parentAnalysisLineId,
            String parentGoodsName,
            String planExecutionStatus,
            UUID latestPlanId,
            String latestPlanNo,
            BigDecimal planExecutionPlannedQty,
            BigDecimal planExecutionInboundQty,
            BigDecimal planExecutionProgressRatio) {
            this(analysisLineId, sourceType, sourceRef, sourceReason, salesOrderItemId, salesOrderId, salesOrderNo, orderDate, deliveryDate, clientName, goodsId, goodsCode, goodsName, spec, colorId, colorName, unitId, unitName, unitRate, requestedQty, submittedQty, approvedQty, remainingQty, allocationPriority, canSchedule, maxSchedulableQty, scheduleBlockedReason, readyNowQty, readyByDateQty, readyStartQty, readyFinishQty, readyShipQty, readinessRatio, hasProductionMaterialChildren, parentAnalysisLineId, parentGoodsName, planExecutionStatus, latestPlanId, latestPlanNo, planExecutionPlannedQty, planExecutionInboundQty, planExecutionProgressRatio, BigDecimal.ZERO, false, null, null, null, null, null, null, null, BigDecimal.ZERO, false);
        }
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
            /** 每个产品一条身份标签「名称 (编号 · 颜色)」，服务端已按同一排版拼好。 */
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
            BigDecimal demandSupplyGapQty,
            BigDecimal subcontractHandoffFutureQty,
            LocalDate expectedReadyDate,
            String sourceSuggestion,
            String sourceConfirmed,
            boolean routeConfirmed,
            String routeReason,
            boolean actionable,
            boolean lowerLevelPending,
            String requirementState,
            UUID delegatedToAnalysisLineId,
            String delegatedToSourceRef,
            BigDecimal delegatedToRequestedQty,
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
            List<DownstreamReference> downstreamReferences,
            BigDecimal publicSurplusApprovedInboundQty,
            BigDecimal publicSurplusRemainingQty,
            BigDecimal sharedFutureClaimedQty,
            BigDecimal additionalSupplyRecommendedQty,
            /** 货品主档的最小起订量，未维护时为空。 */
            BigDecimal minOrderQty,
            /** 货品主档的订货倍数（整箱/整包），未维护时为空。 */
            BigDecimal orderMultipleQty,
            BigDecimal selectedWarehousesAvailableQty,
            BigDecimal selectedOtherWarehouseTransferableQty,
            LocalDate publicSurplusExpectedDate,
            List<SharedFutureSupplyRef> sharedFutureSupplyRefs,
            String flowStage,
            UUID planAnchorAnalysisLineId,
            BigDecimal mainWarehousePublicAvailableQty,
            BigDecimal mainWarehouseOpenSafetySupplyQty,
            BigDecimal mainWarehouseSafetyReplenishmentGapQty,
            BigDecimal priorityMakeSupplementQty,
            BigDecimal sharedFuturePendingQty,
            BigDecimal lateSharedFutureAvailableQty,
            /**
             * V581 委外发出物形态。目前只有两种取值：
             * {@code "COMPONENT_OUTBOUND"} 表示该委外件的活动 BOM 恰好只有一个
             * PER_UNIT 投入的叶子子件——不先自制，仓库直接把那个子件发给委外商，
             * 委外商加工后交回目标件；{@code null} 表示其余所有情况（无子层的纯
             * 外协、需要先自制的有子层件、非委外路线，以及旧服务端）。
             *
             * <p>客户端拿 null 一律按旧口径（有子层 ⇒ 先自制）回退，不得把 null
             * 当成 COMPONENT_OUTBOUND。
             */
            String subcontractOutboundForm,
            /**
             * V587 货品主档的「所属仓库」(这批货平时归哪个仓管)。
             * 既不是单据落点仓，也不是本次分析的范围仓 (warehouseIds)；未登记为 null。
             */
            UUID owningWarehouseId,
            String owningWarehouseName,
            /**
             * V590 货品主档的「归属生产车间」：最近一次排产确认/车间改派学习回写。
             */
            UUID owningWorkshopId,
            String owningWorkshopName,
            /** External final output that can satisfy this node without consuming its children. */
            BigDecimal externalFutureCoverageQty,
            /** Existing internal output commitment; never subtract it as external finished supply. */
            BigDecimal internalCommittedOutputQty,
            /**
             * 本节点此刻可认领的同主仓公共在途合计（按期 + 晚到，不含本分析自己的）。
             * 下达采购/委外时服务端先自动认领它，再为余下部分新下单（ADR-099）。
             */
            BigDecimal sharedFutureClaimableQty,
            /**
             * 计划产出量（ADR-099）：顶层供给行 = 来源计划产出量换成基本单位；
             * 已建自制/前置自制锚点的物料行 = 锚点已下达且仍有效的计划总量
             * （归需求量 + 公共备货产出）；其余行为 0。下层物料按它展开。
             */
            BigDecimal plannedOutputQty,
            /**
             * 还缺数量 (ADR-102 一张表口径): 在 additionalSupplyRecommendedQty
             * 的基础上再把「此刻可认领的同主仓公共在途」当成已占用扣掉, 也就是
             * 人真正还要另外下单的量。
             *
             * <p>它是**纯展示量**: 不建任何占用, 不进物理预留。真正的占用仍然
             * 只发生在下达那一刻由服务端自动认领公共在途 (ADR-099)。
             *
             * <p>务必与 {@link #shortageQty} 区分: shortageQty 是物理缺口, 同时
             * 是 actionable / 让料候选 / 入库齐套三处的判据, 口径不动。
             */
            BigDecimal netShortageQty,
            /**
             * 原始销售/计划汇总需求按本节点 BOM 规则展开的数量。
             * 不随下单、追加、到货、库存占用或车间执行变化；实际备料仍使用 requiredQty。
             */
            BigDecimal sourceRequiredQty) {
        @JsonProperty("nodeRole")
        public String nodeRole() {
            return level == 0 ? "ROOT_SUPPLY" : "BOM_COMPONENT";
        }
    }

    /**
     * 批量可调拨量 (ADR-102): 本分析每一行此刻能从**别的计划已锁定的量**里调进来
     * 多少。主表「物料办理」列用它决定调拨按钮灰不灰, 避免逐行去问
     * cross-reallocation-sources 那条递归查询。
     *
     * <p>结果随登录人的对象级可见范围变, 不可跨账号缓存。
     */
    public record TransferableInSummary(
            java.util.Map<UUID, BigDecimal> qtyByMaterialLineId) {}

    public record SharedFutureSupplyRef(
            String route,
            BigDecimal approvedInboundQty,
            BigDecimal availableToClaimQty,
            LocalDate expectedDate,
            UUID sourceActionId,
            String documentType,
            UUID documentId,
            String documentNo,
            boolean sourceIsCurrentAnalysis) {
    }

    public record WarehouseBreakdown(
            UUID warehouseId,
            String warehouseCode,
            String warehouseName,
            BigDecimal onHandQty,
            BigDecimal reservedQty,
            BigDecimal availableQty,
            BigDecimal ownPeggedQty,
            BigDecimal publicAvailableQty,
            BigDecimal openSafetySupplyQty,
            BigDecimal safetyReplenishmentGapQty,
            BigDecimal publicSurplusApprovedInboundQty,
            BigDecimal publicSurplusRemainingQty,
            LocalDate publicSurplusExpectedDate) {
    }

    public record WarehouseView(
            UUID warehouseId,
            String warehouseCode,
            String warehouseName,
            boolean selected,
            boolean primary) {
    }

    public record DownstreamReference(
            UUID actionId,
            String route,
            String status,
            String documentType,
            UUID documentId,
            String documentNo,
            BigDecimal allocatedQty,
            boolean notificationReversalPending,
            /**
             * ADR-099：该行动锚定的申请明细仍未订货(采购/委外部门还没动过, 追加会
             * 就地改大)时 = 明细当前数量(需求份 + 公共份)；已订货/已处理为 null。
             */
            BigDecimal growableLineQty) {
        public DownstreamReference(UUID actionId, String route, String status,
                String documentType, UUID documentId, String documentNo, BigDecimal allocatedQty) {
            this(actionId,route,status,documentType,documentId,documentNo,allocatedQty,false,null);
        }
        public DownstreamReference(UUID actionId, String route, String status,
                String documentType, UUID documentId, String documentNo, BigDecimal allocatedQty,
                boolean notificationReversalPending) {
            this(actionId,route,status,documentType,documentId,documentNo,allocatedQty,
                    notificationReversalPending,null);
        }
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
     * documentType/documentId 是可跳转单据的稳定锚点；docNo 只作展示，禁止反查 UUID。
     */
    public record SupplyProgressStep(
            String key,
            String label,
            String state,
            String detail,
            String docNo,
            String at,
            String operatorName,
            String documentType,
            UUID documentId) {

        public SupplyProgressStep(
                String key,
                String label,
                String state,
                String detail,
                String docNo,
                String at,
                String operatorName) {
            this(key, label, state, detail, docNo, at, operatorName, null, null);
        }
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
            BigDecimal safetyReplenishmentQty,
            BigDecimal totalRequestedQty,
            BigDecimal safetyStockSnapshotQty,
            BigDecimal publicAvailableSnapshotQty,
            BigDecimal openSafetySupplySnapshotQty,
            LocalDate needDate,
            String documentType,
            UUID documentId,
            String documentNo,
            BigDecimal publicSurplusQty,
            UUID publicSurplusExternalItemId,
            String operationType,
            UUID claimSourceActionId) {
    }

    public record GenerateResult(
            AnalysisView analysis,
            boolean replayed,
            List<GeneratedPlan> plans) {
    }

    /**
     * @param mergedIntoExisting ADR-104：本行追加并入了一张已有的未开工计划(同一单号)，
     *                           而不是新建；此时 {@code appendedQty} 是并入的追加量
     *                           (幂等重放只知道并入过、不知道当时的量，为 null)。
     */
    public record GeneratedPlan(
            UUID planId,
            String planNo,
            String status,
            UUID planningDraftId,
            UUID packageId,
            List<UUID> segmentIds,
            List<UUID> drawIds,
            List<GeneratedDraw> drawDocuments,
            boolean mergedIntoExisting,
            BigDecimal appendedQty) {

        public GeneratedPlan(UUID planId, String planNo, String status, UUID planningDraftId,
                UUID packageId, List<UUID> segmentIds, List<UUID> drawIds,
                List<GeneratedDraw> drawDocuments) {
            this(planId, planNo, status, planningDraftId, packageId, segmentIds, drawIds,
                    drawDocuments, false, null);
        }

        public GeneratedPlan merged(BigDecimal appendedQty) {
            return new GeneratedPlan(planId, planNo, status, planningDraftId, packageId,
                    segmentIds, drawIds, drawDocuments, true, appendedQty);
        }
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
        UUID analysisId,
        String analysisStatus,
        Long analysisVersion) {
    }
}
