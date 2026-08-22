package com.uten.imp.features.org.department.staffpermission;

import com.uten.imp.features.org.department.staffpermission.dto.BatchSetStaffPermissionsRequest;
import com.uten.imp.features.org.department.staffpermission.dto.BatchSetStaffPermissionsResultDto;
import com.uten.imp.features.org.department.staffpermission.dto.PagePermissionEmployeePermissionsDto;
import com.uten.imp.features.org.department.staffpermission.dto.PagePermissionStaffPageDto;
import jakarta.validation.Valid;
import jakarta.validation.constraints.Max;
import jakarta.validation.constraints.Min;
import jakarta.validation.constraints.Size;
import lombok.RequiredArgsConstructor;
import org.springframework.validation.annotation.Validated;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PutMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import java.util.UUID;

/** Bounded read/write API used by the page-permission split workspace. */
@Validated
@RestController
@RequestMapping("/api/department-staff-permissions")
@RequiredArgsConstructor
public class PagePermissionWorkspaceController {

    private final PagePermissionWorkspaceService workspace;

    @GetMapping("/staff")
    public PagePermissionStaffPageDto staff(
            @RequestParam String surfaceKey,
            @RequestParam(required = false) UUID departmentId,
            @RequestParam(required = false) @Size(max = 100) String search,
            @RequestParam(defaultValue = "1") @Min(1) int page,
            @RequestParam(defaultValue = "30") @Min(1) @Max(50) int size) {
        return workspace.staff(
                surfaceKey, departmentId, search, page, size);
    }

    @GetMapping("/employees/{employeeId}/permissions")
    public PagePermissionEmployeePermissionsDto employeePermissions(
            @PathVariable UUID employeeId,
            @RequestParam String surfaceKey,
            @RequestParam UUID departmentId) {
        return workspace.employeePermissions(
                employeeId, departmentId, surfaceKey);
    }

    @PutMapping("/employees/{employeeId}/permissions")
    public BatchSetStaffPermissionsResultDto setPermissions(
            @PathVariable UUID employeeId,
            @RequestParam String surfaceKey,
            @RequestParam UUID departmentId,
            @Valid @RequestBody BatchSetStaffPermissionsRequest request) {
        return workspace.setPermissions(
                employeeId, departmentId, surfaceKey, request);
    }
}
