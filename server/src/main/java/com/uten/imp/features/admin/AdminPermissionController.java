package com.uten.imp.features.admin;

import com.uten.imp.features.admin.dto.DepartmentPermissionsDto;
import com.uten.imp.features.admin.dto.EffectivePermissionsDto;
import com.uten.imp.features.admin.dto.PermissionBulkScopeDto;
import com.uten.imp.features.admin.dto.PermissionCatalogDto;
import com.uten.imp.features.admin.dto.PermissionChangeDto;
import jakarta.validation.Valid;
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
 * 权限目录 / 部门直配权限点 / 全员基础包 / 用户有效权限分解(管理端)。
 * 全部要求 authorization:manage，且主体必须仍是数据库确认的超级管理员。
 * 保存接口按差量落库并返回本次真正改动的码(ADR-109)。
 */
@RestController
@RequestMapping("/api/admin")
@RequiredArgsConstructor
@PreAuthorize("hasAuthority('authorization:manage') and principal.superAdmin")
public class AdminPermissionController {

    private final DepartmentPermissionAdminService departmentPermissionAdmin;

    /** 完整权限目录（按 category 分组、组内 sort_order+code 排序）。 */
    @GetMapping("/permission-catalog")
    public List<PermissionCatalogDto> permissionCatalog() {
        return departmentPermissionAdmin.catalog();
    }

    /** 某部门已直配的权限点 code 列表。 */
    @GetMapping("/departments/{departmentId}/permissions")
    public DepartmentPermissionsDto getDepartmentPermissions(@PathVariable UUID departmentId) {
        return departmentPermissionAdmin.getDepartmentPermissions(departmentId);
    }

    /** 保存某部门的直配权限点(期望的完整集合，服务端按差量落库)。 */
    @PutMapping("/departments/{departmentId}/permissions")
    public PermissionChangeDto setDepartmentPermissions(@PathVariable UUID departmentId,
                                                        @Valid @RequestBody DepartmentPermissionsDto req) {
        return departmentPermissionAdmin.setDepartmentPermissions(departmentId,
                req.permissions() == null ? List.of() : req.permissions());
    }

    /** 部门「全部授权 / 本模块 / 本组」：服务端按授权策略过滤后补齐。 */
    @PutMapping("/departments/{departmentId}/permissions/grant-all")
    public PermissionChangeDto grantAllToDepartment(@PathVariable UUID departmentId,
                                                    @Valid @RequestBody(required = false) PermissionBulkScopeDto scope) {
        return departmentPermissionAdmin.grantAll(departmentId,
                scope == null ? PermissionBulkScopeDto.everything() : scope);
    }

    /** 全员基础包(每个在职员工都隐式持有的码)。 */
    @GetMapping("/permission-baseline")
    public DepartmentPermissionsDto baseline() {
        return departmentPermissionAdmin.baseline();
    }

    /** 保存全员基础包(期望的完整集合，服务端按差量落库)。 */
    @PutMapping("/permission-baseline")
    public PermissionChangeDto setBaseline(@Valid @RequestBody DepartmentPermissionsDto req) {
        return departmentPermissionAdmin.setBaseline(
                req.permissions() == null ? List.of() : req.permissions());
    }

    /** 某用户的有效权限分解(基础包/部门/覆盖/负责人委派/最终有效)。 */
    @GetMapping("/users/{userId}/effective-permissions")
    public EffectivePermissionsDto effectivePermissions(@PathVariable UUID userId) {
        return departmentPermissionAdmin.effectivePermissions(userId);
    }
}
