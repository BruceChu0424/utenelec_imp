package com.uten.imp.features.purchase.request.dto;

import lombok.AllArgsConstructor;
import lombok.Getter;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.UUID;

@Getter @AllArgsConstructor
public class RequestListItem {
    private UUID id;
    private String billNo;
    private LocalDate billDate;
    private UUID warehouseId;
    private BigDecimal totalLocal;
    private Short status;
    private boolean closed;
    private Integer legacyId;
}
