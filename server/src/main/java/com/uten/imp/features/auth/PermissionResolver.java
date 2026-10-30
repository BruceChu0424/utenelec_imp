package com.uten.imp.features.auth;

import com.uten.imp.features.auth.model.UserAccount;
import com.uten.imp.features.auth.model.UserAccountRepository;
import com.uten.imp.features.org.department.Department;
import com.uten.imp.features.org.department.DepartmentRepository;
import com.uten.imp.features.org.department.staffpermission.PermissionSurfaceRegistry;
import com.uten.imp.features.org.department.staffpermission.PagePermissionDelegationFeatureGate;
import com.uten.imp.features.org.employee.Employee;
import com.uten.imp.features.org.employee.EmploymentStatusPolicy;
import com.uten.imp.features.org.employee.EmployeeRepository;
import com.uten.imp.features.rbac.DepartmentPermissionRepository;
import com.uten.imp.features.rbac.ManagerPermissionDelegationRepository;
import com.uten.imp.features.rbac.PermissionRepository;
import com.uten.imp.features.rbac.PermissionDependencyCatalog;
import com.uten.imp.features.rbac.UserPermissionOverrideRepository;
import com.uten.imp.security.PermissionDelegationPolicy;
import org.springframework.stereotype.Service;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.transaction.annotation.Transactional;
import org.springframework.boot.sql.init.dependency.DependsOnDatabaseInitialization;
import jakarta.annotation.PostConstruct;

import java.util.ArrayList;
import java.util.Collection;
import java.util.HashMap;
import java.util.HashSet;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;

/**
 * 权限合成(ADR-011 演进版；ADR-109 起角色体系彻底删除)：
 * <pre>
 *   有效权限 = 全员基础包(permissions.baseline，人人有份，管理页可编辑)
 *            ∪ 部门配置（department_permissions，员工所在部门 + 所有上级部门，向上取并集）
 *            ∪ 中央个人加授
 *            ∪ 当前仍有效的负责人页面委派
 *            − 中央个人收回（user_permission_overrides revoke 始终优先）
 *   超级管理员默认全部目录码(含超管专属码)；2026-10-30 起个人收回同样压过默认，
 *   但超管专属码只随身份生效、不参与减法。
 * </pre>
 *
 * <p>说明：
 * <ul>
 *   <li>roles / user_roles / role_permissions / department_roles 四张表已随 V677 删除，
 *       权限只有上面这一套来源。</li>
 *   <li>部门配置向上生效：在「综合营销部」配的权限，销售一~四组等下级部门员工自动获得；
 *       子部门也可以单独追加配置。与 ADR-007 的"仅直属"决策不同，此处是向上读取配置，
 *       符合"给部门配权限、部门里的人就有"的直觉。</li>
 * </ul>
 */
@Service
@DependsOnDatabaseInitialization
public class PermissionResolver {

    private final PermissionRepository permissionRepo;
    private final DepartmentPermissionRepository departmentPermissionRepo;
    private final UserPermissionOverrideRepository overrideRepo;
    private final EmployeeRepository employeeRepo;
    private final com.uten.imp.features.org.employee.EmployeeSecondaryDepartmentRepository secondaryDepartmentRepo;
    private final UserAccountRepository userAccountRepo;
    private final DepartmentRepository departmentRepo;
    private final ManagerPermissionDelegationRepository managerDelegationRepo;
    private final PermissionDelegationPolicy delegationPolicy;
    private final PermissionSurfaceRegistry surfaceRegistry;
    private final PagePermissionDelegationFeatureGate delegationFeatureGate;
    private final NamedParameterJdbcTemplate batchJdbc;
    private volatile PermissionDependencyCatalog dependencies = new PermissionDependencyCatalog(List.of());

    /** Catalog structure changes with migrations; loading once preserves bounded fanout reads. */
    @PostConstruct
    public void initializeDependencyCatalog() {
        dependencies = new PermissionDependencyCatalog(permissionRepo.findAll());
    }

    public PermissionResolver(PermissionRepository permissionRepo,
                              DepartmentPermissionRepository departmentPermissionRepo,
                              UserPermissionOverrideRepository overrideRepo,
                              EmployeeRepository employeeRepo,
                              com.uten.imp.features.org.employee.EmployeeSecondaryDepartmentRepository secondaryDepartmentRepo,
                              UserAccountRepository userAccountRepo,
                              DepartmentRepository departmentRepo,
                              ManagerPermissionDelegationRepository managerDelegationRepo,
                              PermissionDelegationPolicy delegationPolicy,
                              PermissionSurfaceRegistry surfaceRegistry,
                              PagePermissionDelegationFeatureGate delegationFeatureGate) {
        this(permissionRepo, departmentPermissionRepo, overrideRepo, employeeRepo,
                secondaryDepartmentRepo, userAccountRepo, departmentRepo,
                managerDelegationRepo, delegationPolicy, surfaceRegistry,
                delegationFeatureGate, null);
    }

    @Autowired
    public PermissionResolver(PermissionRepository permissionRepo,
                              DepartmentPermissionRepository departmentPermissionRepo,
                              UserPermissionOverrideRepository overrideRepo,
                              EmployeeRepository employeeRepo,
                              com.uten.imp.features.org.employee.EmployeeSecondaryDepartmentRepository secondaryDepartmentRepo,
                              UserAccountRepository userAccountRepo,
                              DepartmentRepository departmentRepo,
                              ManagerPermissionDelegationRepository managerDelegationRepo,
                              PermissionDelegationPolicy delegationPolicy,
                              PermissionSurfaceRegistry surfaceRegistry,
                              PagePermissionDelegationFeatureGate delegationFeatureGate,
                              JdbcTemplate jdbc) {
        this.permissionRepo = permissionRepo;
        this.departmentPermissionRepo = departmentPermissionRepo;
        this.overrideRepo = overrideRepo;
        this.employeeRepo = employeeRepo;
        this.secondaryDepartmentRepo = secondaryDepartmentRepo;
        this.userAccountRepo = userAccountRepo;
        this.departmentRepo = departmentRepo;
        this.managerDelegationRepo = managerDelegationRepo;
        this.delegationPolicy = delegationPolicy;
        this.surfaceRegistry = surfaceRegistry;
        this.delegationFeatureGate = delegationFeatureGate;
        this.batchJdbc = jdbc == null ? null : new NamedParameterJdbcTemplate(jdbc);
    }

    /**
     * 有效权限分解（供管理端"查看某用户有效权限"直接渲染，避免前端平行实现合成逻辑）。
     *
     * @param departmentId          员工直属部门 id（无部门时为 null）
     * @param departmentName        员工直属部门名称（无部门时为 null）
     * @param departmentPermissions 部门配置权限点（所在部门 + 上级部门并集）
     * @param baselinePermissions   全员基础包(permissions.baseline)
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
                                List<String> revokes, Set<String> effective, List<String> templatePermissions) {
        public PermBreakdown(UUID departmentId,String departmentName,Set<String> departmentPermissions,Set<String> baselinePermissions,
                List<String> grants,List<String> confirmedGrants,List<String> legacyUnknownGrants,List<String> legacyUnknownRevokes,
                List<String> managerGrants,boolean contextualDelegationPresent,List<String> revokes,Set<String> effective) {
            this(departmentId,departmentName,departmentPermissions,baselinePermissions,grants,confirmedGrants,
                    legacyUnknownGrants,legacyUnknownRevokes,managerGrants,contextualDelegationPresent,revokes,effective,List.of());
        }
        /** Source grants before operation-dependency normalization; explicit revokes still win. */
        public Set<String> configuredPermissions() {
            Set<String> configured = new LinkedHashSet<>(baselinePermissions);
            configured.addAll(departmentPermissions);
            configured.addAll(grants);
            configured.addAll(managerGrants);
            configured.addAll(templatePermissions);
            configured.removeAll(revokes);
            return Set.copyOf(configured);
        }
    }

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
            Set<String> permissions,
            boolean contextualDelegationPresent) {
        public AuthorizationSnapshot(Set<String> permissions) {
            this(permissions, false);
        }

        public AuthorizationSnapshot {
            permissions = Set.copyOf(permissions);
        }
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
                breakdown.effective(),
                breakdown.contextualDelegationPresent());
    }

    public Set<String> permsOf(UserAccount user) {
        // Effective-only callers do not need the management-page breakdown.
        // Account/employment eligibility remains the caller's existing gate;
        // super admins default to the whole catalog, with personal revokes
        // applied the same way since 2026-10-30, hence the shared breakdown.
        return breakdownOf(user).effective();
    }

    /**
     * 真实授出的有效权限（不含超管全量镜像）。
     *
     * <p>超管的「全部目录码」是<b>操作授权面</b>（什么都能做），不是<b>任务归属</b>（这些活归他）。
     * 业务任务卡（审核待办 / 部门定向提醒）的发卡池与收件人解析一律用这份口径（2026-10-09，
     * ADR-063 追加修订）：超管只有从 全员基础包 / 部门矩阵 / 个人加授 / 负责人委派 里真实拿到
     * 该码时才进池，个人收回仍优先。面向超管本身的运维告警（ServerAlertAudience）等继续用
     * {@link #permsOf}。
     */
    public Set<String> grantedPermsOf(UserAccount user) {
        if (!user.isSuperAdmin()) return permsOf(user);
        return breakdownsOf(user.getId(), user.getEmployeeId(), false).full().effective();
    }

    /** 按账号 id 解析真实授出权限（账号不存在/已删/停用返回空集）；供只持有 AuthUser 的读侧使用。 */
    @Transactional(readOnly = true)
    public Set<String> grantedPermsOf(UUID userId) {
        return userAccountRepo.findById(userId)
                .filter(account -> !account.isDeleted() && "active".equals(account.getStatus()))
                .map(this::grantedPermsOf)
                .orElse(Set.of());
    }

    /**
     * Current, actually granted authority intersection for an entire recipient pool.
     * One statement reads both base sources and every dynamic delegation condition;
     * no per-account JPA lookups or super-admin catalog expansion are performed.
     */
    @Transactional(readOnly = true)
    public List<UUID> usersGrantedAll(Collection<UUID> candidates, Set<String> required) {
        return usersGrantedAllAndAny(candidates, required, Set.of());
    }

    /** JDBC is mandatory in the production constructor; direct unit fixtures may omit it. */
    public boolean supportsGrantedPermissionBatch() { return batchJdbc != null; }

    @Transactional(readOnly = true)
    public List<UUID> usersGrantedAllAndAny(Collection<UUID> candidates,
                                          Set<String> required, Set<String> alternatives) {
        if (candidates.isEmpty()) return List.of();
        Set<String> requested = new HashSet<>(required);
        requested.addAll(alternatives);
        Map<UUID, Set<String>> granted = grantedPermissionsFor(candidates, requested);
        return candidates.stream().distinct().filter(id -> {
            Set<String> actual = granted.getOrDefault(id, Set.of());
            return actual.containsAll(required)
                    && (alternatives.isEmpty() || alternatives.stream().anyMatch(actual::contains));
        }).toList();
    }

    /** A single authority statement, shared by conjunctions and complex recipient predicates. */
    @Transactional(readOnly = true)
    public Map<UUID, Set<String>> grantedPermissionsFor(Collection<UUID> candidates, Set<String> requested) {
        if (candidates.isEmpty()) return Map.of();
        if (requested.isEmpty()) throw new IllegalArgumentException("At least one authority is required");
        // Retain the established direct-construction test seam. Spring always uses
        // the JDBC constructor above, including database-backed integration tests.
        if (batchJdbc == null) {
            Map<UUID, Set<String>> legacy = new HashMap<>();
            candidates.stream().distinct().forEach(id -> legacy.put(id, grantedPermsOf(id)));
            return Map.copyOf(legacy);
        }
        Map<UUID, Set<String>> granted = new HashMap<>();
        var rows = batchJdbc.query(GRANTED_PERMISSION_BATCH_SQL,
                Map.of("userIds", candidates, "codes", dependencies.lookupPermissions(requested),
                        "dependencyRules", dependencies.rulesJson(),
                        "delegationsEnabled", delegationFeatureGate.enabled()),
                (rs, row) -> new BatchGrantedPermission(rs.getObject("user_id", UUID.class),
                        rs.getString("code"), rs.getString("surface_key")));
        for (BatchGrantedPermission row : rows) {
            if (row.surfaceKey() != null && (!delegationPolicy.isDelegable(row.code())
                    || !surfaceRegistry.isKnown(row.surfaceKey())
                    || !surfaceRegistry.contains(row.surfaceKey(), row.code()))) continue;
            granted.computeIfAbsent(row.userId(), ignored -> new HashSet<>()).add(row.code());
        }
        granted.replaceAll((id, codes) -> {
            Set<String> usable = new HashSet<>(dependencies.usablePermissions(codes));
            usable.retainAll(requested);
            return Set.copyOf(usable);
        });
        return Map.copyOf(granted);
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
        // 全员基础包(permissions.baseline，一条 SQL)
        Set<String> baseline = new HashSet<>(permissionRepo.findBaselineCodes());

        // 部门配置：员工所在部门 + 所有上级部门（递归 CTE，一条 SQL 取并集，避免懒加载）
        Employee e = employeeId == null ? null : employeeRepo.findById(employeeId).orElse(null);
        Department dept = (e != null) ? e.getDepartment() : null;
        UUID deptId = dept != null ? dept.getId() : null;
        String deptName = dept != null ? dept.getName() : null;
        // V459 兼职部门：每个兼职部门（含其全部上级递归）的配置并入并集；
        // 兼职表默认空 = 与既有合成零差异。
        List<UUID> deptIds = new ArrayList<>();
        if (deptId != null) {
            deptIds.add(deptId);
        }
        if (employeeId != null) {
            deptIds.addAll(secondaryDepartmentRepo.findDepartmentIdsByEmployeeId(employeeId));
        }
        Set<String> deptPerms = deptIds.isEmpty()
                ? new HashSet<>()
                : new HashSet<>(departmentPermissionRepo
                        .findPermissionCodesByDepartmentIdsWithAncestors(deptIds));

        // 个人权限点覆盖：grant → add，revoke → remove
        List<String> grants = new ArrayList<>();
        List<String> confirmedGrants = new ArrayList<>();
        List<String> legacyUnknownGrants = new ArrayList<>();
        List<String> legacyUnknownRevokes = new ArrayList<>();
        List<String> revokes = new ArrayList<>();
        List<String> templatePermissions=permissionRepo.findUserTemplateCodes(userId);
        Set<String> effective = new HashSet<>(baseline);
        effective.addAll(deptPerms);
        effective.addAll(templatePermissions);
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
            // 超管：默认全部目录码(即便将来新增 permission 也按"已有"处理)。
            // 2026-10-30 起个人收回可压过默认；超管专属码只随身份生效，
            // 永不参与减法(即使覆盖表被手工污染)，防止把授权管理本身锁死。
            Set<String> mirrored = allPermissionCodes();
            mirrored.removeAll(revokes);
            mirrored.addAll(permissionRepo.findSuperAdminOnlyCodes());
            effective = mirrored;
        }
        return new BaseParts(
                deptId, deptName, Set.copyOf(deptPerms), Set.copyOf(baseline),
                List.copyOf(grants), List.copyOf(confirmedGrants),
                List.copyOf(legacyUnknownGrants), List.copyOf(legacyUnknownRevokes),
                List.copyOf(revokes), Set.copyOf(effective), List.copyOf(templatePermissions));
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
                dependencies.usablePermissions(effective), base.templatePermissions());
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
            ceiling.addAll(base.templatePermissions());
        }
        ceiling.removeAll(base.baselinePermissions());
        ceiling.removeAll(base.revokes());
        ceiling.retainAll(dependencies.usablePermissions(base.effective()));
        ceiling.removeIf(code -> !delegationPolicy.isDelegable(code));
        return Set.copyOf(ceiling);
    }

    private boolean isCurrentEmployee(Employee employee) {
        return employee != null
                && !employee.isDeleted()
                && EmploymentStatusPolicy.isCurrentEmployee(employee.getStatus());
    }

    private Set<String> allPermissionCodes() {
        return new HashSet<>(permissionRepo.findAllCodes());
    }

    private record BatchGrantedPermission(UUID userId, String code, String surfaceKey) {}

    // Mirrors baseParts/delegationCeiling/resolveManagerGrants for requested codes.
    // A single MVCC statement prevents mixed authorization generations during fanout.
    private static final String GRANTED_PERMISSION_BATCH_SQL = """
            WITH RECURSIVE requested AS MATERIALIZED (
                SELECT id, code, baseline FROM permissions WHERE code IN (:codes)
            ), dependency_requirements AS MATERIALIZED (
                SELECT dependency.key AS code,
                       ARRAY(SELECT jsonb_array_elements_text(alternatives.value)) AS alternatives
                FROM jsonb_each(CAST(:dependencyRules AS jsonb)) dependency
                CROSS JOIN LATERAL jsonb_array_elements(dependency.value) alternatives(value)
            ), requested_accounts AS MATERIALIZED (
                SELECT account.id, account.employee_id, account.is_super_admin,
                       account.permission_delegation_generation, account.auth_version
                FROM users account
                WHERE account.id IN (:userIds) AND NOT account.is_deleted AND account.status='active'
            ), accounts AS MATERIALIZED (
                SELECT account.* FROM requested_accounts account
                UNION
                SELECT grantor.id, grantor.employee_id, grantor.is_super_admin,
                       grantor.permission_delegation_generation, grantor.auth_version
                FROM users grantor
                JOIN manager_permission_delegations delegation ON delegation.granted_by_user_id=grantor.id
                JOIN requested_accounts target ON target.id=delegation.user_id
                JOIN requested permission ON permission.id=delegation.permission_id
                WHERE delegation.enabled AND :delegationsEnabled
                  AND NOT grantor.is_deleted AND grantor.status='active'
            ), memberships(user_id, department_id) AS (
                SELECT account.id, employee.department_id FROM accounts account
                JOIN employees employee ON employee.id=account.employee_id
                WHERE employee.department_id IS NOT NULL
                UNION
                SELECT account.id, secondary.department_id FROM accounts account
                JOIN employee_secondary_departments secondary ON secondary.employee_id=account.employee_id
            ), ancestors(user_id, department_id, parent_id) AS (
                SELECT membership.user_id, department.id, department.parent_id FROM memberships membership
                JOIN departments department ON department.id=membership.department_id
                UNION
                SELECT ancestor.user_id, parent.id, parent.parent_id FROM ancestors ancestor
                JOIN departments parent ON parent.id=ancestor.parent_id
            ), department_codes AS MATERIALIZED (
                SELECT DISTINCT ancestor.user_id, permission.code FROM ancestors ancestor
                JOIN authorization_department_permission_sources allocation ON allocation.department_id=ancestor.department_id
                JOIN requested permission ON permission.id=allocation.permission_id
            ), template_codes AS MATERIALIZED (
                SELECT source.user_id,source.code FROM authorization_user_template_permission_sources source
                JOIN accounts account ON account.id=source.user_id
                JOIN requested permission ON permission.code=source.code
            ), overrides AS MATERIALIZED (
                SELECT allocation.user_id, permission.code, allocation.effect, allocation.authority_source
                FROM user_permission_overrides allocation
                JOIN accounts account ON account.id=allocation.user_id
                JOIN requested permission ON permission.id=allocation.permission_id
                WHERE allocation.active
            ), base_codes(user_id, code) AS (
                SELECT account.id, permission.code FROM requested_accounts account
                CROSS JOIN requested permission WHERE permission.baseline
                UNION SELECT template.user_id,template.code FROM template_codes template
                JOIN requested_accounts account ON account.id=template.user_id
                UNION
                SELECT department.user_id, department.code FROM department_codes department
                JOIN requested_accounts account ON account.id=department.user_id
                UNION
                SELECT allocation.user_id, allocation.code FROM overrides allocation
                JOIN requested_accounts account ON account.id=allocation.user_id
                WHERE allocation.effect IS DISTINCT FROM 'revoke'
            ), grantor_base_codes(user_id, code) AS MATERIALIZED (
                SELECT raw.user_id, raw.code FROM (
                    SELECT account.id AS user_id, permission.code FROM accounts account
                    CROSS JOIN requested permission WHERE permission.baseline
                    UNION SELECT department.user_id, department.code FROM department_codes department
                    UNION SELECT template.user_id,template.code FROM template_codes template
                    UNION SELECT allocation.user_id, allocation.code FROM overrides allocation
                          WHERE allocation.effect IS DISTINCT FROM 'revoke'
                ) raw
                WHERE NOT EXISTS (SELECT 1 FROM overrides allocation
                    WHERE allocation.user_id=raw.user_id AND allocation.code=raw.code AND allocation.effect='revoke')
            ), delegation_targets AS MATERIALIZED (
                SELECT delegation.*, permission.code, permission.baseline,
                       grantor.employee_id AS grantor_employee_id,
                       grantor.is_super_admin AS grantor_super_admin,
                       target_employee.department_id AS current_department_id
                FROM manager_permission_delegations delegation
                JOIN requested permission ON permission.id=delegation.permission_id
                JOIN requested_accounts target ON target.id=delegation.user_id
                JOIN employees target_employee ON target_employee.id=target.employee_id
                JOIN departments target_department ON target_department.id=target_employee.department_id
                JOIN accounts grantor ON grantor.id=delegation.granted_by_user_id
                LEFT JOIN employees grantor_employee ON grantor_employee.id=grantor.employee_id
                CROSS JOIN authorization_state auth_state
                WHERE :delegationsEnabled AND delegation.enabled AND auth_state.singleton_id=1
                  AND NOT target_employee.is_deleted AND target_employee.status IN ('active','probation','onLeave')
                  AND NOT target_department.is_deleted
                  AND delegation.department_id=target_employee.department_id
                  AND delegation.target_user_generation=target.permission_delegation_generation
                  AND delegation.target_employee_generation=target_employee.permission_delegation_generation
                  AND delegation.target_department_generation=target_department.permission_delegation_generation
                  AND delegation.grantor_user_generation=grantor.permission_delegation_generation
                  AND delegation.grantor_auth_version=grantor.auth_version
                  AND delegation.grantor_authorization_epoch=auth_state.epoch
                  AND (grantor.is_super_admin OR (NOT grantor_employee.is_deleted
                       AND grantor_employee.status IN ('active','probation','onLeave')))
                  AND NOT permission.baseline
                  AND (grantor.is_super_admin OR EXISTS (
                      SELECT 1 FROM department_codes department
                      WHERE department.user_id=grantor.id AND department.code=permission.code)
                      OR EXISTS (SELECT 1 FROM overrides allocation
                          WHERE allocation.user_id=grantor.id AND allocation.code=permission.code
                            AND allocation.effect IS DISTINCT FROM 'revoke'
                            AND allocation.authority_source='SUPER_ADMIN_CONFIRMED')
                      OR EXISTS(SELECT 1 FROM template_codes template
                          WHERE template.user_id=grantor.id AND template.code=permission.code))
                  AND NOT EXISTS (SELECT 1 FROM overrides allocation
                      WHERE allocation.user_id=grantor.id AND allocation.code=permission.code
                        AND allocation.effect='revoke')
                  AND (grantor.is_super_admin OR NOT EXISTS (
                      SELECT 1 FROM dependency_requirements required
                      WHERE required.code=permission.code AND NOT EXISTS (
                          SELECT 1 FROM grantor_base_codes held
                          WHERE held.user_id=grantor.id AND held.code=ANY(required.alternatives))))
            ), scope_ancestors(user_id, permission_id, id, parent_id, code, level, manager_id, depth) AS (
                SELECT target.user_id, target.permission_id, department.id, department.parent_id,
                       department.code, department.level, department.manager_id, 0
                FROM delegation_targets target JOIN departments department ON department.id=target.current_department_id
                WHERE NOT department.is_deleted
                UNION ALL
                SELECT child.user_id, child.permission_id, parent.id, parent.parent_id,
                       parent.code, parent.level, parent.manager_id, child.depth+1
                FROM scope_ancestors child JOIN departments parent ON parent.id=child.parent_id
                WHERE NOT parent.is_deleted
            ), delegated_codes(user_id, code, surface_key) AS (
                SELECT target.user_id, target.code, target.surface_key FROM delegation_targets target
                LEFT JOIN departments scope ON scope.id=target.scope_department_id
                LEFT JOIN employees grantor_employee ON grantor_employee.id=target.grantor_employee_id
                LEFT JOIN LATERAL (
                    SELECT authority.id FROM (
                        SELECT office.id, 0 AS priority, 0 AS depth
                        FROM departments office JOIN departments company ON company.id=office.parent_id
                        WHERE office.code='GM' AND office.manager_id=target.grantor_employee_id
                          AND NOT office.is_deleted
                          AND office.level IN ('管理中心','一级部门','二级班组','三级科室')
                          AND grantor_employee.department_id=office.id AND NOT grantor_employee.is_deleted
                          AND grantor_employee.status IN ('active','probation','onLeave')
                          AND NOT company.is_deleted AND company.level='公司' AND company.parent_id IS NULL
                        UNION ALL
                        SELECT ancestor.id, 1 AS priority, ancestor.depth FROM scope_ancestors ancestor
                        WHERE ancestor.user_id=target.user_id AND ancestor.permission_id=target.permission_id
                          AND ancestor.manager_id=target.grantor_employee_id AND ancestor.code<>'GM'
                          AND ancestor.level IN ('管理中心','一级部门','二级班组','三级科室')
                    ) authority ORDER BY authority.priority, authority.depth LIMIT 1
                ) current_scope ON TRUE
                WHERE (target.scope_source='SUPER_ADMIN' AND target.grantor_super_admin
                    AND target.grantor_employee_generation IS NULL AND target.scope_department_id IS NULL
                    AND target.scope_generation IS NULL AND target.scope_assignment_id IS NULL
                    AND target.scope_assignment_version IS NULL)
                  OR (target.scope_source='DEPARTMENT_MANAGER' AND grantor_employee.id IS NOT NULL
                    AND target.grantor_employee_generation=grantor_employee.permission_delegation_generation
                    AND scope.id IS NOT NULL AND NOT scope.is_deleted
                    AND target.scope_generation=scope.permission_delegation_generation
                    AND target.scope_assignment_id IS NULL AND target.scope_assignment_version IS NULL
                    AND current_scope.id=scope.id)
            ), granted(user_id, code, surface_key) AS (
                SELECT base.user_id, base.code, CAST(NULL AS text) FROM base_codes base
                UNION ALL SELECT delegated.user_id, delegated.code, delegated.surface_key FROM delegated_codes delegated
            )
            SELECT granted.user_id, granted.code, granted.surface_key FROM granted
            WHERE NOT EXISTS (SELECT 1 FROM overrides allocation
                WHERE allocation.user_id=granted.user_id AND allocation.code=granted.code AND allocation.effect='revoke')
            """;

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
            Set<String> effective, List<String> templatePermissions) {
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
