package com.uten.imp.features.finance.payment;

import com.uten.imp.common.domain.BaseEntity;
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
 * 采购付款核销明细。源老库 M_out 中 BStyle=21 行（DIRECT_PAYMENT）。
 *
 * <p>每行 = 一次核销一笔 AP。{@code applied_ledger_id} 显式指向 {@code ar_ap_ledger.id}（AP 行）。
 */
@Getter
@Setter
@NoArgsConstructor
@Entity
@Table(name = "finance_payment_lines")
public class FinancePaymentLine extends BaseEntity {

    private Integer legacyId;                          // M_out.ID（仅 DIRECT_PAYMENT 行）

    @Column(name = "payment_id", nullable = false)
    private UUID paymentId;

    @Column(name = "bill_no", nullable = false)
    private String billNo;

    @Column(name = "bill_date", nullable = false)
    private LocalDate billDate;

    /** 核销的 AP 行（显式关联）。 */
    @Column(name = "applied_ledger_id")
    private UUID appliedLedgerId;

    /** 老库 Purc_ID 核销立帐单号（前缀 CJ 或 EJ）。 */
    @Column(name = "applied_bill_no")
    private String appliedBillNo;

    @Column(name = "supplier_id")
    private UUID supplierId;

    @Column(name = "line_no")
    private Integer lineNo;

    @Column(name = "amount_original", nullable = false, precision = 18, scale = 4)
    private BigDecimal amountOriginal;     // NowPaid 本次付款（原币）

    @Column(name = "amount_local", nullable = false, precision = 18, scale = 4)
    private BigDecimal amountLocal;        // CNPaid 本次核销（本币）

    @Column(name = "exchange_diff", precision = 18, scale = 4)
    private BigDecimal exchangeDiff = BigDecimal.ZERO;

    private String remark;
}
