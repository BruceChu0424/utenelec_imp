package com.uten.imp.features.subcontract.application.dto;

import lombok.AllArgsConstructor;
import lombok.Getter;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.UUID;

/** 委外申请单列表项。 */
@Getter
@AllArgsConstructor
public class ApplicationListItem extends com.uten.imp.common.history.DocumentHistoryMetadata {
    private UUID id;
    private String billNo;
    private LocalDate billDate;
    private UUID supplierId;
    private UUID warehouseId;
    private BigDecimal totalLocal;
    private Short status;
    private boolean closed;
    private Integer legacyId;

    @Override public void disableHistoryActions() {
    }
}
