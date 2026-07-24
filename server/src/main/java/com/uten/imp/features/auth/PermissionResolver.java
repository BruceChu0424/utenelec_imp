package com.uten.imp.features.auth;

import com.uten.imp.features.auth.model.UserAccount;
import com.uten.imp.features.org.department.Department;
import com.uten.imp.features.org.employee.Employee;
import com.uten.imp.features.org.employee.EmployeeRepository;
import com.uten.imp.features.rbac.DepartmentPermissionRepository;
import com.uten.imp.features.rbac.Permission;
import com.uten.imp.features.rbac.PermissionRepository;
import com.uten.imp.features.rbac.Role;
import com.uten.imp.features.rbac.RolePermissionRepository;
import com.uten.imp.features.rbac.RoleRepository;
import com.uten.imp.features.rbac.UserPermissionOverrideRepository;
import com.uten.imp.features.rbac.UserRoleRepository;
import org.springframework.stereotype.Service;

import java.util.ArrayList;
import java.util.HashSet;
import java.util.List;
import java.util.Set;
import java.util.UUID;

/**
 * 权限合成（ADR-011 演进版，角色体系下线后）：
 * <pre>
 *   有效权限 = 全员基础权限（employee 角色权限包，人人有份）
 *            ∪ 部门配置（department_permissions，员工所在部门 + 所有上级部门，向上取并集）
 *            ∪ 个人加授 − 个人收回（user_permission_overrides）
 *   超级管理员恒为全量 permissions。
 * </pre>
 *
 * <p>说明：
 * <ul>
 *   <li>旧的"直接角色 ∪ 部门默认角色"层已下线（角色分配 UI 同步移除），
 *       仅保留 employee 角色作为全员基础权限包；user_roles 里其他角色数据保留
 *       但不再参与合成（JWT roles claim、DataAccessPolicy 脱敏仍读 user_roles，不受影响）。</li>
 *   <li>部门配置向上生效：在「综合营销部」配的权限，销售一~四组等下级部门员工自动获得；
 *       子部门也可以单独追加配置。与 ADR-007 的"仅直属"决策不同，此处是向上读取配置，
 *       符合"给部门配权限、部门里的人就有"的直觉。</li>
 * </ul>
 */
@Service
public class PermissionResolver {

    /** 全员基础权限包的角色 code（人人隐式持有，无需在 user_roles 里显式挂） */
    private static final String BASELINE_ROLE_CODE = "employee";

    private final UserRoleRepository userRoleRepo;
    private final RolePermissionRepository rolePermissionRepo;
    private final PermissionRepository permissionRepo;
    private final RoleRepository roleRepo;
    private final DepartmentPermissionRepository departmentPermissionRepo;
    private final UserPermissionOverrideRepository overrideRepo;
    private final EmployeeRepository employeeRepo;

    public PermissionResolver(UserRoleRepository userRoleRepo, RolePermissionRepository rolePermissionRepo,
                              PermissionRepository permissionRepo, RoleRepository roleRepo,
                              DepartmentPermissionRepository departmentPermissionRepo,
                              UserPermissionOverrideRepository overrideRepo, EmployeeRepository employeeRepo) {
        this.userRoleRepo = userRoleRepo;
        this.rolePermissionRepo = rolePermissionRepo;
        this.permissionRepo = permissionRepo;
        this.roleRepo = roleRepo;
        this.departmentPermissionRepo = departmentPermissionRepo;
        this.overrideRepo = overrideRepo;
        this.employeeRepo = employeeRepo;
    }

    /**
     * 有效权限分解（供管理端"查看某用户有效权限"直接渲染，避免前端平行实现合成逻辑）。
     *
     * @param departmentId          员工直属部门 id（无部门时为 null）
     * @param departmentName        员工直属部门名称（无部门时为 null）
     * @param departmentPermissions 部门配置权限点（所在部门 + 上级部门并集）
     * @param baselinePermissions   全员基础权限点（employee 角色包）
     * @param grants                个人加授覆盖
     * @param revokes               个人回收覆盖
     * @param effective             最终有效权限（超管为全量）
     */
    public record PermBreakdown(UUID departmentId, String departmentName,
                                Set<String> departmentPermissions, Set<String> baselinePermissions,
                                List<String> grants, List<String> revokes, Set<String> effective) {}

    /** JWT roles claim 兼容：仍返回 user_roles 里显式挂的角色（不影响权限合成）。 */
    public Set<String> rolesOf(UUID userId) {
        return new HashSet<>(userRoleRepo.findRoleCodesByUserId(userId));
    }

    public Set<String> permsOf(UserAccount user) {
        return breakdownOf(user).effective();
    }

    /**
     * 计算某用户的有效权限分解。超管的各来源分量照常计算（便于管理端展示），
     * 但 effective 恒为全量 permissions。
     */
    public PermBreakdown breakdownOf(UserAccount user) {
        // 全员基础权限（employee 角色包）
        Set<String> baseline = roleRepo.findByCode(BASELINE_ROLE_CODE)
                .map(Role::getId)
                .map(id -> new HashSet<>(rolePermissionRepo.findPermissionCodesByRoleIds(Set.of(id))))
                .orElseGet(HashSet::new);

        // 部门配置：员工所在部门 + 所有上级部门（递归 CTE，一条 SQL 取并集，避免懒加载）
        Employee e = employeeRepo.findById(user.getEmployeeId()).orElse(null);
        Department dept = (e != null) ? e.getDepartment() : null;
        UUID deptId = dept != null ? dept.getId() : null;
        String deptName = dept != null ? dept.getName() : null;
        Set<String> deptPerms = deptId == null
                ? new HashSet<>()
                : new HashSet<>(departmentPermissionRepo.findPermissionCodesByDepartmentIdWithAncestors(deptId));

        // 个人权限点覆盖：grant → add，revoke → remove
        List<String> grants = new ArrayList<>();
        List<String> revokes = new ArrayList<>();
        Set<String> effective = new HashSet<>(baseline);
        effective.addAll(deptPerms);
        for (Object[] row : overrideRepo.findCodeAndEffectByUserId(user.getId())) {
            String code = (String) row[0];
            if ("revoke".equals(row[1])) {
                revokes.add(code);
                effective.remove(code);
            } else {
                grants.add(code);
                effective.add(code);
            }
        }
        if (user.isSuperAdmin()) {
            // 超管：effective 恒为全量（即便将来新增 permission 也按"已有"处理）
            effective = allPermissionCodes();
        }
        return new PermBreakdown(deptId, deptName, deptPerms, baseline, grants, revokes, effective);
    }

    private Set<String> allPermissionCodes() {
        return permissionRepo.findAll().stream()
                .map(Permission::getCode)
                .collect(java.util.stream.Collectors.toCollection(HashSet::new));
    }
}
