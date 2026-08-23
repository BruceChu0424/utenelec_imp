package com.uten.imp.features.org.department.staffpermission;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.org.department.staffpermission.dto.ManagedDepartmentDto;
import com.uten.imp.features.org.department.staffpermission.dto.PermissionDelegationCapabilityDto;
import com.uten.imp.features.org.department.staffpermission.dto.SetStaffDelegationRequest;
import com.uten.imp.features.org.department.staffpermission.dto.SetStaffOverrideRequest;
import com.uten.imp.features.org.department.staffpermission.dto.StaffDelegationResultDto;
import jakarta.validation.Valid;
import lombok.RequiredArgsConstructor;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PutMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import java.util.List;
import java.util.UUID;

/**
 * Page-context permission delegation for organization leaders and super admins.
 * Every endpoint is authenticated by the global security chain; staff subject,
 * live organization scope and per-permission authority are rechecked in service.
 */
@RestController
@RequestMapping("/api/department-staff-permissions")
@RequiredArgsConstructor
public class DepartmentStaffPermissionController {

    private final DepartmentStaffPermissionService service;
    private final PagePermissionWorkspaceService workspace;

    @GetMapping("/capability")
    public PermissionDelegationCapabilityDto capability(
            @RequestParam String surfaceKey) {
        return workspace.capability(surfaceKey);
    }

    @GetMapping("/managed-departments")
    public List<ManagedDepartmentDto> managedDepartments(
            @RequestParam String surfaceKey) {
        return workspace.managedDepartments(surfaceKey);
    }

    @GetMapping("/managed")
    @Deprecated(forRemoval = true)
    public void managed(
            @RequestParam String surfaceKey,
            @RequestParam(required = false) UUID departmentId) {
        throw new ApiException(
                ErrorCode.CONFLICT,
                "旧版整部门权限矩阵接口已停用，请升级客户端使用分页人员和单人权限接口");
    }

    @PutMapping("/employees/{employeeId}/delegations/{code}")
    public StaffDelegationResultDto setDelegation(
            @PathVariable UUID employeeId,
            @PathVariable String code,
            @RequestParam String surfaceKey,
            @RequestParam UUID departmentId,
            @Valid @RequestBody SetStaffDelegationRequest request) {
        return workspace.setSinglePermission(
                employeeId,
                departmentId,
                surfaceKey,
                code,
                request.enabled(),
                request.expectedVersion());
    }

    /**
     * Compatibility route for old clients. It intentionally never mutates
     * user_permission_overrides; the service returns an explicit 403.
     */
    @PutMapping("/employees/{employeeId}/overrides/{code}")
    public void rejectLegacyOverride(
            @PathVariable UUID employeeId,
            @PathVariable String code,
            @RequestBody(required = false) SetStaffOverrideRequest request) {
        service.setStaffOverride(
                employeeId,
                code,
                request == null ? null : request.effect());
    }
}
