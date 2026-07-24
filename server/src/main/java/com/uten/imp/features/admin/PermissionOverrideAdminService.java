package com.uten.imp.features.admin;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.admin.dto.PermissionOverridesDto;
import com.uten.imp.features.auth.model.UserAccount;
import com.uten.imp.features.rbac.Permission;
import com.uten.imp.features.rbac.PermissionRepository;
import com.uten.imp.features.rbac.UserPermissionOverride;
import com.uten.imp.features.rbac.UserPermissionOverrideId;
import com.uten.imp.features.rbac.UserPermissionOverrideRepository;
import com.uten.imp.security.TxSessionVars;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.util.ArrayList;
import java.util.HashSet;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import java.util.stream.Collectors;

/** 个人权限点覆盖管理（HR）：查询与整体替换某用户的 grant/revoke 覆盖。 */
@Service
@RequiredArgsConstructor
public class PermissionOverrideAdminService {

    private final UserPermissionOverrideRepository overrideRepo;
    private final PermissionRepository permissionRepo;
    private final TxSessionVars tx;
    private final AdminUserSupport support;

    /** 某用户的个人权限点覆盖（grant/revoke 分列）。 */
    @Transactional(readOnly = true)
    public PermissionOverridesDto getPermissionOverrides(UUID userId) {
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
        UserAccount target = support.require(userId);
        support.requireNotSuperAdmin(target);
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
            if (!byCode.containsKey(code)) {
                throw new ApiException(ErrorCode.BUSINESS, "权限不存在: " + code);
            }
        }
        overrideRepo.deleteByIdUserId(userId);
        for (String code : grantSet) {
            saveOverride(userId, byCode.get(code).getId(), "grant");
        }
        for (String code : revokeSet) {
            saveOverride(userId, byCode.get(code).getId(), "revoke");
        }
    }

    private void saveOverride(UUID userId, UUID permissionId, String effect) {
        UserPermissionOverride o = new UserPermissionOverride();
        o.setId(new UserPermissionOverrideId(userId, permissionId));
        o.setEffect(effect);
        overrideRepo.save(o);
    }
}
