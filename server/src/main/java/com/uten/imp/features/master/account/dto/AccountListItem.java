package com.uten.imp.features.master.account.dto;

import lombok.AllArgsConstructor;
import lombok.Getter;

import java.math.BigDecimal;
import java.util.UUID;

/** 账户列表项。 */
@Getter
@AllArgsConstructor
public class AccountListItem {
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
    private String status;
}
