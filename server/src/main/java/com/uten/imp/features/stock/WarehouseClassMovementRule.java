package com.uten.imp.features.stock;

import java.util.Set;

/**
 * 出入库类别矩阵(ADR-146): 每种流水类型能落在哪类仓(良品仓 / 不良品仓)。
 *
 * <p>与数据库 {@code fn_stock_movement_class_violation} 是同一张表(契约测试逐格比对),
 * 库存内核 {@link StockService} 过账前先用它给出中文原因, 数据库守卫兜底。
 * 方向不区分: 红冲按原流水反向记同一类型, 「允许落在哪类仓」对正向和红冲天然一致。
 * <ul>
 *   <li>采购退货 2 / 盘盈 9 / 盘亏 10 / 其它出库与报废 12 / 委外成品退回 18: 两类仓都可以;</li>
 *   <li>调拨 7/8 来自仓库调拨单时按调拨类型: 普通调拨两端同类, 转不良品仓 = 良品 -> 不良品,
 *       不良复判转回 = 不良品 -> 良品;</li>
 *   <li>其它来源的 7/8(车间余料直送退回等)与其余一切类型: 只能落在良品仓。</li>
 * </ul>
 */
public final class WarehouseClassMovementRule {

    public static final String DEFECTIVE_REJECTS_GOOD_BUSINESS = "DEFECTIVE_REJECTS_GOOD_BUSINESS";
    public static final String NORMAL_TRANSFER_MIXED = "NORMAL_TRANSFER_MIXED";
    public static final String TO_DEFECTIVE_SHAPE = "TO_DEFECTIVE_SHAPE";
    public static final String DEFECT_RELEASE_SHAPE = "DEFECT_RELEASE_SHAPE";
    public static final String TRANSFER_END_MISMATCH = "TRANSFER_END_MISMATCH";

    /** 良品仓、不良品仓都能落的流水类型。 */
    static final Set<Short> ANY_CLASS_TYPES = Set.of((short) 2, (short) 9, (short) 10, (short) 12, (short) 18);

    private WarehouseClassMovementRule() {
    }

    /**
     * 一笔流水调拨单一侧的事实; 不是仓库调拨单的 7/8 或其它类型传 null。
     *
     * @param kind          调拨类型(数据库值)
     * @param fromDefective 调出仓是不良品仓(null = 单据没有调出仓)
     * @param toDefective   调入仓是不良品仓(null = 单据没有调入仓)
     * @param transferEnd   这笔流水的仓就是单据上的调出仓或调入仓
     */
    public record TransferSide(String kind, Boolean fromDefective, Boolean toDefective, boolean transferEnd) {
    }

    /** 允许返回 null, 否则返回原因码。 */
    public static String violation(short movementType, boolean warehouseDefective, TransferSide transfer) {
        if ((movementType == 7 || movementType == 8) && transfer != null && transfer.kind() != null) {
            if (!transfer.transferEnd()) return TRANSFER_END_MISMATCH;
            switch (transfer.kind()) {
                case "TO_DEFECTIVE" -> {
                    return orTrue(transfer.fromDefective()) || !orFalse(transfer.toDefective())
                            ? TO_DEFECTIVE_SHAPE : null;
                }
                case "DEFECT_RELEASE" -> {
                    return !orFalse(transfer.fromDefective()) || orTrue(transfer.toDefective())
                            ? DEFECT_RELEASE_SHAPE : null;
                }
                case "NORMAL" -> {
                    boolean from = transfer.fromDefective() == null ? warehouseDefective : transfer.fromDefective();
                    boolean to = transfer.toDefective() == null ? warehouseDefective : transfer.toDefective();
                    return from != to ? NORMAL_TRANSFER_MIXED : null;
                }
                default -> {
                    return TRANSFER_END_MISMATCH;
                }
            }
        }
        if (ANY_CLASS_TYPES.contains(movementType)) return null;
        return warehouseDefective ? DEFECTIVE_REJECTS_GOOD_BUSINESS : null;
    }

    /** 普通调拨/专门通道两端的形状(建单与审核前预检; 只比两端类别)。 */
    public static String transferShapeViolation(StockTransferKind kind, boolean fromDefective, boolean toDefective) {
        return violation((short) 8, fromDefective, new TransferSide(kind.name(), fromDefective, toDefective, true));
    }

    /** 给人看的文案, 与数据库 fn_stock_movement_class_message 同文。 */
    public static String message(String code, String warehouseName, short movementType) {
        return switch (code) {
            case DEFECTIVE_REJECTS_GOOD_BUSINESS -> "「" + (warehouseName == null ? "该仓库" : warehouseName)
                    + "」是不良品仓, " + typeLabel(movementType)
                    + "不能进出不良品仓; 请改选良品仓, 判为不良的货请用「转不良品仓」";
            case NORMAL_TRANSFER_MIXED -> "普通调拨的调出仓和调入仓必须同是良品仓或同是不良品仓; "
                    + "良品转不良请用「转不良品仓」, 复判合格的不良品请用「不良复判转回」";
            case TO_DEFECTIVE_SHAPE -> "转不良品仓只能从良品仓调出、调入不良品仓";
            case DEFECT_RELEASE_SHAPE -> "不良复判转回只能从不良品仓调出、调入良品仓";
            default -> "调拨流水的仓库必须是调拨单上的调出仓或调入仓";
        };
    }

    /** 与数据库 fn_stock_movement_type_label 同文。 */
    static String typeLabel(short movementType) {
        return switch (movementType) {
            case 1 -> "采购入库";
            case 2 -> "采购退货";
            case 3 -> "销售出库";
            case 4 -> "销售退货";
            case 5 -> "生产领料";
            case 6 -> "生产退料";
            case 7 -> "调拨调入";
            case 8 -> "调拨调出";
            case 9 -> "盘盈";
            case 10 -> "盘亏";
            case 11 -> "其它入库";
            case 12 -> "其它出库";
            case 13 -> "产成品进仓";
            case 14 -> "产成品出仓";
            case 15 -> "委外发料";
            case 16 -> "委外材料退回";
            case 17 -> "委外成品进仓";
            case 18 -> "委外成品退回";
            case 19 -> "委外材料损耗";
            case 20 -> "销售其它出库";
            case 21 -> "内料仓盘点耗用";
            case 22 -> "内料仓盘盈";
            case 23 -> "内料仓盘点修正";
            default -> "这笔出入库";
        };
    }

    private static boolean orTrue(Boolean value) {
        return value == null || value;
    }

    private static boolean orFalse(Boolean value) {
        return value != null && value;
    }
}
