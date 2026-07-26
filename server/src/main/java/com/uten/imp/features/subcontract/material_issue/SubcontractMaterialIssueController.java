package com.uten.imp.features.subcontract.material_issue;

import com.uten.imp.common.web.PageResponse;
import com.uten.imp.features.subcontract.material_issue.dto.MaterialIssueDetail;
import com.uten.imp.features.subcontract.material_issue.dto.MaterialIssueListItem;
import com.uten.imp.features.subcontract.material_issue.dto.MaterialIssueQueryFilter;
import com.uten.imp.features.subcontract.material_issue.dto.MaterialIssueSaveRequest;
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
import java.util.UUID;

/**
 * 委外材料出仓单 API（委外管理）。
 *
 * - GET    /api/subcontract/material-issues?keyword=&supplierId=&warehouseId=&status=&dateFrom=&dateTo=&page=&size= → 分页
 * - GET    /api/subcontract/material-issues/{id}            → 详情（主+明细）
 * - POST   /api/subcontract/material-issues                 → 新建（草稿）subcontract_material_issue:edit
 * - PUT    /api/subcontract/material-issues/{id}            → 编辑（仅草稿）
 * - DELETE /api/subcontract/material-issues/{id}            → 删除（草稿/红冲可删；已审核禁删）
 * - POST   /api/subcontract/material-issues/{id}/approve    → 审核（出库 + 回写订货 issued_qty；不立应付）
 * - POST   /api/subcontract/material-issues/{id}/reverse    → 红冲（反向入库）
 */
@RestController
@RequestMapping("/api/subcontract/material-issues")
@RequiredArgsConstructor
public class SubcontractMaterialIssueController {

    private final SubcontractMaterialIssueService service;

    @GetMapping
    @PreAuthorize("hasAuthority('subcontract_material_issue:view')")
    public PageResponse<MaterialIssueListItem> list(
            @RequestParam(required = false) String keyword,
            @RequestParam(required = false) UUID supplierId,
            @RequestParam(required = false) UUID warehouseId,
            @RequestParam(required = false) Short status,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate dateFrom,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate dateTo,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "20") int size) {
        return service.list(new MaterialIssueQueryFilter(keyword, supplierId, warehouseId, status, dateFrom, dateTo), page, size);
    }

    @GetMapping("/{id}")
    @PreAuthorize("hasAuthority('subcontract_material_issue:view')")
    public MaterialIssueDetail detail(@PathVariable UUID id) {
        return service.detail(id);
    }

    @PostMapping
    @PreAuthorize("hasAuthority('subcontract_material_issue:edit')")
    public MaterialIssueDetail create(@Valid @RequestBody MaterialIssueSaveRequest req) {
        return service.create(req);
    }

    @PutMapping("/{id}")
    @PreAuthorize("hasAuthority('subcontract_material_issue:edit')")
    public MaterialIssueDetail update(@PathVariable UUID id, @Valid @RequestBody MaterialIssueSaveRequest req) {
        return service.update(id, req);
    }

    @DeleteMapping("/{id}")
    @PreAuthorize("hasAuthority('subcontract_material_issue:edit')")
    public void delete(@PathVariable UUID id) {
        service.delete(id);
    }

    @PostMapping("/{id}/approve")
    @PreAuthorize("hasAuthority('subcontract_material_issue:edit')")
    public MaterialIssueDetail approve(@PathVariable UUID id) {
        return service.approve(id);
    }

    @PostMapping("/{id}/reverse")
    @PreAuthorize("hasAuthority('subcontract_material_issue:edit')")
    public MaterialIssueDetail reverse(@PathVariable UUID id) {
        return service.reverse(id);
    }
}
