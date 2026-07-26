package com.uten.imp.features.sales.shipment.dto;

import lombok.AllArgsConstructor;
import lombok.Getter;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.UUID;

/** 销售出货列表项。 */
@Getter
@AllArgsConstructor
public class ShipmentListItem {
    private UUID id;
    private String billNo;
    private LocalDate billDate;
    private UUID clientId;
    private UUID warehouseId;
    private BigDecimal totalLocal;
    private Short status;
    private boolean closed;
    private boolean arPosted;
    private Integer legacyId;
}
