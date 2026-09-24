package com.uten.imp.features.sales.shipment.warehouse;

import com.uten.imp.audit.AuditDetailViewRecorder;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.features.sales.shipment.dto.WarehouseWorkTransitionRequest;
import jakarta.validation.Valid;
import org.springframework.format.annotation.DateTimeFormat;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import java.time.LocalDate;
import java.util.Map;
import java.util.UUID;

/** Warehouse-only sales outbound task API. */
@RestController
@RequestMapping("/api/warehouse/sales-outbound")
@PreAuthorize("hasAuthority('warehouse_sales_outbound:view')")
public class WarehouseSalesOutboundController {

    private final WarehouseSalesOutboundProjectionService service;
    private final AuditDetailViewRecorder auditViews;
    private final com.uten.imp.application.port.WarehouseTaskScopePort warehouseScopes;

    public WarehouseSalesOutboundController(
            WarehouseSalesOutboundProjectionService service,
            AuditDetailViewRecorder auditViews,
            com.uten.imp.application.port.WarehouseTaskScopePort warehouseScopes) {
        this.service = service;
        this.auditViews = auditViews;
        this.warehouseScopes = warehouseScopes;
    }

    @GetMapping
    public PageResponse<WarehouseSalesOutboundListItem> list(
            @RequestParam(required = false) String keyword,
            @RequestParam(required = false) String warehouseWorkStatus,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate dateFrom,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate dateTo,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "20") int size,
            @RequestParam(defaultValue = "") String warehouseScope,
            @RequestParam(required = false) UUID scopeWarehouseId) {
        // 仓库范围(ADR-115)：MINE = 我负责的仓库；scopeWarehouseId = 指定仓库(含子仓)。
        return service.list(keyword, warehouseWorkStatus, dateFrom, dateTo, page, size,
                warehouseScopes.resolve(warehouseScope, scopeWarehouseId));
    }

    /** 待出库任务计数（出库任务中心/工作台角标：未交接出库的放行单）。 */
    @GetMapping("/count")
    public Map<String, Long> pendingCount() {
        return Map.of("count", service.pendingCount());
    }

    /** 仓库作业状态分组计数(出库任务中心「销售出库」小类行: 待出库红徽章 / 已出库中性计数), 键为 warehouse_work_status. */
    @GetMapping("/counts")
    public Map<String, Long> counts() {
        return service.counts();
    }

    @GetMapping("/{id}")
    public WarehouseSalesOutboundDetail detail(@PathVariable UUID id) {
        WarehouseSalesOutboundDetail result = service.detail(id);
        auditViews.record(
                "view_sales_shipment_detail",
                "sales_shipments",
                id,
                result.billNo(),
                null,
                "销售出货单");
        return result;
    }

    @PostMapping("/{id}/warehouse-work")
    @PreAuthorize("hasAuthority('warehouse_sales_outbound:view') and hasAuthority('warehouse_sales_outbound:execute')")
    public WarehouseSalesOutboundDetail warehouseWork(
            @PathVariable UUID id,
            @Valid @RequestBody WarehouseWorkTransitionRequest request) {
        return service.transition(id, request);
    }
}
