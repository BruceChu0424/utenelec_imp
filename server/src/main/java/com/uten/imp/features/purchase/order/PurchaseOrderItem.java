package com.uten.imp.features.purchase.order;

import com.uten.imp.common.domain.BaseEntity;
import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.Table;
import lombok.Getter;
import lombok.NoArgsConstructor;
import lombok.Setter;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.util.UUID;

/**
 * 采购订货明细。源 P_OrderItem。
 *
 * <p>request_item_id 关联申请明细（ApplyID），审核时据此回写 ordered_qty。
 * received_qty/returned_qty 由收货/退货单审核回写。
 */
@Getter
@Setter
@NoArgsConstructor
@Entity
@Table(name = "purchase_order_items")
public class PurchaseOrderItem extends BaseEntity {

    private Integer legacyId;

    @Column(name = "bill_no")
    private String billNo;

    @Column(name = "bill_date")
    private LocalDate billDate;

    @Column(name = "order_id", nullable = false)
    private UUID orderId;

    @Column(name = "request_item_id")
    private UUID requestItemId;

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
    private OffsetDateTime goodsSnapshotLockedAt;

    @Column(name = "color_id")
    private UUID colorId;

    @Column(name = "unit_id")
    private UUID unitId;

    @Column(name = "unit_rate", precision = 18, scale = 6)
    private BigDecimal unitRate;

    @Column(name = "qty", nullable = false, precision = 18, scale = 4)
    private BigDecimal qty;

    @Column(name = "price", columnDefinition = "numeric")
    private BigDecimal price;

    @Column(name = "amount_original", columnDefinition = "numeric")
    private BigDecimal amountOriginal;

    @Column(name = "amount_local", columnDefinition = "numeric")
    private BigDecimal amountLocal;

    /** 已收量（收货单审核回写）。 */
    @Column(name = "received_qty", precision = 18, scale = 4)
    private BigDecimal receivedQty = BigDecimal.ZERO;

    /** 已退量（退货单审核回写）。 */
    @Column(name = "returned_qty", precision = 18, scale = 4)
    private BigDecimal returnedQty = BigDecimal.ZERO;

    @Column(name = "gift_qty", precision = 18, scale = 4)
    private BigDecimal giftQty = BigDecimal.ZERO;

    @Column(name = "deliver_date")
    private LocalDate deliverDate;

    @Column(name = "weight", precision = 18, scale = 4)
    private BigDecimal weight;

    @Column(name = "source_doc_no")
    private String sourceDocNo;

    /** 老库交叉引用文本（软关联，报表按列展示，不强 FK）。 */
    @Column(name = "sales_order_no")
    private String salesOrderNo;

    @Column(name = "receipt_no")
    private String receiptNo;

    @Column(name = "production_plan_no")
    private String productionPlanNo;

    private String remark;
}
