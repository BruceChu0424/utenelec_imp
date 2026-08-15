package com.uten.imp.features.finance.other_income;

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
 * 其它收入单主表（钱流管理）。源老库 M_OGet（1,552 行）+ M_OGetItem（1,551 行）。与 {@code FinanceExpense} 对称。
 *
 * <p>审核（0→1）：累加账户余额（{@code balance_current += amount_local, receipts_total += amount_local}）+
 * 写 finance_reconciliations(source_doc_type=INCOME, in_amount=amount_local)。不涉 AR/AP。
 */
@Getter
@Setter
@NoArgsConstructor
@Entity
@Table(name = "finance_other_incomes")
public class FinanceOtherIncome extends SoftDeletableEntity {

    @Column(name = "legacy_id", unique = true)
    private Integer legacyId;             // M_OGet.ID

    @Column(name = "bill_no", nullable = false)
    private String billNo;                // QS 前缀

    @Column(name = "bill_date", nullable = false)
    private LocalDate billDate;           // GetDate

    @Column(name = "account_id")
    private UUID accountId;               // RecAcc 收款账户

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

    @Column(name = "receipt_method_id")
    private UUID receiptMethodId;

    @Column(name = "receipt_method_legacy_id")
    private Integer receiptMethodLegacyId;

    @Column(name = "operator_id")
    private UUID operatorId;

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

    private String remark;

    @Column(nullable = false)
    private Short status = 0;

    @Column(name = "is_closed", nullable = false)
    private boolean closed = false;
}
