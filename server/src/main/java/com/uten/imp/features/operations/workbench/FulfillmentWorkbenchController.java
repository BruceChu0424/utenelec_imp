package com.uten.imp.features.operations.workbench;

import java.time.LocalDate;
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

    @GetMapping("/warehouse")
    @PreAuthorize("hasAnyAuthority('stock_doc:view')")
    public FulfillmentWorkbenchPage warehouse(
            @RequestParam(defaultValue = "") String status,
            @RequestParam(defaultValue = "") String exception,
            @RequestParam(defaultValue = "") String keyword,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate dateFrom,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate dateTo,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "50") int size) {
        return queryService.query("WAREHOUSE", status, keyword, exception, dateFrom, dateTo, page, size);
    }

    @GetMapping("/warehouse/count")
    @PreAuthorize("hasAuthority('stock_doc:view')")
    public Map<String, Long> warehouseCount() {
        return Map.of("count", queryService.countPending("WAREHOUSE"));
    }

    /** 领料任务分状态计数（任务中心子分类徽章；待完成=READY+PARTIAL）。 */
    @GetMapping("/warehouse/status-breakdown")
    @PreAuthorize("hasAuthority('stock_doc:view')")
    public Map<String, Long> warehouseStatusBreakdown() {
        return queryService.warehouseStatusBreakdown();
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
            @RequestParam(defaultValue = "50") int size) {
        return queryService.query("PURCHASE", status, keyword, exception, dateFrom, dateTo, page, size);
    }

    @GetMapping("/purchase/count")
    @PreAuthorize("hasAnyAuthority('purchase_request:view','purchase_order:view','purchase_receipt:view','purchase_return:view')")
    public Map<String, Long> purchaseCount() {
        return Map.of("count", queryService.countPending("PURCHASE"));
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
        return Map.of("count", queryService.countPending("SUBCONTRACT"));
    }
}
