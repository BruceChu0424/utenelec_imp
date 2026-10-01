package com.uten.imp.features.subcontract.ret;

import com.uten.imp.audit.AuditDetailViewRecorder;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.features.subcontract.ret.dto.ReturnDetail;
import com.uten.imp.features.subcontract.ret.dto.ReturnListItem;
import com.uten.imp.features.subcontract.ret.dto.ReturnQueryFilter;
import com.uten.imp.features.subcontract.ret.dto.ReturnSaveRequest;
import jakarta.validation.Valid;
import lombok.RequiredArgsConstructor;
import org.springframework.format.annotation.DateTimeFormat;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.DeleteMapping;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.PutMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import java.time.LocalDate;
import java.util.List;
import java.util.UUID;

/**
 * 委外退货单 API（委外管理，包名 ret 避开 Java 关键字 return）。
 *
 * - GET    /api/subcontract/returns?keyword=&supplierId=&warehouseId=&status=&dateFrom=&dateTo=&page=&size= → 分页
 * - GET    /api/subcontract/returns/{id}            → 详情（主+明细）
 * - POST   /api/subcontract/returns                 → 新建（草稿）subcontract_return:create
 * - PUT    /api/subcontract/returns/{id}            → 编辑（仅草稿）
 * - DELETE /api/subcontract/returns/{id}            → 删除（草稿/红冲可删；已审核禁删）
 * - POST   /api/subcontract/returns/{id}/approve    → 审核（出库 + 双回写 + 反向立 AP + ap_posted）
 * - POST   /api/subcontract/returns/{id}/reverse    → 红冲（先反立帐，再反向冲销）
 */
@RestController
@RequestMapping("/api/subcontract/returns")
@RequiredArgsConstructor
public class SubcontractReturnController {

    private final SubcontractReturnService service;
    private final AuditDetailViewRecorder auditViews;

    @GetMapping
    @PreAuthorize("hasAuthority('subcontract_return:view')")
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
            @RequestParam(defaultValue = "false") boolean onlyDeleted,
            @RequestParam java.util.Map<String, String> headerParams) {
        return service.list(new ReturnQueryFilter(keyword, supplierId, warehouseId, status, dateFrom, dateTo, billNo).withHistory(includeDeleted, onlyDeleted).withHeaders(com.uten.imp.common.web.HeaderColumnFilter.from(headerParams)), page, size, sort, order);
    }

    /** 单据号列值筛选桶（2026-09-25 单号列统一）：与列表同一过滤口径分组计数。 */
    @GetMapping("/facets")
    @PreAuthorize("hasAuthority('subcontract_return:view')")
    public java.util.Map<String, List<java.util.Map<String, Object>>> facets(
            @RequestParam(required = false) String keyword,
            @RequestParam(required = false) UUID supplierId,
            @RequestParam(required = false) UUID warehouseId,
            @RequestParam(required = false) Short status,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate dateFrom,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate dateTo,
            @RequestParam(defaultValue = "false") boolean includeDeleted,
            @RequestParam(defaultValue = "false") boolean onlyDeleted,
            @RequestParam java.util.Map<String, String> headerParams) {
        return service.facets(new ReturnQueryFilter(keyword, supplierId, warehouseId, status, dateFrom, dateTo, null).withHistory(includeDeleted, onlyDeleted).withHeaders(com.uten.imp.common.web.HeaderColumnFilter.from(headerParams)));
    }

    @GetMapping("/{id}")
    @PreAuthorize("hasAuthority('subcontract_return:view')")
    public ReturnDetail detail(@PathVariable UUID id) {
        ReturnDetail result = service.detail(id);
        auditViews.record(
                "view_subcontract_return_detail",
                "subcontract_returns",
                id,
                result.getBillNo(),
                result.getLegacyId(),
                "委外退货单");
        return result;
    }

    @GetMapping("/{id}/history")
    @PreAuthorize("hasAuthority('subcontract_return:view')")
    public ReturnDetail history(@PathVariable UUID id) {
        ReturnDetail result = service.detailHistory(id);
        auditViews.recordHistory(
                "view_subcontract_return_detail",
                "subcontract_returns",
                id,
                result.getBillNo(),
                result.getLegacyId(),
                "委外退货单");
        return result;
    }

    @PostMapping
    @PreAuthorize("hasAuthority('subcontract_return:create')")
    public ReturnDetail create(@Valid @RequestBody ReturnSaveRequest req) {
        return service.create(req);
    }

    @PutMapping("/{id}")
    @PreAuthorize("hasAuthority('subcontract_return:edit')")
    public ReturnDetail update(@PathVariable UUID id, @Valid @RequestBody ReturnSaveRequest req) {
        return service.update(id, req);
    }

    @DeleteMapping("/{id}")
    @PreAuthorize("hasAuthority('subcontract_return:delete')")
    public void delete(@PathVariable UUID id) {
        service.delete(id);
    }

    @PostMapping("/{id}/approve")
    @PreAuthorize("hasAuthority('subcontract_return:approve')")
    public ReturnDetail approve(@PathVariable UUID id) {
        return service.approve(id);
    }

    @PostMapping("/{id}/reverse")
    @PreAuthorize("hasAuthority('subcontract_return:reverse')")
    public ReturnDetail reverse(@PathVariable UUID id) {
        return service.reverse(id);
    }

    @GetMapping("/{id}/history/rows")
    @PreAuthorize("hasAuthority('subcontract_return:view')")
    public java.util.List<com.uten.imp.common.history.RetainedRecordReader.RetainedRow> historyRows(
            @PathVariable UUID id, @RequestParam(required=false) Long beforeId,
            @RequestParam(defaultValue="50") int size) {
        var rows = service.historyRows(id,beforeId,size);
        auditViews.recordHistory("view_subcontract_return_detail", "subcontract_returns", id, null, null, "单据历史明细");
        return rows;
    }
}
