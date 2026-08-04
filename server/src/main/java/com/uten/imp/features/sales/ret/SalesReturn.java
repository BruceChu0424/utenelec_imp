package com.uten.imp.features.sales.ret;

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
 * 销售退货单主表（销售管理）。源 S_Withdraw（单号前缀 XT）。
 *
 * <p>V51/V90 历史审核（status 0→1）曾直接库存入库；V189 之后的新退货审核改为质量冻结，
 * 只有 GOOD_RELEASE 处置进入可售库存。审核仍双挂回写 sales_shipment_items.returned_qty/amount
 * 与 sales_order_items.returned_qty，并立红字应收（AR, SALES_RETURN, BStyle=18, 负应收）及重算结案。
 * ar_posted 为立帐标志。未处置的 V189 冻结可随原单受控反向；已发生处置时禁止整单普通红冲。
 *
 * <p>明细 amount 与主表 total 均为正数（design 20 §6.1/§7.3），红字负数仅在 ar_ap_ledger 立帐时取负。
 */
@Getter
@Setter
@NoArgsConstructor
@Entity
@Table(name = "sales_returns")
public class SalesReturn extends SoftDeletableEntity {

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

    @Column(name = "maker_id")
    private UUID makerId;

    @Column(name = "approver_id")
    private UUID approverId;

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

    /** 退货原因（销售退货专属，由销售录入；可为空）。 */
    @Column(name = "return_reason")
    private String returnReason;

    /** 应收红字已立帐标志（审核置 true，反审校验）。 */
    @Column(name = "ar_posted", nullable = false)
    private boolean arPosted = false;
}
