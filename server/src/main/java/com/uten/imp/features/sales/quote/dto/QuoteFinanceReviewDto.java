package com.uten.imp.features.sales.quote.dto;

import com.fasterxml.jackson.databind.annotation.JsonSerialize;
import com.uten.imp.common.finance.ExactDecimalText;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.util.List;
import java.util.UUID;

/**
 * 财务核价页详情(ADR-134)。金额不脱敏: 核价人必须看到标价、折扣与金额。
 *
 * <p>每行: 标价(listPrice) | 文件单价原币(clientPrice, 币种 clientFileCurrency) | 折合本币(clientPriceLocal,
 * 按财务参考汇率, 没有汇率为空) | 成交单价(dealPrice = 标价 × 折扣) | 折扣 | 金额 | 与文件差额(diffToFile =
 * 金额 − 数量 × 折合本币)。salesProposedDiscount 为最近一次提交时销售填的折扣;
 * lastFinanceConfirmedDiscount 为上次财务确认时的折扣, changedSinceLastConfirm 只在确认之后销售又提交过、
 * 且提交的折扣与确认的不同时为 true(财务撤销确认后自己改的不算); lastFinanceDiscount 为这次提交之前
 * 最近一次财务核价结果(修改/退回/确认/撤销确认时的折扣), changedSinceFinance = 这次提交把财务定的折扣改了
 * (包括财务改过、还没确认就退回或被撤回的情况)。
 *
 * <p>financeActions 按当前用户与状态给出可做的核价动作(edit / return / confirm / reopen); 编辑、退回、确认还要求
 * 先认领(claimType = SALES_QUOTE_FINANCE_REVIEW, targetKey = 报价 id), 没有认领时页面只读。
 */
public record QuoteFinanceReviewDto(
        UUID id,
        String billNo,
        LocalDate billDate,
        UUID clientId,
        String clientName,
        String clientCode,
        String makerName,
        String sellerName,
        String currencyName,
        boolean baseCurrency,
        UUID settlementMethodId,
        String settlementMethodName,
        LocalDate validUntil,
        LocalDate deliverDate,
        String contractNo,
        String remark,
        String clientFileCurrency,
        @JsonSerialize(using = ExactDecimalText.class) BigDecimal financeRate,
        boolean financeRateMissing,
        Short status,
        String statusBucket,
        int reviewRevision,
        OffsetDateTime submittedAt,
        String submittedByName,
        String financeRemark,
        String financeReturnReason,
        OffsetDateTime financeReturnedAt,
        String financeReturnedByName,
        OffsetDateTime financeConfirmedAt,
        String financeConfirmedByName,
        @JsonSerialize(using = ExactDecimalText.class) BigDecimal totalOriginal,
        @JsonSerialize(using = ExactDecimalText.class) BigDecimal fileTotalLocal,
        int pricePendingCount,
        int blockingLineCount,
        boolean resubmitted,
        String convertedOrderNo,
        boolean canMaintainGoodsPrice,
        List<String> financeActions,
        String claimType,
        List<Line> lines,
        List<QuoteRevisionDto> revisions) {

    public record Line(
            UUID itemId,
            Integer lineNo,
            UUID goodsId,
            String goodsCode,
            String goodsName,
            String colorName,
            String unitName,
            @JsonSerialize(using = ExactDecimalText.class) BigDecimal qty,
            @JsonSerialize(using = ExactDecimalText.class) BigDecimal listPrice,
            String priceSource,
            String financePriceByName,
            OffsetDateTime financePriceAt,
            @JsonSerialize(using = ExactDecimalText.class) BigDecimal currentMasterPrice,
            @JsonSerialize(using = ExactDecimalText.class) BigDecimal clientPrice,
            @JsonSerialize(using = ExactDecimalText.class) BigDecimal clientPriceLocal,
            @JsonSerialize(using = ExactDecimalText.class) BigDecimal dealPrice,
            @JsonSerialize(using = ExactDecimalText.class) BigDecimal discount,
            @JsonSerialize(using = ExactDecimalText.class) BigDecimal amount,
            @JsonSerialize(using = ExactDecimalText.class) BigDecimal fileAmountLocal,
            @JsonSerialize(using = ExactDecimalText.class) BigDecimal diffToFile,
            @JsonSerialize(using = ExactDecimalText.class) BigDecimal salesProposedDiscount,
            @JsonSerialize(using = ExactDecimalText.class) BigDecimal lastFinanceConfirmedDiscount,
            boolean changedSinceLastConfirm,
            @JsonSerialize(using = ExactDecimalText.class) BigDecimal lastFinanceDiscount,
            boolean changedSinceFinance,
            String clientModel,
            String clientGoodsName,
            String remark,
            /** 确认前必须处理的问题(空 = 没有): 「还没有单价」/「标价为 0, 请定价或勾选赠品」。 */
            String blockingReason) {
    }
}
