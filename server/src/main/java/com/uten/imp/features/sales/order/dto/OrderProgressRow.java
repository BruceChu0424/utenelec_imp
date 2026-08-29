package com.uten.imp.features.sales.order.dto;

import java.time.OffsetDateTime;

/**
 * 销售订单进度看板行（订单进度查询卡用）。每张已审订单聚合其明细的
 * 订货/已排/已产/已发/可发数量，并派生生产进度百分比与链路阶段。
 *
 * <p>stage 取值（前端按此分 Tab）：
 * <ul>
 *   <li>REJECTED 财务驳回：当前仍待销售修订或重新审核，优先于生产阶段</li>
 *   <li>PENDING 待排产：未排产且未完工</li>
 *   <li>PRODUCING 生产中：含已排产/待物料/生产中/部分完工（produced>0 且未齐套）</li>
 *   <li>SHIPPABLE 可分批发货：存在大于零的成品销售预留，不要求整单全部完工</li>
 *   <li>SHIPPED 已发货：已发数量已达订货量</li>
 * </ul>
 * productionPct = 已产/订货（clamp ≤1），即「外层总进度环」口径（用户决策：生产进度为主）。
 *
 * <p>financeConfirmed（V300）：false 时前端不展示排产进度，卡片显示「等待财务审核」；
 * 财务确认通过后进度才可见（与 V294 计划可见性闸门同口径的销售端呈现）。
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
        String stage,
        boolean financeConfirmed,
        boolean financeRejected,
        String financeRejectedReason,
        String financeRejectedByName,
        OffsetDateTime financeRejectedAt) {
}
