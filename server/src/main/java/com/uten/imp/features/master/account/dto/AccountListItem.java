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
    private BigDecimal initBalance;
    private BigDecimal receiptsTotal;
    private BigDecimal paymentsTotal;
    private BigDecimal balanceCurrent;
    private String status;
}
