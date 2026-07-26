package com.uten.imp.features.finance.report.dto;

import lombok.AllArgsConstructor;
import lombok.Getter;

import java.math.BigDecimal;
import java.time.OffsetDateTime;
import java.util.UUID;

/**
 * 账户流水对账行（S 报表，finance_reconciliations 滚动余额）。
 *
 * <p>{@code runningBalance} 按账户时序累加 in_amount − out_amount。
 */
@Getter
@AllArgsConstructor
public class AccountStatementRow {
    private UUID id;
    private OffsetDateTime billDate;
    private String billNo;
    private String sourceDocType;
    private String counterpartName;
    private String checkNo;
    private BigDecimal inAmount;
    private BigDecimal outAmount;
    private BigDecimal runningBalance;
}
