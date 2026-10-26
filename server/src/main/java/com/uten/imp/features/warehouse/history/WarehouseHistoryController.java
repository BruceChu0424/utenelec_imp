package com.uten.imp.features.warehouse.history;

import com.uten.imp.audit.AuditDetailViewRecorder;
import com.uten.imp.common.web.PageResponse;
import org.springframework.format.annotation.DateTimeFormat;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import java.time.LocalDate;
import java.util.UUID;

/** Warehouse-only, amount-free history API. */
@RestController
@RequestMapping("/api/warehouse/document-history")
public class WarehouseHistoryController {

    private final WarehouseHistoryQueryService service;
    private final AuditDetailViewRecorder auditViews;

    public WarehouseHistoryController(
            WarehouseHistoryQueryService service,
            AuditDetailViewRecorder auditViews) {
        this.service = service;
        this.auditViews = auditViews;
    }

    @GetMapping("/purchase-receipts")
    @PreAuthorize("hasAuthority('" + WarehouseHistoryPermissions.PURCHASE_RECEIPT_VIEW + "')")
    public PageResponse<WarehouseHistoryListItem> purchaseReceipts(
            @RequestParam(required = false) String keyword,
            @RequestParam(required = false) Short status,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate dateFrom,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate dateTo,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "20") int size,
            @RequestParam(required = false) String sort,
            @RequestParam(required = false) String order,
            @RequestParam(required = false) String billNo,
            @RequestParam(required = false) String sourceDocNo,
            @RequestParam(required = false) UUID scopeWarehouseId) {
        // 2026-09-25 单号列统一：sort/order 表头排序 + 单据号/来源单据号表头值筛选。
        return service.list(WarehouseHistoryType.PURCHASE_RECEIPT, keyword, status, dateFrom, dateTo, page, size,
                sort, order, billNo, sourceDocNo, scopeWarehouseId);
    }

    @GetMapping("/purchase-receipts/{id}")
    @PreAuthorize("hasAuthority('" + WarehouseHistoryPermissions.PURCHASE_RECEIPT_VIEW + "')")
    public WarehouseHistoryDetail purchaseReceipt(@PathVariable UUID id,
            @RequestParam(required = false) UUID scopeWarehouseId) {
        WarehouseHistoryDetail result = service.detail(WarehouseHistoryType.PURCHASE_RECEIPT, id, scopeWarehouseId);
        auditViews.record(
                "view_purchase_receipt_detail",
                "purchase_receipts",
                id,
                result.billNo(),
                null,
                "采购收货单");
        return result;
    }

    @GetMapping("/subcontract-receipts")
    @PreAuthorize("hasAuthority('" + WarehouseHistoryPermissions.SUBCONTRACT_RECEIPT_VIEW + "')")
    public PageResponse<WarehouseHistoryListItem> subcontractReceipts(
            @RequestParam(required = false) String keyword,
            @RequestParam(required = false) Short status,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate dateFrom,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate dateTo,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "20") int size,
            @RequestParam(required = false) String sort,
            @RequestParam(required = false) String order,
            @RequestParam(required = false) String billNo,
            @RequestParam(required = false) String sourceDocNo,
            @RequestParam(required = false) UUID scopeWarehouseId) {
        // 2026-09-25 单号列统一：sort/order 表头排序 + 单据号/来源单据号表头值筛选。
        return service.list(WarehouseHistoryType.SUBCONTRACT_RECEIPT, keyword, status, dateFrom, dateTo, page, size,
                sort, order, billNo, sourceDocNo, scopeWarehouseId);
    }

    @GetMapping("/subcontract-receipts/{id}")
    @PreAuthorize("hasAuthority('" + WarehouseHistoryPermissions.SUBCONTRACT_RECEIPT_VIEW + "')")
    public WarehouseHistoryDetail subcontractReceipt(@PathVariable UUID id,
            @RequestParam(required = false) UUID scopeWarehouseId) {
        WarehouseHistoryDetail result = service.detail(WarehouseHistoryType.SUBCONTRACT_RECEIPT, id, scopeWarehouseId);
        auditViews.record(
                "view_subcontract_receipt_detail",
                "subcontract_receipts",
                id,
                result.billNo(),
                null,
                "委外进仓单");
        return result;
    }

    @GetMapping("/subcontract-material-issues")
    @PreAuthorize("hasAuthority('" + WarehouseHistoryPermissions.SUBCONTRACT_MATERIAL_ISSUE_VIEW + "')")
    public PageResponse<WarehouseHistoryListItem> subcontractMaterialIssues(
            @RequestParam(required = false) String keyword,
            @RequestParam(required = false) Short status,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate dateFrom,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate dateTo,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "20") int size,
            @RequestParam(required = false) String sort,
            @RequestParam(required = false) String order,
            @RequestParam(required = false) String billNo,
            @RequestParam(required = false) String sourceDocNo,
            @RequestParam(required = false) UUID scopeWarehouseId) {
        // 2026-09-25 单号列统一：sort/order 表头排序 + 单据号/来源单据号表头值筛选。
        return service.list(WarehouseHistoryType.SUBCONTRACT_MATERIAL_ISSUE, keyword, status, dateFrom, dateTo, page, size,
                sort, order, billNo, sourceDocNo, scopeWarehouseId);
    }

    @GetMapping("/subcontract-material-issues/{id}")
    @PreAuthorize("hasAuthority('" + WarehouseHistoryPermissions.SUBCONTRACT_MATERIAL_ISSUE_VIEW + "')")
    public WarehouseHistoryDetail subcontractMaterialIssue(@PathVariable UUID id,
            @RequestParam(required = false) UUID scopeWarehouseId) {
        WarehouseHistoryDetail result = service.detail(
                WarehouseHistoryType.SUBCONTRACT_MATERIAL_ISSUE, id, scopeWarehouseId);
        auditViews.record(
                "view_subcontract_material_issue_detail",
                "subcontract_material_issues",
                id,
                result.billNo(),
                null,
                "委外材料出仓单");
        return result;
    }

    @GetMapping("/subcontract-returns")
    @PreAuthorize("hasAuthority('" + WarehouseHistoryPermissions.SUBCONTRACT_RETURN_VIEW + "')")
    public PageResponse<WarehouseHistoryListItem> subcontractReturns(
            @RequestParam(required = false) String keyword,
            @RequestParam(required = false) Short status,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate dateFrom,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate dateTo,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "20") int size,
            @RequestParam(required = false) String sort,
            @RequestParam(required = false) String order,
            @RequestParam(required = false) String billNo,
            @RequestParam(required = false) String sourceDocNo,
            @RequestParam(required = false) UUID scopeWarehouseId) {
        // 2026-09-25 单号列统一：sort/order 表头排序 + 单据号/来源单据号表头值筛选。
        return service.list(WarehouseHistoryType.SUBCONTRACT_RETURN, keyword, status, dateFrom, dateTo, page, size,
                sort, order, billNo, sourceDocNo, scopeWarehouseId);
    }

    @GetMapping("/subcontract-returns/{id}")
    @PreAuthorize("hasAuthority('" + WarehouseHistoryPermissions.SUBCONTRACT_RETURN_VIEW + "')")
    public WarehouseHistoryDetail subcontractReturn(@PathVariable UUID id,
            @RequestParam(required = false) UUID scopeWarehouseId) {
        WarehouseHistoryDetail result = service.detail(WarehouseHistoryType.SUBCONTRACT_RETURN, id, scopeWarehouseId);
        auditViews.record(
                "view_subcontract_return_detail",
                "subcontract_returns",
                id,
                result.billNo(),
                null,
                "委外退货单");
        return result;
    }

    @GetMapping("/subcontract-material-returns")
    @PreAuthorize("hasAuthority('" + WarehouseHistoryPermissions.SUBCONTRACT_MATERIAL_RETURN_VIEW + "')")
    public PageResponse<WarehouseHistoryListItem> subcontractMaterialReturns(
            @RequestParam(required = false) String keyword,
            @RequestParam(required = false) Short status,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate dateFrom,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate dateTo,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "20") int size,
            @RequestParam(required = false) String sort,
            @RequestParam(required = false) String order,
            @RequestParam(required = false) String billNo,
            @RequestParam(required = false) String sourceDocNo,
            @RequestParam(required = false) UUID scopeWarehouseId) {
        // 2026-09-25 单号列统一：sort/order 表头排序 + 单据号/来源单据号表头值筛选。
        return service.list(WarehouseHistoryType.SUBCONTRACT_MATERIAL_RETURN, keyword, status, dateFrom, dateTo, page, size,
                sort, order, billNo, sourceDocNo, scopeWarehouseId);
    }

    @GetMapping("/subcontract-material-returns/{id}")
    @PreAuthorize("hasAuthority('" + WarehouseHistoryPermissions.SUBCONTRACT_MATERIAL_RETURN_VIEW + "')")
    public WarehouseHistoryDetail subcontractMaterialReturn(@PathVariable UUID id,
            @RequestParam(required = false) UUID scopeWarehouseId) {
        WarehouseHistoryDetail result = service.detail(
                WarehouseHistoryType.SUBCONTRACT_MATERIAL_RETURN, id, scopeWarehouseId);
        auditViews.record(
                "view_subcontract_material_return_detail",
                "subcontract_material_returns",
                id,
                result.billNo(),
                null,
                "委外材料退货单");
        return result;
    }

    @GetMapping("/subcontract-wastes")
    @PreAuthorize("hasAuthority('" + WarehouseHistoryPermissions.SUBCONTRACT_WASTE_VIEW + "')")
    public PageResponse<WarehouseHistoryListItem> subcontractWastes(
            @RequestParam(required = false) String keyword,
            @RequestParam(required = false) Short status,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate dateFrom,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate dateTo,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "20") int size,
            @RequestParam(required = false) String sort,
            @RequestParam(required = false) String order,
            @RequestParam(required = false) String billNo,
            @RequestParam(required = false) String sourceDocNo,
            @RequestParam(required = false) UUID scopeWarehouseId) {
        // 2026-09-25 单号列统一：sort/order 表头排序 + 单据号/来源单据号表头值筛选。
        return service.list(WarehouseHistoryType.SUBCONTRACT_WASTE, keyword, status, dateFrom, dateTo, page, size,
                sort, order, billNo, sourceDocNo, scopeWarehouseId);
    }

    @GetMapping("/subcontract-wastes/{id}")
    @PreAuthorize("hasAuthority('" + WarehouseHistoryPermissions.SUBCONTRACT_WASTE_VIEW + "')")
    public WarehouseHistoryDetail subcontractWaste(@PathVariable UUID id,
            @RequestParam(required = false) UUID scopeWarehouseId) {
        WarehouseHistoryDetail result = service.detail(WarehouseHistoryType.SUBCONTRACT_WASTE, id, scopeWarehouseId);
        auditViews.record(
                "view_subcontract_waste_detail",
                "subcontract_wastes",
                id,
                result.billNo(),
                null,
                "委外材料损耗单");
        return result;
    }

    /** 单号 facets（2026-09-25 单号列统一）：{billNo/sourceDocNo:[各单号]}——
     *  同列表过滤口径（不含单号列自身值筛选）。 */
    @org.springframework.web.bind.annotation.RequestMapping(value="/purchase-receipts/facets", method={org.springframework.web.bind.annotation.RequestMethod.GET, org.springframework.web.bind.annotation.RequestMethod.POST})
    @PreAuthorize("hasAuthority('" + WarehouseHistoryPermissions.PURCHASE_RECEIPT_VIEW + "')")
    public java.util.Map<String, java.util.List<java.util.Map<String, Object>>> purchaseReceiptFacets(
            @RequestParam(required = false) String keyword,
            @RequestParam(required = false) Short status,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate dateFrom,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate dateTo,
            @RequestParam(required = false) UUID scopeWarehouseId) {
        return service.facets(WarehouseHistoryType.PURCHASE_RECEIPT, keyword, status, dateFrom, dateTo, scopeWarehouseId);
    }

    /** 单号 facets（2026-09-25 单号列统一）：{billNo/sourceDocNo:[各单号]}。 */
    @org.springframework.web.bind.annotation.RequestMapping(value="/subcontract-receipts/facets", method={org.springframework.web.bind.annotation.RequestMethod.GET, org.springframework.web.bind.annotation.RequestMethod.POST})
    @PreAuthorize("hasAuthority('" + WarehouseHistoryPermissions.SUBCONTRACT_RECEIPT_VIEW + "')")
    public java.util.Map<String, java.util.List<java.util.Map<String, Object>>> subcontractReceiptFacets(
            @RequestParam(required = false) String keyword,
            @RequestParam(required = false) Short status,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate dateFrom,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate dateTo,
            @RequestParam(required = false) UUID scopeWarehouseId) {
        return service.facets(WarehouseHistoryType.SUBCONTRACT_RECEIPT, keyword, status, dateFrom, dateTo, scopeWarehouseId);
    }

    /** 单号 facets（2026-09-25 单号列统一）：{billNo/sourceDocNo:[各单号]}。 */
    @org.springframework.web.bind.annotation.RequestMapping(value="/subcontract-material-issues/facets", method={org.springframework.web.bind.annotation.RequestMethod.GET, org.springframework.web.bind.annotation.RequestMethod.POST})
    @PreAuthorize("hasAuthority('" + WarehouseHistoryPermissions.SUBCONTRACT_MATERIAL_ISSUE_VIEW + "')")
    public java.util.Map<String, java.util.List<java.util.Map<String, Object>>> subcontractMaterialIssueFacets(
            @RequestParam(required = false) String keyword,
            @RequestParam(required = false) Short status,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate dateFrom,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate dateTo,
            @RequestParam(required = false) UUID scopeWarehouseId) {
        return service.facets(WarehouseHistoryType.SUBCONTRACT_MATERIAL_ISSUE, keyword, status, dateFrom, dateTo, scopeWarehouseId);
    }

    /** 单号 facets（2026-09-25 单号列统一）：{billNo/sourceDocNo:[各单号]}。 */
    @org.springframework.web.bind.annotation.RequestMapping(value="/subcontract-returns/facets", method={org.springframework.web.bind.annotation.RequestMethod.GET, org.springframework.web.bind.annotation.RequestMethod.POST})
    @PreAuthorize("hasAuthority('" + WarehouseHistoryPermissions.SUBCONTRACT_RETURN_VIEW + "')")
    public java.util.Map<String, java.util.List<java.util.Map<String, Object>>> subcontractReturnFacets(
            @RequestParam(required = false) String keyword,
            @RequestParam(required = false) Short status,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate dateFrom,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate dateTo,
            @RequestParam(required = false) UUID scopeWarehouseId) {
        return service.facets(WarehouseHistoryType.SUBCONTRACT_RETURN, keyword, status, dateFrom, dateTo, scopeWarehouseId);
    }

    /** 单号 facets（2026-09-25 单号列统一）：{billNo/sourceDocNo:[各单号]}。 */
    @org.springframework.web.bind.annotation.RequestMapping(value="/subcontract-material-returns/facets", method={org.springframework.web.bind.annotation.RequestMethod.GET, org.springframework.web.bind.annotation.RequestMethod.POST})
    @PreAuthorize("hasAuthority('" + WarehouseHistoryPermissions.SUBCONTRACT_MATERIAL_RETURN_VIEW + "')")
    public java.util.Map<String, java.util.List<java.util.Map<String, Object>>> subcontractMaterialReturnFacets(
            @RequestParam(required = false) String keyword,
            @RequestParam(required = false) Short status,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate dateFrom,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate dateTo,
            @RequestParam(required = false) UUID scopeWarehouseId) {
        return service.facets(WarehouseHistoryType.SUBCONTRACT_MATERIAL_RETURN, keyword, status, dateFrom, dateTo, scopeWarehouseId);
    }

    /** 单号 facets（2026-09-25 单号列统一）：{billNo/sourceDocNo:[各单号]}。 */
    @org.springframework.web.bind.annotation.RequestMapping(value="/subcontract-wastes/facets", method={org.springframework.web.bind.annotation.RequestMethod.GET, org.springframework.web.bind.annotation.RequestMethod.POST})
    @PreAuthorize("hasAuthority('" + WarehouseHistoryPermissions.SUBCONTRACT_WASTE_VIEW + "')")
    public java.util.Map<String, java.util.List<java.util.Map<String, Object>>> subcontractWasteFacets(
            @RequestParam(required = false) String keyword,
            @RequestParam(required = false) Short status,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate dateFrom,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate dateTo,
            @RequestParam(required = false) UUID scopeWarehouseId) {
        return service.facets(WarehouseHistoryType.SUBCONTRACT_WASTE, keyword, status, dateFrom, dateTo, scopeWarehouseId);
    }
}
