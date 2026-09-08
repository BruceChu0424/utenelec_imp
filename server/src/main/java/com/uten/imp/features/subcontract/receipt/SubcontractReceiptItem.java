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
import java.time.OffsetDateTime;
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

    @Column(name = "goods_code_snapshot") private String goodsCodeSnapshot;
    @Column(name = "goods_name_snapshot") private String goodsNameSnapshot;
    @Column(name = "goods_snapshot_source", nullable = false) private String goodsSnapshotSource;
    @Column(name = "goods_snapshot_locked_at") private OffsetDateTime goodsSnapshotLockedAt;

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

    /** 围数（E_InItem.KQTY）。 */
    @Column(name = "girth_qty", precision = 18, scale = 4)
    private BigDecimal girthQty;

    /** 工序 legacy id（E_InItem.StepID → B_Step；B_Step 未迁，暂空白）。 */
    @Column(name = "step_legacy_id")
    private Integer stepLegacyId;

    /** 退货金额（E_InItem.EWTotal）。 */
    @Column(name = "return_amount", precision = 18, scale = 4)
    private BigDecimal returnAmount;

    /** 委外退货单号（E_InItem.EWDrawNo，多值 varchar 原样）。 */
    @Column(name = "return_no")
    private String returnNo;

    /** 委外订货单号（E_InItem.OrderNo，多值 varchar 原样）。 */
    @Column(name = "order_no")
    private String orderNo;

    private String remark;
}
