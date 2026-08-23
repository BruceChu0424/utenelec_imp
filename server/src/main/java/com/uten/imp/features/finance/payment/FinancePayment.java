package com.uten.imp.features.finance.payment;

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
 * 采购付款单主表（钱流管理）。源老库 M_Paid（4,545 行）。与 {@code FinanceReceipt} 完全对称
 * （Client↔Vend、receipt↔payment、AR↔AP、account_id 取 PaidAcc）。
 *
 * <p>审核（0→1）：核销 AP / 直接付款（建 DIRECT_PAYMENT 立帐行）/ 账户 {@code balance_current -= amount_local,
 * payments_total += amount_local} / 写 finance_reconciliations(source_doc_type=PAYMENT)。
 */
@Getter
@Setter
@NoArgsConstructor
@Entity
@Table(name = "finance_payments")
public class FinancePayment extends SoftDeletableEntity {

    @Column(name = "legacy_id", unique = true)
    private Integer legacyId;             // M_Paid.ID

    @Column(name = "bill_no", nullable = false)
    private String billNo;                // CF 前缀 = 直接付款

    @Column(name = "bill_date", nullable = false)
    private LocalDate billDate;           // PaidDate

    @Column(name = "supplier_id")
    private UUID supplierId;              // VendID

    @Column(name = "account_id")
    private UUID accountId;               // PaidAcc 付款账户

    @Column(name = "counterpart_account_id")
    private UUID counterpartAccountId;    // dfzh 对方账户

    @Column(name = "currency_id")
    private UUID currencyId;

    @Column(name = "exchange_rate", precision = 18, scale = 6)
    private BigDecimal exchangeRate = BigDecimal.ONE;

    @Column(name = "amount_original", precision = 18, scale = 4)
    private BigDecimal amountOriginal = BigDecimal.ZERO;

    @Column(name = "amount_local", precision = 18, scale = 4)
    private BigDecimal amountLocal = BigDecimal.ZERO;

    /** Version 1 means the current service recalculated every accounting amount. */
    @Column(name = "amount_authority_version", nullable = false)
    private short amountAuthorityVersion = 0;

    @Column(name = "payment_method_id")
    private UUID paymentMethodId;         // PaidStyle（暂不 FK）

    @Column(name = "payment_method_legacy_id")
    private Integer paymentMethodLegacyId;

    @Column(name = "invoice_no")
    private String invoiceNo;             // 发票号/支票号

    @Column(name = "cancel_date")
    private OffsetDateTime cancelDate;

    @Column(name = "operator_name")
    private String operatorName;          // jsr 经手人姓名（老库文本，非 FK）

    @Column(name = "operator_id")
    private UUID operatorId;              // 运行时录入（UUID）

    @Column(name = "operator_legacy_id")
    private Integer operatorLegacyId;

    @Column(name = "maker_id")
    private UUID makerId;

    @Column(name = "maker_legacy_id")
    private Integer makerLegacyId;

    @Column(name = "maker_name")
    private String makerName;

    @Column(name = "approver_id")
    private UUID approverId;

    @Column(name = "approver_legacy_id")
    private Integer approverLegacyId;

    @Column(name = "approver_name")
    private String approverName;

    @Column(name = "source_remark")
    private String sourceRemark;

    private String remark;

    @Column(nullable = false)
    private Short status = 0;

    /** 红冲时间：一次写入后由 V390 触发器锁定，月结/报表红冲事件日以此为准。 */
    @Column(name = "reversed_at")
    private OffsetDateTime reversedAt;

    @Column(name = "is_closed", nullable = false)
    private boolean closed = false;
}
