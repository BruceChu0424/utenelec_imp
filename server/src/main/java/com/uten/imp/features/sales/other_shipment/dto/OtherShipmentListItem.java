package com.uten.imp.features.sales.other_shipment.dto;

import lombok.AllArgsConstructor;
import lombok.Getter;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.UUID;

/** 其它出货列表项。 */
@Getter
@AllArgsConstructor
public class OtherShipmentListItem {
    private UUID id;
    private String billNo;
    private LocalDate billDate;
    private UUID clientId;
    private UUID warehouseId;
    private String outType;
    private BigDecimal totalLocal;
    private Short status;
    private boolean closed;
    private Integer legacyId;
}
