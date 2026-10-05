package com.uten.imp.features.warehouse.materialbin;

import com.uten.imp.application.port.WorkshopMaterialChoicePort;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.util.List;
import java.util.Map;
import java.util.UUID;

/**
 * 车间内料仓接口的请求与响应 (ADR-131, 规格 §2.3)。
 *
 * <p>写接口都带请求号 {@code idempotencyKey} (8-128 位), 可改的对象带 {@code expectedVersion};
 * 响应里的 {@code allowedActions} 是服务端按当前主体算好的可用按钮, 页面只看它。
 */
public final class WorkshopMaterialDtos {

    private WorkshopMaterialDtos() {}

    // ------------------------------------------------------------------ 通用

    /** 期间摘要。 */
    public record PeriodRef(UUID id, int no, LocalDate startDate, LocalDate endDate, String status, String closeState) {}

    // ------------------------------------------------------------------ 开通与整批领料 (ADR-147)

    /** 车间内料仓三态 (服务端唯一给出, 页面只认它)。 */
    public static final String STATUS_NOT_OPEN = "NOT_OPEN";
    public static final String STATUS_OPEN = "OPEN";
    public static final String STATUS_OPEN_PERIODIC = "OPEN_PERIODIC";

    /**
     * 一个车间的内料仓开通状态。
     *
     * @param status          {@link #STATUS_NOT_OPEN} 未开通 / {@link #STATUS_OPEN} 已开通(收车间直送) /
     *                        {@link #STATUS_OPEN_PERIODIC} 已开通且整批领料中
     * @param rowVersion      开通状态版本(开通行 row_version; 未开通为 0), 批量命令按它判断有没有被别人改过
     * @param sourceWarehouseId 默认发料来源仓; 为空时按货品所属仓库
     * @param mainWarehouseId 内料仓挂在哪个主仓下(单主仓后恒为主仓 001)
     * @param currentPeriod   开着的那一期 (发料、退回、其它耗用记进它); 没开整批领料为空
     * @param pendingPeriod   最早一张正在盘点或已盘点、还没结算的期间; 没有为空
     * @param revokeBlockers  撤销这一步(整批领料或开通)现在做不了的原因; 空 = 可以撤销
     * @param allowedActions  SETUP 有设置权限; OPEN / ENABLE_PERIODIC / CHANGE_SOURCE / REVOKE 当前状态下可做的动作
     */
    public record SettingsView(UUID workshopDepartmentId, String workshopName, String status,
                               boolean binOpened, boolean periodicEnabled,
                               UUID binWarehouseId, String binWarehouseName, String binWarehouseCode,
                               UUID sourceWarehouseId, String sourceWarehouseName,
                               UUID mainWarehouseId, String mainWarehouseName,
                               LocalDate goLiveDate, long rowVersion, OffsetDateTime openedAt,
                               PeriodRef currentPeriod, PeriodRef pendingPeriod,
                               List<String> revokeBlockers, List<String> allowedActions) {}

    /** 批量里的一个车间: 页面看到的状态与版本, 与服务端不一致即拒绝 (被别人改过)。 */
    public record BinItem(UUID workshopId, String expectedStatus, Long expectedVersion) {}

    /**
     * 批量开通 / 开启整批领料 / 改来源仓 (POST /settings/batch-enable)。每个车间按当前状态往前走:
     * 未开通 -> 开通 (periodic 为真时同时开启整批领料); 已开通 -> 开启整批领料 (periodic 为真) 或只改来源仓。
     *
     * @param sourceWarehouseId 默认发料来源仓 (可空); 已开通的车间传了才改
     * @param clearSource       为真 = 不再指定来源仓, 恢复按货品所属仓库发料 (来源仓置空); 不能与
     *                          sourceWarehouseId 同时给
     * @param goLiveDate        开启整批领料时必填
     * @param inProgressChoices 在产还没认料的产品 (按产品去重, 一个产品只认一次)
     */
    public record BatchEnableRequest(@jakarta.validation.constraints.Size(max = 50) List<BinItem> items,
                                     UUID sourceWarehouseId, Boolean clearSource, Boolean periodic, LocalDate goLiveDate,
                                     @jakarta.validation.constraints.Size(max = 500)
                                     List<WorkshopMaterialChoicePort.ProductChoice> inProgressChoices,
                                     String idempotencyKey) {}

    /** 批量撤销一步 (POST /settings/batch-disable): 整批领料中 -> 已开通; 已开通 -> 未开通。只撤销设错的。 */
    public record BatchDisableRequest(@jakarta.validation.constraints.Size(max = 50) List<BinItem> items,
                                      String idempotencyKey) {}

    /** 单车间命令 (PUT /settings/{workshopId}) 与批量走同一条代码路径。enabled 为假 = 撤销一步。 */
    public record SettingsRequest(String expectedStatus, Long expectedVersion, Boolean enabled,
                                  UUID sourceWarehouseId, Boolean clearSource, Boolean periodic, LocalDate goLiveDate,
                                  @jakarta.validation.constraints.Size(max = 500)
                                  List<WorkshopMaterialChoicePort.ProductChoice> inProgressChoices,
                                  String idempotencyKey) {}

    /** 批量命令的结果: 每个车间办完后的状态 (按请求顺序)。 */
    public record BatchResult(List<SettingsView> settings) {}

    /** 发料来源仓滑窗用的仓库元数据 (只有层级与能不能选, 不含库存与负责人)。 */
    public record SourceWarehouseOption(UUID id, String code, String name, UUID parentId, String status,
                                        boolean defective, boolean selectable, boolean selectableDefective) {}

    /**
     * 开启整批领料前需要认料的在产产品 (多车间按产品去重)。
     *
     * @param workshopNames 这个产品在哪些所选车间里在产
     */
    public record PendingProduct(@com.fasterxml.jackson.annotation.JsonUnwrapped
                                 WorkshopMaterialChoicePort.PendingChoice choice,
                                 List<UUID> workshopIds, List<String> workshopNames) {}

    public record PendingChoiceList(List<PendingProduct> products) {}

    // ------------------------------------------------------------------ 机台与容器

    public record ContainerView(UUID id, UUID machineId, String name, BigDecimal capacityQty, boolean enabled,
                                int sortOrder, long rowVersion) {}

    public record MachineView(UUID id, UUID workshopDepartmentId, String code, String name, String model,
                              BigDecimal tonnage, boolean enabled, int sortOrder, String remark, long rowVersion,
                              List<ContainerView> containers) {}

    public record MachineList(List<MachineView> machines) {}

    public record ContainerSpec(String name, BigDecimal capacityQty) {}

    public record MachineBatchCreate(UUID workshopDepartmentId, Integer count, String codePrefix, Integer startNo,
                                     List<ContainerSpec> containers, String idempotencyKey) {}

    public record MachineEdit(UUID id, Long expectedVersion, String name, String model, BigDecimal tonnage,
                              Boolean enabled, Integer sortOrder, String remark) {}

    public record MachineBatchUpdate(List<MachineEdit> items, String idempotencyKey) {}

    public record ContainerEdit(UUID id, UUID machineId, Long expectedVersion, String name, BigDecimal capacityQty,
                                Boolean enabled, Integer sortOrder) {}

    public record ContainerBatchUpdate(List<ContainerEdit> items, String idempotencyKey) {}

    // ------------------------------------------------------------------ 领料单 / 退回单 / 其它耗用

    /** qty 为货品基本单位数量; 只给袋数时按每袋净重折算。 */
    public record RequisitionLineInput(UUID goodsId, UUID colorId, BigDecimal qty, BigDecimal bags) {}

    public record RequisitionCreate(String kind, UUID workshopDepartmentId, List<RequisitionLineInput> lines,
                                    String remark, String idempotencyKey) {}

    public record FulfilLine(UUID lineId, UUID leafWarehouseId, BigDecimal qty) {}

    /** 漏录补录: 补到指定的"盘点中"或"已盘点、还没结算"的那一期, 必须写原因。 */
    public record Supplement(UUID periodId, String reason) {}

    public record MaterialSetup(UUID goodsId, Long expectedVersion, String periodicCostBasis) {}

    public record FulfilRequest(Long expectedVersion, List<FulfilLine> lines, Supplement supplement,
                                String idempotencyKey, List<MaterialSetup> materialSetup) {
        public FulfilRequest(Long expectedVersion, List<FulfilLine> lines, Supplement supplement, String idempotencyKey) {
            this(expectedVersion, lines, supplement, idempotencyKey, null);
        }
    }

    public record CancelRequest(Long expectedVersion, String reason, String idempotencyKey) {}

    public record DirectIssueLine(UUID goodsId, UUID colorId, BigDecimal bags, BigDecimal qty, UUID leafWarehouseId) {}

    public record DirectIssueRequest(UUID workshopDepartmentId, UUID receiverEmployeeId, List<DirectIssueLine> lines,
                                     Supplement supplement, String idempotencyKey) {}

    public record DirectIssueDefaults(UUID workshopDepartmentId, UUID receiverEmployeeId, String receiverName) {}

    public record RequisitionLineView(UUID id, int lineNo, UUID goodsId, String goodsCode, String goodsName,
                                      UUID colorId, String colorName, UUID unitId, String unitName,
                                      BigDecimal requestedQty, BigDecimal requestedBags, BigDecimal bulkPackageQty,
                                      UUID suggestedLeafWarehouseId, String suggestedLeafWarehouseName,
                                      BigDecimal fulfilledQty, String issueMethod) {
        public RequisitionLineView(UUID id, int lineNo, UUID goodsId, String goodsCode, String goodsName,
                UUID colorId, String colorName, UUID unitId, String unitName, BigDecimal requestedQty,
                BigDecimal requestedBags, BigDecimal bulkPackageQty, UUID suggestedLeafWarehouseId,
                String suggestedLeafWarehouseName, BigDecimal fulfilledQty) {
            this(id, lineNo, goodsId, goodsCode, goodsName, colorId, colorName, unitId, unitName, requestedQty,
                    requestedBags, bulkPackageQty, suggestedLeafWarehouseId, suggestedLeafWarehouseName, fulfilledQty, null);
        }
    }

    /** 一张调拨单 (一个叶仓一张) 及其所属期间。 */
    public record RequisitionDocumentView(UUID documentId, String billNo, UUID leafWarehouseId,
                                          String leafWarehouseName, UUID periodId, int periodNo,
                                          boolean supplement, BigDecimal qty) {}

    /**
     * @param period 这张单的料记进了哪一期 (发完或收完之后才有; 还在等发料为空)。补录时是被补的那一期。
     */
    public record RequisitionView(UUID id, String requestNo, String kind, String origin, String status,
                                  UUID workshopDepartmentId, String workshopName,
                                  UUID binWarehouseId, String binWarehouseName,
                                  UUID receiverEmployeeId, String receiverName,
                                  String requestedByName, OffsetDateTime requestedAt,
                                  String doneByName, OffsetDateTime doneAt, String cancelReason, String remark,
                                  long rowVersion, List<RequisitionLineView> lines,
                                  List<RequisitionDocumentView> documents, PeriodRef period,
                                  List<String> allowedActions) {}

    public record OtherIssueRequest(UUID workshopDepartmentId, UUID goodsId, UUID colorId, BigDecimal qty,
                                    String reason, String reasonText, String idempotencyKey) {}

    public record OtherIssueView(UUID id, UUID workshopDepartmentId, UUID binWarehouseId, UUID goodsId,
                                 String goodsName, UUID colorId, BigDecimal qty, String reason, String reasonText,
                                 UUID periodId, int periodNo, LocalDate businessDate, UUID documentId,
                                 String billNo) {}

    // ------------------------------------------------------------------ 期间与盘点

    /**
     * @param currentCountId     这一期当前的盘点单: 有草稿给草稿, 否则给已提交那张; 还没开始盘点为空
     * @param currentCountStatus 当前盘点单的状态 (DRAFT / SUBMITTED); 没有为空
     */
    public record PeriodView(UUID id, UUID binWarehouseId, UUID workshopDepartmentId, int no,
                             LocalDate startDate, LocalDate endDate, String status, String closeState,
                             List<Map<String, Object>> closeBlockers, int closeAttempts, int closeFailures,
                             OffsetDateTime heldUntil, long rowVersion, UUID draftCountId, UUID submittedCountId,
                             UUID currentCountId, String currentCountStatus, List<String> allowedActions) {}

    public record PeriodList(List<PeriodView> periods) {}

    public record StartCountRequest(Long expectedVersion, LocalDate cutoffDate, String idempotencyKey) {}

    public record VersionRequest(Long expectedVersion, String idempotencyKey) {}

    public record CorrectCountRequest(Long expectedVersion, String reason, String idempotencyKey) {}

    public record ZeroRestRequest(String idempotencyKey) {}

    /**
     * 一行盘点的录入。lineKind: FULL_BAGS 整袋 / CONTAINER 机台容器 / WEIGHED 过秤公斤数;
     * weighNote 只给过秤行分组显示 (OPEN_BAG / MIXED / LOOSE); fillLevel: FULL / HALF / EMPTY / WEIGHED。
     */
    public record CountLineInput(Long expectedVersion, String lineKind, String weighNote, UUID goodsId, UUID colorId,
                                 BigDecimal bagCount, BigDecimal bagNetQty, BigDecimal weighedQty,
                                 UUID machineId, UUID containerId, String fillLevel) {}

    public record CountLineView(UUID id, String clientLineKey, String lineKind, String weighNote,
                                UUID goodsId, String goodsCode, String goodsName, UUID colorId, String colorName,
                                BigDecimal bagCount, BigDecimal bagNetQty, BigDecimal weighedQty,
                                UUID machineId, String machineName, UUID containerId, String containerName,
                                BigDecimal capacityQty, String fillLevel, BigDecimal qtyBase,
                                String enteredByName, OffsetDateTime enteredAt, long rowVersion) {}

    /** 机台卡片上的一个容器; clientLineKey 是建议的行号, line 为已录的那一行 (没录为空)。 */
    public record ContainerSlot(UUID containerId, String name, BigDecimal capacityQty, String clientLineKey,
                                CountLineView line) {}

    /**
     * 盘点单里一台机的卡片。lastGoodsId / lastColorId 是这台机上一次盘点时容器里在用的料 (之前没盘过为空),
     * 页面用来预选「在用料」。
     */
    public record MachineCard(UUID machineId, String code, String name, UUID lastGoodsId, UUID lastColorId,
                              List<ContainerSlot> containers) {}

    /** 这一期必须盘到的料 (有账或本期有进出); bagNetQty 预填每袋净重。 */
    public record MaterialSlot(UUID goodsId, String goodsCode, String goodsName, UUID colorId, String colorName,
                               String unitName, BigDecimal bookQty, BigDecimal bagNetQty, String clientLineKey,
                               int lineCount) {}

    public record CountDetail(UUID id, UUID periodId, int periodNo, LocalDate startDate, LocalDate endDate,
                              String periodStatus, UUID binWarehouseId, String binWarehouseName,
                              UUID workshopDepartmentId, String workshopName, int version, String status,
                              String correctionReason, long rowVersion, List<CountLineView> lines,
                              List<MachineCard> machines, List<MaterialSlot> materials,
                              int missingContainerCount, int missingMaterialCount, List<String> allowedActions) {}

    public record StartCountResult(PeriodView period, PeriodView nextPeriod, CountDetail count) {}

    public record ZeroRestResult(List<CountLineView> lines) {}

    // ------------------------------------------------------------------ 内料仓页

    public record PositionRow(UUID goodsId, String goodsCode, String goodsName, UUID colorId, String colorName,
                              String unitName, BigDecimal bulkPackageQty, BigDecimal bookQty,
                              BigDecimal lastCountQty, LocalDate lastCountDate, BigDecimal periodInQty,
                              BigDecimal periodReturnQty, BigDecimal periodOtherQty, BigDecimal estimatedUsedQty,
                              BigDecimal estimatedRemainingQty, BigDecimal warehouseAvailableQty,
                              int missingWeightProducts, int draftReportCount) {}

    /**
     * @param periodStatus 顶部显示的期间状态: 有正在盘点或待结算的期间时取它, 否则取开着的那一期
     * @param blockers     自动结算被拦的原因 (差什么、谁来补), 由结算写入
     */
    public record PositionView(UUID binWarehouseId, String binWarehouseName, UUID workshopDepartmentId,
                               String workshopName, String periodStatus, String closeState,
                               List<Map<String, Object>> blockers, OffsetDateTime heldUntil,
                               PeriodRef currentPeriod, PeriodRef pendingPeriod, List<PositionRow> rows,
                               List<String> allowedActions) {}

    // ------------------------------------------------------------------ 可发到内料仓的料

    /** 某个叶仓里这种料还能发多少 (账面减去已被占用的, 不小于 0)。 */
    public record LeafStockView(UUID warehouseId, String warehouseName, BigDecimal availableQty) {}

    /**
     * 可发到某车间内料仓的一种料 (只列整批领料的料; 申请、发料、上线准备的下拉共用)。
     *
     * @param costBasis             分摊方式: OWN 主料 / SHARED 辅料 / EXPENSE 记车间费用
     * @param warehouseAvailableQty 全部叶仓合计还能发多少 (与内料仓页「仓库可发」同一口径)
     * @param leafWarehouses        有存货的叶仓 (默认出库叶仓即使没货也列出)
     */
    public record MaterialStockOption(UUID goodsId, String goodsCode, String goodsName, UUID colorId,
                                      String colorName, String unitName, BigDecimal bulkPackageQty,
                                      String costBasis, UUID defaultLeafWarehouseId,
                                      String defaultLeafWarehouseName, BigDecimal warehouseAvailableQty,
                                      List<LeafStockView> leafWarehouses) {}

    // ------------------------------------------------------------------ 徽章

    public record BadgeCounts(long pendingIssue, long pendingReturn, long counting) {}

    // ------------------------------------------------------------------ 认料与换料

    public record ChooseRequest(UUID workshopDepartmentId, List<WorkshopMaterialChoicePort.ProductChoice> choices,
                                String idempotencyKey) {}

    public record ChoiceView(UUID id, UUID productGoodsId, String productName, String kind, UUID materialGoodsId,
                             String materialName, UUID materialColorId, boolean alsoOrderMaterials,
                             String prefillSource, OffsetDateTime chosenAt) {}

    public record ChoiceList(List<ChoiceView> choices) {}

    /** weightBasis: FROM_REPLACED 沿用原料单重 (默认) / OWN_BOM 按新料 BOM 单重; fromRowId 为空表示加一种料。 */
    public record MaterialChangeRequest(Long expectedVersion, UUID fromRowId, UUID toMaterialGoodsId,
                                        UUID toMaterialColorId, LocalDate effectiveFrom, String weightBasis,
                                        String reason, String idempotencyKey) {}

    /**
     * 段的一行期间料。unitWeightGrams 是这一行现在按规则算出的单个重量 (克; 单位不是千克或克、或还没填时为空)。
     */
    public record PeriodicRowView(UUID id, UUID materialGoodsId, String materialCode, String materialName,
                                  UUID materialColorId, String colorName, String origin, LocalDate effectiveFrom,
                                  LocalDate effectiveTo, BigDecimal designQtySnapshot, BigDecimal unitWeightGrams) {}

    /**
     * 换料对话框的底稿与换料结果。
     *
     * @param lockVersion           段的最新版本 (换料请求的 expectedVersion)
     * @param earliestEffectiveFrom 最早可以从哪天起改用 (内料仓已结算截止日的下一天; 还没结算过为启用日)
     * @param options               可换的料 (本车间内料仓收的整批领料主料); 只在读底稿时给, 换料结果里为空
     */
    public record SegmentMaterials(UUID segmentId, UUID binWarehouseId, long lockVersion,
                                   LocalDate earliestEffectiveFrom, List<PeriodicRowView> rows,
                                   List<WorkshopMaterialChoicePort.MaterialOption> options) {}
}
