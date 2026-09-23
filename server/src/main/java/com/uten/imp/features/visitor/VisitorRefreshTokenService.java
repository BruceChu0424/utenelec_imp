package com.uten.imp.features.visitor;

import com.uten.imp.common.util.HashUtil;
import com.uten.imp.features.auth.AuthSessionService;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;

import java.security.SecureRandom;
import java.time.OffsetDateTime;
import java.util.Base64;
import java.util.Objects;
import java.util.UUID;

/**
 * 访客不透明刷新令牌（独立于员工 RefreshTokenService）。
 * 只存 sha256(原文)；轮换 + 重用检测见 {@link VisitorAuthService#refresh}。
 * 与员工同口径 (ADR-110): 登录先开服务端会话, 刷新令牌过期时间就是会话的绝对期限, 轮换不延长。
 */
@Service
@RequiredArgsConstructor
public class VisitorRefreshTokenService {

    private static final SecureRandom RNG = new SecureRandom();

    private final VisitorRefreshTokenRepository repo;
    private final AuthSessionService sessions;

    public record IssuedRefreshToken(
            String rawToken,
            UUID tokenId,
            UUID sessionId,
            OffsetDateTime expiresAt) {
    }

    /** Starts one new visitor login session and issues its first refresh token. */
    public IssuedRefreshToken issueNewSession(UUID visitorId, String deviceInfo) {
        AuthSessionService.OpenedSession session = sessions.openVisitorSession(visitorId);
        return issueInSession(visitorId, deviceInfo, session.sid(), session.absoluteExpiresAt());
    }

    /** Rotates within an existing server-authoritative visitor session; never extends it. */
    public IssuedRefreshToken issueInSession(
            UUID visitorId,
            String deviceInfo,
            UUID sessionId,
            OffsetDateTime sessionExpiresAt) {
        Objects.requireNonNull(sessionId, "sessionId");
        Objects.requireNonNull(sessionExpiresAt, "sessionExpiresAt");
        String raw = rawToken();
        VisitorRefreshToken t = new VisitorRefreshToken();
        t.setVisitorAccountId(visitorId);
        t.setSessionId(sessionId);
        t.setDeviceInfo(deviceInfo);
        t.setTokenHash(HashUtil.sha256(raw));
        t.setIssuedAt(OffsetDateTime.now());
        t.setExpiresAt(sessionExpiresAt);
        repo.save(t);
        return new IssuedRefreshToken(raw, t.getId(), sessionId, t.getExpiresAt());
    }

    public void revoke(VisitorRefreshToken token, UUID replacedById) {
        token.setRevokedAt(OffsetDateTime.now());
        token.setReplacedBy(replacedById);
        repo.save(token);
    }

    private static String rawToken() {
        byte[] bytes = new byte[32];
        RNG.nextBytes(bytes);
        return Base64.getUrlEncoder().withoutPadding().encodeToString(bytes);
    }
}
