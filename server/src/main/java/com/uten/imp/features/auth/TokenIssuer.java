package com.uten.imp.features.auth;

import com.uten.imp.audit.AuditService;
import com.uten.imp.common.util.HashUtil;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.auth.dto.TokenResponse;
import com.uten.imp.features.auth.model.RefreshToken;
import com.uten.imp.features.auth.model.RefreshTokenRepository;
import com.uten.imp.features.auth.model.UserAccount;
import com.uten.imp.features.auth.model.UserAccountRepository;
import com.uten.imp.features.org.employee.Employee;
import com.uten.imp.features.org.employee.EmployeeRepository;
import com.uten.imp.security.JwtService;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.time.OffsetDateTime;
import java.util.List;
import java.util.Set;
import java.util.UUID;

/**
 * 令牌签发与轮换：refresh（悲观锁轮换 + 重用检测）、logout、令牌对签发、UserProfile 组装。
 */
@Service
public class TokenIssuer {

    private final UserAccountRepository userRepo;
    private final EmployeeRepository employeeRepo;
    private final RefreshTokenRepository refreshTokenRepo;
    private final RefreshTokenService refreshTokenService;
    private final JwtService jwtService;
    private final PermissionResolver permissionResolver;
    private final AuditService audit;

    public TokenIssuer(UserAccountRepository userRepo, EmployeeRepository employeeRepo,
                       RefreshTokenRepository refreshTokenRepo, RefreshTokenService refreshTokenService,
                       JwtService jwtService, PermissionResolver permissionResolver, AuditService audit) {
        this.userRepo = userRepo;
        this.employeeRepo = employeeRepo;
        this.refreshTokenRepo = refreshTokenRepo;
        this.refreshTokenService = refreshTokenService;
        this.jwtService = jwtService;
        this.permissionResolver = permissionResolver;
        this.audit = audit;
    }

    @Transactional
    public TokenResponse refresh(String rawRefresh) {
        String hash = HashUtil.sha256(rawRefresh);
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
        // 管理员手动锁定（无 lockedUntil）→ 拒绝刷新（与登录一致）
        if ("locked".equals(user.getStatus()) && user.getLockedUntil() == null) {
            throw new ApiException(ErrorCode.ACCOUNT_LOCKED, "账号已被管理员锁定，请联系管理员解锁");
        }

        // 轮换：撤销旧令牌，签发新对
        String newRaw = refreshTokenService.issue(user.getId(), token.getDeviceInfo());
        RefreshToken newToken = refreshTokenRepo.findByTokenHash(HashUtil.sha256(newRaw))
                .orElseThrow();
        refreshTokenService.revoke(token, newToken.getId());

        return buildTokenResponse(user, newRaw);
    }

    @Transactional
    public void logout(String rawRefresh) {
        if (rawRefresh == null || rawRefresh.isBlank()) {
            return;
        }
        refreshTokenRepo.findByTokenHash(HashUtil.sha256(rawRefresh))
                .ifPresent(t -> refreshTokenService.revoke(t, null));
    }

    @Transactional(readOnly = true)
    public TokenResponse.UserProfile me(java.util.function.Supplier<UUID> userIdSupplier) {
        UUID userId = userIdSupplier.get();
        UserAccount user = userRepo.findById(userId)
                .orElseThrow(() -> new ApiException(ErrorCode.UNAUTHORIZED));
        return profile(user);
    }

    /** 为某用户签发新令牌对（登录 / 改密成功后调用）。 */
    public TokenResponse issueTokens(UserAccount user) {
        String refresh = refreshTokenService.issue(user.getId(), null);
        return buildTokenResponse(user, refresh);
    }

    private TokenResponse buildTokenResponse(UserAccount user, String rawRefresh) {
        Set<String> roles = permissionResolver.rolesOf(user.getId());
        Set<String> perms = permissionResolver.permsOf(user);
        String access = jwtService.issueAccess(user.getId(), user.getEmployeeId(), user.getLoginAccount(),
                roles, perms, user.isMustChangePassword());
        return new TokenResponse(access, rawRefresh, jwtService.getAccessTtlSeconds(),
                user.isMustChangePassword(), profile(user));
    }

    private TokenResponse.UserProfile profile(UserAccount user) {
        Employee e = employeeRepo.findById(user.getEmployeeId()).orElse(null);
        List<String> roles = permissionResolver.rolesOf(user.getId()).stream().sorted().toList();
        List<String> perms = permissionResolver.permsOf(user).stream().sorted().toList();
        String dept = (e != null && e.getDepartment() != null) ? e.getDepartment().getName() : null;
        // 超管：position 字段为 null（不设置职务）。这样前端能按 isSuperAdmin && position == null
        // 自然展示"系统管理员"，避免显示一个空岗位。
        String pos = (user.isSuperAdmin() || e == null || e.getPosition() == null)
                ? null
                : e.getPosition().getName();
        return new TokenResponse.UserProfile(
                user.getId().toString(),
                user.getLoginAccount(),
                e == null ? null : e.getId().toString(),
                e == null ? null : e.getFullName(),
                e == null ? null : e.getCode(),
                dept,
                pos,
                user.isSuperAdmin(),
                roles,
                perms);
    }
}
