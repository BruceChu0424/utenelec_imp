package com.uten.imp.features.warehouse.taskcenter;

import org.springframework.format.annotation.DateTimeFormat;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import java.time.LocalDate;
import java.util.UUID;

/** Read-only source union. Every original command keeps its original authorization. */
@RestController
@RequestMapping("/api/warehouse/task-center/outbound")
public class WarehouseOutboundTaskCenterController {
    private final WarehouseOutboundTaskCenterQueryService queries;

    public WarehouseOutboundTaskCenterController(WarehouseOutboundTaskCenterQueryService queries) {
        this.queries = queries;
    }

    @GetMapping
    @PreAuthorize("hasAnyAuthority('warehouse_sales_outbound:view','subcontract_outbound:view',"
            + "'warehouse_subcontract_outbound_history:view','stock_doc:view','workshop_material:view')")
    public WarehouseTaskCenterContracts.Page list(
            @RequestParam(defaultValue = "ALL") String source,
            @RequestParam(defaultValue = "ACTIVE") String view,
            @RequestParam(required = false) String status,
            @RequestParam(required = false) String keyword,
            @RequestParam(required = false) String billNo,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate dateFrom,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate dateTo,
            @RequestParam(required = false) UUID scopeWarehouseId,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "20") int size,
            @RequestParam(required = false) String sort,
            @RequestParam(required = false) String order) {
        return queries.list(new WarehouseTaskCenterContracts.Filter(source, status, keyword, billNo,
                dateFrom, dateTo, scopeWarehouseId, page, size, sort, order,
                WarehouseTaskCenterContracts.TaskView.requested(view)));
    }

    @GetMapping("/{rowKey}/detail")
    @PreAuthorize("hasAnyAuthority('warehouse_sales_outbound:view','subcontract_outbound:view',"
            + "'warehouse_subcontract_outbound_history:view','stock_doc:view','workshop_material:view')")
    public WarehouseOutboundTaskCenterQueryService.PhysicalDetail detail(
            @PathVariable String rowKey,
            @RequestParam(required = false) UUID scopeWarehouseId,
            @RequestParam(defaultValue = "1") int linePage,
            @RequestParam(defaultValue = "100") int lineSize) {
        return queries.detail(rowKey, scopeWarehouseId, linePage, lineSize);
    }
}
