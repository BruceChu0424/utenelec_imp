package com.uten.imp.features.sales.order.dto;

import java.time.OffsetDateTime;
import java.util.UUID;

/**
 * 订单全链路进度时间线事件（快递式追踪，GET /api/sales/orders/{id}/progress-timeline）。
 *
 * <p>一条事件 = 业务链路上的一次留痕：阶段标题 + 责任人（operatorLabel/operatorName，
 * 如 下单人/审核人/执行人/采购人）+ 发生时间 + 状态 + 补充说明 + 可跳转单据锚点。
 *
 * <p>state 取值：DONE（已完成）/ CURRENT（当前进行）/ PENDING（未到该阶段）/ REJECTED（被驳回/红冲）。
 * seq 为业务顺序（下单=10 起按链路递增），用于同刻事件的稳定排序与 PENDING 占位排序；
 * 列表展示顺序由服务端排好：已发生事件按时间倒序（最新在最上），PENDING 占位按业务顺序垫底。
 */
public record OrderProgressTimelineEvent(
        int seq,
        String code,
        String title,
        String operatorLabel,
        String operatorName,
        OffsetDateTime occurredAt,
        String state,
        String detail,
        String docType,
        UUID docId,
        String docNo) {

    public static final String DONE = "DONE";
    public static final String CURRENT = "CURRENT";
    public static final String PENDING = "PENDING";
    public static final String REJECTED = "REJECTED";
}
