package com.uten.imp.features.finance.reconciliation.dto;

import lombok.AllArgsConstructor;
import lombok.Getter;

import java.math.BigDecimal;
import java.time.OffsetDateTime;
import java.util.UUID;

/** 账户流水列表行（只读，要求 account:view + account:balance:view + account:flow:view）。 */
@Getter
@AllArgsConstructor
public class FinanceReconciliationListItem {
    private UUID id;
    private String billNo;
    private String sourceDocType;       // RECEIPT/PAYMENT/EXPENSE/INCOME/BANK_TRANSFER
    private UUID sourceDocId;
    private UUID accountId;
    private String checkNo;
    private String counterpartName;
    private BigDecimal inAmount;
    private BigDecimal outAmount;
    private OffsetDateTime billDate;
    private OffsetDateTime settledDate;
    private String sourceRemark;
    private Integer legacyBstyle;
    private String entryKind;
    private UUID reversalOfId;
}
