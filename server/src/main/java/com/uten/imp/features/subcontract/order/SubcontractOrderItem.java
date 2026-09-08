package com.uten.imp.features.subcontract.order;

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
 * 委外订货明细。源 E_OrderItem；成品（父件）维度。
 *
 * <p>累计量字段分为权威成品累计和 legacy 展示：
 * <ul>
 *   <li>{@code received_qty} ← 进仓单审核（E_In, IQTY），见 {@code SubcontractReceiptService}</li>
 *   <li>{@code returned_qty} ← 退货单审核（E_WithDraw, WQTY 成品维度）</li>
 *   <li>{@code issued_qty}/{@code material_returned_qty} 仅保留 legacy
 *       展示，不再由新业务写入；成品行不能累计不同子件数量</li>
 * </ul>
 * {@code application_item_id} 真FK（可选）挂申请明细；审核订货时回写申请明细 ordered_qty。
 */
@Getter
@Setter
@NoArgsConstructor
@Entity
@Table(name = "subcontract_order_items")
public class SubcontractOrderItem extends BaseEntity {

    @Column(name = "is_deleted", nullable = false)
    private boolean deleted;

    private Integer legacyId;

    @Column(name = "bill_no")
    private String billNo;

    @Column(name = "bill_date")
    private LocalDate billDate;

    @Column(name = "order_id", nullable = false)
    private UUID orderId;

    private Integer lineNo;

    @Column(name = "goods_id", nullable = false)
    private UUID goodsId;                // 成品（父件）

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
    private BigDecimal qty;              // 订货量（成品）

    @Column(name = "price", columnDefinition = "numeric")
    private BigDecimal price;            // 加工单价

    @Column(name = "amount_original", columnDefinition = "numeric")
    private BigDecimal amountOriginal;

    @Column(name = "amount_local", columnDefinition = "numeric")
    private BigDecimal amountLocal;

    /** 已进仓（E_In 审核回写）。 */
    @Column(name = "received_qty", precision = 18, scale = 4)
    private BigDecimal receivedQty = BigDecimal.ZERO;

    /** 已成品退（E_WithDraw 审核回写）。 */
    @Column(name = "returned_qty", precision = 18, scale = 4)
    private BigDecimal returnedQty = BigDecimal.ZERO;

    /** Legacy 已发料展示值；子件量不能作为成品行权威累计，新业务不写。 */
    @Column(name = "issued_qty", precision = 18, scale = 4)
    private BigDecimal issuedQty = BigDecimal.ZERO;

    /** Legacy 已材料退展示值；子件量不能作为成品行权威累计，新业务不写。 */
    @Column(name = "material_returned_qty", precision = 18, scale = 4)
    private BigDecimal materialReturnedQty = BigDecimal.ZERO;

    /** 申请明细真FK（可选；审核订货时回写 application_items.ordered_qty）。 */
    @Column(name = "application_item_id")
    private UUID applicationItemId;

    @Column(name = "deliver_date")
    private LocalDate deliverDate;

    @Column(name = "weight", precision = 18, scale = 4)
    private BigDecimal weight;

    @Column(name = "source_doc_no")
    private String sourceDocNo;

    private String remark;
}
