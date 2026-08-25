package com.uten.imp.features.admin;

import com.uten.imp.common.identity.CurrentEmployeeStatusPolicy;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.auth.model.UserAccount;
import com.uten.imp.features.auth.model.UserAccountRepository;
import com.uten.imp.features.org.employee.Employee;
import com.uten.imp.features.org.employee.EmployeeRepository;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;

import java.util.Objects;
import java.util.UUID;

/** Canonical lifecycle lock for account/authorization writes: employee, then user. */
@Component
@RequiredArgsConstructor
final class AdminAccountLifecycleLock {

    private final EmployeeRepository employeeRepo;
    private final UserAccountRepository userRepo;

    LockedTarget lock(UUID userId) {
        UserAccountRepository.AccountState initial = userRepo.findAccountStateById(userId)
                .filter(state -> !state.isDeleted())
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "账号不存在"));
        UUID initialEmployeeId = initial.getEmployeeId();
        if (initialEmployeeId == null) {
            throw new ApiException(ErrorCode.CONFLICT, "账号未绑定员工档案");
        }

        Employee employee = employeeRepo.findByIdForUpdate(initialEmployeeId)
                .filter(candidate -> !candidate.isDeleted())
                .orElseThrow(() -> new ApiException(
                        ErrorCode.CONFLICT, "账号绑定的员工档案不存在或已删除"));
        UserAccount account = userRepo.findByIdForUpdate(userId)
                .filter(candidate -> !candidate.isDeleted())
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "账号不存在"));
        if (!Objects.equals(initialEmployeeId, account.getEmployeeId())
                || !Objects.equals(employee.getId(), account.getEmployeeId())) {
            throw new ApiException(
                    ErrorCode.CONFLICT, "账号与员工绑定已变化，请刷新后重试");
        }
        return new LockedTarget(employee, account);
    }

    void requireCurrentEmployee(LockedTarget target) {
        if (target == null
                || target.employee() == null
                || target.employee().isDeleted()
                || !CurrentEmployeeStatusPolicy.isCurrentEmployee(
                target.employee().getStatus())) {
            throw new ApiException(
                    ErrorCode.CONFLICT, "离职员工必须先完成复职流程，不能执行该账号操作");
        }
    }

    void requireActiveAccount(LockedTarget target) {
        if (target == null
                || target.account() == null
                || target.account().isDeleted()
                || !"active".equals(target.account().getStatus())) {
            throw new ApiException(
                    ErrorCode.CONFLICT, "目标登录账号未启用，不能执行该授权操作");
        }
    }

    record LockedTarget(Employee employee, UserAccount account) {
    }
}
