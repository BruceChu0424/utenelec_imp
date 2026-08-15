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
 * <p>order_item_id 关联订货明细（新流程必填；历史行可空），审核时回写 shipped_qty。
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

    /** 关联订货明细（OrderID）；新流程必填，历史迁移行可空。 */
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

    /** SPrice 材料价（补列，成本分项）。 */
    @Column(name = "material_price", precision = 18, scale = 4)
    private BigDecimal materialPrice;

    /** WPrice 压铸价（补列，成本分项）。 */
    @Column(name = "die_cast_price", precision = 18, scale = 4)
    private BigDecimal dieCastPrice;

    /** JPrice 机加价（补列，成本分项）。 */
    @Column(name = "machining_price", precision = 18, scale = 4)
    private BigDecimal machiningPrice;

    /** KQTY2 围数（补列，包装派生）。 */
    @Column(name = "circumference", precision = 18, scale = 4)
    private BigDecimal circumference;

    /** Discount 折扣（补列，报表"折扣"+"成交金额"用）。 */
    @Column(name = "discount", precision = 18, scale = 4)
    private BigDecimal discount = BigDecimal.ZERO;

    @Column(name = "source_doc_no")
    private String sourceDocNo;

    private String remark;
}
