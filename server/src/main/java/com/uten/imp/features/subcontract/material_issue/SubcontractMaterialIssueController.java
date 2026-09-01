package com.uten.imp.features.subcontract.material_issue;

import com.uten.imp.audit.AuditDetailViewRecorder;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.features.subcontract.material_issue.dto.MaterialIssueDetail;
import com.uten.imp.features.subcontract.material_issue.dto.MaterialIssueListItem;
import com.uten.imp.features.subcontract.material_issue.dto.MaterialIssueQueryFilter;
import com.uten.imp.features.subcontract.material_issue.dto.MaterialIssueSaveRequest;
import io.swagger.v3.oas.annotations.Operation;
import io.swagger.v3.oas.annotations.responses.ApiResponse;
import io.swagger.v3.oas.annotations.responses.ApiResponses;
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
 * - POST   /api/subcontract/material-issues                 → 历史入口已关闭（固定 409；改走仓库委外出仓任务）
 * - PUT    /api/subcontract/material-issues/{id}            → 编辑（仅草稿）
 * - DELETE /api/subcontract/material-issues/{id}            → 删除（草稿/红冲可删；已审核禁删）
 * - POST   /api/subcontract/material-issues/{id}/approve    → 审核（当前安全关闭，返回冲突；不产生库存/财务副作用）
 * - POST   /api/subcontract/material-issues/{id}/reverse    → 红冲（反向入库）
 */
@RestController
@RequestMapping("/api/subcontract/material-issues")
@RequiredArgsConstructor
public class SubcontractMaterialIssueController {

    private final SubcontractMaterialIssueService service;
    private final AuditDetailViewRecorder auditViews;

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
            @RequestParam(defaultValue = "20") int size,
            @RequestParam(required = false) String sort,
            @RequestParam(required = false) String order) {
        return service.list(new MaterialIssueQueryFilter(keyword, supplierId, warehouseId, status, dateFrom, dateTo), page, size, sort, order);
    }

    @GetMapping("/{id}")
    @PreAuthorize("hasAuthority('subcontract_material_issue:view')")
    public MaterialIssueDetail detail(@PathVariable UUID id) {
        MaterialIssueDetail result = service.detail(id);
        auditViews.record(
                "view_subcontract_material_issue_detail",
                "subcontract_material_issues",
                id,
                result.getBillNo(),
                result.getLegacyId(),
                "委外材料出仓单");
        return result;
    }

    @PostMapping
    @PreAuthorize("hasAuthority('subcontract_material_issue:create')")
    @Operation(
            summary = "历史委外发料手工新建入口（已停用）",
            description = "该兼容端点不再创建单据。请从仓库委外出仓任务执行，旧权限客户端固定收到 409。",
            deprecated = true)
    @ApiResponses({
            @ApiResponse(responseCode = "403", description = "没有历史新建权限"),
            @ApiResponse(responseCode = "409", description = "手工新建入口已停用")
    })
    public MaterialIssueDetail create(@Valid @RequestBody MaterialIssueSaveRequest req) {
        throw new ApiException(
                ErrorCode.CONFLICT,
                "旧委外发料手工新建已关闭；请从“仓库管理 → 委外出仓”领取系统任务并执行出仓");
    }

    @PutMapping("/{id}")
    @PreAuthorize("hasAuthority('subcontract_material_issue:edit')")
    public MaterialIssueDetail update(@PathVariable UUID id, @Valid @RequestBody MaterialIssueSaveRequest req) {
        return service.update(id, req);
    }

    @DeleteMapping("/{id}")
    @PreAuthorize("hasAuthority('subcontract_material_issue:delete')")
    public void delete(@PathVariable UUID id) {
        service.delete(id);
    }

    @PostMapping("/{id}/approve")
    @PreAuthorize("hasAuthority('subcontract_material_issue:approve')")
    public MaterialIssueDetail approve(@PathVariable UUID id) {
        return service.approve(id);
    }

    @PostMapping("/{id}/reverse")
    @PreAuthorize("hasAuthority('subcontract_material_issue:reverse')")
    public MaterialIssueDetail reverse(@PathVariable UUID id) {
        return service.reverse(id);
    }
}
