package com.uten.imp.features.sales.quote.dto;

import com.uten.imp.common.validation.RequestLimits;
import jakarta.validation.Valid;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Size;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.List;
import java.util.UUID;

/**
 * 财务核价修改(报价待核价、本人持有认领)。
 *
 * <p>表头 validUntil / settlementMethodId / financeRemark 是整体状态(页面总是带上当前值; 空 = 清空)。
 * lines 只列要改的行, 每行四选一:
 * <ul>
 *   <li>discount: 直接核定折扣(0 < 折扣 <= 1, 4 位小数);</li>
 *   <li>dealPrice: 填成交单价, 服务端按标价反推折扣; 货品没有标价或成交单价高于标价时改用财务定价
 *       (单价 = 成交单价, 折扣 1);</li>
 *   <li>giftZeroPrice = true: 赠品/0 价(财务定价 0);</li>
 *   <li>useMasterPrice = true: 按货品资料最新标价刷新单价(财务刚维护了标价时用), 折扣不变。</li>
 * </ul>
 * 财务还可填写 price（报价基价，可与 discount 同时填写）、qty（正数数量），或 removed=true 删除整行。
 * 删除不允许混合其他操作，至少保留一行。所有变化追加修订快照；新增或替换货品由销售重开修改。
 */
public record QuoteFinanceEditRequest(
        @NotNull(message = "缺少核价修订号, 请刷新后重试") Integer expectedRevision,
        UUID expectedClaimId,
        LocalDate validUntil,
        UUID settlementMethodId,
        @Size(max = 500, message = "财务备注不能超过 500 个字符") String financeRemark,
        @Valid @Size(max = RequestLimits.DOCUMENT_LINES) List<Line> lines) {

    public record Line(
            @NotNull UUID itemId,
            BigDecimal discount,
            BigDecimal dealPrice,
            Boolean giftZeroPrice,
            Boolean useMasterPrice,
            BigDecimal qty,
            BigDecimal price,
            Boolean removed) {
        public Line(UUID itemId, BigDecimal discount, BigDecimal dealPrice, Boolean giftZeroPrice,
                    Boolean useMasterPrice) {
            this(itemId, discount, dealPrice, giftZeroPrice, useMasterPrice, null, null, null);
        }
    }
}
