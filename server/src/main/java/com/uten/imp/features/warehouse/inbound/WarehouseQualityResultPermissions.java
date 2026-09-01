package com.uten.imp.features.warehouse.inbound;

/**
 * 品质部检查结果（原 IQC 合格待入库 + IQC 不合格实物退回合并页）的权威口径：
 * 复用两块既有仓库视图权限，任一满足即可查看；入库与退回动作仍由各自动作权限收口。
 *
 * <p>权限字面量按 ADR-017 架构边界在仓库侧内联（仓库不得新增 warehouse→finance
 * 依赖边）：值的权威定义在
 * {@code features.finance.payables.warehouse.WarehouseIqcReturnPermissions}，
 * 两处必须保持一致，由 WarehouseQualityResultApiContractTest 反射校验。
 */
public final class WarehouseQualityResultPermissions {

    public static final String STOCK_IN_VIEW = ProcurementIqcStockInPermissions.VIEW;

    /** 等价于 finance 侧 WarehouseIqcReturnPermissions.VIEW。 */
    public static final String RETURN_VIEW = "warehouse_iqc_return:view";

    /** 等价于 finance 侧 WarehouseIqcReturnPermissions.RECORD_RETURN。 */
    public static final String RECORD_RETURN = "procurement_iqc_rejection:record_return";

    private WarehouseQualityResultPermissions() {
    }
}
