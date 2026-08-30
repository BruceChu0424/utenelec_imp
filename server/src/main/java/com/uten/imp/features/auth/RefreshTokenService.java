package com.uten.imp.features.auth;

import com.uten.imp.common.util.HashUtil;
import com.uten.imp.config.props.JwtProperties;
import com.uten.imp.features.admin.systemsetting.SystemSettingsService;
import com.uten.imp.features.auth.model.RefreshToken;
import com.uten.imp.features.auth.model.RefreshTokenRepository;
import org.springframework.stereotype.Service;

import java.security.SecureRandom;
import java.time.OffsetDateTime;
import java.util.Base64;
import java.util.Objects;
import java.util.UUID;

/**
 * 不透明刷新令牌：生成 256bit 随机串，只存 sha256 哈希。轮换 + 重用检测见 {@link TokenIssuer#refresh}。
 */
@Service
public class RefreshTokenService {

    private static final SecureRandom RNG = new SecureRandom();

    private final RefreshTokenRepository repo;
    private final JwtProperties props;
    private final SystemSettingsService settings;

    public RefreshTokenService(RefreshTokenRepository repo, JwtProperties props, SystemSettingsService settings) {
        this.repo = repo;
        this.props = props;
        this.settings = settings;
    }

    public record IssuedRefreshToken(
            String rawToken,
            UUID tokenId,
            UUID sessionId,
            OffsetDateTime expiresAt) {
    }

    /** Starts one new login session and issues its first refresh token. */
    public IssuedRefreshToken issueNewSession(UUID userId, String deviceInfo) {
        return issueInSession(userId, deviceInfo, UUID.randomUUID());
    }

    /** Rotates within an existing server-authoritative login session. */
    public IssuedRefreshToken issueInSession(
            UUID userId,
            String deviceInfo,
            UUID sessionId) {
        Objects.requireNonNull(sessionId, "sessionId");
        String raw = rawToken();
        RefreshToken t = new RefreshToken();
        t.setUserId(userId);
        t.setSessionId(sessionId);
        t.setDeviceInfo(deviceInfo);
        t.setTokenHash(HashUtil.sha256(raw));
        t.setIssuedAt(OffsetDateTime.now());
        t.setExpiresAt(OffsetDateTime.now().plusDays(settings.readLong("jwt_refresh_ttl_days", 7)));
        repo.save(t);
        return new IssuedRefreshToken(raw, t.getId(), sessionId, t.getExpiresAt());
    }

    /** 标记某令牌已撤销（轮换时），并记录被哪个新令牌取代。 */
    public void revoke(RefreshToken token, UUID replacedById) {
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
