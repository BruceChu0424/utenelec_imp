package com.uten.imp.features.sales.other_shipment.dto;

import java.time.LocalDate;
import java.util.UUID;

/** 其它出货列表查询条件。billNo=单据号表头值筛选（2026-09-25 单号列统一，精确匹配）。 */
public record OtherShipmentQueryFilter(
        String keyword,
        UUID clientId,
        UUID warehouseId,
        String outType,
        Short status,
        LocalDate dateFrom,
        LocalDate dateTo,
        String billNo,
        boolean includeDeleted, boolean onlyDeleted) {
    public OtherShipmentQueryFilter(
        String keyword,
        UUID clientId,
        UUID warehouseId,
        String outType,
        Short status,
        LocalDate dateFrom,
        LocalDate dateTo,
        String billNo) { this(keyword, clientId, warehouseId, outType, status, dateFrom, dateTo, billNo, false, false); }
    public OtherShipmentQueryFilter withHistory(boolean includeDeleted, boolean onlyDeleted) {
        return new OtherShipmentQueryFilter(keyword, clientId, warehouseId, outType, status, dateFrom, dateTo, billNo, includeDeleted || onlyDeleted, onlyDeleted);
    }


    /** 兼容旧签名（无单号筛选）。 */
    public OtherShipmentQueryFilter(
            String keyword, UUID clientId, UUID warehouseId, String outType, Short status,
            LocalDate dateFrom, LocalDate dateTo) {
        this(keyword, clientId, warehouseId, outType, status, dateFrom, dateTo, null);
    }
}
