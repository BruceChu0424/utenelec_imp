package com.uten.imp.features.sales.shipment.dto;

import com.uten.imp.application.port.WarehouseTaskScopePort.WarehouseTaskScope;

import java.time.LocalDate;
import java.util.UUID;

/**
 * 销售出货列表查询条件。currencyId=按币种筛选（2026-09-16 表头筛选，客户零星发货段共用本筛选）。
 *
 * <p>stage（2026-09-20 列表分段口径）：出货单的 {@code status} 只在仓库确认出库时才变 1，
 * 财审前后的全部中间态都是 status=0，按 status 分段会把「等待财务审核」「财务已放行待出库」
 * 整体归到草稿。列表改按真实阶段过滤：
 * DRAFT 销售未确认 / PENDING_FINANCE 等待财务审核 / FINANCE_REJECTED 财务已退回 /
 * FINANCE_APPROVED 财务已放行待出库 / SHIPPED 已出库 / REVERSED 红冲；空=不按阶段过滤。
 *
 * <p>warehouseScope：仓库任务中心「销售出库」的仓库范围(ADR-115 我的仓库/指定仓库)，表头仓或任一
 * 明细拣货仓落在范围内即算；其它列表不传(= 不过滤)。
 */
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
        UUID currencyId,
        String stage,
        WarehouseTaskScope warehouseScope) {
    public ShipmentQueryFilter {
        warehouseScope = warehouseScope == null ? WarehouseTaskScope.ALL : warehouseScope;
    }

    /** 兼容旧调用：不按仓库范围过滤。 */
    public ShipmentQueryFilter(String keyword,UUID clientId,UUID warehouseId,Short status,Boolean arPosted,
            Short financeAudit,Boolean financeRejected,String warehouseWorkStatus,
            LocalDate dateFrom,LocalDate dateTo,String shipmentKind,UUID currencyId,String stage) {
        this(keyword,clientId,warehouseId,status,arPosted,financeAudit,financeRejected,
                warehouseWorkStatus,dateFrom,dateTo,shipmentKind,currencyId,stage,WarehouseTaskScope.ALL);
    }
    /** 兼容旧调用：不按退回标记过滤。 */
    public ShipmentQueryFilter(String keyword,UUID clientId,UUID warehouseId,Short status,Boolean arPosted,
            Short financeAudit,String warehouseWorkStatus,LocalDate dateFrom,LocalDate dateTo) {
        this(keyword,clientId,warehouseId,status,arPosted,financeAudit,null,warehouseWorkStatus,dateFrom,dateTo,null,null,null);
    }
    /** 兼容旧调用：无 currencyId。 */
    public ShipmentQueryFilter(String keyword,UUID clientId,UUID warehouseId,Short status,Boolean arPosted,
            Short financeAudit,Boolean financeRejected,String warehouseWorkStatus,
            LocalDate dateFrom,LocalDate dateTo,String shipmentKind) {
        this(keyword,clientId,warehouseId,status,arPosted,financeAudit,financeRejected,
                warehouseWorkStatus,dateFrom,dateTo,shipmentKind,null,null);
    }
    /** 兼容旧调用：无 stage。 */
    public ShipmentQueryFilter(String keyword,UUID clientId,UUID warehouseId,Short status,Boolean arPosted,
            Short financeAudit,Boolean financeRejected,String warehouseWorkStatus,
            LocalDate dateFrom,LocalDate dateTo,String shipmentKind,UUID currencyId) {
        this(keyword,clientId,warehouseId,status,arPosted,financeAudit,financeRejected,
                warehouseWorkStatus,dateFrom,dateTo,shipmentKind,currencyId,null);
    }
}
