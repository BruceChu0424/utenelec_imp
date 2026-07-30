package com.uten.imp.features.admin;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.auth.model.UserAccount;
import com.uten.imp.features.auth.model.UserAccountRepository;
import org.springframework.stereotype.Component;

import java.util.UUID;

/** admin 三个 Service 共用的账号查找与超管保护。 */
@Component
class AdminUserSupport {

    private final UserAccountRepository userRepo;

    AdminUserSupport(UserAccountRepository userRepo) {
        this.userRepo = userRepo;
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
}
