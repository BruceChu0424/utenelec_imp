package com.uten.imp.features.auth;

import com.uten.imp.features.auth.model.UserAccount;
import com.uten.imp.features.auth.model.UserAccountRepository;
import com.uten.imp.features.org.department.Department;
import com.uten.imp.features.org.department.DepartmentRepository;
import com.uten.imp.features.org.department.staffpermission.PermissionSurfaceRegistry;
import com.uten.imp.features.org.department.staffpermission.PagePermissionDelegationFeatureGate;
import com.uten.imp.features.org.employee.Employee;
import com.uten.imp.features.org.employee.EmployeeRepository;
import com.uten.imp.features.rbac.DepartmentPermissionRepository;
import com.uten.imp.features.rbac.ManagerPermissionDelegationRepository;
import com.uten.imp.features.rbac.Permission;
import com.uten.imp.features.rbac.PermissionRepository;
import com.uten.imp.features.rbac.Role;
import com.uten.imp.features.rbac.RolePermissionRepository;
import com.uten.imp.features.rbac.RoleRepository;
import com.uten.imp.features.rbac.UserPermissionOverrideRepository;
import com.uten.imp.features.rbac.UserRoleRepository;
import com.uten.imp.security.PermissionDelegationPolicy;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;

/**
 * 权限合成（ADR-011 演进版，角色体系下线后）：
 * <pre>
 *   有效权限 = 全员基础权限（employee 角色权限包，人人有份）
 *            ∪ 部门配置（department_permissions，员工所在部门 + 所有上级部门，向上取并集）
 *            ∪ 中央个人加授
 *            ∪ 当前仍有效的负责人页面委派
 *            − 中央个人收回（user_permission_overrides revoke 始终优先）
 *   超级管理员恒为全量 permissions。
 * </pre>
 *
 * <p>说明：
 * <ul>
 *   <li>旧的"直接角色 ∪ 部门默认角色"层已下线（角色分配 UI 同步移除），
 *       仅保留 employee 角色作为全员基础权限包；user_roles 里其他角色数据保留
 *       但不再参与权限合成；rolesOf 只为 AuthUser/AdminGrantGuard 的角色兼容读取。</li>
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
    private final UserAccountRepository userAccountRepo;
    private final DepartmentRepository departmentRepo;
    private final ManagerPermissionDelegationRepository managerDelegationRepo;
    private final PermissionDelegationPolicy delegationPolicy;
    private final PermissionSurfaceRegistry surfaceRegistry;
    private final PagePermissionDelegationFeatureGate delegationFeatureGate;

    private static final Set<String> CURRENT_EMPLOYEE_STATUSES =
            Set.of("active", "probation", "onLeave");

    public PermissionResolver(UserRoleRepository userRoleRepo, RolePermissionRepository rolePermissionRepo,
                              PermissionRepository permissionRepo, RoleRepository roleRepo,
                              DepartmentPermissionRepository departmentPermissionRepo,
                              UserPermissionOverrideRepository overrideRepo,
                              EmployeeRepository employeeRepo,
                              UserAccountRepository userAccountRepo,
                              DepartmentRepository departmentRepo,
                              ManagerPermissionDelegationRepository managerDelegationRepo,
                              PermissionDelegationPolicy delegationPolicy,
                              PermissionSurfaceRegistry surfaceRegistry,
                              PagePermissionDelegationFeatureGate delegationFeatureGate) {
        this.userRoleRepo = userRoleRepo;
        this.rolePermissionRepo = rolePermissionRepo;
        this.permissionRepo = permissionRepo;
        this.roleRepo = roleRepo;
        this.departmentPermissionRepo = departmentPermissionRepo;
        this.overrideRepo = overrideRepo;
        this.employeeRepo = employeeRepo;
        this.userAccountRepo = userAccountRepo;
        this.departmentRepo = departmentRepo;
        this.managerDelegationRepo = managerDelegationRepo;
        this.delegationPolicy = delegationPolicy;
        this.surfaceRegistry = surfaceRegistry;
        this.delegationFeatureGate = delegationFeatureGate;
    }

    /**
     * 有效权限分解（供管理端"查看某用户有效权限"直接渲染，避免前端平行实现合成逻辑）。
     *
     * @param departmentId          员工直属部门 id（无部门时为 null）
     * @param departmentName        员工直属部门名称（无部门时为 null）
     * @param departmentPermissions 部门配置权限点（所在部门 + 上级部门并集）
     * @param baselinePermissions   全员基础权限点（employee 角色包）
     * @param grants                个人加授覆盖
     * @param confirmedGrants       超级管理员在全局权限页重新确认的个人加授
     * @param legacyUnknownGrants   来源不可证明、仅维持现状且不可二次转授的历史加授
     * @param legacyUnknownRevokes  来源不可证明但继续 fail-closed 生效的历史收回
     * @param managerGrants         当前仍有效的组织负责人页面委派
     * @param contextualDelegationPresent 是否存在启用中的上下文委派行（即使当前因临时状态失效）
     * @param revokes               个人回收覆盖
     * @param effective             最终有效权限（超管为全量）
     */
    public record PermBreakdown(UUID departmentId, String departmentName,
                                Set<String> departmentPermissions, Set<String> baselinePermissions,
                                List<String> grants, List<String> confirmedGrants,
                                List<String> legacyUnknownGrants,
                                List<String> legacyUnknownRevokes,
                                List<String> managerGrants,
                                boolean contextualDelegationPresent,
                                List<String> revokes, Set<String> effective) {}

    /**
     * Base and full permission views produced from one base-source query pass.
     * The full view adds only currently valid manager delegations.
     */
    public record PermissionBreakdowns(
            PermBreakdown base,
            PermBreakdown full) {
    }

    /** Immutable server-side authority snapshot suitable for short-lived caching. */
    public record AuthorizationSnapshot(
            Set<String> roles,
            Set<String> permissions,
            boolean contextualDelegationPresent) {
        public AuthorizationSnapshot(Set<String> roles, Set<String> permissions) {
            this(roles, permissions, false);
        }

        public AuthorizationSnapshot {
            roles = Set.copyOf(roles);
            permissions = Set.copyOf(permissions);
        }
    }

    /** AuthUser 角色兼容：仍返回 user_roles 里显式挂的角色（不影响权限合成，也不写入 staff JWT）。 */
    public Set<String> rolesOf(UUID userId) {
        return new HashSet<>(userRoleRepo.findRoleCodesByUserId(userId));
    }

    /**
     * Resolves authorities from current server-side state. The caller supplies only
     * identity and authorization-shape fields already read from the account projection.
     */
    @Transactional(readOnly = true)
    public AuthorizationSnapshot authorizationSnapshot(
            UUID userId,
            UUID employeeId,
            boolean superAdmin) {
        PermBreakdown breakdown = breakdownOf(userId, employeeId, superAdmin);
        return new AuthorizationSnapshot(
                rolesOf(userId),
                breakdown.effective(),
                breakdown.contextualDelegationPresent());
    }

    public Set<String> permsOf(UserAccount user) {
        return breakdownOf(user).effective();
    }

    /**
     * 计算某用户的有效权限分解。超管的各来源分量照常计算（便于管理端展示），
     * 但 effective 恒为全量 permissions。
     */
    public PermBreakdown breakdownOf(UserAccount user) {
        return breakdownsOf(user).full();
    }

    /**
     * Effective permission sources excluding manager delegations.  This is the
     * only ceiling from which another manager delegation may be created, so
     * delegated permissions can never be re-delegated recursively.
     */
    public PermBreakdown baseBreakdownOf(UserAccount user) {
        BaseParts base = baseParts(user.getId(), user.getEmployeeId(), user.isSuperAdmin());
        return asBreakdown(base, List.of(), false, base.effective());
    }

    /**
     * Resolves the base and full views without repeating role, department or
     * central-override queries for the selected account.
     */
    public PermissionBreakdowns breakdownsOf(UserAccount user) {
        return breakdownsOf(
                user.getId(),
                user.getEmployeeId(),
                user.isSuperAdmin());
    }

    public Set<String> delegableCeilingOf(UserAccount user) {
        BaseParts base = baseParts(
                user.getId(), user.getEmployeeId(), user.isSuperAdmin());
        return delegationCeiling(base, user.isSuperAdmin());
    }

    private PermBreakdown breakdownOf(UUID userId, UUID employeeId, boolean superAdmin) {
        return breakdownsOf(userId, employeeId, superAdmin).full();
    }

    private PermissionBreakdowns breakdownsOf(
            UUID userId,
            UUID employeeId,
            boolean superAdmin) {
        BaseParts base = baseParts(userId, employeeId, superAdmin);
        PermBreakdown baseBreakdown =
                asBreakdown(base, List.of(), false, base.effective());
        if (superAdmin) {
            return new PermissionBreakdowns(baseBreakdown, baseBreakdown);
        }

        ManagerGrantResolution managerResolution =
                resolveManagerGrants(userId, employeeId);
        Set<String> managerGrants = managerResolution.codes();
        Set<String> effective = new HashSet<>(base.effective());
        effective.addAll(managerGrants);
        // A central personal revoke always wins over every manager contribution.
        effective.removeAll(base.revokes());
        List<String> sortedManagerGrants = managerGrants.stream().sorted().toList();
        PermBreakdown fullBreakdown = asBreakdown(
                base,
                sortedManagerGrants,
                managerResolution.contextualDelegationPresent(),
                effective);
        return new PermissionBreakdowns(baseBreakdown, fullBreakdown);
    }

    private BaseParts baseParts(UUID userId, UUID employeeId, boolean superAdmin) {
        // 全员基础权限（employee 角色包）
        Set<String> baseline = roleRepo.findByCode(BASELINE_ROLE_CODE)
                .map(Role::getId)
                .map(id -> new HashSet<>(rolePermissionRepo.findPermissionCodesByRoleIds(Set.of(id))))
                .orElseGet(HashSet::new);

        // 部门配置：员工所在部门 + 所有上级部门（递归 CTE，一条 SQL 取并集，避免懒加载）
        Employee e = employeeId == null ? null : employeeRepo.findById(employeeId).orElse(null);
        Department dept = (e != null) ? e.getDepartment() : null;
        UUID deptId = dept != null ? dept.getId() : null;
        String deptName = dept != null ? dept.getName() : null;
        Set<String> deptPerms = deptId == null
                ? new HashSet<>()
                : new HashSet<>(departmentPermissionRepo.findPermissionCodesByDepartmentIdWithAncestors(deptId));

        // 个人权限点覆盖：grant → add，revoke → remove
        List<String> grants = new ArrayList<>();
        List<String> confirmedGrants = new ArrayList<>();
        List<String> legacyUnknownGrants = new ArrayList<>();
        List<String> legacyUnknownRevokes = new ArrayList<>();
        List<String> revokes = new ArrayList<>();
        Set<String> effective = new HashSet<>(baseline);
        effective.addAll(deptPerms);
        for (Object[] row : overrideRepo.findCodeAndEffectByUserId(userId)) {
            String code = (String) row[0];
            boolean confirmed = row.length > 2
                    && "SUPER_ADMIN_CONFIRMED".equals(row[2]);
            if ("revoke".equals(row[1])) {
                revokes.add(code);
                if (!confirmed) {
                    legacyUnknownRevokes.add(code);
                }
                effective.remove(code);
            } else {
                grants.add(code);
                if (confirmed) {
                    confirmedGrants.add(code);
                } else {
                    legacyUnknownGrants.add(code);
                }
                effective.add(code);
            }
        }
        if (superAdmin) {
            // 超管：effective 恒为全量（即便将来新增 permission 也按"已有"处理）
            effective = allPermissionCodes();
        }
        return new BaseParts(
                deptId, deptName, Set.copyOf(deptPerms), Set.copyOf(baseline),
                List.copyOf(grants), List.copyOf(confirmedGrants),
                List.copyOf(legacyUnknownGrants), List.copyOf(legacyUnknownRevokes),
                List.copyOf(revokes), Set.copyOf(effective));
    }

    private PermBreakdown asBreakdown(
            BaseParts base,
            List<String> managerGrants,
            boolean contextualDelegationPresent,
            Set<String> effective) {
        return new PermBreakdown(
                base.departmentId(),
                base.departmentName(),
                base.departmentPermissions(),
                base.baselinePermissions(),
                base.grants(),
                base.confirmedGrants(),
                base.legacyUnknownGrants(),
                base.legacyUnknownRevokes(),
                List.copyOf(managerGrants),
                contextualDelegationPresent,
                base.revokes(),
                Set.copyOf(effective));
    }

    private ManagerGrantResolution resolveManagerGrants(
            UUID userId,
            UUID employeeId) {
        if (!delegationFeatureGate.enabled()
                || userId == null
                || employeeId == null) {
            return ManagerGrantResolution.empty();
        }
        UserAccount targetAccount = userAccountRepo.findById(userId)
                .filter(row -> !row.isDeleted() && "active".equals(row.getStatus()))
                .orElse(null);
        Employee target = employeeRepo.findById(employeeId).orElse(null);
        if (targetAccount == null
                || !Objects.equals(targetAccount.getEmployeeId(), employeeId)
                || !isCurrentEmployee(target)
                || target.getDepartment() == null
                || target.getDepartment().isDeleted()) {
            return ManagerGrantResolution.empty();
        }
        UUID currentDepartmentId = target.getDepartment().getId();
        long currentDepartmentGeneration =
                target.getDepartment().getPermissionDelegationGeneration();
        long currentAuthorizationEpoch =
                managerDelegationRepo.currentAuthorizationEpoch();
        List<ManagerPermissionDelegationRepository.EnabledDelegationCandidate> candidates =
                managerDelegationRepo.findEnabledCandidatesByUserId(userId);
        if (candidates.isEmpty()) {
            return ManagerGrantResolution.empty();
        }

        Map<UUID, GrantorContext> grantors = new HashMap<>();
        Map<UUID, Department> scopes = new HashMap<>();
        Map<UUID, Optional<UUID>> managerScopes = new HashMap<>();
        Set<String> valid = new HashSet<>();
        for (ManagerPermissionDelegationRepository.EnabledDelegationCandidate candidate : candidates) {
            String code = candidate.getPermissionCode();
            String scopeSource = candidate.getScopeSource();
            if ((!"SUPER_ADMIN".equals(scopeSource)
                    && !"DEPARTMENT_MANAGER".equals(scopeSource))
                    || !currentDepartmentId.equals(candidate.getDepartmentId())
                    || candidate.getTargetUserGeneration()
                            != targetAccount.getPermissionDelegationGeneration()
                    || candidate.getTargetEmployeeGeneration()
                            != target.getPermissionDelegationGeneration()
                    || candidate.getTargetDepartmentGeneration()
                            != currentDepartmentGeneration
                    || candidate.getGrantorAuthorizationEpoch()
                            != currentAuthorizationEpoch
                    || !delegationPolicy.isDelegable(code)
                    || !surfaceRegistry.isKnown(candidate.getSurfaceKey())
                    || !surfaceRegistry.contains(candidate.getSurfaceKey(), code)) {
                continue;
            }
            GrantorContext grantor = grantors.computeIfAbsent(
                    candidate.getGrantorUserId(), this::grantorContext);
            if (grantor == null
                    || candidate.getGrantorUserGeneration()
                            != grantor.account().getPermissionDelegationGeneration()
                    || candidate.getGrantorAuthVersion()
                            != grantor.account().getAuthVersion()
                    || !grantor.ceiling().contains(code)) {
                continue;
            }

            boolean scopeStillValid = false;
            if ("SUPER_ADMIN".equals(scopeSource)) {
                scopeStillValid = grantor.account().isSuperAdmin()
                        && candidate.getGrantorEmployeeGeneration() == null
                        && candidate.getScopeDepartmentId() == null
                        && candidate.getScopeGeneration() == null
                        && candidate.getScopeAssignmentId() == null
                        && candidate.getScopeAssignmentVersion() == null;
            } else if ("DEPARTMENT_MANAGER".equals(scopeSource)
                    && grantor.employee() != null
                    && candidate.getGrantorEmployeeGeneration() != null
                    && candidate.getGrantorEmployeeGeneration()
                            == grantor.employee().getPermissionDelegationGeneration()
                    && candidate.getScopeDepartmentId() != null
                    && candidate.getScopeGeneration() != null
                    && candidate.getScopeAssignmentId() == null
                    && candidate.getScopeAssignmentVersion() == null) {
                Department scope = scopes.computeIfAbsent(
                        candidate.getScopeDepartmentId(),
                        id -> departmentRepo.findById(id).orElse(null));
                Optional<UUID> currentScope = managerScopes.computeIfAbsent(
                        grantor.employee().getId(),
                        employee -> departmentRepo.findManagerScopeDepartmentId(
                                currentDepartmentId,
                                employee));
                scopeStillValid = scope != null
                        && !scope.isDeleted()
                        && scope.getPermissionDelegationGeneration()
                                == candidate.getScopeGeneration()
                        && currentScope.isPresent()
                        && currentScope.get().equals(scope.getId());
            }
            if (scopeStillValid) {
                valid.add(code);
            }
        }
        return new ManagerGrantResolution(Set.copyOf(valid), true);
    }

    private GrantorContext grantorContext(UUID grantorUserId) {
        UserAccount account = userAccountRepo.findById(grantorUserId)
                .filter(row -> !row.isDeleted() && "active".equals(row.getStatus()))
                .orElse(null);
        if (account == null) {
            return null;
        }
        Employee employee = account.getEmployeeId() == null
                ? null
                : employeeRepo.findById(account.getEmployeeId()).orElse(null);
        if (!account.isSuperAdmin() && !isCurrentEmployee(employee)) {
            return null;
        }
        BaseParts base = baseParts(account.getId(), account.getEmployeeId(), account.isSuperAdmin());
        return new GrantorContext(
                account,
                employee,
                delegationCeiling(base, account.isSuperAdmin()));
    }

    private Set<String> delegationCeiling(BaseParts base, boolean superAdmin) {
        Set<String> ceiling = superAdmin
                ? new HashSet<>(base.effective())
                : new HashSet<>(base.departmentPermissions());
        if (!superAdmin) {
            ceiling.addAll(base.confirmedGrants());
        }
        ceiling.removeAll(base.baselinePermissions());
        ceiling.removeAll(base.revokes());
        ceiling.removeIf(code -> !delegationPolicy.isDelegable(code));
        return Set.copyOf(ceiling);
    }

    private boolean isCurrentEmployee(Employee employee) {
        return employee != null
                && !employee.isDeleted()
                && CURRENT_EMPLOYEE_STATUSES.contains(employee.getStatus());
    }

    private Set<String> allPermissionCodes() {
        return permissionRepo.findAllByActiveTrue().stream()
                .map(Permission::getCode)
                .collect(java.util.stream.Collectors.toCollection(HashSet::new));
    }

    private record BaseParts(
            UUID departmentId,
            String departmentName,
            Set<String> departmentPermissions,
            Set<String> baselinePermissions,
            List<String> grants,
            List<String> confirmedGrants,
            List<String> legacyUnknownGrants,
            List<String> legacyUnknownRevokes,
            List<String> revokes,
            Set<String> effective) {
    }

    private record GrantorContext(
            UserAccount account,
            Employee employee,
            Set<String> ceiling) {
    }

    private record ManagerGrantResolution(
            Set<String> codes,
            boolean contextualDelegationPresent) {
        private static ManagerGrantResolution empty() {
            return new ManagerGrantResolution(Set.of(), false);
        }
    }
}
