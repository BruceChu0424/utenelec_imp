package com.uten.imp.features.master.goods.dto;

import com.fasterxml.jackson.annotation.JsonProperty;
import jakarta.validation.Valid;
import jakarta.validation.constraints.NotEmpty;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Size;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.List;
import java.util.UUID;

/**
 * 基础资料里整批领料的料 (ADR-131 §5.1): 发料方式与分摊方式切换 (预览 → 确认)、上线准备 (批量填颗粒与单个重量)。
 *
 * <p>状态、动作字段是给界面分支用的代码, 界面按代码显示中文; 各处 {@code note} / {@code blockers}
 * 是写给员工看的中文。
 */
public final class GoodsPeriodicMaterialDtos {

    private GoodsPeriodicMaterialDtos() {}

    // ================================================================ 发料方式切换

    /**
     * 切换预览: 列出受影响的 BOM 行、没清账的工单、内料仓账面、没结算期间的用量、在做的工单与会作废的认料;
     * {@code blockers} 非空时不能切换 ({@code canSwitch} 为假)。
     *
     * @param targetIssueMethod       ORDER / PERIODIC
     * @param targetCostBasis         OWN / SHARED / EXPENSE; 按工单领料为 null
     * @param massUnit                基本单位是不是重量单位 (整批领料必须是)
     * @param suggestedBulkPackageQty 每袋净重预填值: 已填的每袋净重, 没填时取整包装量 (订货倍数)
     */
    public record IssueMethodPreview(
            UUID goodsId, String goodsCode, String goodsName, long version,
            String currentIssueMethod, String currentCostBasis,
            String targetIssueMethod, String targetCostBasis,
            String unitName, boolean massUnit,
            BigDecimal bulkPackageQty, BigDecimal suggestedBulkPackageQty, boolean recycledMaterial,
            List<AffectedBomRow> bomRows,
            List<UnclearedDemand> unclearedDemands,
            List<BinBalance> binBalances,
            List<OpenPeriodUsage> openPeriods,
            List<UnsettledTheory> unsettledTheory,
            List<InProgressSegment> inProgressSegments,
            List<ActiveChoice> activeChoices,
            List<String> blockers,
            boolean canSwitch) {}

    /**
     * 用到这种料的一行 BOM 在切换时怎么处理。
     *
     * @param action          CONVERT 改成单个重量 (开工前、按每件、不设齐套门槛) / KEEP 不用改 /
     *                        REMOVE 辅料不写进 BOM, 从这个产品的 BOM 里去掉 / RESTORE 改回按工单领料的齐套门槛 /
     *                        BLOCKED 按包装、按批或基准产量折不成每件用量, 要先人工改
     * @param unitWeightGrams 切换后的单个重量 (克); 不能按克换算时为 null
     */
    public record AffectedBomRow(UUID bomItemId, UUID productGoodsId, String productCode, String productName,
                                 BigDecimal qty, BigDecimal basisOutputQty, String controlStage,
                                 String consumptionBasis, boolean hardGate, BigDecimal unitWeightGrams,
                                 String action, String note) {}

    /**
     * 按工单领了这种料、还没核清的需求 (改为整批领料的前提是一条都没有)。
     *
     * @param unclearedQty 已领 − 已退 − 已清账 (实耗 + 核定损耗)
     */
    public record UnclearedDemand(UUID demandId, String planNo, String segmentCode, String productCode,
                                  String productName, String status, BigDecimal requiredQty,
                                  BigDecimal issuedQty, BigDecimal returnedQty, BigDecimal settledQty,
                                  BigDecimal wipQty, BigDecimal unclearedQty, String note) {}

    /** 车间内料仓里这种料的账面 (不为 0 时不能改回按工单领料或改分摊方式)。 */
    public record BinBalance(UUID warehouseId, String warehouseName, BigDecimal qty) {}

    /** 还没结算、用到这种料 (有期间行或进出) 的内料仓期间。 */
    public record OpenPeriodUsage(UUID periodId, UUID binWarehouseId, String binName, int periodNo,
                                  LocalDate startDate, LocalDate endDate, String status) {}

    /** 还没结算的日子里按这种料算了理论用量的产品 (按内料仓汇总)。 */
    public record UnsettledTheory(UUID binWarehouseId, String binName, int productCount, BigDecimal theoryQty) {}

    /** 按整批领料用着这种料、还在生产中的工单段。 */
    public record InProgressSegment(UUID segmentId, String segmentCode, String productCode, String productName) {}

    /** 认了这种料的产品 (切换后作废, 下次开工重新认料)。 */
    public record ActiveChoice(UUID productGoodsId, String productCode, String productName,
                               boolean alsoOrderMaterials) {}

    /**
     * 确认切换 (一次原子请求, 可多种料)。分摊方式、每袋净重、回收料的改动也只走这里。
     *
     * @param idempotencyKey 请求号 (8-128 位字母数字与 . _ : -), 同号重放返回原结果
     */
    public record IssueMethodBatchRequest(
            @NotEmpty @Size(max = 200) List<@Valid @NotNull IssueMethodItem> items,
            @NotNull @Size(min = 8, max = 128) String idempotencyKey) {}

    /**
     * 一种料的目标设置。
     *
     * @param expectedVersion    货品版本 (详情里的 version), 不一致拒绝
     * @param issueMethod        ORDER / PERIODIC
     * @param periodicCostBasis  整批领料必填 OWN / SHARED / EXPENSE; 按工单领料必须为空
     * @param bulkPackageQty     每袋净重 (基本单位); 为空 = 不改 (改为整批领料且原来没填时取整包装量)
     * @param isRecycledMaterial 回收料; 为空 = 不改
     */
    public record IssueMethodItem(
            @NotNull UUID goodsId,
            @NotNull Long expectedVersion,
            @NotNull String issueMethod,
            String periodicCostBasis,
            BigDecimal bulkPackageQty,
            @JsonProperty("isRecycledMaterial") Boolean isRecycledMaterial) {}

    public record IssueMethodBatchResult(List<IssueMethodItemResult> items) {}

    /**
     * @param bomRowsConverted  改成单个重量的 BOM 行数
     * @param bomRowsRemoved    从 BOM 里去掉的辅料行数
     * @param bomRowsRestored   改回齐套门槛的行数
     * @param choicesSuperseded 作废的认料条数
     */
    public record IssueMethodItemResult(UUID goodsId, String issueMethod, String periodicCostBasis,
                                        BigDecimal bulkPackageQty, boolean recycledMaterial,
                                        int bomRowsConverted, int bomRowsRemoved, int bomRowsRestored,
                                        int choicesSuperseded) {}

    // ================================================================ 上线准备

    /**
     * 上线准备列表: 近 12 个月在该车间做过或归属该车间的产品。
     *
     * @param totalProducts   产品数
     * @param chosenProducts  已选料 (BOM 里有整批领料的料, 或认了料) 的产品数
     * @param weighedProducts 已填单个重量的产品数
     * @param materials       可选的料 (整批领料的主料)
     */
    public record PreparationView(UUID workshopDepartmentId, String workshopName,
                                  int totalProducts, int chosenProducts, int weighedProducts,
                                  List<PreparationRow> rows, List<MaterialOption> materials) {}

    /**
     * 一行 (一个产品; 双料件一种料一行)。
     *
     * @param legacyMaterial    老库材质文字
     * @param recentRuns        近 12 个月在该车间做过几次
     * @param bomItemId         已有期间边的 BOM 行; 没有为空
     * @param materialSource    料从哪来: BOM (BOM 里已有) / CHOICE (车间认过) / LEGACY_MATERIAL_TEXT (老库材质唯一命中) / null
     * @param unitWeightGrams   BOM 里的单个重量 (克)
     * @param goodsWeightGrams  货品资料单重 (克, 按质量单位换算), 供"勾选行用货品资料单重填入"; 不能换算为空
     * @param status            WEIGHED 已填单重 / CHOSEN 已选料未填单重 / NOT_FROM_STORE 不用内料仓的料 / PENDING 待准备
     * @param alsoOrderMaterials 认料时勾了"还要按工单领别的料"
     * @param hasOrderBom       产品另有按工单领的 BOM 行 (嵌件、包材等)
     */
    public record PreparationRow(UUID productGoodsId, String productCode, String productName, String productSpec,
                                 String legacyMaterial, int recentRuns, UUID bomItemId,
                                 UUID materialGoodsId, String materialCode, String materialName, UUID materialColorId,
                                 String materialSource, BigDecimal unitWeightGrams, BigDecimal goodsWeightGrams,
                                 String status, boolean alsoOrderMaterials, boolean hasOrderBom) {}

    /** @param gramsConvertible 基本单位能按克填 (千克、克) */
    public record MaterialOption(UUID goodsId, String code, String name, UUID colorId, String colorName,
                                 String unitName, boolean gramsConvertible) {}

    /**
     * 一次保存: 填了单个重量的行写 BOM 期间边, 只选了料的行经内料仓认料。
     *
     * @param workshopDepartmentId 上线准备所在车间 (认料记在这个车间名下)
     */
    public record PreparationBatchRequest(
            UUID workshopDepartmentId,
            @NotEmpty @Size(max = 500) List<@Valid @NotNull PreparationRowInput> rows,
            @NotNull @Size(min = 8, max = 128) String idempotencyKey) {}

    /**
     * @param bomItemId       要改的已有期间边 (改料或改单重); 为空时按 (产品, 料) 找, 找不到就新增
     * @param unitWeightGrams 单个重量 (克); 为空 = 只选料 (写认料)
     * @param prefillSource   直接采用了老库材质预填时带 LEGACY_MATERIAL_TEXT
     */
    public record PreparationRowInput(
            @NotNull UUID productGoodsId,
            UUID bomItemId,
            @NotNull UUID materialGoodsId,
            UUID colorId,
            BigDecimal unitWeightGrams,
            Boolean confirmUnusualWeight,
            Boolean confirmSecondPeriodicMaterial,
            String prefillSource) {}

    /**
     * @param warnings 保存后的提醒 (不拦保存), 如单个重量与货品资料单重相差 20% 以上
     */
    public record PreparationBatchResult(int edgesCreated, int edgesUpdated, int choicesWritten,
                                         List<String> warnings) {}
}
