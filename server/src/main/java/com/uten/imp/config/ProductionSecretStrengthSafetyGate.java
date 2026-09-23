package com.uten.imp.config;

import jakarta.annotation.PostConstruct;
import org.springframework.core.env.Environment;
import org.springframework.core.env.Profiles;
import org.springframework.stereotype.Component;
import org.springframework.util.StringUtils;

import java.nio.charset.StandardCharsets;

/**
 * Fails application startup when a production-like profile runs with weak or
 * placeholder signing/encryption secrets.
 *
 * <p>{@code JwtService} already rejects short JWT secrets, and the dedicated
 * {@code internal-test} runtime gate re-checks every secret; this gate closes
 * the same gap for {@code prod}/{@code cloud} so no profile can start with a
 * short or placeholder HMAC/PGP master key.</p>
 */
@Component
public class ProductionSecretStrengthSafetyGate {

    private static final Profiles PRODUCTION_PROFILES = Profiles.of("prod", "cloud");

    private final Environment environment;

    public ProductionSecretStrengthSafetyGate(Environment environment) {
        this.environment = environment;
    }

    @PostConstruct
    void validate() {
        if (!environment.acceptsProfiles(PRODUCTION_PROFILES)) {
            return;
        }
        requireSecret("uten.jwt.secret", 32);
        requireSecret("uten.crypto.pgp-master-key", 32);
        requireSecret("uten.crypto.hmac-key", 32);
        // 官网询盘推送的共享密钥是公网 permitAll 入口的唯一认证边界: 留空=功能关闭 (拒绝全部推送),
        // 一旦配置就必须是 32 字节以上的非占位强密钥 (security-16)。
        if (StringUtils.hasText(environment.getProperty("uten.website.inquiry-ingest-token"))) {
            requireSecret("uten.website.inquiry-ingest-token", 32);
        }
    }

    private void requireSecret(String key, int minimumUtf8Bytes) {
        String value = environment.getProperty(key);
        if (!StringUtils.hasText(value)
                || value.contains("REPLACE")
                || value.contains("CHANGE_ME")) {
            throw new IllegalStateException(
                    "prod/cloud profiles require a non-placeholder value for " + key);
        }
        if (value.getBytes(StandardCharsets.UTF_8).length < minimumUtf8Bytes) {
            throw new IllegalStateException(
                    "prod/cloud secret is too short (min " + minimumUtf8Bytes
                            + " UTF-8 bytes): " + key);
        }
    }
}
