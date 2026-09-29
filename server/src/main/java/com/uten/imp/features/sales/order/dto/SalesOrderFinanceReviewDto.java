package com.uten.imp.features.sales.order.dto;

import com.fasterxml.jackson.databind.annotation.JsonSerialize;
import com.uten.imp.common.finance.ExactDecimalText;
import com.uten.imp.common.finance.PartyOpenBalanceView;
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
 * (本单币种应收余额 ADR-128 / 信用额度 / 铺底额 / 是否超信用)与结算方式；不含销售端运营按钮语义
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
        @JsonSerialize(using = ExactDecimalText.class) BigDecimal legacyDepositSnapshot,
        String remark,
        long itemCount,
        @JsonSerialize(using = ExactDecimalText.class) BigDecimal totalOriginal,
        // ===== 客户财务快照 =====
        /**
         * ADR-128: 客户在本单币种下的应收 / 可用预收 / 还差多少, 其它币种另列;
         * 信用额度只在视图里下发一次({@code creditLimitLocal}, 迁入客户的旧额度、为空或不大于 0 都按未设置 = null),
         * {@code overCredit} = 全币种正式应收账面本币毛额(不扣预收) > 信用额度。
         */
        PartyOpenBalanceView clientBalance,
        @JsonSerialize(using = ExactDecimalText.class) BigDecimal clientCreditFloor,
        // ===== 财务确认/驳回事实 =====
        boolean financeConfirmed,
        OffsetDateTime financeConfirmedAt,
        String financeConfirmedByName,
        String financeConfirmRemark,
        boolean financeRejected,
        String financeRejectedReason,
        String financeRejectedByName,
        OffsetDateTime financeRejectedAt,
        List<Line> items,
        /** 上次财务确认之后的改量清单（以前→现在；空 = 未修改过或清单已随重新确认归档）。 */
        List<QtyChange> qtyChanges,
        List<com.uten.imp.features.sales.order.SalesOrderRevisionService.FieldChange> commercialChanges,
        long financeReviewRevision,
        com.uten.imp.features.sales.order.SalesOrderRevisionService.RevisionDiff revisionDiff,
        /** ADR-134 来源报价(报价转入才有): 单号 + 财务核价人与时间; allLinesMatch = 每行单价折扣都与报价核定一致。 */
        SourceQuote sourceQuote,
        /** ADR-134 客户文件上单价的币种代码(阅读明细 clientPrice 用)。 */
        String clientFileCurrency,
        /** ADR-134 整单是否与来源报价核定一致(= sourceQuote.allLinesMatch; 不是报价转入为 null), 与列表同口径。 */
        Boolean matchesQuote) {

    /** 来源报价核价信息(订单确认只需再核信用与条款; 价格已由财务在报价上核定)。 */
    public record SourceQuote(
            @JsonSerialize(using = ToStringSerializer.class) UUID id,
            String billNo,
            String financeConfirmedByName,
            OffsetDateTime financeConfirmedAt,
            boolean allLinesMatch) {
    }

    /**
     * 修改清单行（2026-09-05 确认后改量）：一行一次数量修改，
     * 财务按 oldQty→newQty 对照复核。
     */
    public record QtyChange(
            @JsonSerialize(using = ToStringSerializer.class) UUID orderItemId,
            String goodsCode,
            String goodsName,
            String colorName,
            String unitName,
            BigDecimal oldQty,
            BigDecimal newQty,
            String changedByName,
            OffsetDateTime changedAt) {
    }

    /**
     * 审核明细行（货品快照优先，颜色/单位按主档解析名称）。
     *
     * <p>{@code unitId} 供前端「合计数量」按单位分组用（不同单位的数量绝不相加），
     * {@code unitName} 只作显示标签。
     */
    public record Line(
            @JsonSerialize(using = ToStringSerializer.class) UUID itemId,
            Integer lineNo,
            String goodsCode,
            String goodsName,
            String colorName,
            @JsonSerialize(using = ToStringSerializer.class) UUID unitId,
            String unitName,
            String clientModel,
            @JsonSerialize(using = ExactDecimalText.class) BigDecimal qty,
            @JsonSerialize(using = ExactDecimalText.class) BigDecimal weight,
            @JsonSerialize(using = ExactDecimalText.class) BigDecimal price,
            @JsonSerialize(using = ExactDecimalText.class) BigDecimal discount,
            @JsonSerialize(using = ExactDecimalText.class) BigDecimal amountOriginal,
            String remark,
            /** ADR-134 客户文件品名原文。 */
            String clientGoodsName,
            /** ADR-134 客户文件单价原文(币种见表头 clientFileCurrency)。 */
            @JsonSerialize(using = ExactDecimalText.class) BigDecimal clientPrice,
            /** 来源报价核定的单价/折扣(报价转入且配对上的行才有)。 */
            @JsonSerialize(using = ExactDecimalText.class) BigDecimal quotePrice,
            @JsonSerialize(using = ExactDecimalText.class) BigDecimal quoteDiscount,
            /** 本行单价与折扣是否与报价核定一致(非报价转入的订单为 null; 报价外新增的行为 false)。 */
            Boolean matchesQuote) {
    }
}
