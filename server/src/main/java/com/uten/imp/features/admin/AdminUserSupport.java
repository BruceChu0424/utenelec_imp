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

    /** 当前操作人（用于显式审计写入，如「设为/取消超管」）。调用方应先过超管校验。 */
    com.uten.imp.security.AuthUser requireCurrentUser() {
        return currentUser.get()
                .orElseThrow(() -> new ApiException(ErrorCode.UNAUTHORIZED));
    }

    /** Authorization changes additionally forbid self-targeting and super-admin targets. */
    void requireAuthorizationTarget(UserAccount target) {
        requireCurrentSuperAdmin();
        requireNotSuperAdmin(target);
        if (currentUser.requireId().equals(target.getId())) {
            throw new ApiException(ErrorCode.FORBIDDEN, "不能修改本人的授权策略");
        }
    }

    /**
     * 校验「设为/取消超级管理员」：仅超管可操作；降级时禁止降本人、禁止降最后一位超管
     * （否则会把所有人锁在授权管理之外）。升级无额外限制。
     */
    void requireSuperAdminToggle(UserAccount target, boolean newFlag) {
        requireCurrentSuperAdmin();
        if (!newFlag && target.isSuperAdmin()) {
            if (currentUser.requireId().equals(target.getId())) {
                throw new ApiException(ErrorCode.FORBIDDEN, "不能取消本人的超级管理员身份");
            }
            if (userRepo.countBySuperAdminTrueAndDeletedFalse() <= 1) {
                throw new ApiException(ErrorCode.CONFLICT, "至少需保留一位超级管理员");
            }
        }
    }
}
