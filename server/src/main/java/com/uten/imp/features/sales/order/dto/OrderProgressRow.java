package com.uten.imp.features.sales.order.dto;

/**
 * 销售订单进度看板行（订单进度查询卡用）。每张已审订单聚合其明细的
 * 订货/已排/已产/已发/可发数量，并派生生产进度百分比与链路阶段。
 *
 * <p>stage 取值（前端按此分 Tab）：
 * <ul>
 *   <li>PENDING 待排产：未排产且未完工</li>
 *   <li>PRODUCING 生产中：含已排产/待物料/生产中/部分完工（produced>0 且未齐套）</li>
 *   <li>SHIPPABLE 可分批发货：存在大于零的成品销售预留，不要求整单全部完工</li>
 *   <li>SHIPPED 已发货：已发数量已达订货量</li>
 * </ul>
 * productionPct = 已产/订货（clamp ≤1），即「外层总进度环」口径（用户决策：生产进度为主）。
 */
public record OrderProgressRow(
        String orderId,
        String billNo,
        String billDate,
        String deliverDate,
        String clientName,
        double orderQty,
        double producedQty,
        double shippedQty,
        double reservedQty,
        double plannedQty,
        double productionPct,
        String stage) {
}
