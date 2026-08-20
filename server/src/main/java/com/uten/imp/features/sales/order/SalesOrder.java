package com.uten.imp.features.sales.order;

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
 * 销售订货单主表（销售管理）。源 S_Order。
 *
 * <p>审核（status 0→1）无库存/应收副作用（订货只承诺，不动账）。
 * 被出货/退货单回写 shipped_qty/returned_qty + is_closed 派生重算（所有明细 qty-shipped+returned-flag≤0）。
 * is_stopped 业务独立位（人工维护，贴老库 Stop）。
 */
@Getter
@Setter
@NoArgsConstructor
@Entity
@Table(name = "sales_orders")
public class SalesOrder extends SoftDeletableEntity {

    public static final String SHIPMENT_POLICY_LEGACY = "LEGACY_UNSPECIFIED";
    public static final String SHIPMENT_POLICY_ALLOW_PARTIAL = "ALLOW_PARTIAL";
    public static final String SHIPMENT_POLICY_REQUIRE_COMPLETE = "REQUIRE_COMPLETE";
    public static final String SHIPMENT_POLICY_CUSTOMER_CONFIRM = "CUSTOMER_CONFIRM";

    @Column(name = "legacy_id", unique = true)
    private Integer legacyId;

    @Column(name = "bill_no", nullable = false)
    private String billNo;

    @Column(name = "bill_date", nullable = false)
    private LocalDate billDate;

    @Column(name = "client_id", nullable = false)
    private UUID clientId;

    @Column(name = "currency_id")
    private UUID currencyId;

    @Column(name = "exchange_rate", precision = 18, scale = 6)
    private BigDecimal exchangeRate;

    @Column(name = "tax_rate", precision = 18, scale = 4)
    private BigDecimal taxRate;

    /** 老库 PStyle → payment_styles（后改 UUID FK，本期留 INT 占位）。 */
    @Column(name = "payment_style_id")
    private Integer paymentStyleId;

    /** Settlement-method UUID truth; paymentStyleId is the legacy B_PStyle snapshot. */
    @Column(name = "settlement_method_id")
    private UUID settlementMethodId;

    @Column(name = "seller_id")
    private UUID sellerId;
    /** 归属业务员（每个销售只看自己的单据；NULL=公共）。 */
    @Column(name = "owner_employee_id")
    private java.util.UUID ownerEmployeeId;

    @Column(name = "maker_id")
    private UUID makerId;

    @Column(name = "approver_id")
    private UUID approverId;

    @Column(name = "deliver_date")
    private LocalDate deliverDate;

    @Column(name = "contract_no")
    private String contractNo;

    @Column(name = "link_phone")
    private String linkPhone;

    @Column(name = "sign_addr")
    private String signAddr;

    @Column(name = "ship_addr")
    private String shipAddr;

    @Column(name = "deposit", precision = 18, scale = 4)
    private BigDecimal deposit;

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

    /** 中止（业务独立位，贴老库 Stop）。 */
    @Column(name = "is_stopped", nullable = false)
    private boolean stopped = false;

    @Column(name = "source_doc_no")
    private String sourceDocNo;

    /** 来源报价 UUID 真源；source_doc_no 仅为转换时的单号快照。 */
    @Column(name = "source_quote_id")
    private UUID sourceQuoteId;

    /** 发运策略：新单默认空（销售自选 ALLOW_PARTIAL/REQUIRE_COMPLETE）；CUSTOMER_CONFIRM/LEGACY 仅供历史单只读保留。 */
    @Column(name = "shipment_policy")
    private String shipmentPolicy;

    @Column(name = "partial_shipment_confirmed_at")
    private OffsetDateTime partialShipmentConfirmedAt;

    @Column(name = "partial_shipment_confirmed_by")
    private UUID partialShipmentConfirmedBy;

    @Column(name = "partial_shipment_confirmation_reason")
    private String partialShipmentConfirmationReason;

    /** 财务确认（V294）：已审订单须财务确认后才对计划部可见/可排产。 */
    @Column(name = "finance_confirmed", nullable = false)
    private boolean financeConfirmed = false;

    @Column(name = "finance_confirmed_at")
    private OffsetDateTime financeConfirmedAt;

    @Column(name = "finance_confirmed_by")
    private UUID financeConfirmedBy;

    @Column(name = "finance_confirm_remark")
    private String financeConfirmRemark;

    /** 财务驳回（V300）：不改订单状态/库存预留，只记事实+通知归属销售；确认时自动清除。 */
    @Column(name = "finance_rejected", nullable = false)
    private boolean financeRejected = false;

    @Column(name = "finance_rejected_reason")
    private String financeRejectedReason;

    @Column(name = "finance_rejected_by")
    private UUID financeRejectedBy;

    @Column(name = "finance_rejected_at")
    private OffsetDateTime financeRejectedAt;
}
