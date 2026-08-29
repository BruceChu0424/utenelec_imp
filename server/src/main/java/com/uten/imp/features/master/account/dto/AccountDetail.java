package com.uten.imp.features.master.account.dto;

import lombok.AllArgsConstructor;
import lombok.Getter;

import java.math.BigDecimal;
import java.util.UUID;

/**
 * 账户详情（扁平主档，与列表项同字段，保留独立 DTO 与基础资料范式对齐）。
 */
@Getter
@AllArgsConstructor
public class AccountDetail {
    private UUID id;
    private Integer legacyId;
    private String code;
    private String name;
    private String bankAccountNo;
    private String accountType;
    private UUID currencyId;
    private String currencyCode;
    private String currencyName;
    private BigDecimal exchangeRate;
    private boolean baseCurrency;
    private BigDecimal initBalance;
    private BigDecimal receiptsTotal;
    private BigDecimal paymentsTotal;
    private BigDecimal adjustmentsTotal;
    private BigDecimal balanceCurrent;
    private BigDecimal balanceFloor;
    private String initBalanceText;
    private String receiptsTotalText;
    private String paymentsTotalText;
    private String adjustmentsTotalText;
    private String balanceCurrentText;
    private String balanceFloorText;
    private String exchangeRateText;
    private Integer parentLegacyId;
    private Integer styleLegacyId;
    private UUID styleId;
    private String status;
    private boolean autoCreated;
    /** Native-currency balance rebuilt from active append-only account flows. */
    private BigDecimal flowBalance;
    private BigDecimal balanceDifference;
    private String flowBalanceText;
    private String balanceDifferenceText;
    private Boolean flowIntegrity;
    private Long activeFlowCount;
    private String latestFlowAt;
}
