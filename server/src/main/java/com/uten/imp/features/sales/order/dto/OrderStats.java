package com.uten.imp.features.sales.order.dto;

/** 销售订货工作台统计卡（按当前用户数据范围统计；一单可同时落入多卡）。 */
public record OrderStats(
        long pendingProduction,  // 待生产：存在行 chain_status ∈ (2待排产,3待物料,4已排产)
        long inProduction,       // 生产中：存在行 chain_status ∈ (5生产中,6部分完工)
        long shippable,          // 待发货：存在行 reserved_qty > 0（有可发货量）
        long monthDone) {        // 本月完成：本月单已结案
}
