package com.uten.imp.features.subcontract.ret;

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
 * 委外退货明细（成品退维度）。源 E_WithDrawItem。
 *
 * <p>双真 FK 骨干（design doc 22 §二）：
 * <ul>
 *   <li>{@code receipt_item_id} → 进仓明细（E_WithDrawItem.InID）；审核时回写
 *       {@code subcontract_receipt_items.returned_qty += qty}</li>
 *   <li>{@code order_item_id} → 订货明细（OrderID）；审核时回写
 *       {@code subcontract_order_items.returned_qty += qty}（双回写）</li>
 * </ul>
 */
@Getter
@Setter
@NoArgsConstructor
@Entity
@Table(name = "subcontract_return_items")
public class SubcontractReturnItem extends BaseEntity {

    private Integer legacyId;

    @Column(name = "bill_no")
    private String billNo;

    @Column(name = "bill_date")
    private LocalDate billDate;

    @Column(name = "return_id", nullable = false)
    private UUID returnId;

    /** 关联进仓明细（E_WithDrawItem.InID）。审核时回写 receipt_items.returned_qty。 */
    @Column(name = "receipt_item_id")
    private UUID receiptItemId;

    /** 关联订货明细（OrderID）。审核时回写 order_items.returned_qty（双回写）。 */
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

    @Column(name = "price", precision = 18, scale = 4)
    private BigDecimal price;

    @Column(name = "amount_original", precision = 18, scale = 4)
    private BigDecimal amountOriginal;

    @Column(name = "amount_local", precision = 18, scale = 4)
    private BigDecimal amountLocal;

    @Column(name = "weight", precision = 18, scale = 4)
    private BigDecimal weight;

    @Column(name = "source_doc_no")
    private String sourceDocNo;

    /** 围数（E_WithDrawItem.KQTY）。 */
    @Column(name = "girth_qty", precision = 18, scale = 4)
    private BigDecimal girthQty;

    /** 工序 legacy id（E_WithDrawItem.StepID → B_Step；B_Step 未迁，暂空白）。 */
    @Column(name = "step_legacy_id")
    private Integer stepLegacyId;

    /** 委外进仓单号（E_WithDrawItem.InNo，多值 varchar 原样）。 */
    @Column(name = "receipt_no")
    private String receiptNo;

    /** 委外订货单号（E_WithDrawItem.OrderNo，多值 varchar 原样）。 */
    @Column(name = "order_no")
    private String orderNo;

    private String remark;
}
