package com.uten.imp.features.org.employee;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.auth.model.RefreshTokenRepository;
import com.uten.imp.features.auth.model.UserAccountRepository;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;

import java.util.UUID;

/**
 * 手机号变更后的登录账号同步（ADR-021 §三）：登录账号 = 手机号，
 * 任何手机号改写（HR 编辑 / change-phone / 员工申请 HR 审批合并）都必须走这里，
 * 单事务内把 users.login_account 改为新号并吊销全部 refresh token（强制重新登录）。
 */
@Component
@RequiredArgsConstructor
public class EmployeeLoginAccountSync {

    private final UserAccountRepository userRepo;
    private final RefreshTokenRepository refreshTokenRepo;

    /**
     * 同步登录账号。必须在手机号加密写入的同一事务内调用。
     *
     * @param employeeId       员工
     * @param normalizedPhone  已规范化的 11 位新手机号
     */
    public void syncLoginAccount(UUID employeeId, String normalizedPhone) {
        userRepo.findByEmployeeId(employeeId).ifPresent(account -> {
            if (normalizedPhone.equals(account.getLoginAccount())) {
                return; // 未变化，不动账号不踢登录
            }
            userRepo.findByLoginAccount(normalizedPhone)
                    .filter(other -> !other.getId().equals(account.getId()))
                    .ifPresent(other -> {
                        throw new ApiException(
                                ErrorCode.CONFLICT, "该手机号已被用作其他账号的登录名");
                    });
            account.setLoginAccount(normalizedPhone);
            userRepo.save(account);
            // 强制重新登录：旧手机号作为登录名的会话全部失效
            refreshTokenRepo.revokeAllByUserId(account.getId());
        });
    }
}
