package com.uten.imp.features.master.currency.dto;

import lombok.AllArgsConstructor;
import lombok.Getter;

import java.math.BigDecimal;
import java.util.UUID;

/**
 * 币种列表项。
 */
@Getter
@AllArgsConstructor
public class CurrencyListItem {
    private UUID id;
    private String code;
    private String name;
    private BigDecimal exchangeRate;
    private boolean baseCurrency;
    private String status;
    private Integer legacyId;
}
