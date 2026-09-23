package com.uten.imp.features.admin;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.admin.dto.PermissionBulkScopeDto;
import com.uten.imp.features.admin.dto.PermissionChangeDto;
import com.uten.imp.features.admin.dto.PermissionOverridesDto;
import com.uten.imp.features.auth.PermissionResolver;
import com.uten.imp.features.auth.model.RefreshTokenRepository;
import com.uten.imp.features.auth.model.UserAccount;
import com.uten.imp.features.rbac.GrantPolicy;
import com.uten.imp.features.rbac.Permission;
import com.uten.imp.features.rbac.PermissionRepository;
import com.uten.imp.features.rbac.UserPermissionOverride;
import com.uten.imp.features.rbac.UserPermissionOverrideId;
import com.uten.imp.features.rbac.UserPermissionOverrideRepository;
import com.uten.imp.security.TxSessionVars;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import java.util.stream.Collectors;

/**
 * 超级管理员维护个人权限点覆盖：查询、按期望集合保存(服务端差量落库)与「全部授权」。
 *
 * <p>ADR-109：只校验本次新增的加授能否授予(SUPERADMIN_ONLY 拒绝)；收回任何码都允许，
 * 历史上已存在的覆盖原样保留。真的有改动才写库、吊销续期令牌并记一条带 added/removed 的
 * 业务事件(条目形如 {@code grant:码} / {@code revoke:码})。
 */
@Service
@RequiredArgsConstructor
@PreAuthorize("hasAuthority('authorization:manage') and principal.superAdmin")
public class PermissionOverrideAdminService {

    private static final String GRANT = "grant";
    private static final String REVOKE = "revoke";
    private static final String CONFIRMED = "SUPER_ADMIN_CONFIRMED";

    private final UserPermissionOverrideRepository overrideRepo;
    private final PermissionRepository permissionRepo;
    private final TxSessionVars tx;
    private final AdminUserSupport support;
    private final RefreshTokenRepository refreshTokenRepo;
    private final AdminAccountLifecycleLock accountLifecycle;
    private final PermissionResolver permissionResolver;
    private final DepartmentPermissionAdminService departmentPermissionAdmin;
    private final PermissionChangeAudit changeAudit;

    /** 某用户的个人权限点覆盖（grant/revoke 分列）。 */
    @Transactional(readOnly = true)
    public PermissionOverridesDto getPermissionOverrides(UUID userId) {
        support.requireCurrentSuperAdmin();
        support.require(userId);
        List<String> grants = new ArrayList<>();
        List<String> revokes = new ArrayList<>();
        for (Object[] row : overrideRepo.findCodeAndEffectByUserId(userId)) {
            if (REVOKE.equals(row[1])) {
                revokes.add((String) row[0]);
            } else {
                grants.add((String) row[0]);
            }
        }
        return new PermissionOverridesDto(grants, revokes);
    }

    /**
     * 保存某用户的个人权限点覆盖(请求体是期望的完整集合，服务端按差量落库)。
     * 校验：code 必须在目录里；同一 code 不得同时出现在 grants 和 revokes；
     * 新增的加授不得是超管专属码。
     */
    @Transactional
    public PermissionChangeDto setPermissionOverrides(UUID userId, List<String> grants, List<String> revokes) {
        tx.bind();
        AdminAccountLifecycleLock.LockedTarget locked = accountLifecycle.lock(userId);
        support.requireAuthorizationTarget(locked.account());
        UUID sourceActorUserId = support.requireCurrentUser().getId();
        Set<String> grantSet = new LinkedHashSet<>(grants == null ? List.of() : grants);
        Set<String> revokeSet = new LinkedHashSet<>(revokes == null ? List.of() : revokes);
        if (!grantSet.isEmpty() || !revokeSet.isEmpty()) {
            accountLifecycle.requireCurrentEmployee(locked);
            accountLifecycle.requireActiveAccount(locked);
        }
        Set<String> overlap = new HashSet<>(grantSet);
        overlap.retainAll(revokeSet);
        if (!overlap.isEmpty()) {
            throw new ApiException(ErrorCode.BUSINESS, "同一权限不能同时加授和回收: " + overlap);
        }
        Map<String, String> desired = new LinkedHashMap<>();
        grantSet.forEach(code -> desired.put(code, GRANT));
        revokeSet.forEach(code -> desired.put(code, REVOKE));
        return apply(locked.account(), desired, sourceActorUserId);
    }

    /**
     * 个人「全部授权 / 本模块 / 本组」：服务端按 grant_policy 挑出可批量的码，
     * 已被收回的撤掉收回，未通过基础包 / 部门 / 负责人委派获得的补一条加授；
     * BULK_EXCLUDED / INDIVIDUAL_ONLY / SUPERADMIN_ONLY 一律不带上，已有的覆盖不动。
     */
    @Transactional
    public PermissionChangeDto grantAll(UUID userId, PermissionBulkScopeDto scope) {
        tx.bind();
        AdminAccountLifecycleLock.LockedTarget locked = accountLifecycle.lock(userId);
        UserAccount target = locked.account();
        support.requireAuthorizationTarget(target);
        UUID sourceActorUserId = support.requireCurrentUser().getId();
        accountLifecycle.requireCurrentEmployee(locked);
        accountLifecycle.requireActiveAccount(locked);
        PermissionResolver.PermBreakdown breakdown = permissionResolver.breakdownOf(target);
        Set<String> inherited = new HashSet<>(breakdown.departmentPermissions());
        inherited.addAll(breakdown.baselinePermissions());
        inherited.addAll(breakdown.managerGrants());
        Map<String, String> desired = currentOverrides(userId);
        for (Permission permission : departmentPermissionAdmin.bulkCandidates(scope)) {
            if (!GrantPolicy.individuallyGrantable(permission.grantPolicies())) {
                continue;
            }
            String code = permission.getCode();
            if (REVOKE.equals(desired.get(code))) {
                desired.remove(code);
            }
            if (!inherited.contains(code) && !desired.containsKey(code)) {
                desired.put(code, GRANT);
            }
        }
        return apply(target, desired, sourceActorUserId);
    }

    private PermissionChangeDto apply(
            UserAccount target, Map<String, String> desired, UUID sourceActorUserId) {
        UUID userId = target.getId();
        Map<String, String> current = currentOverrides(userId);
        Set<String> newlyGranted = desired.entrySet().stream()
                .filter(entry -> GRANT.equals(entry.getValue()) && !GRANT.equals(current.get(entry.getKey())))
                .map(Map.Entry::getKey)
                .collect(Collectors.toCollection(LinkedHashSet::new));
        Set<String> touched = new LinkedHashSet<>(desired.keySet());
        Map<String, Permission> byCode = touched.isEmpty() ? Map.of()
                : permissionRepo.findByCodeIn(touched).stream()
                        .collect(Collectors.toMap(Permission::getCode, p -> p));
        for (String code : desired.keySet()) {
            Permission permission = byCode.get(code);
            if (permission == null) {
                throw new ApiException(ErrorCode.BUSINESS, "权限不存在: " + code);
            }
            if (newlyGranted.contains(code)
                    && !GrantPolicy.individuallyGrantable(permission.grantPolicies())) {
                throw new ApiException(ErrorCode.BUSINESS,
                        "这项权限只随超级管理员身份生效，不能单独授予：" + permission.getName());
            }
        }
        Map<UUID, String> desiredByPermissionId = new LinkedHashMap<>();
        desired.forEach((code, effect) -> desiredByPermissionId.put(byCode.get(code).getId(), effect));

        List<UserPermissionOverride> changed = new ArrayList<>();
        Set<String> added = new LinkedHashSet<>();
        Set<String> removed = new LinkedHashSet<>();
        List<UserPermissionOverride> existing = overrideRepo.findAllByUserIdForUpdate(userId);
        Map<UUID, String> codeById = new HashMap<>();
        byCode.values().forEach(p -> codeById.put(p.getId(), p.getCode()));
        Set<UUID> unknownIds = existing.stream()
                .map(row -> row.getId().getPermissionId())
                .filter(id -> !codeById.containsKey(id))
                .collect(Collectors.toSet());
        if (!unknownIds.isEmpty()) {
            permissionRepo.findAllById(unknownIds).forEach(p -> codeById.put(p.getId(), p.getCode()));
        }
        for (UserPermissionOverride row : existing) {
            UUID permissionId = row.getId().getPermissionId();
            String desiredEffect = desiredByPermissionId.remove(permissionId);
            if (desiredEffect == null) {
                if (!row.isActive()) continue;
                row.setActive(false);
                removed.add(row.getEffect() + ":" + codeById.get(permissionId));
            } else {
                if (row.isActive()
                        && desiredEffect.equals(row.getEffect())
                        && CONFIRMED.equals(row.getAuthoritySource())) {
                    continue;
                }
                if (row.isActive() && !desiredEffect.equals(row.getEffect())) {
                    removed.add(row.getEffect() + ":" + codeById.get(permissionId));
                }
                if (!row.isActive() || !desiredEffect.equals(row.getEffect())) {
                    added.add(desiredEffect + ":" + codeById.get(permissionId));
                } else {
                    // 来源不可证明的历史覆盖经超级管理员重新确认，同样是一次授权决定。
                    added.add("confirm_" + desiredEffect + ":" + codeById.get(permissionId));
                }
                row.setActive(true);
                row.setEffect(desiredEffect);
            }
            row.setAuthoritySource(CONFIRMED);
            row.setSourceActorUserId(sourceActorUserId);
            row.setRowVersion(row.getRowVersion() + 1L);
            changed.add(row);
        }
        for (Map.Entry<UUID, String> entry : desiredByPermissionId.entrySet()) {
            UserPermissionOverride row = new UserPermissionOverride();
            row.setId(new UserPermissionOverrideId(userId, entry.getKey()));
            row.setEffect(entry.getValue());
            row.setActive(true);
            row.setRowVersion(1L);
            row.setAuthoritySource(CONFIRMED);
            row.setSourceActorUserId(sourceActorUserId);
            changed.add(row);
            added.add(entry.getValue() + ":" + codeById.get(entry.getKey()));
        }
        if (changed.isEmpty()) {
            return PermissionChangeDto.unchanged();
        }
        overrideRepo.saveAllAndFlush(changed);
        // 吊销 refresh token，阻止继续续期旧权限；已签发 access token 由用户授权版本触发器失效。
        refreshTokenRepo.revokeAllByUserId(userId);
        changeAudit.record("user_permission_override_change", "users", userId.toString(),
                added, removed, null);
        return new PermissionChangeDto(
                added.stream().sorted().toList(), removed.stream().sorted().toList());
    }

    /** 当前生效的覆盖：code → grant/revoke。 */
    private Map<String, String> currentOverrides(UUID userId) {
        Map<String, String> current = new LinkedHashMap<>();
        for (Object[] row : overrideRepo.findCodeAndEffectByUserId(userId)) {
            current.put((String) row[0], (String) row[1]);
        }
        return current;
    }
}
