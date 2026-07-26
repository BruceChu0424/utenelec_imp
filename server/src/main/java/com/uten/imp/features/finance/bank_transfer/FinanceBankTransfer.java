package com.uten.imp.features.finance.bank_transfer;

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
 * 银行存取款单主表（钱流管理）。源老库 M_Bank（0 行空结构）+ M_BankItem（0 行）。
 *
 * <p>保未来：跨币种换算核销是老库最复杂触发器之一（{@code TRI_BankItem}），
 * 现仅 CRUD 骨架；启用时审核逻辑需实现：游标多行存款账户，每个 in_account 累加（含跨币种换算）、
 * out_account 扣减，写 finance_reconciliations(source_doc_type=BANK_TRANSFER)。
 *
 * <p>详见 design doc 26 §4.7。
 */
@Getter
@Setter
@NoArgsConstructor
@Entity
@Table(name = "finance_bank_transfers")
public class FinanceBankTransfer extends SoftDeletableEntity {

    @Column(name = "legacy_id", unique = true)
    private Integer legacyId;             // M_Bank.ID（老库 0 行）

    @Column(name = "bill_no", nullable = false)
    private String billNo;                // YC 前缀（推测）

    @Column(name = "bill_date", nullable = false)
    private LocalDate billDate;

    @Column(name = "out_account_id")
    private UUID outAccountId;            // OutAcc 取款账户

    @Column(name = "currency_id")
    private UUID currencyId;

    @Column(name = "exchange_rate", precision = 18, scale = 6)
    private BigDecimal exchangeRate = BigDecimal.ONE;

    @Column(name = "amount_original", precision = 18, scale = 4)
    private BigDecimal amountOriginal = BigDecimal.ZERO;

    @Column(name = "amount_local", precision = 18, scale = 4)
    private BigDecimal amountLocal = BigDecimal.ZERO;

    @Column(name = "invoice_no")
    private String invoiceNo;             // InvoicesNo（关联支票号）

    @Column(name = "operator_id")
    private UUID operatorId;              // WorkID 经办人

    @Column(name = "maker_id")
    private UUID makerId;

    @Column(name = "approver_id")
    private UUID approverId;

    private String remark;

    @Column(nullable = false)
    private Short status = 0;

    @Column(name = "is_closed", nullable = false)
    private boolean closed = false;
}
