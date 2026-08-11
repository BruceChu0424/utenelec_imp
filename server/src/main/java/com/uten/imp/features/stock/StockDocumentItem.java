package com.uten.imp.features.stock;

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
 * 仓库管理统一出入库明细。base_qty = qty×unit_rate（库存基本量）。
 * surplus_qty/count_qty 仅盘点（盘盈亏/实盘）；upstream_item_id 链路（退料→领料明细等）。
 */
@Getter
@Setter
@NoArgsConstructor
@Entity
@Table(name = "stock_document_items")
public class StockDocumentItem extends BaseEntity {

    private Integer legacyId;

    @Column(name = "doc_id", nullable = false)
    private UUID docId;

    @Column(name = "bill_type")
    private String billType;

    @Column(name = "bill_no")
    private String billNo;

    @Column(name = "bill_date")
    private LocalDate billDate;

    private Integer lineNo;

    @Column(name = "goods_id", nullable = false)
    private UUID goodsId;

    @Column(name = "color_id")
    private UUID colorId;

    @Column(name = "unit_id")
    private UUID unitId;

    @Column(name = "unit_rate", precision = 18, scale = 6)
    private BigDecimal unitRate;

    @Column(name = "qty", nullable = false, precision = 18, scale = 4)
    private BigDecimal qty;

    /** 基本量 = qty×unit_rate（库存用）。 */
    @Column(name = "base_qty", precision = 18, scale = 4)
    private BigDecimal baseQty;

    @Column(name = "price", precision = 18, scale = 4)
    private BigDecimal price;

    @Column(name = "amount_original", precision = 18, scale = 4)
    private BigDecimal amountOriginal;

    @Column(name = "amount_local", precision = 18, scale = 4)
    private BigDecimal amountLocal;

    @Column(name = "weight", precision = 18, scale = 4)
    private BigDecimal weight;

    @Column(name = "gift_qty", precision = 18, scale = 4)
    private BigDecimal giftQty = BigDecimal.ZERO;

    /** 盘点盘盈(+)盘亏(-)（仅 CHECK）。 */
    @Column(name = "surplus_qty", precision = 18, scale = 4)
    private BigDecimal surplusQty;

    /** 盘点实盘数（仅 CHECK）。 */
    @Column(name = "count_qty", precision = 18, scale = 4)
    private BigDecimal countQty;

    private String place;

    @Column(name = "upstream_item_id")
    private UUID upstreamItemId;

    /** Exact V155 execution segment for FINISHED_IN lines. */
    @Column(name = "execution_segment_id")
    private UUID executionSegmentId;

    /** Exact V157 sales ownership inherited from the production report. */
    @Column(name = "execution_segment_sales_allocation_id")
    private UUID executionSegmentSalesAllocationId;

    /** 已出库量（V97，仅 DRAW 领料行）：分轮出库累计，qty−issued_qty=剩余可出。 */
    @Column(name = "issued_qty", nullable = false, precision = 18, scale = 4)
    private BigDecimal issuedQty = BigDecimal.ZERO;

    @Column(name = "source_doc_no")
    private String sourceDocNo;

    private String remark;
}
