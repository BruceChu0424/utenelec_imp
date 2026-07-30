package com.uten.imp.features.admin;

import com.uten.imp.features.admin.dto.PermissionDto;
import com.uten.imp.features.rbac.PermissionRepository;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.util.List;

/**
 * 权限点查询（管理端）。
 * 角色体系已下线（ADR-011/V29）：原角色分配 / 部门默认角色方法随端点一并移除，
 * 仅剩权限点列表（权限目录的平铺版，分组版见 DepartmentPermissionAdminService.catalog）。
 */
@Service
@RequiredArgsConstructor
@PreAuthorize("hasAuthority('authorization:manage') and principal.superAdmin")
public class RoleAdminService {

    private final PermissionRepository permissionRepo;

    /** 全量权限点列表。 */
    @Transactional(readOnly = true)
    public List<PermissionDto> listPermissions() {
        return permissionRepo.findAll().stream().map(PermissionDto::of).toList();
    }
}
