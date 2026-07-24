package com.uten.imp.features.auth;

import com.uten.imp.features.auth.model.UserAccount;
import com.uten.imp.features.org.employee.Employee;
import com.uten.imp.features.org.employee.EmployeeRepository;
import com.uten.imp.features.rbac.DepartmentRoleRepository;
import com.uten.imp.features.rbac.Permission;
import com.uten.imp.features.rbac.PermissionRepository;
import com.uten.imp.features.rbac.RolePermissionRepository;
import com.uten.imp.features.rbac.UserPermissionOverrideRepository;
import com.uten.imp.features.rbac.UserRoleRepository;
import org.springframework.stereotype.Service;

import java.util.HashSet;
import java.util.List;
import java.util.Set;
import java.util.UUID;

/**
 * 权限合成：角色（直接 + 部门默认）→ role_permissions 并集 → 个人权限点覆盖。
 * 超级管理员直接返回全量 permissions，绕过 role_permissions 缺漏。
 */
@Service
public class PermissionResolver {

    private final UserRoleRepository userRoleRepo;
    private final RolePermissionRepository rolePermissionRepo;
    private final PermissionRepository permissionRepo;
    private final DepartmentRoleRepository departmentRoleRepo;
    private final UserPermissionOverrideRepository overrideRepo;
    private final EmployeeRepository employeeRepo;

    public PermissionResolver(UserRoleRepository userRoleRepo, RolePermissionRepository rolePermissionRepo,
                              PermissionRepository permissionRepo, DepartmentRoleRepository departmentRoleRepo,
                              UserPermissionOverrideRepository overrideRepo, EmployeeRepository employeeRepo) {
        this.userRoleRepo = userRoleRepo;
        this.rolePermissionRepo = rolePermissionRepo;
        this.permissionRepo = permissionRepo;
        this.departmentRoleRepo = departmentRoleRepo;
        this.overrideRepo = overrideRepo;
        this.employeeRepo = employeeRepo;
    }

    public Set<String> rolesOf(UUID userId) {
        return new HashSet<>(userRoleRepo.findRoleCodesByUserId(userId));
    }

    /**
     * 用户权限集合。超级管理员（{@code users.is_super_admin=true}）直接拿到全量
     * permissions 表内容，绕过 role_permissions 是否有缺漏。
     *
     * <p>普通用户合成顺序：
     * <ol>
     *   <li>直接角色（user_roles）∪ 所在部门默认角色（department_roles，仅直属部门）</li>
     *   <li>取这些角色的 role_permissions 并集</li>
     *   <li>应用个人权限点覆盖：grant 加授 / revoke 回收</li>
     * </ol>
     */
    public Set<String> permsOf(UserAccount user) {
        if (user.isSuperAdmin()) {
            return permissionRepo.findAll().stream()
                    .map(Permission::getCode)
                    .collect(java.util.stream.Collectors.toCollection(HashSet::new));
        }
        Set<UUID> roleIds = new HashSet<>(userRoleRepo.findRoleIdsByUserIds(List.of(user.getId())));
        // 部门默认角色（仅员工直属部门，不含子部门）
        Employee e = employeeRepo.findById(user.getEmployeeId()).orElse(null);
        if (e != null && e.getDepartment() != null) {
            roleIds.addAll(departmentRoleRepo.findRoleIdsByDepartmentId(e.getDepartment().getId()));
        }
        Set<String> perms = roleIds.isEmpty()
                ? new HashSet<>()
                : new HashSet<>(rolePermissionRepo.findPermissionCodesByRoleIds(roleIds));
        // 个人权限点覆盖：grant → add，revoke → remove
        for (Object[] row : overrideRepo.findCodeAndEffectByUserId(user.getId())) {
            String code = (String) row[0];
            if ("revoke".equals(row[1])) {
                perms.remove(code);
            } else {
                perms.add(code);
            }
        }
        return perms;
    }
}
