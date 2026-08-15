package com.uten.imp.features.sales.order.dto;

import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.util.UUID;

/**
 * 订单详情内的出货单聚合行（SOP §三.7：分批部分发货会产生多张出货单，
 * 订单详情聚合展示全部出货单与各自物流单号，不能只存一个）。
 *
 * <p>不含金额——商业字段脱敏由出货单详情自身的 DTO 契约负责，订单聚合只承载
 * 运营事实（单号/日期/状态/物流单号/仓库作业状态/交接时间）。
 */
public record OrderShipmentRefDto(
        UUID id,
        String billNo,
        LocalDate billDate,
        Short status,
        String statusLabel,
        String logisticsNo,
        Integer parcelCount,
        String warehouseWorkStatus,
        OffsetDateTime handedOverAt) {

    public static String statusLabel(Short status) {
        if (status == null) return "未知";
        return switch (status) {
            case 0 -> "草稿";
            case 1 -> "已审/已出库";
            case -1 -> "红冲";
            default -> "未知";
        };
    }
}
