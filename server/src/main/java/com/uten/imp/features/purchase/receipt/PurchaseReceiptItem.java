package com.uten.imp.features.purchase.receipt;

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
 * 采购收货明细。源 P_InItem。
 *
 * <p>继承 BaseEntity（id + 审计，不软删）：明细随主表重建（update 时物理删旧+插新）。
 * order_item_id 关联订货明细（OrderID），审核时据此回写 received_qty。
 * gift_qty = BPQTY 赠品（独立入库）。
 */
@Getter
@Setter
@NoArgsConstructor
@Entity
@Table(name = "purchase_receipt_items")
public class PurchaseReceiptItem extends BaseEntity {

    private Integer legacyId;

    @Column(name = "bill_no")
    private String billNo;

    @Column(name = "bill_date")
    private LocalDate billDate;

    @Column(name = "receipt_id", nullable = false)
    private UUID receiptId;

    /** 关联订货明细（P_InItem.OrderID）。审核时回写 purchase_order_items.received_qty。 */
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
    private OffsetDateTime goodsSnapshotLockedAt;

    @Column(name = "color_id")
    private UUID colorId;

    @Column(name = "unit_id")
    private UUID unitId;

    @Column(name = "unit_rate", precision = 18, scale = 6)
    private BigDecimal unitRate;

    @Column(name = "qty", nullable = false, precision = 18, scale = 4)
    private BigDecimal qty;

    @Column(name = "replacement_intent", length = 24)
    private String replacementIntent;

    @Column(name = "price", columnDefinition = "numeric")
    private BigDecimal price;

    @Column(name = "amount_original", columnDefinition = "numeric")
    private BigDecimal amountOriginal;

    @Column(name = "amount_local", columnDefinition = "numeric")
    private BigDecimal amountLocal;

    /** 被退货量（退货单审核回写）。 */
    @Column(name = "returned_qty", precision = 18, scale = 4)
    private BigDecimal returnedQty = BigDecimal.ZERO;

    /** BPQTY 赠品。 */
    @Column(name = "gift_qty", precision = 18, scale = 4)
    private BigDecimal giftQty = BigDecimal.ZERO;

    @Column(name = "weight", precision = 18, scale = 4)
    private BigDecimal weight;

    @Column(name = "source_doc_no")
    private String sourceDocNo;

    /** 老库交叉引用文本（软关联，报表按列展示，不强 FK）。 */
    @Column(name = "order_no")
    private String orderNo;

    @Column(name = "sales_order_no")
    private String salesOrderNo;

    @Column(name = "production_plan_no")
    private String productionPlanNo;

    private String remark;
}
