package com.uten.imp.features.sales.quote;

import com.uten.imp.common.domain.BaseEntity;
import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.Table;
import lombok.Getter;
import lombok.NoArgsConstructor;
import lombok.Setter;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.UUID;

/**
 * 销售报价明细。源 S_QuoteItem。草稿保存时按行 id 原位更新(新行插入、去掉的行删除),
 * 行 id 在修订之间保持不变, 核价页据此对照「销售提交的折扣」与「上次财务确认的折扣」。
 *
 * <p>单价是货品资料售价(销售不能改)或财务核价时设定的成交单价(price_source = FINANCE);
 * 金额 = 数量 × 单价 × 折扣, 由服务端计算。文件型号/品名/单价只作参考, 从不参与金额。
 */
@Getter
@Setter
@NoArgsConstructor
@Entity
@Table(name = "sales_quote_items")
public class SalesQuoteItem extends BaseEntity {

    private Integer legacyId;

    @Column(name = "bill_no")
    private String billNo;

    @Column(name = "bill_date")
    private LocalDate billDate;

    @Column(name = "quote_id", nullable = false)
    private UUID quoteId;

    private Integer lineNo;

    @Column(name = "goods_id", nullable = false)
    private UUID goodsId;

    @Column(name = "goods_code_snapshot")
    private String goodsCodeSnapshot;

    @Column(name = "goods_name_snapshot")
    private String goodsNameSnapshot;

    @Column(name = "goods_snapshot_source", nullable = false)
    private String goodsSnapshotSource;

    @Column(name = "goods_snapshot_locked_at")
    private java.time.OffsetDateTime goodsSnapshotLockedAt;

    @Column(name = "color_id")
    private UUID colorId;

    @Column(name = "unit_id")
    private UUID unitId;

    @Column(name = "unit_rate", precision = 18, scale = 6)
    private BigDecimal unitRate;

    @Column(name = "qty", nullable = false, precision = 18, scale = 4)
    private BigDecimal qty;

    @Column(name = "price", precision = 18, scale = 4)
    private BigDecimal price;

    @Column(name = "amount_original", precision = 18, scale = 4)
    private BigDecimal amountOriginal;

    @Column(name = "amount_local", precision = 18, scale = 4)
    private BigDecimal amountLocal;

    @Column(name = "weight", precision = 18, scale = 4)
    private BigDecimal weight;

    private String remark;

    /** 折扣倍率(0 < 折扣 <= 1, 4 位小数): 金额 = 数量 × 单价 × 折扣。 */
    @Column(name = "discount", nullable = false, precision = 18, scale = 4)
    private BigDecimal discount = BigDecimal.ONE.setScale(4);

    /** MASTER 货品资料售价 / FINANCE 财务核价时设定的成交单价。 */
    @Column(name = "price_source", nullable = false)
    private String priceSource = PRICE_SOURCE_MASTER;

    @Column(name = "finance_price_by")
    private UUID financePriceBy;

    @Column(name = "finance_price_at")
    private java.time.OffsetDateTime financePriceAt;

    /** 客户文件上的型号/货号原文。 */
    @Column(name = "client_model")
    private String clientModel;

    /** 客户文件上的品名/描述原文。 */
    @Column(name = "client_goods_name")
    private String clientGoodsName;

    /** 客户文件上的单价原文数值(币种见表头 client_file_currency), 只作参考。 */
    @Column(name = "client_price")
    private BigDecimal clientPrice;

    public static final String PRICE_SOURCE_MASTER = "MASTER";
    public static final String PRICE_SOURCE_FINANCE = "FINANCE";
}
