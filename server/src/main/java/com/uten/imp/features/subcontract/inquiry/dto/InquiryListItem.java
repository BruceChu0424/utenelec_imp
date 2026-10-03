package com.uten.imp.features.subcontract.inquiry.dto;

import lombok.AllArgsConstructor;
import lombok.Getter;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.UUID;

/** 委外询价单列表项。 */
@Getter
@AllArgsConstructor
public class InquiryListItem extends com.uten.imp.common.history.DocumentHistoryMetadata {
    private UUID id;
    private String billNo;
    private LocalDate billDate;
    private UUID supplierId;
    private UUID warehouseId;
    private BigDecimal totalLocal;
    private Short status;
    private boolean closed;
    private Integer legacyId;
    private boolean priceMasked;

    @Override public void disableHistoryActions() {
    }
}
