package com.uten.imp.features.visitor;

import com.uten.imp.config.props.JwtProperties;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
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

    /** 签发新令牌：返回原始令牌（仅此一次交给客户端），库内只存哈希。 */
    public String issue(UUID visitorId, String deviceInfo) {
        String raw = rawToken();
        VisitorRefreshToken t = new VisitorRefreshToken();
        t.setVisitorAccountId(visitorId);
        t.setDeviceInfo(deviceInfo);
        t.setTokenHash(sha256(raw));
        t.setIssuedAt(OffsetDateTime.now());
        t.setExpiresAt(OffsetDateTime.now().plusDays(props.getRefreshTtlDays()));
        repo.save(t);
        return raw;
    }

    public void revoke(VisitorRefreshToken token, UUID replacedById) {
        token.setRevokedAt(OffsetDateTime.now());
        token.setReplacedBy(replacedById);
        repo.save(token);
    }

    /** 撤销某访客全部有效令牌（重用检测）。TODO 生产改批量 update。 */
    public void revokeAllByVisitor(UUID visitorId) {
        repo.findAll().stream()
                .filter(t -> visitorId.equals(t.getVisitorAccountId()) && t.getRevokedAt() == null)
                .forEach(t -> {
                    t.setRevokedAt(OffsetDateTime.now());
                    repo.save(t);
                });
    }

    public static String sha256(String raw) {
        try {
            MessageDigest md = MessageDigest.getInstance("SHA-256");
            byte[] h = md.digest(raw.getBytes(StandardCharsets.UTF_8));
            return Base64.getEncoder().encodeToString(h);
        } catch (Exception e) {
            throw new IllegalStateException(e);
        }
    }

    private static String rawToken() {
        byte[] bytes = new byte[32];
        RNG.nextBytes(bytes);
        return Base64.getUrlEncoder().withoutPadding().encodeToString(bytes);
    }
}
