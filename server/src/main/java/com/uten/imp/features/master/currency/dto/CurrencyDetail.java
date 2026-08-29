package com.uten.imp.features.master.currency.dto;

import lombok.AllArgsConstructor;
import lombok.Getter;

import java.math.BigDecimal;
import java.util.UUID;

/**
 * 币种详情（扁平主档，与列表项同字段，保留独立 DTO 与基础资料范式对齐）。
 */
@Getter
@AllArgsConstructor
public class CurrencyDetail {
    private UUID id;
    private String code;
    private String name;
    private BigDecimal exchangeRate;
    private boolean baseCurrency;
    private String status;
    private Integer legacyId;
}
