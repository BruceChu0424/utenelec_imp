package com.uten.imp.features.purchase.ret;

import com.uten.imp.audit.AuditDetailViewRecorder;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.features.purchase.ret.dto.ReturnDetail;
import com.uten.imp.features.purchase.ret.dto.ReturnListItem;
import com.uten.imp.features.purchase.ret.dto.ReturnQueryFilter;
import com.uten.imp.features.purchase.ret.dto.ReturnSaveRequest;
import jakarta.validation.Valid;
import lombok.RequiredArgsConstructor;
import org.springframework.format.annotation.DateTimeFormat;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.*;

import java.time.LocalDate;
import java.util.List;
import java.util.UUID;

/** 采购退货单 API（采购管理）。CRUD + 审核（出库）+ 红冲（入库）。 */
@RestController
@RequestMapping("/api/purchase/returns")
@RequiredArgsConstructor
public class PurchaseReturnController {

    private final PurchaseReturnService service;
    private final AuditDetailViewRecorder auditViews;

    @GetMapping
    @PreAuthorize("hasAuthority('purchase_return:view')")
    public PageResponse<ReturnListItem> list(
            @RequestParam(required = false) String keyword,
            @RequestParam(required = false) UUID supplierId,
            @RequestParam(required = false) UUID warehouseId,
            @RequestParam(required = false) Short status,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate dateFrom,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate dateTo,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "20") int size,
            @RequestParam(required = false) String sort,
            @RequestParam(required = false) String order,
            @RequestParam(required = false) String billNo,
            @RequestParam(defaultValue = "false") boolean includeDeleted,
            @RequestParam(defaultValue = "false") boolean onlyDeleted) {
        return service.list(new ReturnQueryFilter(keyword, supplierId, warehouseId, status, dateFrom, dateTo, billNo).withHistory(includeDeleted, onlyDeleted), page, size, sort, order);
    }

    /** 单据号列值筛选桶（2026-09-25 单号列统一）：与列表同一过滤口径分组计数。 */
    @GetMapping("/facets")
    @PreAuthorize("hasAuthority('purchase_return:view')")
    public java.util.Map<String, List<java.util.Map<String, Object>>> facets(
            @RequestParam(required = false) String keyword,
            @RequestParam(required = false) UUID supplierId,
            @RequestParam(required = false) UUID warehouseId,
            @RequestParam(required = false) Short status,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate dateFrom,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate dateTo,
            @RequestParam(defaultValue = "false") boolean includeDeleted,
            @RequestParam(defaultValue = "false") boolean onlyDeleted) {
        return service.facets(new ReturnQueryFilter(keyword, supplierId, warehouseId, status, dateFrom, dateTo, null).withHistory(includeDeleted, onlyDeleted));
    }

    @GetMapping("/{id}")
    @PreAuthorize("hasAuthority('purchase_return:view')")
    public ReturnDetail detail(@PathVariable UUID id) {
        ReturnDetail result = service.detail(id);
        auditViews.record(
                "view_purchase_return_detail",
                "purchase_returns",
                id,
                result.getBillNo(),
                result.getLegacyId(),
                "采购退货单");
        return result;
    }

    @GetMapping("/{id}/history")
    @PreAuthorize("hasAuthority('purchase_return:view')")
    public ReturnDetail history(@PathVariable UUID id) {
        ReturnDetail result = service.detailHistory(id);
        auditViews.recordHistory(
                "view_purchase_return_detail",
                "purchase_returns",
                id,
                result.getBillNo(),
                result.getLegacyId(),
                "采购退货单");
        return result;
    }

    @PostMapping
    @PreAuthorize("hasAuthority('purchase_return:create')")
    public ReturnDetail create(@Valid @RequestBody ReturnSaveRequest req) {
        return service.create(req);
    }

    @PutMapping("/{id}")
    @PreAuthorize("hasAuthority('purchase_return:edit')")
    public ReturnDetail update(@PathVariable UUID id, @Valid @RequestBody ReturnSaveRequest req) {
        return service.update(id, req);
    }

    @DeleteMapping("/{id}")
    @PreAuthorize("hasAuthority('purchase_return:delete')")
    public void delete(@PathVariable UUID id) {
        service.delete(id);
    }

    @PostMapping("/{id}/approve")
    @PreAuthorize("hasAuthority('purchase_return:approve')")
    public ReturnDetail approve(@PathVariable UUID id) {
        return service.approve(id);
    }

    @PostMapping("/{id}/reverse")
    @PreAuthorize("hasAuthority('purchase_return:reverse')")
    public ReturnDetail reverse(@PathVariable UUID id) {
        return service.reverse(id);
    }

    @GetMapping("/{id}/history/rows")
    @PreAuthorize("hasAuthority('purchase_return:view')")
    public java.util.List<com.uten.imp.common.history.RetainedRecordReader.RetainedRow> historyRows(
            @PathVariable UUID id, @RequestParam(required=false) Long beforeId,
            @RequestParam(defaultValue="50") int size) {
        var rows = service.historyRows(id,beforeId,size);
        auditViews.recordHistory("view_purchase_return_detail", "purchase_returns", id, null, null, "单据历史明细");
        return rows;
    }
}
