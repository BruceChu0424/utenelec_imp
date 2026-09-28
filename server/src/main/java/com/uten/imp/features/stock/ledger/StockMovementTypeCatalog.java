package com.uten.imp.features.stock.ledger;

import java.util.EnumSet;
import java.util.List;
import java.util.Optional;
import java.util.Set;
import java.util.stream.Collectors;

/**
 * stock_movements.movement_type 目录 (V59 字典 + 自然方向 + 分类), 流水标签、流水汇总与库存分析共用的唯一口径。
 *
 * <p>红冲沿用同一类型、方向相反 (如销售出库红冲 = 类型 3 方向 +1), 所以标签按方向给:
 * 方向与自然方向不同时加「(红冲)」。新增类型 (如在途 V740 的 21 内料仓盘点耗用 / 22 内料仓盘盈)
 * 只在这里加一行即可被流水、汇总与分析认到; 没登记的类型显示「类型N」且不参与分类口径。
 */
public enum StockMovementTypeCatalog {
    PURCHASE_RECEIPT(1, "采购入库", 1, Category.EXTERNAL_IN),
    PURCHASE_RETURN(2, "采购退货", -1, Category.RETURN_OUT),
    SALES_OUT(3, "销售出库", -1, Category.CONSUMPTION),
    SALES_RETURN(4, "销售退货", 1, Category.EXTERNAL_IN),
    PRODUCTION_DRAW(5, "生产领料", -1, Category.CONSUMPTION),
    PRODUCTION_RETURN(6, "生产退料", 1, Category.RETURN_IN),
    TRANSFER_IN(7, "调拨入", 1, Category.TRANSFER),
    TRANSFER_OUT(8, "调拨出", -1, Category.TRANSFER),
    CHECK_GAIN(9, "盘盈入", 1, Category.COUNT),
    CHECK_LOSS(10, "盘亏出", -1, Category.COUNT),
    OTHER_IN(11, "其它入", 1, Category.EXTERNAL_IN),
    OTHER_OUT(12, "其它出", -1, Category.CONSUMPTION),
    FINISHED_IN(13, "产成品进仓", 1, Category.EXTERNAL_IN),
    FINISHED_OUT(14, "产成品出仓", -1, Category.CONSUMPTION),
    SUBCONTRACT_MATERIAL_ISSUE(15, "委外材料出仓", -1, Category.CONSUMPTION),
    SUBCONTRACT_MATERIAL_RETURN(16, "委外材料退回", 1, Category.RETURN_IN),
    SUBCONTRACT_RECEIPT(17, "委外成品进仓", 1, Category.EXTERNAL_IN),
    SUBCONTRACT_RETURN(18, "委外成品退", -1, Category.RETURN_OUT),
    SUBCONTRACT_WASTE(19, "委外材料损耗", -1, Category.LOSS),
    SALES_OTHER_OUT(20, "销售其它出库", -1, Category.CONSUMPTION);

    /** 分类: 流水汇总与库存分析 (库龄/周转/ABC) 的口径。 */
    public enum Category {
        /** 外部来货 (采购/委外成品/产成品/其它入/销售退货): 会重置库龄。 */
        EXTERNAL_IN,
        /** 退回本仓 (生产退料/委外材料退回): 不重置库龄, 退回的货落回更早的批次。 */
        RETURN_IN,
        /** 仓间调拨 (调入/调出成对)。 */
        TRANSFER,
        /** 盘点盈亏。 */
        COUNT,
        /** 消耗 (销售/领料/其它出/产成品出/委外发料/销售其它出): 周转、ABC、呆滞的需求口径。 */
        CONSUMPTION,
        /** 退回外部 (采购退货/委外成品退): 不是需求。 */
        RETURN_OUT,
        /** 损耗。 */
        LOSS
    }

    /** 报废单 (stock_documents.doc_type = WASTE) 过账为「其它出」(12), 流水里按单据种类显示。 */
    private static final String DOC_WASTE = "WASTE";

    private final short code;
    private final String label;
    private final short naturalDirection;
    private final Category category;

    StockMovementTypeCatalog(int code, String label, int naturalDirection, Category category) {
        this.code = (short) code;
        this.label = label;
        this.naturalDirection = (short) naturalDirection;
        this.category = category;
    }

    public short code() {
        return code;
    }

    public String label() {
        return label;
    }

    /** 正常 (非红冲) 业务的方向: +1 入库 / -1 出库。 */
    public short naturalDirection() {
        return naturalDirection;
    }

    public Category category() {
        return category;
    }

    public static Optional<StockMovementTypeCatalog> of(Short code) {
        if (code == null) {
            return Optional.empty();
        }
        for (StockMovementTypeCatalog type : values()) {
            if (type.code == code) {
                return Optional.of(type);
            }
        }
        return Optional.empty();
    }

    /** 不看方向的类型名 (筛选项/facet 用); 未登记类型为「类型N」。 */
    public static String baseLabel(Short code) {
        return of(code).map(StockMovementTypeCatalog::label).orElse(code == null ? "—" : "类型" + code);
    }

    /**
     * 流水行的类型名: 报废单按单据种类显示「报废出库」; 方向与自然方向相反时加「(红冲)」。
     *
     * @param code          movement_type
     * @param direction     本行方向 (+1/-1)
     * @param sourceDocCode 仓库单据的 doc_type (非仓库单据为 null)
     */
    public static String label(Short code, Short direction, String sourceDocCode) {
        Optional<StockMovementTypeCatalog> type = of(code);
        String base = type.map(StockMovementTypeCatalog::label).orElse(code == null ? "—" : "类型" + code);
        if (type.isPresent() && type.get() == OTHER_OUT && DOC_WASTE.equals(sourceDocCode)) {
            base = "报废出库";
        }
        if (type.isPresent() && direction != null && direction != type.get().naturalDirection) {
            return base + "(红冲)";
        }
        return base;
    }

    /** 自然方向为入库的类型代码 (流水汇总「本期收入」按自然方向归类, 红冲为负数冲减本期收入)。 */
    public static List<Short> naturalInCodes() {
        return codes(EnumSet.allOf(StockMovementTypeCatalog.class).stream()
                .filter(t -> t.naturalDirection > 0).collect(Collectors.toSet()));
    }

    /** 某分类的类型代码。 */
    public static List<Short> codesOf(Category category) {
        return codes(EnumSet.allOf(StockMovementTypeCatalog.class).stream()
                .filter(t -> t.category == category).collect(Collectors.toSet()));
    }

    /**
     * 库龄入库批次类型: 外部来货 + 盘盈 (1/4/9/11/13/17)。调入 (7) 只在对应调出不在范围内时另算,
     * 退料 (6/16) 不重置库龄。
     */
    public static List<Short> agingInboundCodes() {
        return codes(EnumSet.allOf(StockMovementTypeCatalog.class).stream()
                .filter(t -> t.naturalDirection > 0
                        && (t.category == Category.EXTERNAL_IN || t.category == Category.COUNT))
                .collect(Collectors.toSet()));
    }

    private static List<Short> codes(Set<StockMovementTypeCatalog> types) {
        return types.stream().map(StockMovementTypeCatalog::code).sorted().toList();
    }
}
