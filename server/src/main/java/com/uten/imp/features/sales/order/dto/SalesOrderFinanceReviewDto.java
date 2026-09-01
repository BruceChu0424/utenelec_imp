package com.uten.imp.features.sales.order.dto;

import com.fasterxml.jackson.databind.annotation.JsonSerialize;
import com.fasterxml.jackson.databind.ser.std.ToStringSerializer;

import java.math.BigDecimal;
import java.time.Instant;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.util.List;
import java.util.UUID;

/**
 * 销售订单财务审核详情（V300 财务审核专用页）。
 *
 * <p>与销售端订单详情分离：面向财务审核决策，额外携带客户财务快照
 * （应收余额/信用额度/铺底额/是否超信用）与结算方式；不含销售端运营按钮语义
 * （改量/排产进度/取消/红冲不在本页操作）。
 *
 * <p>金额口径：与待确认列表一致——sales_order_finance:view 持有者可见订单原币金额
 * （财务确认必须核对金额，与 V294 pending 列表下发 totalOriginal 同口径）。
 */
public record SalesOrderFinanceReviewDto(
        @JsonSerialize(using = ToStringSerializer.class) UUID orderId,
        String billNo,
        LocalDate billDate,
        @JsonSerialize(using = ToStringSerializer.class) UUID clientId,
        String clientName,
        String clientCode,
        String sellerName,
        String makerName,
        Instant createdAt,
        LocalDate deliverDate,
        String currencyCode,
        /** 币种显示名（主档 name 人民币/美金…，前端展示优先于 code 编号）。 */
        String currencyName,
        String shipmentPolicy,
        /** 发运策略显示名（服务端解析，前端不跨 feature 复用销售标签函数）。 */
        String shipmentPolicyName,
        String settlementMethodName,
        String contractNo,
        /** Historical commercial snapshot only; finance money facts come from customer-prepayment summary. */
        BigDecimal legacyDepositSnapshot,
        String remark,
        long itemCount,
        BigDecimal totalOriginal,
        // ===== 客户财务快照 =====
        BigDecimal clientOutstanding,
        BigDecimal clientCredit,
        BigDecimal clientCreditFloor,
        /** 应收余额是否已超信用额度（信用额度为空/≤0 时按未配置处理，恒 false）。 */
        boolean clientOverCredit,
        // ===== 财务确认/驳回事实 =====
        boolean financeConfirmed,
        OffsetDateTime financeConfirmedAt,
        String financeConfirmedByName,
        String financeConfirmRemark,
        boolean financeRejected,
        String financeRejectedReason,
        String financeRejectedByName,
        OffsetDateTime financeRejectedAt,
        List<Line> items) {

    /** 审核明细行（货品快照优先，颜色/单位按主档解析名称）。 */
    public record Line(
            @JsonSerialize(using = ToStringSerializer.class) UUID itemId,
            Integer lineNo,
            String goodsCode,
            String goodsName,
            String colorName,
            String unitName,
            String clientModel,
            BigDecimal qty,
            BigDecimal weight,
            BigDecimal price,
            BigDecimal discount,
            BigDecimal amountOriginal,
            String remark) {
    }
}
