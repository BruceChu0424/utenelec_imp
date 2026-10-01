package com.uten.imp.features.subcontract.application;

import com.uten.imp.audit.AuditDetailViewRecorder;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.features.subcontract.application.dto.ApplicationDetail;
import com.uten.imp.features.subcontract.application.dto.ApplicationListItem;
import com.uten.imp.features.subcontract.application.dto.ApplicationQueryFilter;
import com.uten.imp.features.subcontract.application.dto.DecompositionPreviewItem;
import com.uten.imp.features.subcontract.application.dto.DecompositionPreviewRequest;
import jakarta.validation.Valid;
import lombok.RequiredArgsConstructor;
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
import java.util.List;
import java.util.UUID;

/**
 * 委外申请只读 API：计划下达需求，委外部门仅查看并分解为订货单。
 */
@RestController
@RequestMapping("/api/subcontract/applications")
@RequiredArgsConstructor
public class SubcontractApplicationController {

    private final SubcontractApplicationService service;
    private final AuditDetailViewRecorder auditViews;

    @GetMapping
    @PreAuthorize("hasAuthority('subcontract_application:view')")
    public PageResponse<ApplicationListItem> list(
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
        return service.list(new ApplicationQueryFilter(keyword, supplierId, warehouseId, status, dateFrom, dateTo, billNo).withHistory(includeDeleted, onlyDeleted), page, size, sort, order);
    }

    /** 单据号列值筛选桶（2026-09-25 单号列统一）：与列表同一过滤口径分组计数。 */
    @GetMapping("/facets")
    @PreAuthorize("hasAuthority('subcontract_application:view')")
    public java.util.Map<String, List<java.util.Map<String, Object>>> facets(
            @RequestParam(required = false) String keyword,
            @RequestParam(required = false) UUID supplierId,
            @RequestParam(required = false) UUID warehouseId,
            @RequestParam(required = false) Short status,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate dateFrom,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate dateTo,
            @RequestParam(defaultValue = "false") boolean includeDeleted,
            @RequestParam(defaultValue = "false") boolean onlyDeleted) {
        return service.facets(new ApplicationQueryFilter(keyword, supplierId, warehouseId, status, dateFrom, dateTo, null).withHistory(includeDeleted, onlyDeleted));
    }

    @GetMapping("/{id}")
    @PreAuthorize("hasAuthority('subcontract_application:view')")
    public ApplicationDetail detail(@PathVariable UUID id) {
        ApplicationDetail result = service.detail(id);
        auditViews.record(
                "view_subcontract_application_detail",
                "subcontract_applications",
                id,
                result.getBillNo(),
                result.getLegacyId(),
                "委外申请单");
        return result;
    }

    @GetMapping("/{id}/history")
    @PreAuthorize("hasAuthority('subcontract_application:view')")
    public ApplicationDetail history(@PathVariable UUID id) {
        ApplicationDetail result = service.detailHistory(id);
        auditViews.recordHistory(
                "view_subcontract_application_detail",
                "subcontract_applications",
                id,
                result.getBillNo(),
                result.getLegacyId(),
                "委外申请单");
        return result;
    }

    @PostMapping("/decomposition-preview")
    @PreAuthorize("hasAuthority('subcontract_application:view') and hasAuthority('subcontract_order:decompose')")
    public List<DecompositionPreviewItem> decompositionPreview(
            @Valid @RequestBody DecompositionPreviewRequest req) {
        return service.decompositionPreview(req.itemIds());
    }

    @GetMapping("/{id}/history/rows")
    @PreAuthorize("hasAuthority('subcontract_application:view')")
    public java.util.List<com.uten.imp.common.history.RetainedRecordReader.RetainedRow> historyRows(
            @PathVariable UUID id, @RequestParam(required=false) Long beforeId,
            @RequestParam(defaultValue="50") int size) {
        var rows = service.historyRows(id,beforeId,size);
        auditViews.recordHistory("view_subcontract_application_detail", "subcontract_applications", id, null, null, "单据历史明细");
        return rows;
    }
}
