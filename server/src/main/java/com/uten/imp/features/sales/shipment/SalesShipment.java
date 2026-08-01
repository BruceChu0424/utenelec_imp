package com.uten.imp.features.sales.shipment;

import com.uten.imp.common.domain.SoftDeletableEntity;
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
 * 销售出货单主表（销售管理）。源 S_Out（主流量）。
 *
 * <p>审核（status 0→1）：库存出库（type=3/dir=-1）+ 回写 sales_order_items.shipped_qty
 * + 立应收（AR, SALES_SHIPMENT, BStyle=3, 正应收）+ 结案重算。ar_posted 立帐标志。
 * 红冲（1→-1）：先 reverseArAp 校验无收款核销 → 反向库存 + 回减 shipped_qty。
 */
@Getter
@Setter
@NoArgsConstructor
@Entity
@Table(name = "sales_shipments")
public class SalesShipment extends SoftDeletableEntity {

    public static final String WORK_LEGACY_PENDING = "LEGACY_PENDING";
    public static final String WORK_PENDING_PICK = "PENDING_PICK";
    public static final String WORK_PICKING = "PICKING";
    public static final String WORK_PICKED = "PICKED";
    public static final String WORK_EXCEPTION = "EXCEPTION";
    public static final String WORK_SHIPPED = "SHIPPED";
    public static final String WORK_CANCELLED = "CANCELLED";
    public static final String WORK_REVERSED = "REVERSED";

    @Column(name = "legacy_id", unique = true)
    private Integer legacyId;

    @Column(name = "bill_no", nullable = false)
    private String billNo;

    @Column(name = "bill_date", nullable = false)
    private LocalDate billDate;

    @Column(name = "client_id", nullable = false)
    private UUID clientId;

    @Column(name = "warehouse_id")
    private UUID warehouseId;

    @Column(name = "currency_id")
    private UUID currencyId;

    @Column(name = "exchange_rate", precision = 18, scale = 6)
    private BigDecimal exchangeRate;

    @Column(name = "tax_rate", precision = 18, scale = 4)
    private BigDecimal taxRate;

    @Column(name = "payment_style_id")
    private Integer paymentStyleId;

    @Column(name = "seller_id")
    private UUID sellerId;
    /** 归属业务员（V91：每个销售只看自己的单据；NULL=公共）。 */
    @Column(name = "owner_employee_id")
    private java.util.UUID ownerEmployeeId;

    @Column(name = "sender_id")
    private UUID senderId;

    @Column(name = "maker_id")
    private UUID makerId;

    @Column(name = "approver_id")
    private UUID approverId;

    @Column(name = "ship_addr")
    private String shipAddr;

    @Column(name = "link_phone")
    private String linkPhone;

    @Column(name = "parcel_count")
    private Integer parcelCount;

    @Column(name = "print_count")
    private Integer printCount = 0;

    /** 最后操作日（立应收/到期日用）。 */
    @Column(name = "last_date")
    private OffsetDateTime lastDate;

    private String remark;

    @Column(name = "total_original", precision = 18, scale = 4)
    private BigDecimal totalOriginal;

    @Column(name = "total_local", precision = 18, scale = 4)
    private BigDecimal totalLocal;

    /** 0 草稿 / 1 已审 / -1 红冲。 */
    @Column(name = "status", nullable = false)
    private Short status = 0;

    @Column(name = "is_closed", nullable = false)
    private boolean closed = false;

    @Column(name = "source_doc_no")
    private String sourceDocNo;

    /** 应收已立帐标志（审核置 true，反审校验）。 */
    @Column(name = "ar_posted", nullable = false)
    private boolean arPosted = false;

    /** 仓库驳回标记（V96）：备货发现货损/丢失/找不到；草稿态终态，不可编辑/审核。 */
    @Column(name = "rejected", nullable = false)
    private boolean rejected = false;

    /** 驳回原因（V96），销售详情页可见。 */
    @Column(name = "reject_reason")
    private String rejectReason;

    /** C6 财务发货审核：0 未审 / 1 已审发货（现金结算客户 price_style=1 须审，仓库见「已审」才可审核出货）。 */
    @Column(name = "finance_audit", nullable = false)
    private Short financeAudit = 0;

    @Column(name = "finance_auditor_id")
    private java.util.UUID financeAuditorId;

    @Column(name = "finance_audited_at")
    private java.time.OffsetDateTime financeAuditedAt;

    @Column(name = "warehouse_work_status", nullable = false)
    private String warehouseWorkStatus = WORK_PENDING_PICK;

    @Column(name = "warehouse_work_updated_at")
    private OffsetDateTime warehouseWorkUpdatedAt;

    @Column(name = "warehouse_work_updated_by")
    private UUID warehouseWorkUpdatedBy;

    @Column(name = "picking_started_at")
    private OffsetDateTime pickingStartedAt;

    @Column(name = "picking_started_by")
    private UUID pickingStartedBy;

    @Column(name = "picked_at")
    private OffsetDateTime pickedAt;

    @Column(name = "picked_by")
    private UUID pickedBy;

    @Column(name = "handed_over_at")
    private OffsetDateTime handedOverAt;

    @Column(name = "handed_over_by")
    private UUID handedOverBy;

    @Column(name = "warehouse_exception_reason")
    private String warehouseExceptionReason;
}
