package com.uten.imp.features.sales.other_shipment;

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
 * 其它出货明细。源 S_OtherOutItem。
 *
 * <p>order_item_id 字段留位但业务上不强制挂单（老库 OrderID 是孤儿，触发器 UPDATE 段已注释）——
 * Java 端录入不挂订单，审核也不回写。无 returned_qty/returned_amount（无对应退货类型）。
 */
@Getter
@Setter
@NoArgsConstructor
@Entity
@Table(name = "sales_other_shipment_items")
public class SalesOtherShipmentItem extends BaseEntity {

    private Integer legacyId;

    @Column(name = "bill_no")
    private String billNo;

    @Column(name = "bill_date")
    private LocalDate billDate;

    @Column(name = "shipment_id", nullable = false)
    private UUID shipmentId;

    /** 字段留位（老库 S_OtherOutItem.OrderID），新库不强制挂单，默认空。 */
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

    @Column(name = "cost_amount", precision = 18, scale = 4)
    private BigDecimal costAmount;

    @Column(name = "weight", precision = 18, scale = 4)
    private BigDecimal weight;

    @Column(name = "parcel_qty", precision = 18, scale = 4)
    private BigDecimal parcelQty;

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
