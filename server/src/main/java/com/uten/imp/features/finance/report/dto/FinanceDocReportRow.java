package com.uten.imp.features.finance.report.dto;

import lombok.AllArgsConstructor;
import lombok.Getter;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.UUID;

/**
 * 钱流单据明细行（E/G/M/O 报表，receipts/payments/expenses/incomes 主表 + 明细 + 主档 JOIN）。
 *
 * <p>{@code partyId} 由单据类型决定：receipt/income→clientId，payment/expense→supplierId。
 * {@code partyName} JOIN 客户/供应商补；{@code accountName} JOIN accounts。
 */
@Getter
@AllArgsConstructor
public class FinanceDocReportRow {
    private UUID id;
    private String billNo;
    private LocalDate billDate;
    private UUID partyId;
    private String partyName;
    private UUID accountId;
    private String accountName;
    private BigDecimal amountOriginal;
    private BigDecimal amountLocal;
    private Short status;
    private String remark;
}
