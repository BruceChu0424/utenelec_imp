package com.uten.imp.security;

import com.uten.imp.config.props.JwtProperties;
import com.uten.imp.features.admin.systemsetting.SystemSettingKey;
import com.uten.imp.features.admin.systemsetting.SystemSettingsService;
import io.jsonwebtoken.Claims;
import io.jsonwebtoken.Jwts;
import io.jsonwebtoken.security.Keys;
import org.springframework.stereotype.Component;

import javax.crypto.SecretKey;
import java.nio.charset.StandardCharsets;
import java.time.Instant;
import java.util.Date;
import java.util.Objects;
import java.util.Set;
import java.util.UUID;

/** Access JWT 签发与解析（HS256）。refresh 用不透明随机串另存哈希（见 RefreshTokenService）。 */
@Component
public class JwtService {

    private final SecretKey key;
    private final JwtProperties props;
    private final SystemSettingsService settings;

    public JwtService(JwtProperties props, SystemSettingsService settings) {
        this.props = props;
        this.settings = settings;
        if (props.getSecret() == null || props.getSecret().isBlank()) {
            throw new IllegalStateException("缺少 UTEN_JWT_SECRET(在 server/.env 或环境变量配置)");
        }
        if (props.getIssuer() == null || props.getIssuer().isBlank()) {
            throw new IllegalStateException("缺少 UTEN_JWT_ISSUER");
        }
        byte[] secret = props.getSecret().getBytes(StandardCharsets.UTF_8);
        if (secret.length < 32) {
            // fail-fast：HS256 至少 32 字节，绝不静默补齐弱密钥
            throw new IllegalStateException("UTEN_JWT_SECRET 至少 32 字节(当前 " + secret.length + ")");
        }
        this.key = Keys.hmacShaKeyFor(secret);
    }

    /**
     * Issues a deliberately small staff access token.
     *
     * <p>Roles, permissions and mutable profile fields are resolved from the database
     * after the authorization stamps are validated on every request. This keeps request
     * headers bounded and prevents a signed-but-stale permission snapshot from being used.
     */
    public String issueAccess(
            UUID userId,
            long authVersion,
            long authorizationEpoch,
            UUID sessionId) {
        // 每个访问令牌都必须挂在一条服务端会话上: 过滤器按 sid 查吊销/空闲/绝对期限 (ADR-110)。
        Objects.requireNonNull(sessionId, "sessionId");
        Instant now = Instant.now();
        Instant exp = now.plusSeconds(getAccessTtlSeconds());
        return Jwts.builder()
                .issuer(props.getIssuer())
                .subject(userId.toString())
                .claim("av", authVersion)
                .claim("ae", authorizationEpoch)
                .claim("typ", "staff")
                .claim("sid", sessionId.toString())
                .issuedAt(Date.from(now))
                .expiration(Date.from(exp))
                .signWith(key)
                .compact();
    }

    /**
     * 超级管理员「切换人」用的模拟身份 token。
     *
     * <p>主体仍是目标用户（sub=目标、av/ae 按目标校验），下游权限/数据范围全部按目标解析。
     * 额外的 {@code imp} claim 记录真实操作人（admin），供只读守卫与审计区分。过期时间由调用方
     * 按「模拟窗口」封顶，短于普通 access token 也可。
     */
    public String issueImpersonationAccess(
            UUID targetUserId,
            long authVersion,
            long authorizationEpoch,
            UUID adminUserId,
            Instant expiresAt,
            UUID sessionId) {
        // sid 是发起模拟的超管自己的会话: 超管退出登录或空闲超时, 模拟令牌随之失效。
        Objects.requireNonNull(sessionId, "sessionId");
        Instant now = Instant.now();
        Instant exp = expiresAt.isBefore(now) ? now.plusSeconds(1) : expiresAt;
        return Jwts.builder()
                .issuer(props.getIssuer())
                .subject(targetUserId.toString())
                .claim("av", authVersion)
                .claim("ae", authorizationEpoch)
                .claim("typ", "staff")
                .claim("imp", adminUserId.toString())
                .claim("sid", sessionId.toString())
                .issuedAt(Date.from(now))
                .expiration(Date.from(exp))
                .signWith(key)
                .compact();
    }

    /**
     * 模拟模式凭证 (proof that the admin recently passed step-up re-authentication)。
     * 自包含: {@code typ=impersonation-mode}、{@code sub=adminId}、{@code sid=签发时的会话}、签名 + 过期。
     * 限时窗口内凭它在 /start 反复切换不同目标, 无需再输密码; 换了会话 (重新登录) 即作废。
     */
    public String issueModeToken(UUID adminUserId, UUID sessionId, Instant expiresAt) {
        Objects.requireNonNull(sessionId, "sessionId");
        Instant now = Instant.now();
        Instant exp = expiresAt.isBefore(now) ? now.plusSeconds(1) : expiresAt;
        return Jwts.builder()
                .issuer(props.getIssuer())
                .subject(adminUserId.toString())
                .claim("typ", "impersonation-mode")
                .claim("sid", sessionId.toString())
                .issuedAt(Date.from(now))
                .expiration(Date.from(exp))
                .signWith(key)
                .compact();
    }

    /** 模拟模式窗口时长 (秒), 系统设置「切换人窗口」。 */
    public long getImpersonationWindowSeconds() {
        return settings.readLong(SystemSettingKey.IMPERSONATION_WINDOW_MINUTES) * 60;
    }

    /** 访客访问 JWT（typ=visitor，subject=visitorId）。 */
    public String issueVisitorAccess(
            UUID visitorId,
            String visitorNo,
            String avatarSeed,
            Set<String> permissions,
            UUID sessionId) {
        Objects.requireNonNull(sessionId, "sessionId");
        Instant now = Instant.now();
        Instant exp = now.plusSeconds(getAccessTtlSeconds());
        return Jwts.builder()
                .issuer(props.getIssuer())
                .subject(visitorId.toString())
                .claim("typ", "visitor")
                // JWT payload is only signed, not encrypted. Keep raw phone PII out of it;
                // the stable visitor number is sufficient for principal/audit display.
                .claim("acc", visitorNo)
                .claim("vno", visitorNo)
                .claim("avs", avatarSeed)
                .claim("perms", permissions)
                .claim("sid", sessionId.toString())
                .issuedAt(Date.from(now))
                .expiration(Date.from(exp))
                .signWith(key)
                .compact();
    }

    public Claims parse(String token) {
        return Jwts.parser()
                .verifyWith(key)
                .requireIssuer(props.getIssuer())
                .build()
                .parseSignedClaims(token)
                .getPayload();
    }

    public long getAccessTtlSeconds() {
        return settings.readLong(SystemSettingKey.JWT_ACCESS_TTL_MINUTES) * 60;
    }
}
