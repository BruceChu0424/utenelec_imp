package com.uten.imp.features.finance.expense;

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
 * 一般费用单主表（钱流管理）。源老库 M_DPaid（1,125 行）+ M_DPaidItem（8,537 行）。按部门分摊。
 *
 * <p>审核（0→1）：扣减账户余额（{@code balance_current -= amount_local, payments_total += amount_local}）+
 * 写 finance_reconciliations(source_doc_type=EXPENSE)。不涉 AR/AP 核销（费用不是应付账款）。
 * 取代老库 TRI_PaidItem 触发器。
 */
@Getter
@Setter
@NoArgsConstructor
@Entity
@Table(name = "finance_expenses")
public class FinanceExpense extends SoftDeletableEntity {

    @Column(name = "legacy_id", unique = true)
    private Integer legacyId;             // M_DPaid.ID

    @Column(name = "bill_no", nullable = false)
    private String billNo;                // YF 前缀

    @Column(name = "bill_date", nullable = false)
    private LocalDate billDate;           // PaidDate

    @Column(name = "account_id")
    private UUID accountId;               // PaidAcc 付款账户

    @Column(name = "counterpart_account_id")
    private UUID counterpartAccountId;    // dfzh 对方账户

    @Column(name = "currency_id")
    private UUID currencyId;

    @Column(name = "exchange_rate", precision = 18, scale = 6)
    private BigDecimal exchangeRate = BigDecimal.ONE;

    @Column(name = "amount_original", precision = 18, scale = 4)
    private BigDecimal amountOriginal = BigDecimal.ZERO;    // MTotal 原币

    @Column(name = "amount_local", precision = 18, scale = 4)
    private BigDecimal amountLocal = BigDecimal.ZERO;       // Total 本币

    @Column(name = "operator_id")
    private UUID operatorId;              // WorkID 经手人

    @Column(name = "maker_id")
    private UUID makerId;

    @Column(name = "approver_id")
    private UUID approverId;

    private String remark;

    @Column(nullable = false)
    private Short status = 0;

    @Column(name = "is_closed", nullable = false)
    private boolean closed = false;

    /** C6：0 未过账 / 1 已过账待财务确认 / 2 财务已确认。 */
    @Column(name = "gl_status", nullable = false)
    private Short glStatus = 0;

    @Column(name = "gl_voucher_id")
    private UUID glVoucherId;
}
