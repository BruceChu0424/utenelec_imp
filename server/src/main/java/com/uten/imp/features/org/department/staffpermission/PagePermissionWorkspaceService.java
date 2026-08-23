package com.uten.imp.features.org.department.staffpermission;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.auth.PermissionResolver;
import com.uten.imp.features.auth.model.RefreshTokenRepository;
import com.uten.imp.features.auth.model.UserAccount;
import com.uten.imp.features.auth.model.UserAccountRepository;
import com.uten.imp.features.org.department.Department;
import com.uten.imp.features.org.department.DepartmentLevelPolicy;
import com.uten.imp.features.org.department.DepartmentRepository;
import com.uten.imp.features.org.department.staffpermission.dto.BatchSetStaffPermissionsRequest;
import com.uten.imp.features.org.department.staffpermission.dto.BatchSetStaffPermissionsResultDto;
import com.uten.imp.features.org.department.staffpermission.dto.ManagedDepartmentDto;
import com.uten.imp.features.org.department.staffpermission.dto.PagePermissionEmployeePermissionsDto;
import com.uten.imp.features.org.department.staffpermission.dto.PagePermissionEmployeePermissionsDto.PermissionState;
import com.uten.imp.features.org.department.staffpermission.dto.PagePermissionStaffPageDto;
import com.uten.imp.features.org.department.staffpermission.dto.PagePermissionStaffPageDto.StaffSummary;
import com.uten.imp.features.org.department.staffpermission.dto.PermissionDelegationCapabilityDto;
import com.uten.imp.features.org.department.staffpermission.dto.StaffDelegationResultDto;
import com.uten.imp.features.org.employee.Employee;
import com.uten.imp.features.org.employee.EmployeeRepository;
import com.uten.imp.features.rbac.ManagerPermissionDelegation;
import com.uten.imp.features.rbac.ManagerPermissionDelegationId;
import com.uten.imp.features.rbac.ManagerPermissionDelegationRepository;
import com.uten.imp.features.rbac.Permission;
import com.uten.imp.features.rbac.PermissionRepository;
import com.uten.imp.features.rbac.UserPermissionOverride;
import com.uten.imp.features.rbac.UserPermissionOverrideId;
import com.uten.imp.features.rbac.UserPermissionOverrideRepository;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.PermissionDelegationPolicy;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.time.Instant;
import java.util.ArrayList;
import java.util.Collection;
import java.util.Comparator;
import java.util.HashMap;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.Set;
import java.util.TreeSet;
import java.util.UUID;
import java.util.function.Function;
import java.util.stream.Collectors;
import com.uten.imp.features.org.employee.EmploymentStatusPolicy;

/**
 * Scalable page-permission workspace: bounded staff search, one selected
 * employee detail, and atomic compare-and-set mutations.
 */
@Service
@RequiredArgsConstructor
public class PagePermissionWorkspaceService {

    static final String CENTRAL_OVERRIDE = "CENTRAL_OVERRIDE";
    static final String MANAGER_DELEGATION = "MANAGER_DELEGATION";
    private final EmployeeRepository employeeRepo;
    private final DepartmentRepository departmentRepo;
    private final DepartmentPermissionStaffQuery staffQuery;
    private final UserAccountRepository userAccountRepo;
    private final PermissionRepository permissionRepo;
    private final ManagerPermissionDelegationRepository delegationRepo;
    private final UserPermissionOverrideRepository overrideRepo;
    private final RefreshTokenRepository refreshTokenRepo;
    private final SecurityContextCurrentUser currentUser;
    private final TxSessionVars tx;
    private final PermissionResolver permissionResolver;
    private final PermissionDelegationPolicy delegationPolicy;
    private final PermissionSurfaceRegistry surfaceRegistry;
    private final PagePermissionDelegationFeatureGate featureGate;
    private final OrganizationPermissionManagementScopeService managementScopeService;

    @Transactional(readOnly = true)
    public PermissionDelegationCapabilityDto capability(String surfaceKey) {
        AuthUser actor = requireStaffSubject();
        if (!featureGate.enabled()) {
            return new PermissionDelegationCapabilityDto(
                    surfaceKey, actor.isSuperAdmin(), false);
        }
        surfaceRegistry.permissionsFor(surfaceKey);
        return new PermissionDelegationCapabilityDto(
                surfaceKey,
                actor.isSuperAdmin(),
                managementScopeService.hasManagementAuthority(actor));
    }

    @Transactional(readOnly = true)
    public List<ManagedDepartmentDto> managedDepartments(String surfaceKey) {
        AuthUser actor = requireStaffSubject();
        featureGate.requireEnabled();
        surfaceRegistry.permissionsFor(surfaceKey);
        return managementScopeService.managedDepartments(actor).stream()
                .map(department -> new ManagedDepartmentDto(
                        department.departmentId(),
                        department.code(),
                        department.departmentName(),
                        department.level(),
                        department.parentId(),
                        department.sortOrder(),
                        department.selectable()))
                .toList();
    }

    @Transactional(readOnly = true)
    public PagePermissionStaffPageDto staff(
            String surfaceKey,
            UUID departmentId,
            String search,
            int page,
            int size) {
        AuthUser actor = requireStaffSubject();
        featureGate.requireEnabled();
        surfaceRegistry.permissionsFor(surfaceKey);
        if (search != null && search.trim().length() > 100) {
            throw new ApiException(
                    ErrorCode.VALIDATION_FAILED,
                    "搜索内容不能超过 100 个字符");
        }
        Department department = departmentId == null
                ? null : requireManagedDepartment(departmentId, actor);
        var searchAuthority = managementScopeService.staffSearchAuthority(actor)
                .orElseThrow(() -> new ApiException(
                        ErrorCode.FORBIDDEN,
                        "当前账号没有可管理的员工范围"));
        DepartmentPermissionStaffQuery.Result result =
                staffQuery.query(
                        searchAuthority,
                        departmentId,
                        actor.isSuperAdmin() ? null : actor.getEmployeeId(),
                        search,
                        page,
                        size);
        List<UUID> employeeIds = result.staff().stream()
                .map(DepartmentPermissionStaffQuery.StaffProjection::employeeId)
                .toList();
        Map<UUID, UserAccount> accounts = employeeIds.isEmpty()
                ? Map.of()
                : userAccountRepo.findActiveRowsByEmployeeIds(employeeIds).stream()
                        .collect(Collectors.toMap(
                                UserAccount::getEmployeeId,
                                Function.identity(),
                                (left, right) -> left));
        List<StaffSummary> staff = result.staff().stream()
                .map(row -> summary(row, accounts.get(row.employeeId())))
                .toList();
        return new PagePermissionStaffPageDto(
                surfaceKey,
                department == null ? null : department.getId(),
                department == null ? null : department.getName(),
                result.page(),
                result.size(),
                result.total(),
                result.totalPages(),
                staff);
    }

    @Transactional(readOnly = true)
    public PagePermissionEmployeePermissionsDto employeePermissions(
            UUID employeeId,
            UUID departmentId,
            String surfaceKey) {
        AuthUser actor = requireStaffSubject();
        featureGate.requireEnabled();
        Set<String> surfacePermissions =
                surfaceRegistry.permissionsFor(surfaceKey);
        Department department = requireManagedDepartment(departmentId, actor);
        Employee target = requireCurrentTargetEmployee(employeeId, department.getId());
        UserAccount actorAccount = requireActorAccount(actor);
        UserAccount targetAccount = userAccountRepo.findByEmployeeId(target.getId())
                .filter(account -> !account.isDeleted())
                .orElse(null);

        List<ManagerPermissionDelegation> delegations = targetAccount == null
                ? List.of()
                : delegationRepo.findForEmployeePanel(
                        targetAccount.getId(), department.getId());
        Map<UUID, ManagerPermissionDelegation> delegationByPermission =
                delegations.stream().collect(Collectors.toMap(
                        row -> row.getId().getPermissionId(),
                        Function.identity(),
                        (left, right) -> left));
        List<UserPermissionOverride> overrides = targetAccount == null
                ? List.of()
                : overrideRepo.findAllByIdUserId(targetAccount.getId());
        Map<UUID, UserPermissionOverride> overrideByPermission =
                overrides.stream().collect(Collectors.toMap(
                        row -> row.getId().getPermissionId(),
                        Function.identity(),
                        (left, right) -> left));

        PermissionResolver.PermBreakdown actorFull =
                permissionResolver.breakdownOf(actorAccount);
        Set<String> actorEffective = actorFull.effective();
        Set<String> actorCeiling = actor.isSuperAdmin()
                ? Set.of()
                : permissionResolver.delegableCeilingOf(actorAccount);
        PermissionResolver.PermissionBreakdowns targetBreakdowns =
                targetAccount == null
                        ? null
                        : permissionResolver.breakdownsOf(targetAccount);

        List<Permission> catalog = permissionRepo.findByCodeIn(surfacePermissions).stream()
                .filter(Permission::isActive)
                .sorted(permissionOrder())
                .toList();
        Set<UUID> enabledHistorical = delegations.stream()
                .filter(ManagerPermissionDelegation::isEnabled)
                .map(row -> row.getId().getPermissionId())
                .collect(Collectors.toSet());
        List<PermissionState> states = new ArrayList<>();
        for (Permission permission : catalog) {
            if (!actor.isSuperAdmin()
                    && !actorEffective.contains(permission.getCode())
                    && !enabledHistorical.contains(permission.getId())) {
                continue;
            }
            states.add(permissionState(
                    actor,
                    targetAccount,
                    permission,
                    actorEffective,
                    actorCeiling,
                    targetBreakdowns,
                    delegationByPermission.get(permission.getId()),
                    overrideByPermission.get(permission.getId())));
        }
        return new PagePermissionEmployeePermissionsDto(
                surfaceKey,
                department.getId(),
                department.getName(),
                summary(target, targetAccount, department),
                actor.isSuperAdmin() ? CENTRAL_OVERRIDE : MANAGER_DELEGATION,
                List.copyOf(states));
    }

    @Transactional
    public BatchSetStaffPermissionsResultDto setPermissions(
            UUID employeeId,
            UUID departmentId,
            String surfaceKey,
            BatchSetStaffPermissionsRequest request) {
        return setPermissionsInternal(
                employeeId, departmentId, surfaceKey, request.changes());
    }

    @Transactional
    public StaffDelegationResultDto setSinglePermission(
            UUID employeeId,
            UUID departmentId,
            String surfaceKey,
            String code,
            boolean enabled,
            long expectedVersion) {
        BatchSetStaffPermissionsResultDto result = setPermissionsInternal(
                employeeId,
                departmentId,
                surfaceKey,
                List.of(new BatchSetStaffPermissionsRequest.Change(
                        code, enabled, expectedVersion)));
        BatchSetStaffPermissionsResultDto.ChangeResult changed =
                result.changes().getFirst();
        return new StaffDelegationResultDto(
                changed.code(),
                changed.enabled(),
                changed.rowVersion(),
                changed.effective());
    }

    private BatchSetStaffPermissionsResultDto setPermissionsInternal(
            UUID employeeId,
            UUID departmentId,
            String surfaceKey,
            List<BatchSetStaffPermissionsRequest.Change> rawChanges) {
        AuthUser actor = requireStaffSubject();
        featureGate.requireEnabled();
        Set<String> surfacePermissions =
                surfaceRegistry.permissionsFor(surfaceKey);
        List<BatchSetStaffPermissionsRequest.Change> changes =
                normalizeChanges(rawChanges);
        for (BatchSetStaffPermissionsRequest.Change change : changes) {
            if (!surfacePermissions.contains(change.code())) {
                throw new ApiException(
                        ErrorCode.FORBIDDEN,
                        "该权限不属于当前页面: " + change.code());
            }
        }
        tx.bind();

        Set<UUID> employeeIdsToLock = new TreeSet<>();
        employeeIdsToLock.add(employeeId);
        if (!actor.isSuperAdmin() && actor.getEmployeeId() != null) {
            employeeIdsToLock.add(actor.getEmployeeId());
        }
        Map<UUID, Employee> lockedEmployees = employeeRepo
                .findAllByIdForUpdate(employeeIdsToLock).stream()
                .collect(Collectors.toMap(Employee::getId, Function.identity()));
        Employee target = lockedEmployees.get(employeeId);
        if (target == null) {
            throw new ApiException(ErrorCode.NOT_FOUND, "员工不存在");
        }
        Employee actorEmployee = actor.isSuperAdmin()
                ? null : lockedEmployees.get(actor.getEmployeeId());
        if (!actor.isSuperAdmin() && !isCurrentEmployee(actorEmployee)) {
            throw new ApiException(ErrorCode.FORBIDDEN, "当前负责人档案已失效");
        }

        UserAccount initialTargetAccount = userAccountRepo
                .findByEmployeeId(target.getId())
                .orElseThrow(() -> new ApiException(
                        ErrorCode.BUSINESS,
                        "该员工尚未开通登录账号，暂无法授权"));
        Set<UUID> userIdsToLock = new TreeSet<>();
        userIdsToLock.add(actor.getId());
        userIdsToLock.add(initialTargetAccount.getId());
        Map<UUID, UserAccount> lockedAccounts = userAccountRepo
                .findAllByIdForUpdate(userIdsToLock).stream()
                .collect(Collectors.toMap(UserAccount::getId, Function.identity()));
        UserAccount actorAccount = lockedAccounts.get(actor.getId());
        UserAccount targetAccount = lockedAccounts.get(initialTargetAccount.getId());
        requireCurrentActorLocked(actor, actorAccount, actorEmployee);
        if (targetAccount == null
                || !Objects.equals(targetAccount.getEmployeeId(), target.getId())) {
            throw new ApiException(
                    ErrorCode.CONFLICT,
                    "目标账号绑定已变化，请刷新后重试");
        }
        requireCurrentTarget(target, targetAccount);
        if (actorAccount.getId().equals(targetAccount.getId())
                || Objects.equals(actorAccount.getEmployeeId(), target.getId())) {
            throw new ApiException(ErrorCode.FORBIDDEN, "不能修改本人的权限");
        }
        if (targetAccount.isSuperAdmin()) {
            throw new ApiException(ErrorCode.FORBIDDEN, "不能修改超级管理员的权限");
        }
        if (target.getDepartment() == null
                || !target.getDepartment().getId().equals(departmentId)) {
            throw new ApiException(
                    ErrorCode.CONFLICT,
                    "员工所属部门已变化，请刷新后重试");
        }

        OrganizationPermissionManagementScopeService.ManagementAuthority authority =
                managementScopeService.resolveAuthority(actor, departmentId)
                        .orElseThrow(() -> new ApiException(
                                ErrorCode.FORBIDDEN,
                                "当前负责人范围不再覆盖该部门"));
        UUID scopeDepartmentId = authority.rootDepartmentId();
        Set<UUID> departmentIdsToLock = new TreeSet<>();
        departmentIdsToLock.add(departmentId);
        if (scopeDepartmentId != null) {
            departmentIdsToLock.add(scopeDepartmentId);
        }
        Map<UUID, Department> lockedDepartments = departmentRepo
                .findAllByIdForUpdate(departmentIdsToLock).stream()
                .collect(Collectors.toMap(Department::getId, Function.identity()));
        Department targetDepartment = lockedDepartments.get(departmentId);
        Department scopeDepartment = scopeDepartmentId == null
                ? null : lockedDepartments.get(scopeDepartmentId);
        requireCurrentTargetDepartment(targetDepartment);
        if (scopeDepartmentId != null
                && (scopeDepartment == null || scopeDepartment.isDeleted())) {
            throw new ApiException(
                    ErrorCode.CONFLICT,
                    "负责人组织范围已变化，请刷新后重试");
        }

        long authorizationEpoch = delegationRepo.lockAuthorizationEpoch();
        OrganizationPermissionManagementScopeService.ManagementAuthority rechecked =
                managementScopeService.resolveAuthority(actor, departmentId)
                        .orElseThrow(() -> new ApiException(
                                ErrorCode.FORBIDDEN,
                                "当前负责人范围不再覆盖该部门"));
        if (!sameAuthority(authority, rechecked)) {
            throw new ApiException(
                    ErrorCode.CONFLICT,
                    "负责人组织范围已变化，请刷新后重试");
        }
        requireCurrentActorLocked(actor, actorAccount, actorEmployee);
        requireCurrentTarget(target, targetAccount);

        Set<String> codes = changes.stream()
                .map(BatchSetStaffPermissionsRequest.Change::code)
                .collect(Collectors.toCollection(LinkedHashSet::new));
        Map<String, Permission> permissionByCode = permissionRepo
                .findByCodeIn(codes).stream()
                .collect(Collectors.toMap(Permission::getCode, Function.identity()));
        for (String code : codes) {
            Permission permission = permissionByCode.get(code);
            if (permission == null) {
                throw new ApiException(ErrorCode.BUSINESS, "权限不存在: " + code);
            }
            if (!permission.isActive() || !permission.isAssignable()) {
                throw new ApiException(
                        ErrorCode.BUSINESS,
                        "权限已停用或不可再分配: " + code);
            }
        }

        PermissionResolver.PermissionBreakdowns targetBreakdowns =
                permissionResolver.breakdownsOf(targetAccount);
        PermissionResolver.PermBreakdown targetBase = targetBreakdowns.base();
        Set<String> actorCeiling = actor.isSuperAdmin()
                ? Set.of()
                : permissionResolver.delegableCeilingOf(actorAccount);
        String settingMode = actor.isSuperAdmin()
                ? CENTRAL_OVERRIDE : MANAGER_DELEGATION;
        Map<String, Long> resultVersions = new LinkedHashMap<>();
        boolean changedAny;

        if (actor.isSuperAdmin()) {
            changedAny = applyCentralOverrides(
                    actorAccount,
                    targetAccount,
                    changes,
                    permissionByCode,
                    resultVersions);
        } else {
            DelegationSnapshot snapshot = new DelegationSnapshot(
                    targetAccount.getPermissionDelegationGeneration(),
                    target.getPermissionDelegationGeneration(),
                    targetDepartment.getPermissionDelegationGeneration(),
                    actorAccount.getPermissionDelegationGeneration(),
                    actorEmployee.getPermissionDelegationGeneration(),
                    actorAccount.getAuthVersion(),
                    authorizationEpoch,
                    authority.source().name(),
                    scopeDepartmentId,
                    scopeDepartment == null
                            ? null
                            : scopeDepartment.getPermissionDelegationGeneration());
            changedAny = applyManagerDelegations(
                    actorAccount,
                    targetAccount,
                    targetBase,
                    actorCeiling,
                    targetDepartment,
                    surfaceKey,
                    changes,
                    permissionByCode,
                    snapshot,
                    resultVersions);
        }
        if (changedAny) {
            refreshTokenRepo.revokeAllByUserId(targetAccount.getId());
        }

        Set<String> effective = actor.isSuperAdmin()
                ? Set.of()
                : permissionResolver.breakdownOf(targetAccount).effective();
        List<BatchSetStaffPermissionsResultDto.ChangeResult> results =
                changes.stream()
                        .map(change -> new BatchSetStaffPermissionsResultDto.ChangeResult(
                                change.code(),
                                change.enabled(),
                                resultVersions.get(change.code()),
                                actor.isSuperAdmin()
                                        ? change.enabled()
                                        : effective.contains(change.code())))
                        .toList();
        return new BatchSetStaffPermissionsResultDto(settingMode, results);
    }

    private boolean applyCentralOverrides(
            UserAccount actorAccount,
            UserAccount targetAccount,
            List<BatchSetStaffPermissionsRequest.Change> changes,
            Map<String, Permission> permissionByCode,
            Map<String, Long> resultVersions) {
        List<UserPermissionOverrideId> ids = changes.stream()
                .map(change -> new UserPermissionOverrideId(
                        targetAccount.getId(),
                        permissionByCode.get(change.code()).getId()))
                .sorted(Comparator.comparing(
                        UserPermissionOverrideId::getPermissionId))
                .toList();
        Map<UserPermissionOverrideId, UserPermissionOverride> existing = ids.isEmpty()
                ? Map.of()
                : overrideRepo.findAllByIdForUpdate(ids).stream()
                        .collect(Collectors.toMap(
                                UserPermissionOverride::getId,
                                Function.identity()));
        requireExpectedVersionsForOverrides(
                changes, permissionByCode, targetAccount.getId(), existing);

        List<UserPermissionOverride> changed = new ArrayList<>();
        for (BatchSetStaffPermissionsRequest.Change change : changes) {
            Permission permission = permissionByCode.get(change.code());
            UserPermissionOverrideId id = new UserPermissionOverrideId(
                    targetAccount.getId(), permission.getId());
            UserPermissionOverride row = existing.get(id);
            String desiredEffect = change.enabled() ? "grant" : "revoke";
            if (row != null
                    && row.isActive()
                    && desiredEffect.equals(row.getEffect())
                    && "SUPER_ADMIN_CONFIRMED".equals(row.getAuthoritySource())) {
                resultVersions.put(change.code(), row.getRowVersion());
                continue;
            }
            if (row == null) {
                row = new UserPermissionOverride();
                row.setId(id);
                row.setRowVersion(1L);
            } else {
                row.setRowVersion(row.getRowVersion() + 1L);
            }
            row.setEffect(desiredEffect);
            row.setActive(true);
            row.setAuthoritySource("SUPER_ADMIN_CONFIRMED");
            row.setSourceActorUserId(actorAccount.getId());
            changed.add(row);
            resultVersions.put(change.code(), row.getRowVersion());
        }
        if (!changed.isEmpty()) {
            overrideRepo.saveAllAndFlush(changed);
        }
        return !changed.isEmpty();
    }

    private boolean applyManagerDelegations(
            UserAccount actorAccount,
            UserAccount targetAccount,
            PermissionResolver.PermBreakdown targetBase,
            Set<String> actorCeiling,
            Department targetDepartment,
            String surfaceKey,
            List<BatchSetStaffPermissionsRequest.Change> changes,
            Map<String, Permission> permissionByCode,
            DelegationSnapshot snapshot,
            Map<String, Long> resultVersions) {
        List<ManagerPermissionDelegationId> ids = changes.stream()
                .map(change -> new ManagerPermissionDelegationId(
                        targetAccount.getId(),
                        permissionByCode.get(change.code()).getId(),
                        targetDepartment.getId()))
                .sorted(Comparator.comparing(
                        ManagerPermissionDelegationId::getPermissionId))
                .toList();
        Map<ManagerPermissionDelegationId, ManagerPermissionDelegation> existing =
                ids.isEmpty()
                        ? Map.of()
                        : delegationRepo.findAllByIdForUpdate(ids).stream()
                                .collect(Collectors.toMap(
                                        ManagerPermissionDelegation::getId,
                                        Function.identity()));
        requireExpectedVersionsForDelegations(
                changes,
                permissionByCode,
                targetAccount.getId(),
                targetDepartment.getId(),
                existing);

        List<ManagerPermissionDelegation> changed = new ArrayList<>();
        Instant now = Instant.now();
        for (BatchSetStaffPermissionsRequest.Change change : changes) {
            String code = change.code();
            Permission permission = permissionByCode.get(code);
            ManagerPermissionDelegationId id = new ManagerPermissionDelegationId(
                    targetAccount.getId(),
                    permission.getId(),
                    targetDepartment.getId());
            ManagerPermissionDelegation row = existing.get(id);
            if (change.enabled()) {
                if (!delegationPolicy.isDelegable(code)) {
                    throw new ApiException(
                            ErrorCode.FORBIDDEN,
                            delegationPolicy.nonDelegableReason(code));
                }
                if (!actorCeiling.contains(code)) {
                    throw new ApiException(
                            ErrorCode.FORBIDDEN,
                            "该权限不在你可转授的范围内: " + code);
                }
                if (targetBase.revokes().contains(code)) {
                    throw new ApiException(
                            ErrorCode.FORBIDDEN,
                            "该权限已被超级管理员明确收回，负责人不能覆盖");
                }
                if (targetBase.effective().contains(code)
                        && (row == null || !row.isEnabled())) {
                    throw new ApiException(
                            ErrorCode.BUSINESS,
                            "该员工已通过基础、部门或中央个人授权获得此权限");
                }
            }
            if (row == null && !change.enabled()) {
                resultVersions.put(code, 0L);
                continue;
            }
            if (row != null
                    && row.isEnabled() == change.enabled()
                    && (!change.enabled() || snapshot.matches(row))
                    && Objects.equals(row.getGrantedByUserId(), actorAccount.getId())
                    && Objects.equals(row.getSurfaceKey(), surfaceKey)) {
                resultVersions.put(code, row.getRowVersion());
                continue;
            }
            if (row == null) {
                row = new ManagerPermissionDelegation();
                row.setId(id);
                row.setCreatedAt(now);
                row.setCreatedBy(actorAccount.getId());
                row.setRowVersion(1L);
            } else {
                row.setRowVersion(row.getRowVersion() + 1L);
            }
            row.setEnabled(change.enabled());
            row.setSurfaceKey(surfaceKey);
            row.setGrantedByUserId(actorAccount.getId());
            snapshot.applyTo(row);
            row.setUpdatedAt(now);
            row.setUpdatedBy(actorAccount.getId());
            changed.add(row);
            resultVersions.put(code, row.getRowVersion());
        }
        if (!changed.isEmpty()) {
            delegationRepo.saveAllAndFlush(changed);
        }
        return !changed.isEmpty();
    }

    private List<BatchSetStaffPermissionsRequest.Change> normalizeChanges(
            List<BatchSetStaffPermissionsRequest.Change> rawChanges) {
        if (rawChanges == null || rawChanges.isEmpty()) {
            throw new ApiException(
                    ErrorCode.VALIDATION_FAILED,
                    "至少选择一个权限变更");
        }
        if (rawChanges.size() > 100) {
            throw new ApiException(
                    ErrorCode.VALIDATION_FAILED,
                    "单次最多修改 100 个权限");
        }
        Set<String> unique = new HashSet<>();
        List<BatchSetStaffPermissionsRequest.Change> normalized = new ArrayList<>();
        for (BatchSetStaffPermissionsRequest.Change change : rawChanges) {
            if (change == null
                    || change.code() == null
                    || change.code().isBlank()
                    || change.enabled() == null
                    || change.expectedVersion() == null
                    || change.expectedVersion() < 0L) {
                throw new ApiException(
                        ErrorCode.VALIDATION_FAILED,
                        "权限变更参数不完整");
            }
            String code = change.code().trim();
            if (!unique.add(code)) {
                throw new ApiException(
                        ErrorCode.VALIDATION_FAILED,
                        "同一权限不能在一批中重复修改: " + code);
            }
            normalized.add(new BatchSetStaffPermissionsRequest.Change(
                    code,
                    change.enabled(),
                    change.expectedVersion()));
        }
        normalized.sort(Comparator.comparing(
                BatchSetStaffPermissionsRequest.Change::code));
        return List.copyOf(normalized);
    }

    private void requireExpectedVersionsForOverrides(
            List<BatchSetStaffPermissionsRequest.Change> changes,
            Map<String, Permission> permissionByCode,
            UUID targetUserId,
            Map<UserPermissionOverrideId, UserPermissionOverride> existing) {
        for (BatchSetStaffPermissionsRequest.Change change : changes) {
            UserPermissionOverride row = existing.get(new UserPermissionOverrideId(
                    targetUserId,
                    permissionByCode.get(change.code()).getId()));
            long actual = row == null ? 0L : row.getRowVersion();
            requireExpectedVersion(change.code(), change.expectedVersion(), actual);
        }
    }

    private void requireExpectedVersionsForDelegations(
            List<BatchSetStaffPermissionsRequest.Change> changes,
            Map<String, Permission> permissionByCode,
            UUID targetUserId,
            UUID departmentId,
            Map<ManagerPermissionDelegationId, ManagerPermissionDelegation> existing) {
        for (BatchSetStaffPermissionsRequest.Change change : changes) {
            ManagerPermissionDelegation row = existing.get(
                    new ManagerPermissionDelegationId(
                            targetUserId,
                            permissionByCode.get(change.code()).getId(),
                            departmentId));
            long actual = row == null ? 0L : row.getRowVersion();
            requireExpectedVersion(change.code(), change.expectedVersion(), actual);
        }
    }

    private void requireExpectedVersion(
            String code,
            long expected,
            long actual) {
        if (expected != actual) {
            throw new ApiException(
                    ErrorCode.CONFLICT,
                    "权限设置已被其他人更新，请刷新后重试: " + code);
        }
    }

    private Department requireManagedDepartment(
            UUID departmentId,
            AuthUser actor) {
        if (departmentId == null) {
            throw new ApiException(
                    ErrorCode.VALIDATION_FAILED,
                    "请选择目标部门");
        }
        Department department = departmentRepo.findById(departmentId)
                .filter(row -> !row.isDeleted())
                .orElseThrow(() -> new ApiException(
                        ErrorCode.NOT_FOUND,
                        "部门不存在"));
        if (!DepartmentLevelPolicy.canHostEmployees(department.getLevel())) {
            throw new ApiException(
                    ErrorCode.FORBIDDEN,
                    "该组织节点不能承载员工权限");
        }
        if (managementScopeService.resolveAuthority(actor, departmentId).isEmpty()) {
            throw new ApiException(
                    ErrorCode.FORBIDDEN,
                    "当前账号没有该组织的负责人范围");
        }
        return department;
    }

    private Employee requireCurrentTargetEmployee(
            UUID employeeId,
            UUID departmentId) {
        Employee employee = employeeRepo.findById(employeeId)
                .orElseThrow(() -> new ApiException(
                        ErrorCode.NOT_FOUND,
                        "员工不存在"));
        if (!isCurrentEmployee(employee)) {
            throw new ApiException(
                    ErrorCode.FORBIDDEN,
                    "只能管理在职、试用或请假员工");
        }
        if (employee.getDepartment() == null
                || !departmentId.equals(employee.getDepartment().getId())) {
            throw new ApiException(
                    ErrorCode.FORBIDDEN,
                    "员工不属于所选部门");
        }
        return employee;
    }

    private AuthUser requireStaffSubject() {
        AuthUser actor = currentUser.get()
                .orElseThrow(() -> new ApiException(ErrorCode.UNAUTHORIZED));
        if (actor.isVisitor()
                || (!actor.isSuperAdmin() && actor.getEmployeeId() == null)) {
            throw new ApiException(
                    ErrorCode.FORBIDDEN,
                    "仅内部员工可管理组织权限");
        }
        return actor;
    }

    private UserAccount requireActorAccount(AuthUser actor) {
        return userAccountRepo.findById(actor.getId())
                .filter(account ->
                        !account.isDeleted() && "active".equals(account.getStatus()))
                .orElseThrow(() -> new ApiException(
                        ErrorCode.FORBIDDEN,
                        "当前账号无效"));
    }

    private void requireCurrentActorLocked(
            AuthUser actor,
            UserAccount actorAccount,
            Employee actorEmployee) {
        if (actorAccount == null
                || actorAccount.isDeleted()
                || !"active".equals(actorAccount.getStatus())) {
            throw new ApiException(ErrorCode.FORBIDDEN, "当前账号无效");
        }
        if (actorAccount.isSuperAdmin() != actor.isSuperAdmin()) {
            throw new ApiException(
                    ErrorCode.CONFLICT,
                    "当前授权身份已变化，请刷新后重试");
        }
        if (!actorAccount.isSuperAdmin()
                && (!isCurrentEmployee(actorEmployee)
                    || !Objects.equals(
                            actorAccount.getEmployeeId(),
                            actorEmployee.getId()))) {
            throw new ApiException(
                    ErrorCode.FORBIDDEN,
                    "当前负责人档案或账号绑定已失效");
        }
    }

    private void requireCurrentTarget(Employee target, UserAccount account) {
        if (!isCurrentEmployee(target)) {
            throw new ApiException(
                    ErrorCode.FORBIDDEN,
                    "只能给在职、试用或请假员工设置权限");
        }
        if (account.isDeleted() || !"active".equals(account.getStatus())) {
            throw new ApiException(
                    ErrorCode.FORBIDDEN,
                    "目标登录账号未启用");
        }
    }

    private void requireCurrentTargetDepartment(Department department) {
        if (department == null || department.isDeleted()) {
            throw new ApiException(
                    ErrorCode.CONFLICT,
                    "员工所属组织已删除或变化，请刷新后重试");
        }
        if (!DepartmentLevelPolicy.canHostEmployees(department.getLevel())) {
            throw new ApiException(
                    ErrorCode.FORBIDDEN,
                    "该组织节点不能承载员工权限");
        }
    }

    private boolean isCurrentEmployee(Employee employee) {
        return employee != null
                && !employee.isDeleted()
                && EmploymentStatusPolicy.isCurrentEmployee(employee.getStatus());
    }

    private boolean sameAuthority(
            OrganizationPermissionManagementScopeService.ManagementAuthority left,
            OrganizationPermissionManagementScopeService.ManagementAuthority right) {
        return left.source() == right.source()
                && Objects.equals(left.id(), right.id())
                && left.version() == right.version()
                && Objects.equals(
                        left.rootDepartmentId(),
                        right.rootDepartmentId())
                && Objects.equals(left.rootGeneration(), right.rootGeneration())
                && left.scopeType() == right.scopeType();
    }

    private record DelegationSnapshot(
            long targetUserGeneration,
            long targetEmployeeGeneration,
            long targetDepartmentGeneration,
            long grantorUserGeneration,
            long grantorEmployeeGeneration,
            long grantorAuthVersion,
            long grantorAuthorizationEpoch,
            String scopeSource,
            UUID scopeDepartmentId,
            Long scopeGeneration) {

        boolean matches(ManagerPermissionDelegation delegation) {
            return targetUserGeneration == delegation.getTargetUserGeneration()
                    && targetEmployeeGeneration
                            == delegation.getTargetEmployeeGeneration()
                    && targetDepartmentGeneration
                            == delegation.getTargetDepartmentGeneration()
                    && grantorUserGeneration
                            == delegation.getGrantorUserGeneration()
                    && Objects.equals(
                            grantorEmployeeGeneration,
                            delegation.getGrantorEmployeeGeneration())
                    && grantorAuthVersion == delegation.getGrantorAuthVersion()
                    && grantorAuthorizationEpoch
                            == delegation.getGrantorAuthorizationEpoch()
                    && Objects.equals(scopeSource, delegation.getScopeSource())
                    && Objects.equals(
                            scopeDepartmentId,
                            delegation.getScopeDepartmentId())
                    && Objects.equals(
                            scopeGeneration,
                            delegation.getScopeGeneration())
                    && delegation.getScopeAssignmentId() == null
                    && delegation.getScopeAssignmentVersion() == null;
        }

        void applyTo(ManagerPermissionDelegation delegation) {
            delegation.setTargetUserGeneration(targetUserGeneration);
            delegation.setTargetEmployeeGeneration(targetEmployeeGeneration);
            delegation.setTargetDepartmentGeneration(targetDepartmentGeneration);
            delegation.setGrantorUserGeneration(grantorUserGeneration);
            delegation.setGrantorEmployeeGeneration(grantorEmployeeGeneration);
            delegation.setGrantorAuthVersion(grantorAuthVersion);
            delegation.setGrantorAuthorizationEpoch(grantorAuthorizationEpoch);
            delegation.setScopeSource(scopeSource);
            delegation.setScopeDepartmentId(scopeDepartmentId);
            delegation.setScopeGeneration(scopeGeneration);
            delegation.setScopeAssignmentId(null);
            delegation.setScopeAssignmentVersion(null);
        }
    }

    private PermissionState permissionState(
            AuthUser actor,
            UserAccount targetAccount,
            Permission permission,
            Set<String> actorEffective,
            Set<String> actorCeiling,
            PermissionResolver.PermissionBreakdowns targetBreakdowns,
            ManagerPermissionDelegation delegation,
            UserPermissionOverride override) {
        String code = permission.getCode();
        boolean baseEffective = targetBreakdowns != null
                && targetBreakdowns.base().effective().contains(code);
        boolean effective = targetBreakdowns != null
                && targetBreakdowns.full().effective().contains(code);
        boolean centralMode = actor.isSuperAdmin();
        String configuredEffect;
        long rowVersion;
        if (centralMode) {
            configuredEffect = override == null || !override.isActive()
                    ? null : override.getEffect();
            rowVersion = override == null ? 0L : override.getRowVersion();
        } else {
            configuredEffect = delegation == null
                    ? null
                    : delegation.isEnabled() ? "grant" : "disabled";
            rowVersion = delegation == null ? 0L : delegation.getRowVersion();
        }
        Editability editability = editability(
                actor,
                targetAccount,
                permission,
                actorCeiling,
                targetBreakdowns,
                delegation);
        return new PermissionState(
                code,
                permission.getName(),
                normalizedActionType(permission.getActionType()),
                permission.getDescription(),
                permission.isAssignable(),
                actor.isSuperAdmin() || actorEffective.contains(code),
                baseEffective,
                effective,
                configuredEffect,
                rowVersion,
                editability.editable(),
                editability.reason());
    }

    private Editability editability(
            AuthUser actor,
            UserAccount targetAccount,
            Permission permission,
            Set<String> actorCeiling,
            PermissionResolver.PermissionBreakdowns targetBreakdowns,
            ManagerPermissionDelegation delegation) {
        String code = permission.getCode();
        if (!permission.isAssignable()) {
            return new Editability(false, "该权限不可再分配");
        }
        if (targetAccount == null) {
            return new Editability(false, "尚未开通登录账号");
        }
        if (targetAccount.isDeleted() || !"active".equals(targetAccount.getStatus())) {
            return new Editability(false, "账号当前不可用");
        }
        if (targetAccount.isSuperAdmin()) {
            return new Editability(false, "不能修改超级管理员权限");
        }
        if (targetAccount.getId().equals(actor.getId())) {
            return new Editability(false, "不能修改本人权限");
        }
        if (actor.isSuperAdmin()) {
            return new Editability(true, null);
        }
        boolean enabledHistorical = delegation != null && delegation.isEnabled();
        if (enabledHistorical && (!delegationPolicy.isDelegable(code)
                || !actorCeiling.contains(code)
                || targetBreakdowns == null
                || targetBreakdowns.base().revokes().contains(code))) {
            return new Editability(true, "仅允许关闭现有委派");
        }
        if (!delegationPolicy.isDelegable(code)) {
            return new Editability(false, delegationPolicy.nonDelegableReason(code));
        }
        if (targetBreakdowns != null
                && targetBreakdowns.base().revokes().contains(code)) {
            return new Editability(false, "超级管理员已明确收回");
        }
        if (!actorCeiling.contains(code)) {
            return new Editability(false, "不在你可转授的权限范围内");
        }
        if (targetBreakdowns != null
                && targetBreakdowns.base().effective().contains(code)
                && !enabledHistorical) {
            return new Editability(false, "已由基础、部门或中央个人授权生效");
        }
        return new Editability(true, null);
    }

    private StaffSummary summary(
            DepartmentPermissionStaffQuery.StaffProjection row,
            UserAccount account) {
        return new StaffSummary(
                row.employeeId(),
                row.code(),
                row.fullName(),
                row.departmentId(),
                row.departmentName(),
                row.positionName(),
                row.departmentManager(),
                account != null,
                account != null
                        && !account.isDeleted()
                        && "active".equals(account.getStatus()));
    }

    private StaffSummary summary(
            Employee employee,
            UserAccount account,
            Department department) {
        return new StaffSummary(
                employee.getId(),
                employee.getCode(),
                employee.getFullName(),
                department.getId(),
                department.getName(),
                employee.getPosition() == null
                        ? null : employee.getPosition().getName(),
                department.getManager() != null
                        && department.getManager().getId().equals(employee.getId()),
                account != null,
                account != null
                        && !account.isDeleted()
                        && "active".equals(account.getStatus()));
    }

    private Comparator<Permission> permissionOrder() {
        return Comparator
                .comparingInt((Permission permission) ->
                        permission.getSortOrder() == null
                                ? 0 : permission.getSortOrder())
                .thenComparing(Permission::getCode);
    }

    private String normalizedActionType(String value) {
        return value == null || value.isBlank() ? "OTHER" : value;
    }

    private record Editability(boolean editable, String reason) {
    }
}
