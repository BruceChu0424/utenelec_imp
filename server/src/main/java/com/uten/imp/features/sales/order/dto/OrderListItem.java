package com.uten.imp.features.sales.order.dto;

import lombok.AllArgsConstructor;
import lombok.Getter;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.UUID;

/** 销售订货列表项。 */
@Getter
@AllArgsConstructor
public class OrderListItem {
    private UUID id;
    private String billNo;
    private LocalDate billDate;
    private UUID clientId;
    private UUID currencyId;
    private BigDecimal totalLocal;
    private Short status;
    private boolean closed;
    private boolean stopped;
    private Integer legacyId;
}
