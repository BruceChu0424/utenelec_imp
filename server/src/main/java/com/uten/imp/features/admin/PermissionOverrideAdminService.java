package com.uten.imp.features.admin;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.admin.dto.PermissionOverridesDto;
import com.uten.imp.features.auth.model.RefreshTokenRepository;
import com.uten.imp.features.auth.model.UserAccount;
import com.uten.imp.features.auth.model.UserAccountRepository;
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
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import java.util.stream.Collectors;

/** 超级管理员维护个人权限点覆盖：查询与整体替换某用户的 grant/revoke 覆盖。 */
@Service
@RequiredArgsConstructor
@PreAuthorize("hasAuthority('authorization:manage') and principal.superAdmin")
public class PermissionOverrideAdminService {

    private final UserPermissionOverrideRepository overrideRepo;
    private final PermissionRepository permissionRepo;
    private final TxSessionVars tx;
    private final AdminUserSupport support;
    private final RefreshTokenRepository refreshTokenRepo;
    private final UserAccountRepository userAccountRepo;

    /** 某用户的个人权限点覆盖（grant/revoke 分列）。 */
    @Transactional(readOnly = true)
    public PermissionOverridesDto getPermissionOverrides(UUID userId) {
        support.requireCurrentSuperAdmin();
        support.require(userId);
        List<String> grants = new ArrayList<>();
        List<String> revokes = new ArrayList<>();
        for (Object[] row : overrideRepo.findCodeAndEffectByUserId(userId)) {
            if ("revoke".equals(row[1])) {
                revokes.add((String) row[0]);
            } else {
                grants.add((String) row[0]);
            }
        }
        return new PermissionOverridesDto(grants, revokes);
    }

    /**
     * 整体替换某用户的个人权限点覆盖。
     * 校验：perm code 必须存在于 permissions 表；同一 code 不得同时出现在 grants 和 revokes。
     */
    @Transactional
    public void setPermissionOverrides(UUID userId, List<String> grants, List<String> revokes) {
        tx.bind();
        UserAccount target = userAccountRepo.findByIdForUpdate(userId)
                .filter(account -> !account.isDeleted())
                .orElseThrow(() -> new ApiException(
                        ErrorCode.NOT_FOUND,
                        "账号不存在"));
        support.requireAuthorizationTarget(target);
        UUID sourceActorUserId = support.requireCurrentUser().getId();
        // 去重（保持顺序），避免主键冲突
        Set<String> grantSet = new LinkedHashSet<>(grants == null ? List.of() : grants);
        Set<String> revokeSet = new LinkedHashSet<>(revokes == null ? List.of() : revokes);

        Set<String> overlap = new HashSet<>(grantSet);
        overlap.retainAll(revokeSet);
        if (!overlap.isEmpty()) {
            throw new ApiException(ErrorCode.BUSINESS, "同一权限不能同时加授和回收: " + overlap);
        }
        Set<String> all = new LinkedHashSet<>(grantSet);
        all.addAll(revokeSet);
        Map<String, Permission> byCode = permissionRepo.findByCodeIn(all).stream()
                .collect(Collectors.toMap(Permission::getCode, p -> p));
        for (String code : all) {
            Permission permission = byCode.get(code);
            if (permission == null) {
                throw new ApiException(ErrorCode.BUSINESS, "权限不存在: " + code);
            }
            if (!permission.isActive() || !permission.isAssignable()) {
                throw new ApiException(
                        ErrorCode.BUSINESS,
                        "权限已停用或不可再分配: " + code);
            }
        }
        Map<UUID, String> desiredByPermissionId = new LinkedHashMap<>();
        grantSet.forEach(code -> desiredByPermissionId.put(
                byCode.get(code).getId(), "grant"));
        revokeSet.forEach(code -> desiredByPermissionId.put(
                byCode.get(code).getId(), "revoke"));

        List<UserPermissionOverride> changed = new ArrayList<>();
        for (UserPermissionOverride row :
                overrideRepo.findAllByUserIdForUpdate(userId)) {
            String desiredEffect = desiredByPermissionId.remove(
                    row.getId().getPermissionId());
            if (desiredEffect == null) {
                if (!row.isActive()) continue;
                row.setActive(false);
            } else {
                if (row.isActive()
                        && desiredEffect.equals(row.getEffect())
                        && "SUPER_ADMIN_CONFIRMED".equals(
                                row.getAuthoritySource())) {
                    continue;
                }
                row.setActive(true);
                row.setEffect(desiredEffect);
            }
            row.setAuthoritySource("SUPER_ADMIN_CONFIRMED");
            row.setSourceActorUserId(sourceActorUserId);
            row.setRowVersion(row.getRowVersion() + 1L);
            changed.add(row);
        }
        for (Map.Entry<UUID, String> desired :
                desiredByPermissionId.entrySet()) {
            UserPermissionOverride row = new UserPermissionOverride();
            row.setId(new UserPermissionOverrideId(
                    userId, desired.getKey()));
            row.setEffect(desired.getValue());
            row.setActive(true);
            row.setRowVersion(1L);
            row.setAuthoritySource("SUPER_ADMIN_CONFIRMED");
            row.setSourceActorUserId(sourceActorUserId);
            changed.add(row);
        }
        if (!changed.isEmpty()) {
            overrideRepo.saveAllAndFlush(changed);
        }
        // 吊销 refresh token，阻止继续续期旧权限。已签发 access token 的权限快照
        // 仍持续到其 exp；上线前需通过权限版本校验或更短 TTL 进一步收口窗口。
        if (!changed.isEmpty()) {
            refreshTokenRepo.revokeAllByUserId(userId);
        }
    }
}
