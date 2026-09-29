package com.uten.imp.features.sales.quote.dto;

import lombok.Getter;
import lombok.NoArgsConstructor;
import lombok.Setter;

import java.math.BigDecimal;
import java.time.OffsetDateTime;
import java.util.UUID;

/**
 * 销售报价明细返回 DTO。
 *
 * <p>价格族(单价/折扣/金额)在看不到价格的人面前置空(priceMasked); 文件型号/品名/单价是客户自己的资料,
 * 不脱敏。pricePending = 货品还没有售价, 等财务定价; financePriced = 单价由财务核价设定。
 */
@Getter
@Setter
@NoArgsConstructor
public class QuoteItemDto {
    private UUID id;
    private Integer lineNo;
    private UUID goodsId;
    private String goodsCodeSnapshot;
    private String goodsNameSnapshot;
    private String goodsSnapshotSource;
    private OffsetDateTime goodsSnapshotLockedAt;
    private UUID colorId;
    private UUID unitId;
    private BigDecimal unitRate;
    private BigDecimal qty;
    private BigDecimal price;
    private BigDecimal discount;
    private BigDecimal amountOriginal;
    private BigDecimal amountLocal;
    private BigDecimal weight;
    private String remark;
    /** MASTER 货品资料售价 / FINANCE 财务设定的成交单价。 */
    private String priceSource;
    private boolean financePriced;
    private boolean pricePending;
    private String clientModel;
    private String clientGoodsName;
    private BigDecimal clientPrice;

    // Exact text is derived after permission masking; null stays null.
    public String getUnitRateExact() { return com.uten.imp.common.util.DecimalText.of(unitRate); }
    public String getQtyExact() { return com.uten.imp.common.util.DecimalText.of(qty); }
    public String getPriceExact() { return com.uten.imp.common.util.DecimalText.of(price); }
    public String getDiscountExact() { return com.uten.imp.common.util.DecimalText.of(discount); }
    public String getAmountOriginalExact() { return com.uten.imp.common.util.DecimalText.of(amountOriginal); }
    public String getAmountLocalExact() { return com.uten.imp.common.util.DecimalText.of(amountLocal); }
    public String getWeightExact() { return com.uten.imp.common.util.DecimalText.of(weight); }
    public String getClientPriceExact() { return com.uten.imp.common.util.DecimalText.of(clientPrice); }
}
