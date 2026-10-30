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
        boolean financeApproved, String orderType, List<MaterialLine> materials) {
    public ProcurementOrderPrintDocument {
        // Keep nullable/malformed values available to the owning boundary while
        // freezing the facts used by both JSON and the authorization digest.
        lines = lines == null ? null : java.util.Collections.unmodifiableList(new java.util.ArrayList<>(lines));
        materials = materials == null ? null : java.util.Collections.unmodifiableList(new java.util.ArrayList<>(materials));
    }

    /** 采购单没有委外物料; 空列表与 null 同义, 兼容既有采购调用点。 */
    public ProcurementOrderPrintDocument(UUID id, String billNo, LocalDate billDate, LocalDate deliverDate,
            String companyName, String companyPhone, String supplierName, String supplierContact,
            String supplierPhone, String deliveryPlace, String currencyName, String currencyCode,
            String settlementMethod, String totalOriginal, boolean priceMasked, String remark,
            String makerName, String reviewerName, String statusLabel, List<PrintLine> lines,
            boolean financeApproved, String orderType) {
        this(id, billNo, billDate, deliverDate, companyName, companyPhone, supplierName, supplierContact,
                supplierPhone, deliveryPlace, currencyName, currencyCode, settlementMethod, totalOriginal,
                priceMasked, remark, makerName, reviewerName, statusLabel, lines, financeApproved,
                orderType, List.of());
    }

    @com.fasterxml.jackson.annotation.JsonProperty(access=com.fasterxml.jackson.annotation.JsonProperty.Access.READ_ONLY)
    public String contentDigest() { return ProcurementPrintSnapshotDigest.of(this); }

    public record PrintLine(UUID id, Integer lineNo, String goodsCode, String goodsName,
            String model, String spec, String colorName, String unitName, String physicalQty,
            String chargedQty, String giftQty, String material, String remark, LocalDate deliverDate) { }

    /**
     * 委外订货单的直属物料行(2026-10-30 用户口径: 订货单要同时有委外成品与委外物料及对应关系)。
     * orderLineNo 指向成品行(对应关系); bomUnitQty=含损耗单耗(物料单位/成品单位),
     * requiredQty=我方需发总量(物料单位)。采购单恒为空。
     */
    public record MaterialLine(UUID orderItemId, Integer orderLineNo, String goodsCode, String goodsName,
            String colorName, String unitName, String bomUnitQty, String requiredQty) { }
}
