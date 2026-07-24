package com.uten.imp.features.admin;

import com.uten.imp.features.admin.dto.DepartmentPermissionsDto;
import com.uten.imp.features.admin.dto.EffectivePermissionsDto;
import com.uten.imp.features.admin.dto.PermissionCatalogDto;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PutMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

import java.util.List;
import java.util.UUID;

/**
 * 权限目录 / 部门直配权限点 / 用户有效权限分解（管理端）。
 * 与 AdminUserController 一致，全部要求 user:manage 权限。
 */
@RestController
@RequestMapping("/api/admin")
@RequiredArgsConstructor
public class AdminPermissionController {

    private final DepartmentPermissionAdminService departmentPermissionAdmin;

    /** 完整权限目录（按 category 分组、组内 sort_order+code 排序）。 */
    @GetMapping("/permission-catalog")
    @PreAuthorize("hasAuthority('user:manage')")
    public List<PermissionCatalogDto> permissionCatalog() {
        return departmentPermissionAdmin.catalog();
    }

    /** 某部门已直配的权限点 code 列表。 */
    @GetMapping("/departments/{departmentId}/permissions")
    @PreAuthorize("hasAuthority('user:manage')")
    public DepartmentPermissionsDto getDepartmentPermissions(@PathVariable UUID departmentId) {
        return departmentPermissionAdmin.getDepartmentPermissions(departmentId);
    }

    /** 整体替换某部门的直配权限点。 */
    @PutMapping("/departments/{departmentId}/permissions")
    @PreAuthorize("hasAuthority('user:manage')")
    public void setDepartmentPermissions(@PathVariable UUID departmentId,
                                         @RequestBody DepartmentPermissionsDto req) {
        departmentPermissionAdmin.setDepartmentPermissions(departmentId,
                req.permissions() == null ? List.of() : req.permissions());
    }

    /** 某用户的有效权限分解（部门/角色/覆盖/最终有效）。 */
    @GetMapping("/users/{userId}/effective-permissions")
    @PreAuthorize("hasAuthority('user:manage')")
    public EffectivePermissionsDto effectivePermissions(@PathVariable UUID userId) {
        return departmentPermissionAdmin.effectivePermissions(userId);
    }
}
