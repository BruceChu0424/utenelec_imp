package com.uten.imp.features.auth;

import com.uten.imp.config.props.JwtProperties;
import com.uten.imp.features.rbac.RefreshToken;
import com.uten.imp.features.rbac.RefreshTokenRepository;
import org.springframework.stereotype.Service;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.SecureRandom;
import java.time.OffsetDateTime;
import java.util.Base64;
import java.util.UUID;

/**
 * 不透明刷新令牌：生成 256bit 随机串，只存 sha256 哈希。轮换 + 重用检测见 {@link AuthService#refresh}。
 */
@Service
public class RefreshTokenService {

    private static final SecureRandom RNG = new SecureRandom();

    private final RefreshTokenRepository repo;
    private final JwtProperties props;

    public RefreshTokenService(RefreshTokenRepository repo, JwtProperties props) {
        this.repo = repo;
        this.props = props;
    }

    /** 签发新令牌：返回原始令牌（仅此一次交给客户端），库内只存哈希。 */
    public String issue(UUID userId, String deviceInfo) {
        String raw = rawToken();
        RefreshToken t = new RefreshToken();
        t.setUserId(userId);
        t.setDeviceInfo(deviceInfo);
        t.setTokenHash(sha256(raw));
        t.setIssuedAt(OffsetDateTime.now());
        t.setExpiresAt(OffsetDateTime.now().plusDays(props.getRefreshTtlDays()));
        repo.save(t);
        return raw;
    }

    /** 标记某令牌已撤销（轮换时），并记录被哪个新令牌取代。 */
    public void revoke(RefreshToken token, UUID replacedById) {
        token.setRevokedAt(OffsetDateTime.now());
        token.setReplacedBy(replacedById);
        repo.save(token);
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
