package com.uten.imp.features.sales.shipment.dto;

import java.time.LocalDate;
import java.util.UUID;

/** 销售出货列表查询条件。currencyId=按币种筛选（2026-09-16 表头筛选，客户零星发货段共用本筛选）。 */
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
        String shipmentKind,
        UUID currencyId) {
    /** 兼容旧调用：不按退回标记过滤。 */
    public ShipmentQueryFilter(String keyword,UUID clientId,UUID warehouseId,Short status,Boolean arPosted,
            Short financeAudit,String warehouseWorkStatus,LocalDate dateFrom,LocalDate dateTo) {
        this(keyword,clientId,warehouseId,status,arPosted,financeAudit,null,warehouseWorkStatus,dateFrom,dateTo,null,null);
    }

    /** 兼容旧调用：无 currencyId。 */
    public ShipmentQueryFilter(String keyword,UUID clientId,UUID warehouseId,Short status,Boolean arPosted,
            Short financeAudit,Boolean financeRejected,String warehouseWorkStatus,
            LocalDate dateFrom,LocalDate dateTo,String shipmentKind) {
        this(keyword,clientId,warehouseId,status,arPosted,financeAudit,financeRejected,
                warehouseWorkStatus,dateFrom,dateTo,shipmentKind,null);
    }
}
