package com.uten.imp.features.sales.other_shipment.dto;

import lombok.AllArgsConstructor;
import lombok.Getter;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.UUID;

/** 其它出货列表项。 */
@Getter
@AllArgsConstructor
public class OtherShipmentListItem extends com.uten.imp.common.history.DocumentHistoryMetadata {
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
    /** Current caller may mutate this document (functional permission + owner scope). */
    private boolean writable;
    @lombok.Setter
    private UUID currencyId;

    /** Existing Java callers retain the original constructor; currency is additional native list metadata. */
    public OtherShipmentListItem(UUID id, String billNo, LocalDate billDate, UUID clientId, UUID warehouseId,
            String outType, BigDecimal totalLocal, Short status, boolean closed, Integer legacyId, boolean writable) {
        this(id, billNo, billDate, clientId, warehouseId, outType, totalLocal, status, closed, legacyId, writable, null);
    }

    @Override public void disableHistoryActions() {
        writable = false;
    }
}
