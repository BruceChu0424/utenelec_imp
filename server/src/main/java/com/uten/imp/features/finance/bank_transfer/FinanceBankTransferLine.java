package com.uten.imp.features.finance.bank_transfer;

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
 * 银行存取款明细。源老库 M_BankItem（0 行空结构）。每行 = 一个存款账户的存入动作。
 *
 * <p>跨币种换算（{@code OCRate/CRate}）由审核 Service 处理；当前仅保结构。
 */
@Getter
@Setter
@NoArgsConstructor
@Entity
@Table(name = "finance_bank_transfer_lines")
public class FinanceBankTransferLine extends BaseEntity {

    @Column(name = "transfer_id", nullable = false)
    private UUID transferId;

    @Column(name = "bill_no", nullable = false)
    private String billNo;

    @Column(name = "bill_date", nullable = false)
    private LocalDate billDate;

    /** AccID 存款账户。 */
    @Column(name = "in_account_id")
    private UUID inAccountId;

    /** FDate 发生日期。 */
    @Column(name = "occur_date")
    private LocalDate occurDate;

    /** CTotal（含跨币种换算 OCRate/CRate）。 */
    @Column(name = "amount_original", precision = 18, scale = 4)
    private BigDecimal amountOriginal;

    @Column(name = "amount_local", precision = 18, scale = 4)
    private BigDecimal amountLocal;

    @Column(name = "line_no")
    private Integer lineNo;

    private String summary;
}
