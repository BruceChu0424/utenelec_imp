package com.uten.imp.security;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;

import java.util.Collection;

/**
 * 授权守卫：仅 admin / superAdmin 可把 admin 角色授予他人（防 HR 提权）。
 * 入职建号、账号角色分配、部门默认角色三处共用。
 */
public final class AdminGrantGuard {

    private AdminGrantGuard() {}

    /** 若待授角色含 "admin" 而当前操作人既不是 admin 也不是 superAdmin，则抛 403。 */
    public static void checkAdminGrant(SecurityContextCurrentUser currentUser, Collection<String> roleCodes) {
        boolean currentIsAdmin = currentUser.get()
                .map(u -> u.getRoles().contains("admin") || u.isSuperAdmin())
                .orElse(false);
        if (roleCodes != null && roleCodes.contains("admin") && !currentIsAdmin) {
            throw new ApiException(ErrorCode.FORBIDDEN, "仅管理员可授予 admin 角色");
        }
    }
}
