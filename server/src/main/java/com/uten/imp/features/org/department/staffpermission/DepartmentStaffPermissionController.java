package com.uten.imp.features.org.department.staffpermission;

import com.uten.imp.features.org.department.staffpermission.dto.DepartmentStaffPermissionsDto;
import com.uten.imp.features.org.department.staffpermission.dto.SetStaffOverrideRequest;
import lombok.RequiredArgsConstructor;
import org.springframework.web.bind.annotation.*;

import java.util.UUID;

/**
 * 部门主管管理"本部门员工权限"（问题 #20）。
 *
 * <p>刻意不用 {@code @PreAuthorize} 静态权限点把关——"是不是部门负责人"是数据驱动的
 * （department.manager_id 是否等于当前登录人），只能在 Service 里查库判断；这里只要求
 * 已登录，越权检查全部在 {@link DepartmentStaffPermissionService} 内完成，未通过直接 403。
 */
@RestController
@RequestMapping("/api/department-staff-permissions")
@RequiredArgsConstructor
public class DepartmentStaffPermissionController {

    private final DepartmentStaffPermissionService service;

    /** 当前登录人管理的部门 + 可转授权限点上限 + 本部门员工当前覆盖状态。 */
    @GetMapping("/managed")
    public DepartmentStaffPermissionsDto managed() {
        return service.getManagedStaffPermissions();
    }

    /** 设置/清除（effect=null）某员工单个权限点的个人覆盖。 */
    @PutMapping("/employees/{employeeId}/overrides/{code}")
    public void setOverride(
            @PathVariable UUID employeeId,
            @PathVariable String code,
            @RequestBody SetStaffOverrideRequest req) {
        service.setStaffOverride(employeeId, code, req.effect());
    }
}
