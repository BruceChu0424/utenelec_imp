package com.uten.imp.features.visitor;

import com.uten.imp.common.util.HashUtil;
import com.uten.imp.config.props.JwtProperties;
import com.uten.imp.features.admin.systemsetting.SystemSettingsService;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;

import java.security.SecureRandom;
import java.time.OffsetDateTime;
import java.util.Base64;
import java.util.UUID;

/**
 * 访客不透明刷新令牌（独立于员工 RefreshTokenService）。
 * 只存 sha256(原文)；轮换 + 重用检测见 {@link VisitorAuthService#refresh}。
 */
@Service
@RequiredArgsConstructor
public class VisitorRefreshTokenService {

    private static final SecureRandom RNG = new SecureRandom();

    private final VisitorRefreshTokenRepository repo;
    private final JwtProperties props;
    private final SystemSettingsService settings;

    /** 签发新令牌：返回原始令牌（仅此一次交给客户端），库内只存哈希。 */
    public String issue(UUID visitorId, String deviceInfo) {
        String raw = rawToken();
        VisitorRefreshToken t = new VisitorRefreshToken();
        t.setVisitorAccountId(visitorId);
        t.setDeviceInfo(deviceInfo);
        t.setTokenHash(HashUtil.sha256(raw));
        t.setIssuedAt(OffsetDateTime.now());
        t.setExpiresAt(OffsetDateTime.now().plusDays(settings.readLong("jwt_refresh_ttl_days", 7)));
        repo.save(t);
        return raw;
    }

    public void revoke(VisitorRefreshToken token, UUID replacedById) {
        token.setRevokedAt(OffsetDateTime.now());
        token.setReplacedBy(replacedById);
        repo.save(token);
    }

    /** 撤销某访客全部有效令牌（重用检测）。批量 UPDATE，对齐员工侧 revokeAllByUserId。 */
    public void revokeAllByVisitor(UUID visitorId) {
        repo.revokeAllByVisitorAccountId(visitorId);
    }

    private static String rawToken() {
        byte[] bytes = new byte[32];
        RNG.nextBytes(bytes);
        return Base64.getUrlEncoder().withoutPadding().encodeToString(bytes);
    }
}
