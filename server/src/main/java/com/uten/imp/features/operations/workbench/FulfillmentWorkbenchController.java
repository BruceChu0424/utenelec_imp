package com.uten.imp.features.operations.workbench;

import com.uten.imp.application.port.WarehouseTaskScopePort;
import java.time.LocalDate;
import java.util.UUID;
import java.util.Map;
import lombok.RequiredArgsConstructor;
import org.springframework.format.annotation.DateTimeFormat;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

/** 履约工作台接口（/api/operations/workbench）：仓库备料 / 采购 / 委外任务聚合视图。 */
@RestController
@RequestMapping("/api/operations/workbench")
@RequiredArgsConstructor
public class FulfillmentWorkbenchController {

    private final FulfillmentWorkbenchQueryService queryService;
    private final WarehouseTaskScopePort warehouseScopes;

    @GetMapping("/warehouse")
    @PreAuthorize("hasAnyAuthority('stock_doc:view')")
    public FulfillmentWorkbenchPage warehouse(
            @RequestParam(defaultValue = "") String status,
            @RequestParam(defaultValue = "") String exception,
            @RequestParam(defaultValue = "") String keyword,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate dateFrom,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate dateTo,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "50") int size,
            @RequestParam(defaultValue = "") String sort,
            @RequestParam(defaultValue = "asc") String order,
            @RequestParam(defaultValue = "") String warehouseScope,
            @RequestParam(required = false) UUID scopeWarehouseId) {
        // 生产领料任务中心表头排序(2026-09-24): 不传 sort 保持原排序(需求日期), 传了走白名单字段。
        FulfillmentWorkbenchTableQuery table = sort.isBlank() ? null
                : new FulfillmentWorkbenchTableQuery(sort, order, Map.of(), null, null, null, null);
        // 仓库范围(ADR-115): MINE = 我负责的仓库; scopeWarehouseId = 指定仓库(含子仓)。
        return queryService.query("WAREHOUSE", status, keyword, exception, dateFrom, dateTo, page, size, table,
                warehouseScopes.resolve(warehouseScope, scopeWarehouseId));
    }

    @GetMapping("/warehouse/count")
    @PreAuthorize("hasAuthority('stock_doc:view')")
    public Map<String, Long> warehouseCount() {
        return counts("WAREHOUSE");
    }

    /** 领料任务分状态计数（任务中心子分类徽章；待完成=READY+PARTIAL）。 */
    @GetMapping("/warehouse/status-breakdown")
    @PreAuthorize("hasAuthority('stock_doc:view')")
    public Map<String, Long> warehouseStatusBreakdown(
            @RequestParam(defaultValue = "") String warehouseScope,
            @RequestParam(required = false) UUID scopeWarehouseId) {
        return queryService.warehouseStatusBreakdown(warehouseScopes.resolve(warehouseScope, scopeWarehouseId));
    }

    @GetMapping("/purchase")
    @PreAuthorize("hasAnyAuthority('purchase_request:view','purchase_order:view','purchase_receipt:view','purchase_return:view')")
    public FulfillmentWorkbenchPage purchase(
            @RequestParam(defaultValue = "") String status,
            @RequestParam(defaultValue = "") String exception,
            @RequestParam(defaultValue = "") String keyword,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate dateFrom,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate dateTo,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "50") int size,
            @RequestParam(defaultValue = "needDate") String sort,
            @RequestParam(defaultValue = "asc") String order,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate issuedFrom,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate issuedTo,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate needFrom,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate needTo,
            @RequestParam Map<String, String> params) {
        return queryService.query("PURCHASE", status, keyword, exception, dateFrom, dateTo, page, size,
                FulfillmentWorkbenchTableQuery.from(sort, order, params, issuedFrom, issuedTo, needFrom, needTo));
    }

    @GetMapping("/purchase/count")
    @PreAuthorize("hasAnyAuthority('purchase_request:view','purchase_order:view','purchase_receipt:view','purchase_return:view')")
    public Map<String, Long> purchaseCount() {
        return counts("PURCHASE");
    }

    @GetMapping("/subcontract")
    @PreAuthorize("hasAnyAuthority('subcontract_inquiry:view','subcontract_application:view','subcontract_order:view','subcontract_receipt:view','subcontract_material_issue:view','subcontract_return:view','subcontract_material_return:view','subcontract_waste:view')")
    public FulfillmentWorkbenchPage subcontract(
            @RequestParam(defaultValue = "") String status,
            @RequestParam(defaultValue = "") String exception,
            @RequestParam(defaultValue = "") String keyword,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate dateFrom,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate dateTo,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "50") int size,
            @RequestParam(defaultValue = "needDate") String sort,
            @RequestParam(defaultValue = "asc") String order,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate issuedFrom,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate issuedTo,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate needFrom,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate needTo,
            @RequestParam Map<String, String> params) {
        return queryService.query("SUBCONTRACT", status, keyword, exception, dateFrom, dateTo, page, size,
                FulfillmentWorkbenchTableQuery.from(sort, order, params, issuedFrom, issuedTo, needFrom, needTo));
    }

    @GetMapping("/subcontract/count")
    @PreAuthorize("hasAnyAuthority('subcontract_application:view','subcontract_order:view')")
    public Map<String, Long> subcontractCount() {
        return counts("SUBCONTRACT");
    }

    /**
     * 任务中心角标：pending = 等本部门动手的单据数(红)，inProgress = 已经在办、
     * 现在不用本部门动手的单据数(黄，ADR-100)。仓库备料没有在办态，inProgress 恒 0。
     *
     * <p>count 是 pending 的旧键名：仓库任务中心的角标仍按这个键读，
     * 两个键同值，不是两个口径。
     */
    private Map<String, Long> counts(String department) {
        long pending = queryService.countPending(department);
        return Map.of(
                "count", pending,
                "pending", pending,
                "inProgress", queryService.countInProgress(department));
    }
}
