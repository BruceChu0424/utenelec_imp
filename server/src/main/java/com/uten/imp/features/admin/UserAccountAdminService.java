package com.uten.imp.features.admin;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.common.web.Pageables;
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

    @PreAuthorize("hasAuthority('account:support')")
    @Transactional(readOnly = true)
    public PageResponse<UserSummary> list(int page, int size, String search, String status) {
        Specification<UserAccount> spec = (root, q, cb) -> {
            List<Predicate> ps = new ArrayList<>();
            ps.add(cb.isFalse(root.get("deleted")));
            if (search != null && !search.isBlank()) {
                ps.add(cb.like(cb.lower(root.get("loginAccount")), "%" + search.toLowerCase() + "%"));
            }
            if (status != null && !status.isBlank()) {
                ps.add(cb.equal(root.get("status"), status));
            }
            return cb.and(ps.toArray(new Predicate[0]));
        };
        Pageable pageable = Pageables.of(page, size, Sort.by(Sort.Direction.ASC, "loginAccount"));
        Page<UserAccount> p = userRepo.findAll(spec, pageable);
        List<UserSummary> items = p.getContent().stream().map(this::toSummary).toList();
        return new PageResponse<>(items, page, size, p.getTotalElements(), p.getTotalPages());
    }

    private UserSummary toSummary(UserAccount u) {
        Employee e = empRepo.findById(u.getEmployeeId()).orElse(null);
        Department dept = e == null ? null : e.getDepartment();
        List<String> roles = userRoleRepo.findRoleCodesByUserId(u.getId());
        return new UserSummary(u.getId(), u.getLoginAccount(),
                e == null ? null : e.getFullName(), e == null ? null : e.getCode(),
                dept == null ? null : dept.getId(), dept == null ? null : dept.getName(),
                u.getStatus(), u.isMustChangePassword(), u.getLastLoginAt(), roles);
    }

    @PreAuthorize("hasAuthority('account:support')")
    @Transactional
    public void setStatus(UUID id, String status) {
        tx.bind();
        UserAccount u = support.require(id);
        support.requireAccountSupportTarget(u);
        if (!List.of("active", "locked", "disabled").contains(status)) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "不支持的账号状态");
        }
        if ("active".equals(status)) {
            requireActiveEmployee(u);
        }
        u.setStatus(status);
        if ("locked".equals(status)) {
            // 管理员手动锁 = 无限期：清掉暴力破解的临时锁时间戳，
            // 避免 lockedUntil 到期后登录成功路径把 status 恢复为 active
            u.setLockedUntil(null);
        }
        userRepo.save(u);
        if ("locked".equals(status) || "disabled".equals(status)) {
            refreshTokenRepo.revokeAllByUserId(id);
        }
    }

    @PreAuthorize("hasAuthority('account:support')")
    @Transactional
    public void unlock(UUID id) {
        tx.bind();
        UserAccount u = support.require(id);
        support.requireAccountSupportTarget(u);
        requireActiveEmployee(u);
        u.setStatus("active");
        u.setFailedAttempts(0);
        u.setLockedUntil(null);
        userRepo.save(u);
    }

    /**
     * Reset to a high-entropy one-time-display temporary password.
     * The plaintext is returned once, never persisted, and the account can only
     * access the password-change flow until it chooses a permanent password.
     */
    @PreAuthorize("hasAuthority('account:support')")
    @Transactional
    public String resetPassword(UUID id) {
        tx.bind();
        UserAccount u = support.require(id);
        support.requireAccountSupportTarget(u);
        String temporaryPassword = temporaryPasswordGenerator.generate();
        u.setPasswordHash(passwordEncoder.encode(temporaryPassword));
        u.setMustChangePassword(true);
        u.setFailedAttempts(0);
        u.setLockedUntil(null);
        if (!"disabled".equals(u.getStatus())) {
            requireActiveEmployee(u);
            u.setStatus("active");
        }
        userRepo.save(u);
        refreshTokenRepo.revokeAllByUserId(id);
        return temporaryPassword;
    }

    private void requireActiveEmployee(UserAccount account) {
        Employee employee = empRepo.findById(account.getEmployeeId())
                .filter(row -> !row.isDeleted())
                .orElseThrow(() -> new ApiException(
                        ErrorCode.CONFLICT, "账号未绑定有效员工档案，不能启用"));
        if ("resigned".equals(employee.getStatus())) {
            throw new ApiException(
                    ErrorCode.CONFLICT, "离职员工必须先完成复职流程，不能直接启用账号");
        }
    }
}
