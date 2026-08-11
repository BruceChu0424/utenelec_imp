package com.uten.imp.features.admin.impersonation;

import com.uten.imp.audit.AuditService;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.features.admin.impersonation.dto.ImpersonationMeta;
import com.uten.imp.features.admin.impersonation.dto.ImpersonationModeResponse;
import com.uten.imp.features.admin.impersonation.dto.ImpersonationStartResponse;
import com.uten.imp.features.admin.impersonation.dto.ImpersonationTargetDto;
import com.uten.imp.features.auth.StaffTokenResponseFactory;
import com.uten.imp.features.auth.dto.TokenResponse;
import com.uten.imp.features.auth.model.UserAccount;
import com.uten.imp.features.auth.model.UserAccountRepository;
import com.uten.imp.features.org.employee.EmployeeQueryService;
import com.uten.imp.features.org.employee.dto.EmployeeListItem;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.JwtService;
import com.uten.imp.security.SecurityContextCurrentUser;
import io.jsonwebtoken.Claims;
import io.jsonwebtoken.JwtException;
import org.springframework.security.crypto.password.PasswordEncoder;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.time.Duration;
import java.time.Instant;
import java.util.List;
import java.util.Set;
import java.util.UUID;

/**
 * 超级管理员「切换人 / 模拟身份」：以目标用户真实视角验证其权限配置（卡片 / 页面 / 数据范围 / 脱敏）。
 *
 * <p>三段式：
 * <ol>
 *   <li>{@link #enter} —— admin 重新确认密码 → 签发限时 modeToken（默认 15 分钟窗口）。</li>
 *   <li>{@link #start} —— 凭 modeToken 切换到目标员工 → 签发 sub=目标 的模拟 token（带 imp=admin 标记）。
 *       模拟期间后端 {@link com.uten.imp.security.ImpersonationWriteGuardFilter} 强制只读。</li>
 *   <li>{@link #end} —— 退出模拟，审计。</li>
 * </ol>
 * enter / start 由 admin token 调用（{@code principal.superAdmin}）；end 由模拟 token 调用（主体=目标）。
 */
@Service
public class ImpersonationService {

    /** 密码长度上限（防 Argon2 CPU DoS，与 LoginService 对齐）。 */
    private static final int PASSWORD_MAX_LENGTH = 128;

    private final SecurityContextCurrentUser currentUser;
    private final UserAccountRepository userRepo;
    private final PasswordEncoder passwordEncoder;
    private final JwtService jwtService;
    private final StaffTokenResponseFactory tokenFactory;
    private final AuditService audit;
    private final EmployeeQueryService employeeQueryService;

    /** 进模式密码校验的时序抹平用 dummy hash（账号已知，弱反枚举，仍对齐以防侧信道）。 */
    private final String dummyHash;

    public ImpersonationService(SecurityContextCurrentUser currentUser,
                                UserAccountRepository userRepo,
                                PasswordEncoder passwordEncoder,
                                JwtService jwtService,
                                StaffTokenResponseFactory tokenFactory,
                                AuditService audit,
                                EmployeeQueryService employeeQueryService) {
        this.currentUser = currentUser;
        this.userRepo = userRepo;
        this.passwordEncoder = passwordEncoder;
        this.jwtService = jwtService;
        this.tokenFactory = tokenFactory;
        this.audit = audit;
        this.employeeQueryService = employeeQueryService;
        this.dummyHash = passwordEncoder.encode("dummy-impersonation-timing");
    }

    /** 模拟目标候选（picker）：仅活跃员工；superAdmin 调用时数据范围不受限。搜索可进一步收窄。 */
    @Transactional(readOnly = true)
    public List<ImpersonationTargetDto> listTargets(String search) {
        PageResponse<EmployeeListItem> page = employeeQueryService.list(
                1, 200, search, Set.of("active"), null, false);
        return page.getItems().stream()
                .map(e -> new ImpersonationTargetDto(
                        e.getId(), e.getFullName(),
                        e.getDepartmentName(), e.getPositionName()))
                .toList();
    }

    public ImpersonationModeResponse enter(String password) {
        AuthUser admin = currentUser.get().orElseThrow(() -> new ApiException(ErrorCode.UNAUTHORIZED));
        UserAccount adminAccount = userRepo.findById(admin.getId())
                .orElseThrow(() -> new ApiException(ErrorCode.UNAUTHORIZED));

        if (password == null || password.length() > PASSWORD_MAX_LENGTH) {
            // 超长/空跑一次 dummy 校验抹平时序，再拒（与错密码同消息）
            passwordEncoder.matches(password == null ? "" : password, dummyHash);
            throw new ApiException(ErrorCode.BAD_CREDENTIALS);
        }
        if (!passwordEncoder.matches(password, adminAccount.getPasswordHash())) {
            throw new ApiException(ErrorCode.BAD_CREDENTIALS);
        }

        long windowSeconds = jwtService.getImpersonationWindowSeconds();
        Instant expiresAt = Instant.now().plusSeconds(windowSeconds);
        String modeToken = jwtService.issueModeToken(admin.getId(), expiresAt);
        audit.logExplicit(admin.getId(), admin.getLoginAccount(),
                "impersonation_enter", "authorization", null, "success");
        return new ImpersonationModeResponse(modeToken, windowSeconds);
    }

    @Transactional(readOnly = true)
    public ImpersonationStartResponse start(UUID targetEmployeeId, String modeToken) {
        AuthUser admin = currentUser.get().orElseThrow(() -> new ApiException(ErrorCode.UNAUTHORIZED));

        // 1) 校验 modeToken：签名 + 类型 + 归属 + 未过期
        Claims claims;
        try {
            claims = jwtService.parse(modeToken);
        } catch (JwtException | IllegalArgumentException ex) {
            throw new ApiException(ErrorCode.UNAUTHORIZED, "模拟模式已失效，请重新确认密码");
        }
        if (!"impersonation-mode".equals(claims.get("typ"))) {
            throw new ApiException(ErrorCode.UNAUTHORIZED, "模拟模式已失效，请重新确认密码");
        }
        UUID modeAdminId;
        try {
            modeAdminId = UUID.fromString(claims.getSubject());
        } catch (IllegalArgumentException ex) {
            throw new ApiException(ErrorCode.UNAUTHORIZED, "模拟模式已失效，请重新确认密码");
        }
        if (!modeAdminId.equals(admin.getId())) {
            throw new ApiException(ErrorCode.FORBIDDEN, "模拟模式不属于当前账号");
        }

        // 2) 解析目标：拒绝超管 / 未激活 / 已删
        UserAccount target = userRepo.findByEmployeeId(targetEmployeeId)
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "目标员工无登录账号"));
        if (target.isSuperAdmin()) {
            throw new ApiException(ErrorCode.BUSINESS, "不能模拟超级管理员身份");
        }
        if (target.isDeleted() || !"active".equals(target.getStatus())) {
            throw new ApiException(ErrorCode.BUSINESS, "目标账号未激活或已停用");
        }

        // 3) 签发目标 token，过期取「access TTL」与「窗口剩余」的较小值
        long accessTtl = jwtService.getAccessTtlSeconds();
        long remaining = Duration.between(Instant.now(), claims.getExpiration().toInstant()).getSeconds();
        long ttlSeconds = Math.max(1, Math.min(accessTtl, remaining));
        Instant expiresAt = Instant.now().plusSeconds(ttlSeconds);
        TokenResponse token = tokenFactory.buildImpersonation(target, admin.getId(), expiresAt);

        TokenResponse.UserProfile profile = token.user();
        ImpersonationMeta meta = new ImpersonationMeta(
                admin.getId(),
                target.getId(),
                profile.name(),
                profile.department(),
                profile.position(),
                expiresAt.toEpochMilli(),
                true);
        audit.logExplicit(admin.getId(), admin.getLoginAccount(),
                "impersonation_switch", "users", target.getId().toString(), "success");
        return new ImpersonationStartResponse(token, meta);
    }

    /** 退出模拟。由模拟 token 调用（主体=目标，impersonatedBy=admin）；非模拟时幂等无操作。 */
    public void end() {
        AuthUser principal = currentUser.get().orElseThrow(() -> new ApiException(ErrorCode.UNAUTHORIZED));
        UUID adminId = principal.getImpersonatedBy();
        if (adminId == null) {
            return; // 不在模拟中，幂等返回
        }
        String adminAccount = userRepo.findById(adminId)
                .map(UserAccount::getLoginAccount)
                .orElse(null);
        audit.logExplicit(adminId, adminAccount,
                "impersonation_exit", "users", principal.getId().toString(), "success");
    }
}
