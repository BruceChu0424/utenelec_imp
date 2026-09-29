package com.uten.imp.security;

import lombok.Getter;
import lombok.Setter;
import org.springframework.boot.context.properties.ConfigurationProperties;
import org.springframework.stereotype.Component;

import java.util.HashMap;
import java.util.Map;

/**
 * 运行期配置的第三方凭据(目前只有 AI 服务商密钥)的加密密钥(uten.crypto.secret-cipher-*, ADR-133)。
 *
 * <p>与 {@link com.uten.imp.config.props.CryptoProperties} 同前缀、不同字段: pgcrypto 主密钥只给
 * 员工 PII 用并以绑定参数进数据库, 这里的密钥只在 JVM 内做 AES-256-GCM, 两者互不复用。
 * 未配置专用密钥时由 {@code uten.crypto.hmac-key} 经 HKDF 派生(版本 {@code h1}), 见 {@link SecretCipher}。
 */
@Getter
@Setter
@Component
@ConfigurationProperties(prefix = "uten.crypto")
public class SecretCipherProperties {

    /** 专用密钥(UTEN_SECRET_CIPHER_KEY, 至少 32 字节)。留空时退回 HMAC 密钥派生。 */
    private String secretCipherKey;

    /** 专用密钥的版本号(密文前缀 {@code g<版本>:}), 默认 1; 以 h 开头的版本保留给派生密钥。 */
    private String secretCipherKeyVersion = "1";

    /** 轮换后的旧专用密钥: 版本 → 密钥, 只用于解密历史密文(启动时自动改用当前版本重新加密)。 */
    private Map<String, String> secretCipherLegacyKeys = new HashMap<>();
}
