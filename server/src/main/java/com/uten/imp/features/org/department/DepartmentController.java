package com.uten.imp.features.org.department;

import com.uten.imp.audit.AuditDetailViewRecorder;
import com.uten.imp.features.org.department.dto.*;
import jakarta.validation.Valid;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.*;

import java.util.List;
import java.util.UUID;

/** 部门组织树接口（/api/org/departments）：树/子树/详情/员工选择器树/人力概览 + CRUD。 */
@RestController
@RequestMapping("/api/org/departments")
@RequiredArgsConstructor
public class DepartmentController {

    private final DepartmentService service;
    private final WorkforceOverviewService workforceOverviewService;
    private final AuditDetailViewRecorder detailViewAudit;

    @GetMapping("/tree")
    @PreAuthorize("hasAnyAuthority('department:view', 'notice:publish')")
    public List<DepartmentNode> tree() {
        return service.tree();
    }

    @GetMapping("/employee-picker-tree")
    @PreAuthorize("hasAuthority('employee:view')")
    public List<DepartmentPickerNode> employeePickerTree() {
        return service.employeePickerTree();
    }

    @GetMapping("/{id}/subtree")
    @PreAuthorize("hasAuthority('department:view')")
    public List<DepartmentNode> subtree(@PathVariable UUID id) {
        return service.subtree(id);
    }

    @GetMapping("/{id}")
    @PreAuthorize("hasAuthority('department:view')")
    public DepartmentDetail detail(@PathVariable UUID id) {
        DepartmentDetail result = service.detail(id);
        String displayName = result.getCode();
        if (displayName == null || displayName.isBlank()) {
            displayName = result.getName();
        }
        detailViewAudit.record(
                "view_department_detail", "departments", id, displayName,
                null, "部门");
        return result;
    }

    @GetMapping("/{id}/workforce-overview")
    @PreAuthorize("hasAuthority('department:view') and hasAuthority('employee:view')")
    public WorkforceOverviewDto workforceOverview(@PathVariable UUID id) {
        return workforceOverviewService.overview(id);
    }

    @PostMapping
    @PreAuthorize("hasAuthority('department:create')")
    public DepartmentDetail create(@Valid @RequestBody DepartmentSaveRequest req) {
        return service.create(req);
    }

    @PutMapping("/{id}")
    @PreAuthorize("hasAnyAuthority('department:edit', 'department:move', 'department:manager_assign')")
    public DepartmentDetail update(@PathVariable UUID id, @Valid @RequestBody DepartmentUpdateRequest req) {
        return service.update(id, req);
    }

    @DeleteMapping("/{id}")
    @PreAuthorize("hasAuthority('department:delete')")
    public void delete(@PathVariable UUID id) {
        service.delete(id);
    }
}
