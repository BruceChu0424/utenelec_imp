package com.uten.imp.features.finance.receipt;

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
 * 销售收款核销明细。源老库 M_in 中 BStyle=20 行（DIRECT_RECEIPT）；运行时核销行新库独有。
 *
 * <p>每行 = 一次核销一笔 AR。{@code applied_ledger_id} 显式指向 {@code ar_ap_ledger.id}。
 *
 * <p>明细随主表重建（update 时物理删旧 + 插新），继承 {@link BaseEntity}（id + 审计，无软删）。
 */
@Getter
@Setter
@NoArgsConstructor
@Entity
@Table(name = "finance_receipt_lines")
public class FinanceReceiptLine extends BaseEntity {

    private Integer legacyId;                       // M_in.ID（仅 DIRECT_RECEIPT 行有）

    @Column(name = "receipt_id", nullable = false)
    private UUID receiptId;

    @Column(name = "bill_no", nullable = false)
    private String billNo;

    @Column(name = "bill_date", nullable = false)
    private LocalDate billDate;

    /** 核销的 AR 行（显式关联；为 null 表示直接收款不指定核销，但本表行通常用于指定核销）。 */
    @Column(name = "applied_ledger_id")
    private UUID appliedLedgerId;

    /** 老库 SellID 核销立帐单号（XC*）。 */
    @Column(name = "applied_bill_no")
    private String appliedBillNo;

    @Column(name = "client_id")
    private UUID clientId;

    /** Actual receipt currency. Applied AR lines must use the AR currency. */
    @Column(name = "currency_id")
    private UUID currencyId;

    /** Receipt-date rate entered by finance; local amounts are server-derived. */
    @Column(name = "exchange_rate", precision = 18, scale = 6)
    private BigDecimal exchangeRate = BigDecimal.ONE;

    @Column(name = "line_no")
    private Integer lineNo;

    @Column(name = "amount_original", nullable = false, precision = 18, scale = 4)
    private BigDecimal amountOriginal;     // NowReceive 本次收款（原币）

    @Column(name = "amount_local", nullable = false, precision = 18, scale = 4)
    private BigDecimal amountLocal;        // CNReceive 本次核销（本币）

    /** Bank/other fee allocated to this AR, expressed in the AR currency. */
    @Column(name = "write_off_amount", precision = 18, scale = 4)
    private BigDecimal writeOffAmount = BigDecimal.ZERO;

    @Column(name = "write_off_local", precision = 18, scale = 4)
    private BigDecimal writeOffLocal = BigDecimal.ZERO;

    /** Carrying value removed from AR, using the recognition-date rate. */
    @Column(name = "applied_amount_local", precision = 18, scale = 4)
    private BigDecimal appliedAmountLocal = BigDecimal.ZERO;

    /** Approval-time snapshots used by historical reports. */
    @Column(name = "balance_before_original", precision = 18, scale = 4)
    private BigDecimal balanceBeforeOriginal;

    @Column(name = "balance_after_original", precision = 18, scale = 4)
    private BigDecimal balanceAfterOriginal;

    @Column(name = "exchange_diff", precision = 18, scale = 4)
    private BigDecimal exchangeDiff = BigDecimal.ZERO;  // RTotal 汇兑差

    private String remark;
}
