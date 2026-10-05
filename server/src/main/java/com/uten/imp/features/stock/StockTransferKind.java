package com.uten.imp.features.stock;

import com.uten.imp.application.port.WarehouseUse;

/**
 * 仓库调拨单的调拨类型(ADR-146, stock_documents.transfer_kind)。
 *
 * <p>普通调拨两端必须同是良品仓或同是不良品仓; 良品与不良品之间只走两条专门通道,
 * 各有独立权限并必须写明原因, 由 {@link StockDefectiveMoveService} 一次建单并过账。
 */
public enum StockTransferKind {
    /** 普通调拨: 两端同类。 */
    NORMAL(null, "仓库调拨", WarehouseUse.TRANSFER, WarehouseUse.TRANSFER),
    /** 转不良品仓: 良品仓 -> 不良品仓。 */
    TO_DEFECTIVE("stock:defective_transfer", "转不良品仓", WarehouseUse.GOOD_OUT, WarehouseUse.DEFECTIVE_IN),
    /** 不良复判转回: 不良品仓 -> 良品仓。 */
    DEFECT_RELEASE("stock:defective_release", "不良复判转回", WarehouseUse.DEFECTIVE_OUT, WarehouseUse.GOOD_IN);

    private final String permission;
    private final String label;
    private final WarehouseUse fromUse;
    private final WarehouseUse toUse;

    StockTransferKind(String permission, String label, WarehouseUse fromUse, WarehouseUse toUse) {
        this.permission = permission;
        this.label = label;
        this.fromUse = fromUse;
        this.toUse = toUse;
    }

    /** 专门通道的独立权限码; 普通调拨为 null(走仓库单据权限)。 */
    public String permission() {
        return permission;
    }

    public String label() {
        return label;
    }

    /** 调出仓的选仓用途。 */
    public WarehouseUse fromUse() {
        return fromUse;
    }

    /** 调入仓的选仓用途。 */
    public WarehouseUse toUse() {
        return toUse;
    }

    public boolean channel() {
        return this != NORMAL;
    }

    /** 数据库值 -> 类型; 空值按普通调拨。 */
    public static StockTransferKind of(String value) {
        if (value == null || value.isBlank()) return NORMAL;
        return valueOf(value.strip());
    }
}
