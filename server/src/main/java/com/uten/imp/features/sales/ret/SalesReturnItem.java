package com.uten.imp.features.sales.ret;

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
 * 销售退货明细。源 S_WithdrawItem。
 *
 * <p>双挂真 FK 骨干：out_item_id→sales_shipment_items（审核回写 returned_qty + returned_amount）、
 * order_item_id→sales_order_items（审核回写 returned_qty + 订货结案重算）。均可空=无来源直销退。
 * solution/responsible 为退货专属字段（老库 qlfa/zrdw）。
 */
@Getter
@Setter
@NoArgsConstructor
@Entity
@Table(name = "sales_return_items")
public class SalesReturnItem extends BaseEntity {

    private Integer legacyId;

    @Column(name = "bill_no")
    private String billNo;

    @Column(name = "bill_date")
    private LocalDate billDate;

    @Column(name = "return_id", nullable = false)
    private UUID returnId;

    /** OutID 真FK → sales_shipment_items.id（可空=无来源直销退）。审核回写 returned_qty/amount。 */
    @Column(name = "out_item_id")
    private UUID outItemId;

    /** OrderID 真FK → sales_order_items.id（双挂）。审核回写 returned_qty + 订货结案重算。 */
    @Column(name = "order_item_id")
    private UUID orderItemId;

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

    /** 退货量（正数；金额在主表与 ar_ap_ledger 端取负）。 */
    @Column(name = "qty", nullable = false, precision = 18, scale = 4)
    private BigDecimal qty;

    @Column(name = "price", precision = 18, scale = 4)
    private BigDecimal price;

    /** 行金额原币（正数）。 */
    @Column(name = "amount_original", precision = 18, scale = 4)
    private BigDecimal amountOriginal;

    @Column(name = "amount_local", precision = 18, scale = 4)
    private BigDecimal amountLocal;

    /** STotal 成本金额（RefreshTotal_PROC 重算值，新库不重算历史）。 */
    @Column(name = "cost_amount", precision = 18, scale = 4)
    private BigDecimal costAmount;

    @Column(name = "weight", precision = 18, scale = 4)
    private BigDecimal weight;

    @Column(name = "client_no")
    private String clientNo;

    @Column(name = "client_model")
    private String clientModel;

    /** qlfa 处理方案（退货专属）。 */
    @Column(name = "solution")
    private String solution;

    /** zrdw 责任单位（退货专属）。 */
    @Column(name = "responsible")
    private String responsible;

    /** Discount 折扣（补列，报表"折扣"+"成交金额"用）。 */
    @Column(name = "discount", precision = 18, scale = 4)
    private BigDecimal discount = BigDecimal.ZERO;

    @Column(name = "source_doc_no")
    private String sourceDocNo;

    private String remark;
}
