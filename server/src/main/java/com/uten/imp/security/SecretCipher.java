package com.uten.imp.security;

import com.uten.imp.config.props.CryptoProperties;
import com.uten.imp.config.props.JwtProperties;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.stereotype.Component;

import javax.crypto.Cipher;
import javax.crypto.Mac;
import javax.crypto.SecretKey;
import javax.crypto.spec.GCMParameterSpec;
import javax.crypto.spec.SecretKeySpec;
import java.nio.charset.StandardCharsets;
import java.security.GeneralSecurityException;
import java.security.SecureRandom;
import java.util.Base64;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.Objects;
import java.util.regex.Pattern;

/**
 * 运行期配置的第三方凭据加密(ADR-133)。只用于超管在系统设置里填写的服务商密钥这类
 * 「运行时配置的第三方凭据」; 员工 PII 仍走 {@link TxSessionVars}(ADR-037 的 KMS 决定之前不迁移)。
 *
 * <p>算法: AES-256-GCM, 每次加密随机 12 字节 IV, 128 位认证标签。密文格式
 * {@code "g" + 版本 + ":" + base64url(iv || 密文+标签)}。附加认证数据(AAD)
 * {@code "uten|" + JWT 签发者 + "|" + 调用方上下文 + "|v" + 版本}: 绑定环境、表、列、行 id 与版本,
 * 密文搬到别的行、别的环境或改版本号都解不开。
 *
 * <p>密钥来源(按顺序):
 * <ol>
 *   <li>{@code uten.crypto.secret-cipher-key}(UTEN_SECRET_CIPHER_KEY, 至少 32 字节)与版本
 *       {@code secret-cipher-key-version}; 旧版本密钥放 {@code secret-cipher-legacy-keys} 只用于解密;</li>
 *   <li>未配置专用密钥时: HKDF-SHA256(ikm = {@code uten.crypto.hmac-key}, salt "uten-secret-cipher",
 *       info "ai-credentials-v1"), 版本固定 {@code h1}。HMAC 密钥只在 JVM 内做 HMAC 计算、从不作为
 *       SQL 参数进数据库(见 ADR-133 的核查记录), 派生出的密钥与 HMAC 用途在 HKDF 层面隔离。</li>
 * </ol>
 * 配置了专用密钥后, 派生密钥仍作为旧版本 {@code h1} 保留解密能力, 启动时由服务商表自动改用新密钥重新加密。
 * pgcrypto 主密钥从不参与。
 *
 * <p>密钥与明文从不写日志; 解密失败一律抛 {@link SecretUnreadableException}(不区分原因)。
 */
@Component
public class SecretCipher {

    /** HMAC 派生密钥的固定版本号(专用密钥的版本不得以 h 开头)。 */
    public static final String DERIVED_VERSION = "h1";

    static final String HKDF_SALT = "uten-secret-cipher";
    static final String DERIVED_INFO = "ai-credentials-v1";
    static final String CONFIGURED_INFO = "secret-cipher-key";

    private static final int IV_BYTES = 12;
    private static final int TAG_BITS = 128;
    private static final int MIN_KEY_BYTES = 32;
    private static final Pattern VERSION = Pattern.compile("^[A-Za-z0-9]{1,16}$");

    private final String issuer;
    private final String currentVersion;
    private final Map<String, SecretKey> keyring;
    private final SecureRandom random;

    @Autowired
    public SecretCipher(SecretCipherProperties properties, CryptoProperties crypto, JwtProperties jwt) {
        this(properties.getSecretCipherKey(), properties.getSecretCipherKeyVersion(),
                properties.getSecretCipherLegacyKeys(), crypto.getHmacKey(), jwt.getIssuer(), new SecureRandom());
    }

    SecretCipher(String configuredKey, String configuredVersion, Map<String, String> legacyKeys,
                 String hmacKey, String issuer, SecureRandom random) {
        this.issuer = issuer == null ? "" : issuer;
        this.random = Objects.requireNonNull(random, "random");
        Map<String, SecretKey> keys = new LinkedHashMap<>();
        if (hasText(hmacKey)) {
            keys.put(DERIVED_VERSION, deriveKey(hmacKey, DERIVED_INFO));
        }
        String current = keys.isEmpty() ? null : DERIVED_VERSION;
        if (legacyKeys != null) {
            for (Map.Entry<String, String> legacy : legacyKeys.entrySet()) {
                String version = requireConfiguredVersion(legacy.getKey());
                keys.put(version, configuredKey(legacy.getValue(), "uten.crypto.secret-cipher-legacy-keys." + version));
            }
        }
        if (hasText(configuredKey)) {
            String version = requireConfiguredVersion(configuredVersion == null ? "1" : configuredVersion.trim());
            keys.put(version, configuredKey(configuredKey, "uten.crypto.secret-cipher-key"));
            current = version;
        }
        this.keyring = Collections.unmodifiableMap(keys);
        this.currentVersion = current;
    }

    /** 当前用于加密的密钥版本; 没有任何可用密钥时为空。 */
    public String currentVersion() {
        return currentVersion;
    }

    /** 是否有可用于加密的密钥(专用密钥或 HMAC 派生密钥)。 */
    public boolean available() {
        return currentVersion != null;
    }

    /**
     * 加密。
     *
     * @param plaintext  明文(非空)
     * @param aadContext 调用方上下文, 如 {@code "ai_providers|secret|" + 行 id}; 解密必须给出同一个值
     */
    public String encrypt(String plaintext, String aadContext) {
        Objects.requireNonNull(plaintext, "plaintext");
        Objects.requireNonNull(aadContext, "aadContext");
        if (currentVersion == null) {
            throw new IllegalStateException(
                    "第三方凭据加密未配置: 需要 UTEN_SECRET_CIPHER_KEY 或 UTEN_HMAC_KEY");
        }
        byte[] iv = new byte[IV_BYTES];
        random.nextBytes(iv);
        try {
            Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
            cipher.init(Cipher.ENCRYPT_MODE, keyring.get(currentVersion), new GCMParameterSpec(TAG_BITS, iv));
            cipher.updateAAD(aad(aadContext, currentVersion));
            byte[] sealed = cipher.doFinal(plaintext.getBytes(StandardCharsets.UTF_8));
            byte[] payload = new byte[iv.length + sealed.length];
            System.arraycopy(iv, 0, payload, 0, iv.length);
            System.arraycopy(sealed, 0, payload, iv.length, sealed.length);
            return "g" + currentVersion + ":" + Base64.getUrlEncoder().withoutPadding().encodeToString(payload);
        } catch (GeneralSecurityException e) {
            throw new IllegalStateException("第三方凭据加密失败", e);
        }
    }

    /**
     * 解密。格式不对、版本没有对应密钥、AAD 不符或密文被篡改一律抛 {@link SecretUnreadableException}。
     */
    public String decrypt(String stored, String aadContext) {
        Objects.requireNonNull(aadContext, "aadContext");
        Parsed parsed = parse(stored);
        SecretKey key = parsed == null ? null : keyring.get(parsed.version());
        if (key == null) {
            throw new SecretUnreadableException();
        }
        try {
            Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
            cipher.init(Cipher.DECRYPT_MODE, key, new GCMParameterSpec(TAG_BITS, parsed.payload(), 0, IV_BYTES));
            cipher.updateAAD(aad(aadContext, parsed.version()));
            byte[] plain = cipher.doFinal(parsed.payload(), IV_BYTES, parsed.payload().length - IV_BYTES);
            return new String(plain, StandardCharsets.UTF_8);
        } catch (GeneralSecurityException | RuntimeException e) {
            throw new SecretUnreadableException();
        }
    }

    /** 密文不是当前版本(需要启动时改用当前密钥重新加密)。格式不对的密文返回 false(交给解密报告)。 */
    public boolean needsRewrap(String stored) {
        Parsed parsed = parse(stored);
        return parsed != null && currentVersion != null && !currentVersion.equals(parsed.version());
    }

    private byte[] aad(String aadContext, String version) {
        return ("uten|" + issuer + "|" + aadContext + "|v" + version).getBytes(StandardCharsets.UTF_8);
    }

    private static Parsed parse(String stored) {
        if (stored == null || stored.length() < 4 || stored.charAt(0) != 'g') {
            return null;
        }
        int colon = stored.indexOf(':');
        if (colon < 2) {
            return null;
        }
        String version = stored.substring(1, colon);
        if (!VERSION.matcher(version).matches()) {
            return null;
        }
        byte[] payload;
        try {
            payload = Base64.getUrlDecoder().decode(stored.substring(colon + 1));
        } catch (IllegalArgumentException e) {
            return null;
        }
        if (payload.length < IV_BYTES + TAG_BITS / 8) {
            return null;
        }
        return new Parsed(version, payload);
    }

    private record Parsed(String version, byte[] payload) {
    }

    private static SecretKey configuredKey(String value, String property) {
        if (!hasText(value) || value.getBytes(StandardCharsets.UTF_8).length < MIN_KEY_BYTES) {
            throw new IllegalStateException(property + " must contain at least " + MIN_KEY_BYTES + " bytes");
        }
        return deriveKey(value, CONFIGURED_INFO);
    }

    private static String requireConfiguredVersion(String version) {
        if (version == null || !VERSION.matcher(version).matches()
                || Character.toLowerCase(version.charAt(0)) == 'h') {
            throw new IllegalStateException(
                    "uten.crypto.secret-cipher-key-version must be 1-16 letters/digits and must not start with h");
        }
        return version;
    }

    static SecretKey deriveKey(String ikm, String info) {
        byte[] okm = hkdfSha256(ikm.getBytes(StandardCharsets.UTF_8),
                HKDF_SALT.getBytes(StandardCharsets.UTF_8), info.getBytes(StandardCharsets.UTF_8), 32);
        return new SecretKeySpec(okm, "AES");
    }

    /** RFC 5869 HKDF(HMAC-SHA256): extract 后 expand 到 {@code length} 字节。 */
    static byte[] hkdfSha256(byte[] ikm, byte[] salt, byte[] info, int length) {
        try {
            Mac mac = Mac.getInstance("HmacSHA256");
            mac.init(new SecretKeySpec(salt.length == 0 ? new byte[32] : salt, "HmacSHA256"));
            byte[] prk = mac.doFinal(ikm);
            mac.init(new SecretKeySpec(prk, "HmacSHA256"));
            byte[] okm = new byte[length];
            byte[] previous = new byte[0];
            int offset = 0;
            for (int counter = 1; offset < length; counter++) {
                mac.update(previous);
                mac.update(info);
                mac.update((byte) counter);
                previous = mac.doFinal();
                int count = Math.min(previous.length, length - offset);
                System.arraycopy(previous, 0, okm, offset, count);
                offset += count;
            }
            return okm;
        } catch (GeneralSecurityException e) {
            throw new IllegalStateException("HKDF 计算失败", e);
        }
    }

    private static boolean hasText(String value) {
        return value != null && !value.isBlank();
    }

    /** 密文无法解开(来自别的环境、密钥已轮换且旧密钥未保留、或被篡改)。消息不含任何细节。 */
    public static final class SecretUnreadableException extends RuntimeException {
        public SecretUnreadableException() {
            super("secret unreadable");
        }
    }
}
