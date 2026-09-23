package com.uten.imp.features.admin;

import com.uten.imp.application.port.AccountSecurityNoticePort;
import com.uten.imp.common.identity.CurrentEmployeeStatusPolicy;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.common.web.Pageables;
import com.uten.imp.audit.AuditService;
import com.uten.imp.features.admin.dto.UserSummary;
import com.uten.imp.features.admin.dto.ProvisionCandidateDto;
import com.uten.imp.features.admin.systemsetting.SystemSettingKey;
import com.uten.imp.features.admin.systemsetting.SystemSettingsService;
import com.uten.imp.features.auth.AuthSessionService;
import com.uten.imp.features.auth.model.RefreshTokenRepository;
import com.uten.imp.features.auth.model.UserAccount;
import com.uten.imp.features.auth.model.UserAccountRepository;
import com.uten.imp.features.org.department.Department;
import com.uten.imp.features.org.employee.Employee;
import com.uten.imp.features.org.employee.EmployeeRepository;
import com.uten.imp.features.org.employee.EmployeeSensitive;
import com.uten.imp.features.org.employee.EmployeeSensitiveRepository;
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

/**
 * 账号支持: 列表、锁定/启停/解锁、重置为随机临时密码、开通账号候选 (ADR-110; security-02)。
 *
 * <p>account:support 只能个人点名授予。重置只发系统生成的高熵临时密码 (不能自定), 明文仅在本次
 * 响应里出现一次, 有效期按系统设置「临时密码有效期」, 首次登录必须改密; 目标持有高危权限时只有
 * 超级管理员能重置。重置、锁定、解锁、停用、启用都给目标本人发系统通知, 并写一条语义化业务事件。</p>
 */
@Service
@RequiredArgsConstructor
public class UserAccountAdminService {

    /** 开通账号候选接口单次返回上限（权限页选择器用，防全量花名册外泄）。 */
    private static final int PROVISION_CANDIDATE_LIMIT = 20;

    private final UserAccountRepository userRepo;
    private final EmployeeRepository empRepo;
    private final EmployeeSensitiveRepository sensitiveRepo;
    private final RefreshTokenRepository refreshTokenRepo;
    private final PasswordEncoder passwordEncoder;
    private final TemporaryPasswordGenerator temporaryPasswordGenerator;
    private final TxSessionVars tx;
    private final AdminUserSupport support;
    private final AdminAccountLifecycleLock accountLifecycle;
    private final AuditService auditService;
    private final AuthSessionService sessions;
    private final SystemSettingsService settings;
    private final AccountSecurityNoticePort accountNotice;

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
        invalidateAllSessions(id, AuthSessionService.REASON_ACCOUNT_STATUS);
        String action = switch (status) {
            case "locked" -> "account_lock";
            case "disabled" -> "account_disable";
            default -> "account_enable";
        };
        String title = switch (status) {
            case "locked" -> "你的登录账号已被锁定";
            case "disabled" -> "你的登录账号已被停用";
            default -> "你的登录账号已恢复可用";
        };
        String body = switch (status) {
            case "locked" -> "管理员锁定了你的登录账号，所有设备已退出登录。如非本人知情，请联系人事或系统管理员。";
            case "disabled" -> "管理员停用了你的登录账号，所有设备已退出登录。如有疑问，请联系人事或系统管理员。";
            default -> "管理员已恢复你的登录账号，可以重新登录使用。如非本人申请，请联系人事或系统管理员。";
        };
        recordAccountEvent(user, action, title, body);
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
        invalidateAllSessions(id, AuthSessionService.REASON_ACCOUNT_STATUS);
        recordAccountEvent(user, "account_unlock", "你的登录账号已解锁",
                "管理员解除了你账号的锁定，可以重新登录。如果你没有申请解锁，请尽快修改密码并联系系统管理员。");
    }

    /**
     * 重置为系统生成的 20 位高熵临时密码 (不能自定)。明文只在本次响应出现一次, 不落库不记日志;
     * 账号被迫首登改密, 全部旧会话吊销, 临时密码按系统设置「临时密码有效期」过期。
     * 目标持有高危权限时只有超级管理员能重置; 控制器入口另要求再认证。
     */
    @PreAuthorize("hasAuthority('account:support')")
    @Transactional
    public String resetPassword(UUID id) {
        tx.bind();
        AdminAccountLifecycleLock.LockedTarget locked = accountLifecycle.lock(id);
        UserAccount user = locked.account();
        support.requirePasswordResetAllowed(user);
        String temporaryPassword = temporaryPasswordGenerator.generate();
        user.setPasswordHash(passwordEncoder.encode(temporaryPassword));
        user.setMustChangePassword(true);
        user.setTempPasswordExpiresAt(OffsetDateTime.now().plusHours(
                settings.readInt(SystemSettingKey.TEMP_PASSWORD_TTL_HOURS)));
        user.setFailedAttempts(0);
        user.setLockedUntil(null);
        if (!"disabled".equals(user.getStatus())) {
            accountLifecycle.requireCurrentEmployee(locked);
            user.setStatus("active");
        }
        userRepo.save(user);
        invalidateAllSessions(id, AuthSessionService.REASON_PASSWORD_RESET);
        // 显式审计：管理员重置他人密码是安全敏感事件。绝不记录明文，只记目标。
        recordAccountEvent(user, "password_temporary_reset", "你的登录密码已被重置",
                "管理员为你重置了登录密码并发放了临时密码，所有设备已退出登录。"
                        + "请用管理员当面交给你的临时密码登录并立即改成自己的密码。"
                        + "如果你没有申请重置，请马上联系系统管理员。");
        notifySuperAdministratorsOfDelegatedReset(locked);
        return temporaryPassword;
    }

    /**
     * 账号支持人员 (非超管) 重置了别人的密码: 同时告知其他超管。目标本人所有设备已退出、也不知道新密码,
     * 通常要等拿到临时密码后才看得到自己的提醒; 另有人知情, 冒充登录才藏不住 (security-02)。
     */
    private void notifySuperAdministratorsOfDelegatedReset(AdminAccountLifecycleLock.LockedTarget locked) {
        var actor = support.requireCurrentUser();
        if (actor.isSuperAdmin()) {
            return;
        }
        String actorName = actor.getEmployeeId() == null ? null
                : empRepo.findById(actor.getEmployeeId()).map(Employee::getFullName).orElse(null);
        String targetName = locked.employee() == null ? null : locked.employee().getFullName();
        accountNotice.notifySuperAdministrators(actor.getId(), "有员工的登录密码被重置",
                (actorName == null ? "账号支持人员" : "账号支持人员" + actorName)
                        + "重置了" + (targetName == null ? "一名员工" : targetName)
                        + "的登录密码，并拿到了一次性临时密码。如果这不是员工本人申请的，请尽快核实。");
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

    private void invalidateAllSessions(UUID userId, String reason) {
        if (userRepo.bumpAuthVersion(userId) != 1) {
            throw new ApiException(ErrorCode.UNAUTHORIZED);
        }
        refreshTokenRepo.revokeAllByUserId(userId);
        sessions.revokeAllForUser(userId, reason);
    }

    /** 账号状态类动作: 同事务写语义化业务事件 + 通知目标本人 (失败随业务回滚)。 */
    private void recordAccountEvent(UserAccount target, String action, String title, String body) {
        var actor = support.requireCurrentUser();
        auditService.logCommitted(
                actor.getId(),
                actor.getLoginAccount(),
                action,
                "user",
                target.getId().toString(),
                "success");
        accountNotice.notifyAccountHolder(target.getId(), title, body);
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
        if (!superAdmin && user.isMustChangePassword() && user.getTempPasswordExpiresAt() == null) {
            // 只有超管的初始密码可以不设过期 (引导管理员, V660); 降为普通账号后与所有临时凭据同口径:
            // 还没改过的初始密码立即作废, 需由账号支持重新发放 (库触发器 trg_users_temp_password_expiry 同样兜底)。
            user.setTempPasswordExpiresAt(OffsetDateTime.now());
        }
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
        // It invalidates access JWTs; refresh tokens and sessions require explicit revocation.
        refreshTokenRepo.revokeAllByUserId(id);
        sessions.revokeAllForUser(id, AuthSessionService.REASON_REMOTE_ACCESS);
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
