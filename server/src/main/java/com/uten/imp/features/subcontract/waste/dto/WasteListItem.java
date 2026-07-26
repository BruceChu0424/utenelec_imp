package com.uten.imp.features.subcontract.waste.dto;

import lombok.AllArgsConstructor;
import lombok.Getter;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.UUID;

/** 委外损耗单列表项。 */
@Getter
@AllArgsConstructor
public class WasteListItem {
    private UUID id;
    private String billNo;
    private LocalDate billDate;
    private UUID supplierId;
    private UUID warehouseId;
    private BigDecimal totalWeight;
    private BigDecimal totalLocal;
    private Short status;
    private boolean closed;
    private Integer legacyId;
}
