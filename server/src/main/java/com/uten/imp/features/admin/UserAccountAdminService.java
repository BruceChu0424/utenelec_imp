package com.uten.imp.features.admin;

import com.uten.imp.common.identity.CurrentEmployeeStatusPolicy;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.common.web.Pageables;
import com.uten.imp.audit.AuditService;
import com.uten.imp.features.admin.dto.UserSummary;
import com.uten.imp.features.admin.dto.ProvisionCandidateDto;
import com.uten.imp.features.auth.model.RefreshTokenRepository;
import com.uten.imp.features.auth.model.UserAccount;
import com.uten.imp.features.auth.model.UserAccountRepository;
import com.uten.imp.features.org.department.Department;
import com.uten.imp.features.org.employee.Employee;
import com.uten.imp.features.org.employee.EmployeeRepository;
import com.uten.imp.features.org.employee.EmployeeSensitive;
import com.uten.imp.features.org.employee.EmployeeSensitiveRepository;
import com.uten.imp.features.rbac.UserRoleRepository;
import com.uten.imp.security.TemporaryPasswordGenerator;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.criteria.Predicate;
import lombok.RequiredArgsConstructor;
import org.springframework.data.domain.Page;
import org.springframework.data.domain.PageRequest;
import org.springframework.data.domain.Pageable;
import org.springframework.data.domain.Sort;
import org.springframework.data.jpa.domain.Specification;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.security.crypto.password.PasswordEncoder;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.time.OffsetDateTime;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import java.util.function.Function;
import java.util.stream.Collectors;

/** 账号支持（HR）：列表、锁定/启停/解锁、随机/自定义临时密码重置、开通账号候选。 */
@Service
@RequiredArgsConstructor
public class UserAccountAdminService {

    /** 开通账号候选接口单次返回上限（权限页选择器用，防全量花名册外泄）。 */
    private static final int PROVISION_CANDIDATE_LIMIT = 20;

    /** 管理员设置的临时密码有效期：72 小时（超时未登录使用则自动失效，需重新设置）。 */
    private static final long TEMP_PASSWORD_TTL_HOURS = 72;

    /** 自定义临时密码长度边界：下限对齐密码策略，上限防 Argon2 CPU DoS。 */
    private static final int TEMP_PASSWORD_MIN_LENGTH = 8;
    private static final int TEMP_PASSWORD_MAX_LENGTH = 64;

    private final UserAccountRepository userRepo;
    private final EmployeeRepository empRepo;
    private final EmployeeSensitiveRepository sensitiveRepo;
    private final RefreshTokenRepository refreshTokenRepo;
    private final UserRoleRepository userRoleRepo;
    private final PasswordEncoder passwordEncoder;
    private final TemporaryPasswordGenerator temporaryPasswordGenerator;
    private final TxSessionVars tx;
    private final AdminUserSupport support;
    private final AdminAccountLifecycleLock accountLifecycle;
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
                employee == null ? null : employee.getId(),
                user.getLoginAccount(),
                employee == null ? null : employee.getFullName(),
                employee == null ? null : employee.getCode(),
                employee == null ? null : employee.getStatus(),
                employee != null && CurrentEmployeeStatusPolicy.isCurrentEmployee(
                        employee.getStatus()),
                department == null ? null : department.getId(),
                department == null ? null : department.getName(),
                user.getStatus(),
                user.isMustChangePassword(),
                user.getLastLoginAt(),
                roles,
                user.isRemoteAccess(),
                user.getTempPasswordExpiresAt());
    }

    /**
     * 开通账号候选：在册且尚未开通登录账号的员工（姓名/工号/部门 + 是否已登记手机号/证件）。
     * 最小信息集，不解密、不回传 PII；最多返回 {@value #PROVISION_CANDIDATE_LIMIT} 条。
     */
    @PreAuthorize("hasAuthority('account:support')")
    @Transactional(readOnly = true)
    public List<ProvisionCandidateDto> provisionCandidates(String search) {
        String keyword = search == null ? "" : search.trim();
        List<Employee> employees = empRepo.findProvisionCandidates(
                keyword, PageRequest.of(0, PROVISION_CANDIDATE_LIMIT));
        if (employees.isEmpty()) {
            return List.of();
        }
        Map<UUID, EmployeeSensitive> sensitiveByEmployee = sensitiveRepo
                .findAllByEmployeeIdIn(employees.stream().map(Employee::getId).toList())
                .stream()
                .collect(Collectors.toMap(EmployeeSensitive::getEmployeeId, Function.identity()));
        return employees.stream()
                .map(e -> {
                    EmployeeSensitive s = sensitiveByEmployee.get(e.getId());
                    Department department = e.getDepartment();
                    return new ProvisionCandidateDto(
                            e.getId(),
                            e.getFullName(),
                            e.getCode(),
                            department == null ? null : department.getName(),
                            s != null && hasText(s.getPhoneEnc()),
                            s != null && hasText(s.getIdCardEnc()));
                })
                .toList();
    }

    private static boolean hasText(String value) {
        return value != null && !value.isBlank();
    }

    @PreAuthorize("hasAuthority('account:support')")
    @Transactional
    public void setStatus(UUID id, String status) {
        tx.bind();
        if (!List.of("active", "locked", "disabled").contains(status)) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "不支持的账号状态");
        }
        AdminAccountLifecycleLock.LockedTarget locked = accountLifecycle.lock(id);
        UserAccount user = locked.account();
        support.requireAccountSupportTarget(user);
        if (!"disabled".equals(status)) {
            accountLifecycle.requireCurrentEmployee(locked);
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
        AdminAccountLifecycleLock.LockedTarget locked = accountLifecycle.lock(id);
        UserAccount user = locked.account();
        support.requireAccountSupportTarget(user);
        accountLifecycle.requireCurrentEmployee(locked);
        boolean changed = !"active".equals(user.getStatus())
                || user.getFailedAttempts() != 0
                || user.getLockedUntil() != null;
        if (!changed) {
            return;
        }
        user.setStatus("active");
        user.setFailedAttempts(0);
        user.setLockedUntil(null);
        userRepo.save(user);
        invalidateAllSessions(id);
    }

    /**
     * Reset to a one-time-display temporary password. When {@code customTemporaryPassword}
     * is blank, a high-entropy 20-char value is generated; otherwise the admin-chosen value
     * must pass the same strength floor as user passwords. The plaintext is returned once,
     * never persisted or logged; the account is forced through the password-change flow,
     * all existing sessions are revoked, and the temporary password expires after
     * {@value #TEMP_PASSWORD_TTL_HOURS} hours (V297).
     */
    @PreAuthorize("hasAuthority('account:support')")
    @Transactional
    public String resetPassword(UUID id, String customTemporaryPassword) {
        tx.bind();
        AdminAccountLifecycleLock.LockedTarget locked = accountLifecycle.lock(id);
        UserAccount user = locked.account();
        support.requireAccountSupportTarget(user);
        boolean custom = customTemporaryPassword != null && !customTemporaryPassword.isBlank();
        String temporaryPassword = custom
                ? validateCustomTemporaryPassword(customTemporaryPassword, user.getLoginAccount())
                : temporaryPasswordGenerator.generate();
        user.setPasswordHash(passwordEncoder.encode(temporaryPassword));
        user.setMustChangePassword(true);
        user.setTempPasswordExpiresAt(OffsetDateTime.now().plusHours(TEMP_PASSWORD_TTL_HOURS));
        user.setFailedAttempts(0);
        user.setLockedUntil(null);
        if (!"disabled".equals(user.getStatus())) {
            accountLifecycle.requireCurrentEmployee(locked);
            user.setStatus("active");
        }
        userRepo.save(user);
        invalidateAllSessions(id);
        // 显式审计：管理员重置他人密码是安全敏感事件。绝不记录明文，只记模式与目标。
        var actor = support.requireCurrentUser();
        auditService.logCommitted(
                actor.getId(),
                actor.getLoginAccount(),
                "password_temporary_reset",
                "user",
                id.toString(),
                custom ? "success;mode=custom" : "success;mode=generated");
        return temporaryPassword;
    }

    /**
     * 自定义临时密码服务端强度校验（与改密策略同口径的下限）：
     * 8–64 位、不含空白、必须同时含字母和数字、不得等于登录账号。
     * 失败统一抛 PASSWORD_TOO_WEAK，并给出具体原因便于管理员修正。
     */
    private static String validateCustomTemporaryPassword(String raw, String loginAccount) {
        String value = raw.trim();
        if (value.length() < TEMP_PASSWORD_MIN_LENGTH) {
            throw new ApiException(
                    ErrorCode.PASSWORD_TOO_WEAK, "临时密码至少 " + TEMP_PASSWORD_MIN_LENGTH + " 位");
        }
        if (value.length() > TEMP_PASSWORD_MAX_LENGTH) {
            throw new ApiException(
                    ErrorCode.PASSWORD_TOO_WEAK, "临时密码最长 " + TEMP_PASSWORD_MAX_LENGTH + " 位");
        }
        boolean hasLetter = false;
        boolean hasDigit = false;
        for (int i = 0; i < value.length(); i++) {
            char c = value.charAt(i);
            if (Character.isWhitespace(c)) {
                throw new ApiException(ErrorCode.PASSWORD_TOO_WEAK, "临时密码不能包含空格等空白字符");
            }
            hasLetter |= Character.isLetter(c);
            hasDigit |= Character.isDigit(c);
        }
        if (!hasLetter || !hasDigit) {
            throw new ApiException(ErrorCode.PASSWORD_TOO_WEAK, "临时密码需同时包含字母和数字");
        }
        if (loginAccount != null && value.equalsIgnoreCase(loginAccount)) {
            throw new ApiException(ErrorCode.PASSWORD_TOO_WEAK, "临时密码不能与登录账号相同");
        }
        return value;
    }

    /**
     * 按员工 ID 锁定其登录账号（员工详情页顶卡按钮，account:support）。
     * 解析 employee_id → users.id 后复用 {@link #setStatus} 的锁定逻辑。
     */
    @PreAuthorize("hasAuthority('account:support')")
    @Transactional
    public void lockByEmployee(UUID employeeId) {
        setStatus(requireUserByEmployee(employeeId).getId(), "locked");
    }

    /**
     * 按员工 ID 解锁其登录账号（员工详情页顶卡按钮，account:support）。
     * 解析 employee_id → users.id 后复用 {@link #unlock} 的解锁逻辑。
     */
    @PreAuthorize("hasAuthority('account:support')")
    @Transactional
    public void unlockByEmployee(UUID employeeId) {
        unlock(requireUserByEmployee(employeeId).getId());
    }

    private UserAccount requireUserByEmployee(UUID employeeId) {
        return userRepo.findByEmployeeId(employeeId)
                .filter(row -> !row.isDeleted())
                .orElseThrow(() -> new ApiException(
                        ErrorCode.NOT_FOUND,
                        "该员工未开通账号，无法锁定/解锁"));
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
        AdminAccountLifecycleLock.LockedTarget locked = accountLifecycle.lock(id);
        UserAccount user = locked.account();
        if (superAdmin == user.isSuperAdmin()) {
            return;
        }
        if (superAdmin) {
            accountLifecycle.requireCurrentEmployee(locked);
            accountLifecycle.requireActiveAccount(locked);
        }
        support.requireSuperAdminToggle(user, superAdmin);
        user.setSuperAdmin(superAdmin);
        userRepo.save(user);
        userRepo.bumpAuthVersion(id);
        // 显式审计：权限升降级是安全敏感事件，单独记一条带方向的业务事件
        // （拦截器层只记 HTTP 调用、不分授/收）。
        var actor = support.requireCurrentUser();
        auditService.logCommitted(
                actor.getId(),
                actor.getLoginAccount(),
                superAdmin ? "super_admin_grant" : "super_admin_revoke",
                "user",
                id.toString(),
                "success");
    }

    /**
     * 设置/取消云端（外网）访问授权。仅超管可操作。变更由触发器即时 bump auth_version，
     * 目标账号的旧 access token 立即失效（须重新登录拿新 token）。
     */
    @PreAuthorize("hasAuthority('authorization:manage') and principal.superAdmin")
    @Transactional
    public void setRemoteAccess(UUID id, boolean remoteAccess) {
        tx.bind();
        AdminAccountLifecycleLock.LockedTarget locked = accountLifecycle.lock(id);
        UserAccount user = locked.account();
        support.requireAuthorizationTarget(user);
        if (remoteAccess) {
            accountLifecycle.requireCurrentEmployee(locked);
            accountLifecycle.requireActiveAccount(locked);
        }
        if (remoteAccess == user.isRemoteAccess()) {
            return;
        }
        user.setRemoteAccess(remoteAccess);
        userRepo.save(user);   // BEFORE UPDATE 触发器自动 bump auth_version
        // A remote-access change is a session boundary in either direction.
        // It invalidates access JWTs; refresh tokens require explicit family revocation.
        refreshTokenRepo.revokeAllByUserId(id);
        var actor = support.requireCurrentUser();
        auditService.logCommitted(
                actor.getId(),
                actor.getLoginAccount(),
                remoteAccess ? "remote_access_grant" : "remote_access_revoke",
                "user",
                id.toString(),
                "success");
    }
}
