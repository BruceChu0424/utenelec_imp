package com.uten.imp.features.subcontract.material_return.dto;

import lombok.AllArgsConstructor;
import lombok.Getter;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.UUID;

/** 委外材料退货单列表项。 */
@Getter
@AllArgsConstructor
public class MaterialReturnListItem {
    private UUID id;
    private String billNo;
    private LocalDate billDate;
    private UUID supplierId;
    private UUID warehouseId;
    private BigDecimal totalLocal;
    private Short status;
    private boolean closed;
    private Integer legacyId;
}
