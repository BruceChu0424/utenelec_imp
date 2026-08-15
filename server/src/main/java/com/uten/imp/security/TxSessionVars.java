package com.uten.imp.security;

import com.uten.imp.audit.AuditRequestContext;
import com.uten.imp.audit.AuditDeviceContext;
import com.uten.imp.config.props.CryptoProperties;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.persistence.EntityManager;
import jakarta.persistence.PersistenceContext;
import org.springframework.stereotype.Component;

import javax.crypto.Mac;
import javax.crypto.spec.SecretKeySpec;
import java.nio.charset.StandardCharsets;
import java.sql.Array;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.util.ArrayList;
import java.util.Collection;
import java.util.HashMap;
import java.util.HexFormat;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import org.hibernate.Session;

/**
 * 事务会话变量 + 指定高风险、非计算型 PII 的 pgcrypto 加解密 + HMAC。
 *
 * <p>本组件不加密金额、数量、汇率或余额；这些计算型字段继续使用 BigDecimal/NUMERIC，
 * 并依赖磁盘/卷、备份和 TLS 等分层保护。它也不替代整库静态加密。</p>
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
    private final AuditDeviceContext auditDeviceContext;

    public TxSessionVars(
            CryptoProperties crypto,
            SecurityContextCurrentUser currentUser,
            AuditDeviceContext auditDeviceContext) {
        this.crypto = crypto;
        this.currentUser = currentUser;
        this.auditDeviceContext = auditDeviceContext;
    }

    /** 绑定审计 actor（当前登录用户，可为空）。 */
    public void bind() {
        currentUser.get().ifPresent(user -> {
            setConfig("app.actor_id", user.getId().toString());
            setConfig("app.actor_account", truncate(user.getLoginAccount(), 200));
        });
        bindRequestMetadata();
    }

    public void bindActor(UUID actorId) {
        bindActor(actorId, null);
    }

    public void bindActor(UUID actorId, String actorAccount) {
        if (actorId != null) {
            setConfig("app.actor_id", actorId.toString());
        }
        if (actorAccount != null && !actorAccount.isBlank()) {
            setConfig("app.actor_account", truncate(actorAccount, 200));
        }
        bindRequestMetadata();
    }

    /**
     * Bind the transaction-local capability required by V284 before any
     * sensitive profile-change row is inserted or updated.
     *
     * <p>This marker is deliberately an exact schema/code-version handshake,
     * not an authorization secret.  A pre-V284 application does not know to
     * set it, so the database rejects old-code approval and old-JAR rollback
     * instead of letting ciphertext be applied as employee plaintext.</p>
     */
    public void bindProfileChangeSnapshotCodecV1() {
        setConfig("app.profile_change_snapshot_codec", "v1");
    }

    /** Bind the V282 runner's transaction-local plaintext-clear capability. */
    public void bindEmployeePiiExtraBackfillV1() {
        setConfig("app.employee_pii_extra_backfill", "v1");
    }

    private void bindRequestMetadata() {
        HttpServletRequest request = AuditRequestContext.currentRequest();
        if (request == null) {
            return;
        }
        setConfig("app.audit_request_id",
                AuditRequestContext.ensureRequestId(request).toString());
        setConfig("app.audit_ip", truncate(request.getRemoteAddr(), 64));
        String userAgent = request.getHeader("User-Agent");
        if (userAgent != null && !userAgent.isBlank()) {
            setConfig("app.audit_user_agent", truncate(userAgent, 1000));
        }
        setConfig(
                "app.audit_device_context",
                auditDeviceContext.sessionJson(request));
    }

    private void setConfig(String name, String value) {
        em.createNativeQuery("SELECT set_config(:name, :value, true)")
                .setParameter("name", name)
                .setParameter("value", value)
                .getSingleResult();
    }

    private String truncate(String value, int maxLength) {
        if (value == null || value.length() <= maxLength) {
            return value;
        }
        return value.substring(0, maxLength);
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

    /**
     * 批量解密同一事务内的一组密文。
     *
     * <p>工资生成会一次读取成百上千名员工的薪资快照。逐字段调用
     * {@link #decrypt(String)} 会产生 N 次数据库往返；此方法按密钥版本分组，
     * 每个版本只执行一条参数化 SQL，并且不把密钥或明文拼进 SQL/日志。
     */
    public Map<String, String> decryptAll(Collection<String> ciphers) {
        Map<String, List<CipherPart>> byVersion = new LinkedHashMap<>();
        if (ciphers == null) {
            return Map.of();
        }
        for (String cipher : ciphers) {
            if (cipher == null || cipher.isBlank()) {
                continue;
            }
            int idx = cipher.indexOf(':');
            String version = idx > 0 ? cipher.substring(0, idx) : crypto.getPgpKeyVersion();
            String body = idx > 0 ? cipher.substring(idx + 1) : cipher;
            byVersion.computeIfAbsent(version, ignored -> new ArrayList<>())
                    .add(new CipherPart(cipher, body));
        }

        Map<String, String> decrypted = new HashMap<>();
        Session session = em.unwrap(Session.class);
        for (Map.Entry<String, List<CipherPart>> entry : byVersion.entrySet()) {
            String key = keyring().get(entry.getKey());
            if (key == null) {
                throw new IllegalStateException("未知加密版本 [" + entry.getKey() + "]，请配置历史密钥");
            }
            List<CipherPart> parts = entry.getValue();
            session.doWork(connection -> {
                String[] raw = parts.stream().map(CipherPart::raw).toArray(String[]::new);
                String[] bodies = parts.stream().map(CipherPart::body).toArray(String[]::new);
                Array rawArray = connection.createArrayOf("text", raw);
                Array bodyArray = connection.createArrayOf("text", bodies);
                try (PreparedStatement statement = connection.prepareStatement("""
                             SELECT input.raw,
                                    pgp_sym_decrypt(decode(input.body, 'base64'), ?)
                             FROM unnest(?::text[], ?::text[]) AS input(raw, body)
                             """)) {
                    statement.setString(1, key);
                    statement.setArray(2, rawArray);
                    statement.setArray(3, bodyArray);
                    try (ResultSet rows = statement.executeQuery()) {
                        while (rows.next()) {
                            decrypted.put(rows.getString(1), rows.getString(2));
                        }
                    }
                } finally {
                    rawArray.free();
                    bodyArray.free();
                }
            });
        }
        return Map.copyOf(decrypted);
    }

    private record CipherPart(String raw, String body) {
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
