package com.uten.imp.features.subcontract.inquiry;

import com.uten.imp.audit.AuditDetailViewRecorder;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.features.subcontract.inquiry.dto.InquiryDetail;
import com.uten.imp.features.subcontract.inquiry.dto.InquiryListItem;
import com.uten.imp.features.subcontract.inquiry.dto.InquiryQueryFilter;
import com.uten.imp.features.subcontract.inquiry.dto.InquirySaveRequest;
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
 * 委外询价单 API（委外管理）。
 *
 * - GET    /api/subcontract/inquiries?keyword=&supplierId=&warehouseId=&status=&dateFrom=&dateTo=&page=&size= → 分页
 * - GET    /api/subcontract/inquiries/{id}            → 详情（主+明细）
 * - POST   /api/subcontract/inquiries                 → 新建（草稿）subcontract_inquiry:create
 * - PUT    /api/subcontract/inquiries/{id}            → 编辑（仅草稿）
 * - DELETE /api/subcontract/inquiries/{id}            → 删除（草稿/红冲可删；已审核禁删）
 * - POST   /api/subcontract/inquiries/{id}/approve    → 审核（仅状态变更；询价是链路起点无联动）
 * - POST   /api/subcontract/inquiries/{id}/reverse    → 红冲
 */
@RestController
@RequestMapping("/api/subcontract/inquiries")
@RequiredArgsConstructor
public class SubcontractInquiryController {

    private final SubcontractInquiryService service;
    private final AuditDetailViewRecorder auditViews;

    @GetMapping
    @PreAuthorize("hasAuthority('subcontract_inquiry:view')")
    public PageResponse<InquiryListItem> list(
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
        return service.list(new InquiryQueryFilter(keyword, supplierId, warehouseId, status, dateFrom, dateTo, billNo).withHistory(includeDeleted, onlyDeleted), page, size, sort, order);
    }

    /** 单据号列值筛选桶（2026-09-25 单号列统一）：与列表同一过滤口径分组计数。 */
    @GetMapping("/facets")
    @PreAuthorize("hasAuthority('subcontract_inquiry:view')")
    public java.util.Map<String, List<java.util.Map<String, Object>>> facets(
            @RequestParam(required = false) String keyword,
            @RequestParam(required = false) UUID supplierId,
            @RequestParam(required = false) UUID warehouseId,
            @RequestParam(required = false) Short status,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate dateFrom,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate dateTo,
            @RequestParam(defaultValue = "false") boolean includeDeleted,
            @RequestParam(defaultValue = "false") boolean onlyDeleted) {
        return service.facets(new InquiryQueryFilter(keyword, supplierId, warehouseId, status, dateFrom, dateTo, null).withHistory(includeDeleted, onlyDeleted));
    }

    @GetMapping("/{id}")
    @PreAuthorize("hasAuthority('subcontract_inquiry:view')")
    public InquiryDetail detail(@PathVariable UUID id) {
        InquiryDetail result = service.detail(id);
        auditViews.record(
                "view_subcontract_inquiry_detail",
                "subcontract_inquiries",
                id,
                result.getBillNo(),
                result.getLegacyId(),
                "委外询价单");
        return result;
    }

    @GetMapping("/{id}/history")
    @PreAuthorize("hasAuthority('subcontract_inquiry:view')")
    public InquiryDetail history(@PathVariable UUID id) {
        InquiryDetail result = service.detailHistory(id);
        auditViews.recordHistory(
                "view_subcontract_inquiry_detail",
                "subcontract_inquiries",
                id,
                result.getBillNo(),
                result.getLegacyId(),
                "委外询价单");
        return result;
    }

    @PostMapping
    @PreAuthorize("hasAuthority('subcontract_inquiry:create')")
    public InquiryDetail create(@Valid @RequestBody InquirySaveRequest req) {
        return service.create(req);
    }

    @PutMapping("/{id}")
    @PreAuthorize("hasAuthority('subcontract_inquiry:edit')")
    public InquiryDetail update(@PathVariable UUID id, @Valid @RequestBody InquirySaveRequest req) {
        return service.update(id, req);
    }

    @DeleteMapping("/{id}")
    @PreAuthorize("hasAuthority('subcontract_inquiry:delete')")
    public void delete(@PathVariable UUID id) {
        service.delete(id);
    }

    @PostMapping("/{id}/approve")
    @PreAuthorize("hasAuthority('subcontract_inquiry:approve')")
    public InquiryDetail approve(@PathVariable UUID id) {
        return service.approve(id);
    }

    @PostMapping("/{id}/reverse")
    @PreAuthorize("hasAuthority('subcontract_inquiry:reverse')")
    public InquiryDetail reverse(@PathVariable UUID id) {
        return service.reverse(id);
    }

    @GetMapping("/{id}/history/rows")
    @PreAuthorize("hasAuthority('subcontract_inquiry:view')")
    public java.util.List<com.uten.imp.common.history.RetainedRecordReader.RetainedRow> historyRows(
            @PathVariable UUID id, @RequestParam(required=false) Long beforeId,
            @RequestParam(defaultValue="50") int size) {
        var rows = service.historyRows(id,beforeId,size);
        auditViews.recordHistory("view_subcontract_inquiry_detail", "subcontract_inquiries", id, null, null, "单据历史明细");
        return rows;
    }
}
