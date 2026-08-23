package com.uten.imp.features.finance.receipt;

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
 * 销售收款单主表（钱流管理）。源老库 M_Get（7,804 行）。
 *
 * <p>审核（status 0→1）触发 {@code FinanceReceiptService.settleReceipt}：
 * <ul>
 *   <li>若 lines 非空（指定核销 AR）：每行 UPDATE ar_ap_ledger.amount_settled += line.amount_local；</li>
 *   <li>若 lines 为空（直接收款）：调 {@link com.uten.imp.features.finance.arap.ArApLedgerService#postArAp}
 *       建 DIRECT_RECEIPT 立帐行（amount_original=0, settled=收款额, balance=负 = 客户预付）；</li>
 *   <li>账户 {@code accounts.balance_current/receipts_total} += amount_local；</li>
 *   <li>INSERT finance_reconciliations(source_doc_type=RECEIPT, in_amount=amount_local)；</li>
 *   <li>有 invoice_no（支票号）→ INSERT finance_check_register(source='收')。</li>
 * </ul>
 *
 * <p>红冲（1→-1）反向冲销（删核销累加 / 删 DIRECT_RECEIPT 行 / 回滚账户 / 删流水）。
 */
@Getter
@Setter
@NoArgsConstructor
@Entity
@Table(name = "finance_receipts")
public class FinanceReceipt extends SoftDeletableEntity {

    @Column(name = "legacy_id", unique = true)
    private Integer legacyId;            // M_Get.ID

    @Column(name = "bill_no", nullable = false)
    private String billNo;               // XS 前缀 = 直接收款

    @Column(name = "bill_date", nullable = false)
    private LocalDate billDate;          // GetDate

    @Column(name = "client_id")
    private UUID clientId;               // ClientID

    @Column(name = "receipt_kind", nullable = false)
    private String receiptKind;          // AR_SETTLEMENT / CUSTOMER_PREPAYMENT

    @Column(name = "sales_order_id")
    private UUID salesOrderId;           // optional exact order binding for customer prepayment

    @Column(name = "account_id")
    private UUID accountId;              // RecAcc 收款账户

    @Column(name = "counterpart_account_id")
    private UUID counterpartAccountId;   // dfch 对方账户

    @Column(name = "currency_id")
    private UUID currencyId;

    @Column(name = "exchange_rate", precision = 18, scale = 6)
    private BigDecimal exchangeRate = BigDecimal.ONE;

    @Column(name = "amount_original", precision = 18, scale = 4)
    private BigDecimal amountOriginal = BigDecimal.ZERO;   // MTotal 原币

    @Column(name = "amount_local", precision = 18, scale = 4)
    private BigDecimal amountLocal = BigDecimal.ZERO;      // Total 本币实收

    @Column(name = "bank_fee", precision = 18, scale = 4)
    private BigDecimal bankFee = BigDecimal.ZERO;          // slf 手续费

    @Column(name = "other_fee", precision = 18, scale = 4)
    private BigDecimal otherFee = BigDecimal.ZERO;         // qtfy 其它费用

    @Column(name = "other_fee_style_id")
    private UUID otherFeeStyleId;                          // qtfymc 其它费用项目

    @Column(name = "receipt_method_id")
    private UUID receiptMethodId;                          // RecStyle 收款方式（暂不 FK）

    @Column(name = "receipt_method_legacy_id")
    private Integer receiptMethodLegacyId;                 // RecStyle 老库 int 暂留

    @Column(name = "invoice_no")
    private String invoiceNo;                              // InvoicesNo 发票号/支票号

    @Column(name = "cancel_date")
    private OffsetDateTime cancelDate;                     // CancelDate 核销日期

    @Column(name = "operator_id")
    private UUID operatorId;                               // WorkID 经手人

    @Column(name = "operator_legacy_id")
    private Integer operatorLegacyId;

    @Column(name = "operator_name")
    private String operatorName;

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
    private String sourceRemark;                           // Source 来源备注

    private String remark;

    @Column(nullable = false)
    private Short status = 0;                              // 0草稿/1已审/-1红冲

    /** 红冲时间：一次写入后由 V390 触发器锁定，报表红冲事件日以此为准。 */
    @Column(name = "reversed_at")
    private OffsetDateTime reversedAt;

    @Column(name = "is_closed", nullable = false)
    private boolean closed = false;
}
