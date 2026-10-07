package com.uten.imp.features.org.department.staffpermission;

import com.uten.imp.features.org.department.staffpermission.dto.ManagedDepartmentDto;
import lombok.RequiredArgsConstructor;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import java.util.List;

/**
 * Page-context permission delegation for organization leaders and super admins.
 * Every endpoint is authenticated by the global security chain; staff subject,
 * live organization scope and per-permission authority are rechecked in service.
 */
@RestController
@RequestMapping("/api/department-staff-permissions")
@RequiredArgsConstructor
public class DepartmentStaffPermissionController {

    private final PagePermissionWorkspaceService workspace;

    @GetMapping("/managed-departments")
    public List<ManagedDepartmentDto> managedDepartments(
            @RequestParam String surfaceKey) {
        return workspace.managedDepartments(surfaceKey);
    }
}
