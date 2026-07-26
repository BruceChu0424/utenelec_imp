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

    /** 老库 PStyle → payment_styles（V50 后改 UUID FK，本期留 INT 占位）。 */
    @Column(name = "payment_style_id")
    private Integer paymentStyleId;

    @Column(name = "seller_id")
    private UUID sellerId;

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
}
