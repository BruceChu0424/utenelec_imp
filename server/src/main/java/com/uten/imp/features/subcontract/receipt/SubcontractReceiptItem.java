package com.uten.imp.features.subcontract.receipt;

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
 * 委外进仓明细。源 E_InItem。
 *
 * <p>order_item_id 关联订货明细（InID/OrderID），审核时据此回写 subcontract_order_items.received_qty。
 * returned_qty 被退货单审核回写（成品退维度）。
 */
@Getter
@Setter
@NoArgsConstructor
@Entity
@Table(name = "subcontract_receipt_items")
public class SubcontractReceiptItem extends BaseEntity {

    private Integer legacyId;

    @Column(name = "bill_no")
    private String billNo;

    @Column(name = "bill_date")
    private LocalDate billDate;

    @Column(name = "receipt_id", nullable = false)
    private UUID receiptId;

    /** 关联订货明细（E_InItem.OrderID）。审核时回写 subcontract_order_items.received_qty。 */
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

    /** CQTY 检验数量（委外进仓检验）。 */
    @Column(name = "check_qty", precision = 18, scale = 4)
    private BigDecimal checkQty;

    /** OrderQTY 关联订单数量（冗余）。 */
    @Column(name = "order_qty", precision = 18, scale = 4)
    private BigDecimal orderQty;

    /** 被成品退回量（退货单审核回写）。 */
    @Column(name = "returned_qty", precision = 18, scale = 4)
    private BigDecimal returnedQty = BigDecimal.ZERO;

    @Column(name = "weight", precision = 18, scale = 4)
    private BigDecimal weight;

    @Column(name = "source_doc_no")
    private String sourceDocNo;

    private String remark;
}
