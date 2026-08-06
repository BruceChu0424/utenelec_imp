package com.uten.imp.features.admin;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.common.web.Pageables;
import com.uten.imp.audit.AuditService;
import com.uten.imp.features.admin.dto.UserSummary;
import com.uten.imp.features.auth.model.RefreshTokenRepository;
import com.uten.imp.features.auth.model.UserAccount;
import com.uten.imp.features.auth.model.UserAccountRepository;
import com.uten.imp.features.org.department.Department;
import com.uten.imp.features.org.employee.Employee;
import com.uten.imp.features.org.employee.EmployeeRepository;
import com.uten.imp.features.rbac.UserRoleRepository;
import com.uten.imp.security.TemporaryPasswordGenerator;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.criteria.Predicate;
import lombok.RequiredArgsConstructor;
import org.springframework.data.domain.Page;
import org.springframework.data.domain.Pageable;
import org.springframework.data.domain.Sort;
import org.springframework.data.jpa.domain.Specification;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.security.crypto.password.PasswordEncoder;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.util.ArrayList;
import java.util.List;
import java.util.UUID;

/** 账号支持（HR）：列表、锁定/启停/解锁、随机临时密码重置。 */
@Service
@RequiredArgsConstructor
public class UserAccountAdminService {

    private final UserAccountRepository userRepo;
    private final EmployeeRepository empRepo;
    private final RefreshTokenRepository refreshTokenRepo;
    private final UserRoleRepository userRoleRepo;
    private final PasswordEncoder passwordEncoder;
    private final TemporaryPasswordGenerator temporaryPasswordGenerator;
    private final TxSessionVars tx;
    private final AdminUserSupport support;
    private final AuditService auditService;

    @PreAuthorize("hasAuthority('account:support')")
    @Transactional(readOnly = true)
    public PageResponse<UserSummary> list(int page, int size, String search, String status) {
        Specification<UserAccount> spec = (root, q, cb) -> {
            List<Predicate> predicates = new ArrayList<>();
            predicates.add(cb.isFalse(root.get("deleted")));
            if (search != null && !search.isBlank()) {
                predicates.add(
                        cb.like(
                                cb.lower(root.get("loginAccount")),
                                "%" + search.toLowerCase() + "%"));
            }
            if (status != null && !status.isBlank()) {
                predicates.add(cb.equal(root.get("status"), status));
            }
            return cb.and(predicates.toArray(new Predicate[0]));
        };
        Pageable pageable = Pageables.of(
                page,
                size,
                Sort.by(Sort.Direction.ASC, "loginAccount"));
        Page<UserAccount> result = userRepo.findAll(spec, pageable);
        List<UserSummary> items = result.getContent().stream().map(this::toSummary).toList();
        return new PageResponse<>(
                items,
                page,
                size,
                result.getTotalElements(),
                result.getTotalPages());
    }

    @PreAuthorize("hasAuthority('authorization:manage') and principal.superAdmin")
    @Transactional(readOnly = true)
    public UserSummary getByEmployeeId(UUID employeeId) {
        UserAccount user = userRepo.findByEmployeeId(employeeId)
                .filter(row -> !row.isDeleted())
                .orElseThrow(() -> new ApiException(
                        ErrorCode.NOT_FOUND,
                        "该员工未开通可用账号，无法设置权限"));
        return toSummary(user);
    }

    private UserSummary toSummary(UserAccount user) {
        Employee employee = empRepo.findById(user.getEmployeeId()).orElse(null);
        Department department = employee == null ? null : employee.getDepartment();
        List<String> roles = userRoleRepo.findRoleCodesByUserId(user.getId());
        return new UserSummary(
                user.getId(),
                user.getLoginAccount(),
                employee == null ? null : employee.getFullName(),
                employee == null ? null : employee.getCode(),
                department == null ? null : department.getId(),
                department == null ? null : department.getName(),
                user.getStatus(),
                user.isMustChangePassword(),
                user.getLastLoginAt(),
                roles);
    }

    @PreAuthorize("hasAuthority('account:support')")
    @Transactional
    public void setStatus(UUID id, String status) {
        tx.bind();
        UserAccount user = support.require(id);
        support.requireAccountSupportTarget(user);
        if (!List.of("active", "locked", "disabled").contains(status)) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "不支持的账号状态");
        }
        boolean statusChanged = !status.equals(user.getStatus());
        boolean manualLockChanged =
                "locked".equals(status) && user.getLockedUntil() != null;
        boolean activationStateChanged =
                "active".equals(status)
                        && (user.getFailedAttempts() != 0 || user.getLockedUntil() != null);
        if (!statusChanged && !manualLockChanged && !activationStateChanged) {
            return;
        }
        if ("active".equals(status)) {
            requireActiveEmployee(user);
            user.setFailedAttempts(0);
            user.setLockedUntil(null);
        }
        user.setStatus(status);
        if ("locked".equals(status)) {
            // 管理员手动锁 = 无限期：清掉暴力破解的临时锁时间戳，
            // 避免 lockedUntil 到期后登录成功路径把 status 恢复为 active。
            user.setLockedUntil(null);
        }
        userRepo.save(user);
        invalidateAllSessions(id);
    }

    @PreAuthorize("hasAuthority('account:support')")
    @Transactional
    public void unlock(UUID id) {
        tx.bind();
        UserAccount user = support.require(id);
        support.requireAccountSupportTarget(user);
        boolean changed = !"active".equals(user.getStatus())
                || user.getFailedAttempts() != 0
                || user.getLockedUntil() != null;
        if (!changed) {
            return;
        }
        requireActiveEmployee(user);
        user.setStatus("active");
        user.setFailedAttempts(0);
        user.setLockedUntil(null);
        userRepo.save(user);
        invalidateAllSessions(id);
    }

    /**
     * Reset to a high-entropy one-time-display temporary password. The plaintext
     * is returned once, never persisted, and only the password-change flow remains
     * available until the user chooses a permanent password.
     */
    @PreAuthorize("hasAuthority('account:support')")
    @Transactional
    public String resetPassword(UUID id) {
        tx.bind();
        UserAccount user = support.require(id);
        support.requireAccountSupportTarget(user);
        String temporaryPassword = temporaryPasswordGenerator.generate();
        user.setPasswordHash(passwordEncoder.encode(temporaryPassword));
        user.setMustChangePassword(true);
        user.setFailedAttempts(0);
        user.setLockedUntil(null);
        if (!"disabled".equals(user.getStatus())) {
            requireActiveEmployee(user);
            user.setStatus("active");
        }
        userRepo.save(user);
        invalidateAllSessions(id);
        return temporaryPassword;
    }

    private void invalidateAllSessions(UUID userId) {
        if (userRepo.bumpAuthVersion(userId) != 1) {
            throw new ApiException(ErrorCode.UNAUTHORIZED);
        }
        refreshTokenRepo.revokeAllByUserId(userId);
    }

    /**
     * 设置/取消超级管理员（允许多个超管）。仅超管可操作；降级禁止降本人与最后一位超管。
     * 改动后 bump auth version，让目标下次请求按新标志重算权限（is_super_admin 逐请求
     * DB 复读，bump 确保权限快照随 token 刷新更新）。
     */
    @PreAuthorize("hasAuthority('authorization:manage') and principal.superAdmin")
    @Transactional
    public void setSuperAdmin(UUID id, boolean superAdmin) {
        tx.bind();
        UserAccount user = support.require(id);
        if (superAdmin == user.isSuperAdmin()) {
            return;
        }
        support.requireSuperAdminToggle(user, superAdmin);
        user.setSuperAdmin(superAdmin);
        userRepo.save(user);
        userRepo.bumpAuthVersion(id);
        // 显式审计：权限升降级是安全敏感事件，单独记一条带方向的业务事件
        // （拦截器层只记 HTTP 调用、不分授/收）。
        var actor = support.requireCurrentUser();
        auditService.logExplicit(
                actor.getId(),
                actor.getLoginAccount(),
                superAdmin ? "super_admin_grant" : "super_admin_revoke",
                "user",
                id.toString(),
                "success");
    }

    private void requireActiveEmployee(UserAccount account) {
        Employee employee = empRepo.findById(account.getEmployeeId())
                .filter(row -> !row.isDeleted())
                .orElseThrow(() -> new ApiException(
                        ErrorCode.CONFLICT,
                        "账号未绑定有效员工档案，不能启用"));
        if ("resigned".equals(employee.getStatus())) {
            throw new ApiException(
                    ErrorCode.CONFLICT,
                    "离职员工必须先完成复职流程，不能直接启用账号");
        }
    }
}
