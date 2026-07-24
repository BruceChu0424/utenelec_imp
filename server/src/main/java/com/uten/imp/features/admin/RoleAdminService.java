package com.uten.imp.features.admin;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.admin.dto.DepartmentRolesDto;
import com.uten.imp.features.admin.dto.PermissionDto;
import com.uten.imp.features.admin.dto.RoleDto;
import com.uten.imp.features.auth.model.UserAccount;
import com.uten.imp.features.org.department.DepartmentRepository;
import com.uten.imp.features.rbac.DepartmentRole;
import com.uten.imp.features.rbac.DepartmentRoleId;
import com.uten.imp.features.rbac.DepartmentRoleRepository;
import com.uten.imp.features.rbac.PermissionRepository;
import com.uten.imp.features.rbac.Role;
import com.uten.imp.features.rbac.RolePermissionRepository;
import com.uten.imp.features.rbac.RoleRepository;
import com.uten.imp.features.rbac.UserRole;
import com.uten.imp.features.rbac.UserRoleId;
import com.uten.imp.features.rbac.UserRoleRepository;
import com.uten.imp.security.AdminGrantGuard;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.util.List;
import java.util.Map;
import java.util.UUID;
import java.util.stream.Collectors;

/** 角色管理（HR）：账号角色分配、角色列表、权限点列表、部门默认角色。 */
@Service
@RequiredArgsConstructor
public class RoleAdminService {

    private final RoleRepository roleRepo;
    private final UserRoleRepository userRoleRepo;
    private final RolePermissionRepository rolePermissionRepo;
    private final PermissionRepository permissionRepo;
    private final DepartmentRepository departmentRepo;
    private final DepartmentRoleRepository departmentRoleRepo;
    private final TxSessionVars tx;
    private final SecurityContextCurrentUser currentUser;
    private final AdminUserSupport support;

    @Transactional
    public void assignRoles(UUID id, List<String> roleCodes) {
        tx.bind();
        UserAccount target = support.require(id);
        support.requireNotSuperAdmin(target);
        // 仅 admin / super admin 可授予 admin 角色（防 HR 提权，C1）
        AdminGrantGuard.checkAdminGrant(currentUser, roleCodes);
        userRoleRepo.deleteByIdUserId(id);
        for (Role role : roleRepo.findByCodeIn(roleCodes)) {
            UserRole ur = new UserRole();
            ur.setId(new UserRoleId(id, role.getId()));
            userRoleRepo.save(ur);
        }
    }

    /** 角色列表（含各角色的权限 code 列表）。 */
    @Transactional(readOnly = true)
    public List<RoleDto> listRoles() {
        Map<UUID, List<String>> permsByRole = rolePermissionRepo.findAllRolePermissionCodes().stream()
                .collect(Collectors.groupingBy(row -> (UUID) row[0],
                        Collectors.mapping(row -> (String) row[1], Collectors.toList())));
        return roleRepo.findAll().stream()
                .map(r -> RoleDto.of(r, permsByRole.getOrDefault(r.getId(), List.of())))
                .toList();
    }

    /** 全量权限点列表。 */
    @Transactional(readOnly = true)
    public List<PermissionDto> listPermissions() {
        return permissionRepo.findAll().stream().map(PermissionDto::of).toList();
    }

    /** 全量部门的默认角色（含未分配的部门 → roles 为空数组）。 */
    @Transactional(readOnly = true)
    public List<DepartmentRolesDto> listDepartmentRoles() {
        Map<UUID, List<String>> rolesByDept = departmentRoleRepo.findAllDepartmentRoleCodes().stream()
                .collect(Collectors.groupingBy(row -> (UUID) row[0],
                        Collectors.mapping(row -> (String) row[1], Collectors.toList())));
        return departmentRepo.findByDeletedFalseOrderById().stream()
                .map(d -> new DepartmentRolesDto(d.getId(), d.getName(),
                        rolesByDept.getOrDefault(d.getId(), List.of())))
                .toList();
    }

    /** 整体替换某部门的默认角色；沿用防提权守卫（非 admin 不能授 admin 角色）。 */
    @Transactional
    public void setDepartmentRoles(UUID departmentId, List<String> roleCodes) {
        tx.bind();
        departmentRepo.findById(departmentId).filter(d -> !d.isDeleted())
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "部门不存在"));
        List<String> codes = roleCodes == null ? List.of() : roleCodes;
        // 仅 admin / super admin 可授予 admin 角色（防 HR 提权，与 assignRoles 一致）
        AdminGrantGuard.checkAdminGrant(currentUser, codes);
        departmentRoleRepo.deleteByIdDepartmentId(departmentId);
        for (Role role : roleRepo.findByCodeIn(codes)) {
            DepartmentRole dr = new DepartmentRole();
            dr.setId(new DepartmentRoleId(departmentId, role.getId()));
            departmentRoleRepo.save(dr);
        }
    }
}
