package com.uten.imp.features.sales.shipment;

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
 * 销售出货明细。源 S_OutItem。
 *
 * <p>order_item_id 关联订货明细（真 FK 骨干，可空=不挂订单的直销行），审核时回写 shipped_qty。
 * returned_qty/returned_amount 由退货审核回写。
 */
@Getter
@Setter
@NoArgsConstructor
@Entity
@Table(name = "sales_shipment_items")
public class SalesShipmentItem extends BaseEntity {

    private Integer legacyId;

    @Column(name = "bill_no")
    private String billNo;

    @Column(name = "bill_date")
    private LocalDate billDate;

    @Column(name = "shipment_id", nullable = false)
    private UUID shipmentId;

    /** 关联订货明细（OrderID），审核时回写 sales_order_items.shipped_qty；可空=直销行。 */
    @Column(name = "order_item_id")
    private UUID orderItemId;

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

    @Column(name = "price", precision = 18, scale = 4)
    private BigDecimal price;

    @Column(name = "amount_original", precision = 18, scale = 4)
    private BigDecimal amountOriginal;

    @Column(name = "amount_local", precision = 18, scale = 4)
    private BigDecimal amountLocal;

    /** STotal 成本金额（RefreshTotal_PROC 重算值，新库不重算历史）。 */
    @Column(name = "cost_amount", precision = 18, scale = 4)
    private BigDecimal costAmount;

    /** WQTY 本出货行的已退量（退货审核回写）。 */
    @Column(name = "returned_qty", precision = 18, scale = 4)
    private BigDecimal returnedQty = BigDecimal.ZERO;

    /** SWTotal 已退金额（退货审核回写）。 */
    @Column(name = "returned_amount", precision = 18, scale = 4)
    private BigDecimal returnedAmount = BigDecimal.ZERO;

    @Column(name = "weight", precision = 18, scale = 4)
    private BigDecimal weight;

    /** KQTY 件数（把/箱）。 */
    @Column(name = "parcel_qty", precision = 18, scale = 4)
    private BigDecimal parcelQty;

    /** Boxs 箱数。 */
    @Column(name = "carton_count", precision = 18, scale = 4)
    private BigDecimal cartonCount;

    @Column(name = "client_no")
    private String clientNo;

    @Column(name = "client_model")
    private String clientModel;

    @Column(name = "source_doc_no")
    private String sourceDocNo;

    private String remark;
}
