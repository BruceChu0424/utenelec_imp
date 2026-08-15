package com.uten.imp.features.sales.order.dto;

import lombok.AllArgsConstructor;
import lombok.Getter;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.util.UUID;

/**
 * 稀缺库存占用视图：某货品+颜色的全部生效预留及其订单上下文，
 * 供主管在"稀缺让单"面板判断让谁、让多少。按优先级升序、创建时间升序排列（急单在前、先占的在前）。
 */
@Getter
@AllArgsConstructor
public class ScarceStockReservationView {
    private UUID reservationId;
    private UUID orderItemId;
    private UUID orderId;
    private String orderNo;
    private String goodsCode;
    private UUID clientId;
    private String clientName;
    /** 订单行优先级：1急单/2普通/3现货。 */
    private Short priority;
    private LocalDate deliverDate;
    /** 生效预留量（行单位，已 ÷ unit_rate 还原）。 */
    private BigDecimal reservedQty;
    /** 预留持有截止（可选覆盖，null=用默认交货日+宽限）。 */
    private OffsetDateTime holdUntil;
    /** 持有已逾期天数（截止已过且未发完；未逾期/不适用为 null）。 */
    private Long overdueDays;
}
