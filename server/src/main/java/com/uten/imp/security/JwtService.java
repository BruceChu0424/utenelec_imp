package com.uten.imp.security;

import com.uten.imp.config.props.JwtProperties;
import io.jsonwebtoken.Claims;
import io.jsonwebtoken.Jwts;
import io.jsonwebtoken.security.Keys;
import org.springframework.stereotype.Component;

import javax.crypto.SecretKey;
import java.nio.charset.StandardCharsets;
import java.time.Instant;
import java.util.Date;
import java.util.Set;
import java.util.UUID;

/** Access JWT 签发与解析（HS256）。refresh 用不透明随机串另存哈希（见 RefreshTokenService）。 */
@Component
public class JwtService {

    private final SecretKey key;
    private final JwtProperties props;

    public JwtService(JwtProperties props) {
        this.props = props;
        if (props.getSecret() == null || props.getSecret().isBlank()) {
            throw new IllegalStateException("缺少 UTEN_JWT_SECRET（在 server/.env 或环境变量配置）");
        }
        byte[] secret = props.getSecret().getBytes(StandardCharsets.UTF_8);
        if (secret.length < 32) {
            // fail-fast：HS256 至少 32 字节，绝不静默补齐弱密钥
            throw new IllegalStateException("UTEN_JWT_SECRET 至少 32 字节（当前 " + secret.length + "）");
        }
        this.key = Keys.hmacShaKeyFor(secret);
    }

    public String issueAccess(UUID userId, UUID employeeId, String loginAccount,
                              Set<String> roles, Set<String> permissions, boolean mustChangePassword) {
        Instant now = Instant.now();
        Instant exp = now.plusSeconds(props.getAccessTtlMinutes() * 60);
        return Jwts.builder()
                .issuer(props.getIssuer())
                .subject(userId.toString())
                .claim("emp", employeeId == null ? null : employeeId.toString())
                .claim("acc", loginAccount)
                .claim("roles", roles)
                .claim("perms", permissions)
                .claim("mcp", mustChangePassword)
                .claim("typ", "staff")
                .issuedAt(Date.from(now))
                .expiration(Date.from(exp))
                .signWith(key)
                .compact();
    }

    /** 访客访问 JWT（typ=visitor，subject=visitorId）。 */
    public String issueVisitorAccess(UUID visitorId, String phone, String visitorNo,
                                     Set<String> permissions) {
        Instant now = Instant.now();
        Instant exp = now.plusSeconds(props.getAccessTtlMinutes() * 60);
        return Jwts.builder()
                .issuer(props.getIssuer())
                .subject(visitorId.toString())
                .claim("typ", "visitor")
                .claim("acc", phone)
                .claim("vno", visitorNo)
                .claim("perms", permissions)
                .issuedAt(Date.from(now))
                .expiration(Date.from(exp))
                .signWith(key)
                .compact();
    }

    public Claims parse(String token) {
        return Jwts.parser()
                .verifyWith(key)
                .build()
                .parseSignedClaims(token)
                .getPayload();
    }

    public long getAccessTtlSeconds() {
        return props.getAccessTtlMinutes() * 60;
    }
}
