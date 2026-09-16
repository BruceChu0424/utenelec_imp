package com.uten.imp.features.sales.shipment.dto;

import java.time.LocalDate;
import java.util.UUID;

/** 销售出货列表查询条件。 */
public record ShipmentQueryFilter(
        String keyword,
        UUID clientId,
        UUID warehouseId,
        Short status,
        Boolean arPosted,
        Short financeAudit,
        Boolean financeRejected,
        String warehouseWorkStatus,
        LocalDate dateFrom,
        LocalDate dateTo,
        String shipmentKind) {
    /** 兼容旧调用：不按退回标记过滤。 */
    public ShipmentQueryFilter(String keyword,UUID clientId,UUID warehouseId,Short status,Boolean arPosted,
            Short financeAudit,String warehouseWorkStatus,LocalDate dateFrom,LocalDate dateTo) {
        this(keyword,clientId,warehouseId,status,arPosted,financeAudit,null,warehouseWorkStatus,dateFrom,dateTo,null);
    }
}
