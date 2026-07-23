package com.uten.imp.features.auth;

import com.uten.imp.audit.AuditService;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.config.props.SecurityProperties;
import com.uten.imp.features.auth.dto.*;
import com.uten.imp.features.org.employee.Employee;
import com.uten.imp.features.org.employee.EmployeeRepository;
import com.uten.imp.features.rbac.*;
import com.uten.imp.security.JwtService;
import com.uten.imp.security.LoginRateLimiter;
import com.uten.imp.security.PasswordPolicy;
import com.uten.imp.security.SecurityContextCurrentUser;
import org.springframework.security.crypto.password.PasswordEncoder;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.time.OffsetDateTime;
import java.util.HashSet;
import java.util.List;
import java.util.Set;
import java.util.UUID;

/**
 * 鉴权服务：登录（防枚举/锁定/限流/密码长度上限）、刷新（轮换+悲观锁+锁定拒绝）、
 * 登出、改密（返回新令牌：当前设备保持登录、其他设备令牌失效）、我的资料。
 *
 * <p>超级管理员（{@code users.is_super_admin=true}）的能力：
 * <ul>
 *   <li>登录成功后 {@link #permsOf(UUID)} 直接返回全量 permissions，绕过 role_permissions 缺漏</li>
 *   <li>返回的 UserProfile.position 为 null（不设置职务语义），position 字段 UI 上隐藏</li>
 *   <li>前端可通过 isSuperAdmin 直接短路所有权限检查</li>
 * </ul>
 */
@Service
public class AuthService {

    /** 密码长度上限（防 Argon2 CPU DoS）。 */
    private static final int PASSWORD_MAX_LENGTH = 128;

    private final UserAccountRepository userRepo;
    private final EmployeeRepository employeeRepo;
    private final UserRoleRepository userRoleRepo;
    private final RolePermissionRepository rolePermissionRepo;
    private final PermissionRepository permissionRepo;
    private final RefreshTokenRepository refreshTokenRepo;
    private final RefreshTokenService refreshTokenService;
    private final PasswordHistoryRepository passwordHistoryRepo;
    private final JwtService jwtService;
    private final PasswordEncoder passwordEncoder;
    private final PasswordPolicy passwordPolicy;
    private final LoginRateLimiter rateLimiter;
    private final SecurityProperties securityProps;
    private final SecurityContextCurrentUser currentUser;
    private final AuditService audit;

    private String dummyHash;   // 用于账号不存在时抹平时序（防枚举）

    public AuthService(UserAccountRepository userRepo, EmployeeRepository employeeRepo,
                       UserRoleRepository userRoleRepo, RolePermissionRepository rolePermissionRepo,
                       PermissionRepository permissionRepo,
                       RefreshTokenRepository refreshTokenRepo, RefreshTokenService refreshTokenService,
                       PasswordHistoryRepository passwordHistoryRepo,
                       JwtService jwtService, PasswordEncoder passwordEncoder,
                       PasswordPolicy passwordPolicy, LoginRateLimiter rateLimiter,
                       SecurityProperties securityProps, SecurityContextCurrentUser currentUser,
                       AuditService audit) {
        this.userRepo = userRepo;
        this.employeeRepo = employeeRepo;
        this.userRoleRepo = userRoleRepo;
        this.rolePermissionRepo = rolePermissionRepo;
        this.permissionRepo = permissionRepo;
        this.refreshTokenRepo = refreshTokenRepo;
        this.refreshTokenService = refreshTokenService;
        this.passwordHistoryRepo = passwordHistoryRepo;
        this.jwtService = jwtService;
        this.passwordEncoder = passwordEncoder;
        this.passwordPolicy = passwordPolicy;
        this.rateLimiter = rateLimiter;
        this.securityProps = securityProps;
        this.currentUser = currentUser;
        this.audit = audit;
    }

    @Transactional
    public TokenResponse login(LoginRequest req, String ip) {
        rateLimiter.check(ip == null ? "unknown" : ip);

        // 密码长度上限：超长直接拒（防 Argon2 CPU DoS），消息与错密码一致（防枚举）
        if (req.password() == null || req.password().length() > PASSWORD_MAX_LENGTH) {
            ensureDummy();
            if (dummyHash != null) {
                passwordEncoder.matches(req.password(), dummyHash);
            }
            throw new ApiException(ErrorCode.BAD_CREDENTIALS);
        }

        var userOpt = userRepo.findByLoginAccount(req.loginAccount());
        // 账号不存在：跑一次 dummy 校验抹平时序，再抛同样的 BAD_CREDENTIALS（防枚举）
        if (userOpt.isEmpty()) {
            ensureDummy();
            passwordEncoder.matches(req.password(), dummyHash);
            audit.logExplicit(null, req.loginAccount(), "login_failed", "users", null, "account_not_found");
            throw new ApiException(ErrorCode.BAD_CREDENTIALS);
        }

        UserAccount user = userOpt.get();

        // 先校验密码（M2：密码正确前不暴露账号状态，防枚举）
        if (!passwordEncoder.matches(req.password(), user.getPasswordHash())) {
            onBadCredentials(user, ip);
            throw new ApiException(ErrorCode.BAD_CREDENTIALS);  // 与账号不存在同消息
        }
        // 密码正确后，才告知停用/锁定（仍锁定期内）
        if ("disabled".equals(user.getStatus())) {
            throw new ApiException(ErrorCode.ACCOUNT_DISABLED);
        }
        // 锁定只看 lockedUntil 时间戳（到期自动恢复，M1）
        if (user.getLockedUntil() != null && user.getLockedUntil().isAfter(OffsetDateTime.now())) {
            throw new ApiException(ErrorCode.ACCOUNT_LOCKED);
        }

        // 成功：清计数与锁定
        user.setFailedAttempts(0);
        user.setLockedUntil(null);
        user.setStatus("active");
        user.setLastLoginAt(OffsetDateTime.now());
        userRepo.save(user);
        audit.logExplicit(user.getId(), user.getLoginAccount(), "login", "users", user.getId().toString(), "success");

        return issueTokens(user);
    }

    private void onBadCredentials(UserAccount user, String ip) {
        int attempts = user.getFailedAttempts() + 1;
        user.setFailedAttempts(attempts);
        if (attempts >= securityProps.getLockoutThreshold()) {
            user.setStatus("locked");
            user.setLockedUntil(OffsetDateTime.now().plusMinutes(securityProps.getLockoutMinutes()));
        }
        userRepo.save(user);
        audit.logExplicit(user.getId(), user.getLoginAccount(), "login_failed", "users", user.getId().toString(), "bad_password");
    }

    @Transactional
    public TokenResponse refresh(String rawRefresh) {
        String hash = RefreshTokenService.sha256(rawRefresh);
        // 悲观锁：SELECT ... FOR UPDATE，杜绝并发轮换的 TOCTOU 重用竞态（H6）
        RefreshToken token = refreshTokenRepo.findAndLockByTokenHash(hash)
                .orElseThrow(() -> new ApiException(ErrorCode.UNAUTHORIZED));
        // 重用检测：已撤销的令牌再次出现 → 视为令牌泄露，撤销该用户全部令牌
        if (token.getRevokedAt() != null) {
            refreshTokenRepo.revokeAllByUserId(token.getUserId());
            audit.logExplicit(token.getUserId(), null, "refresh_reuse", "refresh_tokens", token.getId().toString(), "reuse_detected");
            throw new ApiException(ErrorCode.UNAUTHORIZED);
        }
        if (!token.isValid()) {
            throw new ApiException(ErrorCode.UNAUTHORIZED);
        }

        UserAccount user = userRepo.findById(token.getUserId())
                .orElseThrow(() -> new ApiException(ErrorCode.UNAUTHORIZED));
        // C2：停用 / 仍在锁定期内 → 拒绝刷新
        if ("disabled".equals(user.getStatus()) || user.isDeleted()) {
            throw new ApiException(ErrorCode.ACCOUNT_DISABLED);
        }
        if (user.getLockedUntil() != null && user.getLockedUntil().isAfter(OffsetDateTime.now())) {
            throw new ApiException(ErrorCode.ACCOUNT_LOCKED);
        }

        // 轮换：撤销旧令牌，签发新对
        String newRaw = refreshTokenService.issue(user.getId(), token.getDeviceInfo());
        RefreshToken newToken = refreshTokenRepo.findByTokenHash(RefreshTokenService.sha256(newRaw))
                .orElseThrow();
        refreshTokenService.revoke(token, newToken.getId());

        return buildTokenResponse(user, newRaw);
    }

    @Transactional
    public void logout(String rawRefresh) {
        if (rawRefresh == null || rawRefresh.isBlank()) {
            return;
        }
        refreshTokenRepo.findByTokenHash(RefreshTokenService.sha256(rawRefresh))
                .ifPresent(t -> refreshTokenService.revoke(t, null));
    }

    /**
     * 改密（首登强制 / 设置中）：校验旧密码 → 强度 → 历史 → Argon2id 入库 → 清 mustChangePassword →
     * 撤销所有旧刷新令牌（其他设备被踢）→ 为当前设备签发新令牌对（保持登录）。返回新令牌。
     */
    @Transactional
    public TokenResponse changePassword(ChangePasswordRequest req) {
        // 长度上限（防 Argon2 CPU DoS）
        if (req.oldPassword() == null || req.oldPassword().length() > PASSWORD_MAX_LENGTH
                || req.newPassword() == null || req.newPassword().length() > PASSWORD_MAX_LENGTH) {
            throw new ApiException(ErrorCode.BAD_CREDENTIALS);
        }

        UUID userId = currentUser.requireId();
        UserAccount user = userRepo.findById(userId)
                .orElseThrow(() -> new ApiException(ErrorCode.UNAUTHORIZED));

        if (!passwordEncoder.matches(req.oldPassword(), user.getPasswordHash())) {
            audit.logExplicit(userId, user.getLoginAccount(), "change_password_failed", "users", userId.toString(), "bad_old_password");
            throw new ApiException(ErrorCode.BAD_CREDENTIALS, "原密码不正确");
        }

        passwordPolicy.validate(req.newPassword(), user.getLoginAccount());

        // 防重用：最近 N 条历史
        for (PasswordHistory h : passwordHistoryRepo.findRecent(userId, securityProps.getPasswordHistorySize())) {
            if (passwordEncoder.matches(req.newPassword(), h.getPasswordHash())) {
                throw new ApiException(ErrorCode.PASSWORD_REUSE);
            }
        }

        // 旧哈希入历史，写新密码
        PasswordHistory history = new PasswordHistory();
        history.setUserId(userId);
        history.setPasswordHash(user.getPasswordHash());
        passwordHistoryRepo.save(history);

        user.setPasswordHash(passwordEncoder.encode(req.newPassword()));
        user.setMustChangePassword(false);
        user.setLastPasswordChangedAt(OffsetDateTime.now());
        userRepo.save(user);

        // 撤销所有旧刷新令牌（其他设备失效），再为当前设备签发新对
        refreshTokenRepo.revokeAllByUserId(userId);
        audit.logExplicit(userId, user.getLoginAccount(), "change_password", "users", userId.toString(), "success");
        return issueTokens(user);
    }

    @Transactional(readOnly = true)
    public TokenResponse.UserProfile me(java.util.function.Supplier<UUID> userIdSupplier) {
        UUID userId = userIdSupplier.get();
        UserAccount user = userRepo.findById(userId)
                .orElseThrow(() -> new ApiException(ErrorCode.UNAUTHORIZED));
        return profile(user);
    }

    // ===== 内部 =====

    private TokenResponse issueTokens(UserAccount user) {
        String refresh = refreshTokenService.issue(user.getId(), null);
        return buildTokenResponse(user, refresh);
    }

    private TokenResponse buildTokenResponse(UserAccount user, String rawRefresh) {
        Set<String> roles = rolesOf(user.getId());
        Set<String> perms = permsOf(user);
        String access = jwtService.issueAccess(user.getId(), user.getEmployeeId(), user.getLoginAccount(),
                roles, perms, user.isMustChangePassword());
        return new TokenResponse(access, rawRefresh, jwtService.getAccessTtlSeconds(),
                user.isMustChangePassword(), profile(user));
    }

    private TokenResponse.UserProfile profile(UserAccount user) {
        Employee e = employeeRepo.findById(user.getEmployeeId()).orElse(null);
        List<String> roles = rolesOf(user.getId()).stream().sorted().toList();
        List<String> perms = permsOf(user).stream().sorted().toList();
        String dept = (e != null && e.getDepartment() != null) ? e.getDepartment().getName() : null;
        // 超管：position 字段为 null（不设置职务）。这样前端能按 isSuperAdmin && position == null
        // 自然展示"系统管理员"，避免显示一个空岗位。
        String pos = (user.isSuperAdmin() || e == null || e.getPosition() == null)
                ? null
                : e.getPosition().getName();
        return new TokenResponse.UserProfile(
                user.getId().toString(),
                user.getLoginAccount(),
                e == null ? null : e.getFullName(),
                e == null ? null : e.getCode(),
                dept,
                pos,
                user.isSuperAdmin(),
                roles,
                perms);
    }

    private Set<String> rolesOf(UUID userId) {
        return new HashSet<>(userRoleRepo.findRoleCodesByUserId(userId));
    }

    /**
     * 用户权限集合。超级管理员（{@code users.is_super_admin=true}）直接拿到全量
     * permissions 表内容，绕过 role_permissions 是否有缺漏。
     */
    private Set<String> permsOf(UserAccount user) {
        if (user.isSuperAdmin()) {
            return permissionRepo.findAll().stream()
                    .map(Permission::getCode)
                    .collect(java.util.stream.Collectors.toCollection(HashSet::new));
        }
        List<UUID> roleIds = userRoleRepo.findRoleIdsByUserIds(List.of(user.getId()));
        return new HashSet<>(rolePermissionRepo.findPermissionCodesByRoleIds(roleIds));
    }

    /** 旧签名（按 userId），留作内部调用保持向后兼容。 */
    private Set<String> permsOf(UUID userId) {
        UserAccount user = userRepo.findById(userId).orElse(null);
        if (user == null) return Set.of();
        return permsOf(user);
    }

    private void ensureDummy() {
        if (dummyHash == null) {
            dummyHash = passwordEncoder.encode("dummy-password-for-timing");
        }
    }
}
