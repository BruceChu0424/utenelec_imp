package com.uten.imp.security;

import com.uten.imp.config.props.CryptoProperties;
import jakarta.persistence.EntityManager;
import jakarta.persistence.PersistenceContext;
import org.springframework.stereotype.Component;

import javax.crypto.Mac;
import javax.crypto.spec.SecretKeySpec;
import java.nio.charset.StandardCharsets;
import java.util.HashMap;
import java.util.HexFormat;
import java.util.Map;
import java.util.UUID;

/**
 * 事务会话变量 + pgcrypto 加解密 + HMAC。
 *
 * <p><b>密钥版本化（M4）</b>：密文格式 {@code <version>:<base64>}；加密用当前密钥/版本，
 * 解密按版本从密钥环取密钥（保留旧密钥即可解密历史密文，轮换不丢数据）。
 * 密钥以<b>绑定参数</b>传入 pgcrypto（非 SQL 字面量、不进查询日志），不再依赖会话变量。
 *
 * <p>{@link #bind()} 仅绑定审计 actor（app.actor_id，供审计触发器读取）。
 */
@Component
public class TxSessionVars {

    @PersistenceContext
    private EntityManager em;

    private final CryptoProperties crypto;
    private final SecurityContextCurrentUser currentUser;

    public TxSessionVars(CryptoProperties crypto, SecurityContextCurrentUser currentUser) {
        this.crypto = crypto;
        this.currentUser = currentUser;
    }

    /** 绑定审计 actor（当前登录用户，可为空）。 */
    public void bind() {
        currentUser.id().ifPresent(id -> setConfig("app.actor_id", id.toString()));
    }

    public void bindActor(UUID actorId) {
        if (actorId != null) {
            setConfig("app.actor_id", actorId.toString());
        }
    }

    private void setConfig(String name, String value) {
        em.createNativeQuery("SELECT set_config(:name, :value, true)")
                .setParameter("name", name)
                .setParameter("value", value)
                .getSingleResult();
    }

    /** 密钥环：当前版本→当前密钥 ∪ 旧密钥。 */
    private Map<String, String> keyring() {
        Map<String, String> m = new HashMap<>(crypto.getPgpLegacyKeys());
        m.put(crypto.getPgpKeyVersion(), crypto.getPgpMasterKey());
        return m;
    }

    /** 加密明文 → "<version>:<base64>"。 */
    public String encrypt(String plain) {
        if (plain == null || plain.isBlank()) {
            return null;
        }
        String b64 = (String) em.createNativeQuery(
                        "SELECT encode(pgp_sym_encrypt(CAST(:plain AS text), :key), 'base64')")
                .setParameter("plain", plain)
                .setParameter("key", crypto.getPgpMasterKey())
                .getSingleResult();
        return crypto.getPgpKeyVersion() + ":" + b64;
    }

    /** 解密 "<version>:<base64>"（或无前缀旧数据→当前密钥）→ 明文。 */
    public String decrypt(String cipher) {
        if (cipher == null || cipher.isBlank()) {
            return null;
        }
        String version;
        String body;
        int idx = cipher.indexOf(':');
        if (idx > 0) {
            version = cipher.substring(0, idx);
            body = cipher.substring(idx + 1);
        } else {
            version = crypto.getPgpKeyVersion();
            body = cipher;
        }
        String key = keyring().get(version);
        if (key == null) {
            throw new IllegalStateException("未知密钥版本 [" + version + "]，请在 uten.crypto.pgp-legacy-keys 配置旧密钥");
        }
        return (String) em.createNativeQuery(
                        "SELECT pgp_sym_decrypt(decode(:c, 'base64'), :key)")
                .setParameter("c", body)
                .setParameter("key", key)
                .getSingleResult();
    }

    /** HMAC-SHA256(hex)，用于确定性查重（如身份证号）。 */
    public String hmac(String plain) {
        if (plain == null || plain.isBlank()) {
            return null;
        }
        if (crypto.getHmacKey() == null || crypto.getHmacKey().isBlank()) {
            throw new IllegalStateException("缺少 UTEN_HMAC_KEY（在 server/.env 或环境变量配置）");
        }
        try {
            Mac mac = Mac.getInstance("HmacSHA256");
            mac.init(new SecretKeySpec(crypto.getHmacKey().getBytes(StandardCharsets.UTF_8), "HmacSHA256"));
            return HexFormat.of().formatHex(mac.doFinal(plain.getBytes(StandardCharsets.UTF_8)));
        } catch (Exception e) {
            throw new IllegalStateException("HMAC 计算失败", e);
        }
    }
}
