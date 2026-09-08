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
    @com.fasterxml.jackson.annotation.JsonUnwrapped
    private final ShipmentWorkflowView workflow=new ShipmentWorkflowView();
    @com.fasterxml.jackson.annotation.JsonUnwrapped
    private final OriginalMoney money=new OriginalMoney();
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
    private boolean rejected;
    /** Current caller may mutate this document through normal sales actions. */
    private boolean writable;
    /** Current caller may reject this draft, including explicit reject-authority bypass. */
    private boolean canReject;
    private Short financeAudit;
    private Short financeGateVersion;
    private String warehouseWorkStatus;
    private boolean canManageWarehouseWork;

    @lombok.Getter @lombok.Setter
    public static class OriginalMoney {
        private UUID currencyId;
        private BigDecimal totalOriginal;
        public String getTotalOriginalExact() { return com.uten.imp.common.util.DecimalText.of(totalOriginal); }
    }
    public String getTotalLocalExact() { return com.uten.imp.common.util.DecimalText.of(totalLocal); }
}
