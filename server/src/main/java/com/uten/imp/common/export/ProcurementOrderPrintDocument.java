package com.uten.imp.common.export;

import java.time.LocalDate;
import java.util.List;
import java.util.UUID;

/** Supplier-facing immutable facts; finance approval is a displayed fact, not permission to export. */
public record ProcurementOrderPrintDocument(UUID id, String billNo, LocalDate billDate, LocalDate deliverDate,
        String companyName, String companyPhone, String supplierName, String supplierContact,
        String supplierPhone, String deliveryPlace, String currencyName, String currencyCode,
        String settlementMethod, String totalOriginal, boolean priceMasked, String remark,
        String makerName, String reviewerName, String statusLabel, List<PrintLine> lines,
        boolean financeApproved, String orderType) {
    public ProcurementOrderPrintDocument {
        // Keep nullable/malformed values available to the owning boundary while
        // freezing the facts used by both JSON and the authorization digest.
        lines = lines == null ? null : java.util.Collections.unmodifiableList(new java.util.ArrayList<>(lines));
    }

    @com.fasterxml.jackson.annotation.JsonProperty(access=com.fasterxml.jackson.annotation.JsonProperty.Access.READ_ONLY)
    public String contentDigest() { return ProcurementPrintSnapshotDigest.of(this); }

    public record PrintLine(UUID id, Integer lineNo, String goodsCode, String goodsName,
            String model, String spec, String colorName, String unitName, String physicalQty,
            String chargedQty, String giftQty, String material, String remark, LocalDate deliverDate) { }
}
