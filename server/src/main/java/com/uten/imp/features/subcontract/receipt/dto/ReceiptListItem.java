package com.uten.imp.features.subcontract.receipt.dto;

import lombok.AllArgsConstructor;
import lombok.Getter;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.UUID;

/** 委外进仓单列表项。 */
@Getter
@AllArgsConstructor
public class ReceiptListItem {
    private UUID id;
    private String billNo;
    private LocalDate billDate;
    private UUID supplierId;
    private UUID warehouseId;
    private BigDecimal totalLocal;
    private Short status;
    private boolean closed;
    private boolean apPosted;
    private Integer legacyId;
}
