package com.uten.imp.features.admin;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.auth.model.UserAccount;
import com.uten.imp.features.auth.model.UserAccountRepository;
import com.uten.imp.security.SecurityContextCurrentUser;
import org.springframework.stereotype.Component;

import java.util.UUID;

/** admin 三个 Service 共用的账号查找与超管保护。 */
@Component
class AdminUserSupport {

    private final UserAccountRepository userRepo;
    private final SecurityContextCurrentUser currentUser;

    AdminUserSupport(UserAccountRepository userRepo, SecurityContextCurrentUser currentUser) {
        this.userRepo = userRepo;
        this.currentUser = currentUser;
    }

    UserAccount require(UUID id) {
        return userRepo.findById(id).filter(u -> !u.isDeleted())
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "账号不存在"));
    }

    /** 超级管理员的权限不可通过管理端修改。 */
    void requireNotSuperAdmin(UserAccount target) {
        if (target.isSuperAdmin()) {
            throw new ApiException(ErrorCode.FORBIDDEN, "不能修改超级管理员的权限");
        }
    }

    /** Routine HR support must never operate on itself or a super administrator. */
    void requireAccountSupportTarget(UserAccount target) {
        requireNotSuperAdmin(target);
        UUID actorId = currentUser.requireId();
        if (actorId.equals(target.getId())) {
            throw new ApiException(ErrorCode.FORBIDDEN, "不能对本人执行账号支持操作");
        }
    }

    /** Authorization policy is a super-admin-only boundary, independent of JWT permission claims. */
    void requireCurrentSuperAdmin() {
        var actor = currentUser.get()
                .orElseThrow(() -> new ApiException(ErrorCode.UNAUTHORIZED));
        if (!actor.isSuperAdmin()) {
            throw new ApiException(ErrorCode.FORBIDDEN, "仅超级管理员可管理授权策略");
        }
    }

    /** Authorization changes additionally forbid self-targeting and super-admin targets. */
    void requireAuthorizationTarget(UserAccount target) {
        requireCurrentSuperAdmin();
        requireNotSuperAdmin(target);
        if (currentUser.requireId().equals(target.getId())) {
            throw new ApiException(ErrorCode.FORBIDDEN, "不能修改本人的授权策略");
        }
    }
}
