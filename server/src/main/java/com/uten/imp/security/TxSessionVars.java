package com.uten.imp.security;

import com.uten.imp.audit.AuditRequestContext;
import com.uten.imp.audit.AuditDeviceContext;
import com.uten.imp.common.concurrency.SavepointSnapshots;
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
import java.sql.SQLException;
import java.sql.Savepoint;
import java.util.ArrayList;
import java.util.Collection;
import java.util.HashMap;
import java.util.HexFormat;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.Optional;
import java.util.UUID;
import org.hibernate.Session;
import org.springframework.core.Ordered;
import org.springframework.transaction.support.TransactionSynchronization;
import org.springframework.transaction.support.TransactionSynchronizationManager;

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
 * <p>{@link #bind()} 仅绑定审计 actor(app.actor_id，供审计触发器读取)。每个读写事务开始时由
 * {@link TransactionAuditActorBinder} 自动绑定一次, 业务代码漏写也不会丢审计操作人; 同一事务、
 * 同一身份、同一请求再调用只做内存比较, 不再往返数据库(ADR-107)。{@link #bindActor} 换人时照常重绑。
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

    /**
     * Bind the current principal when present. Without a principal, retain an
     * explicitly established system actor for nested background work (for
     * example automatic material readiness); transaction-local settings prevent
     * that identity from leaking to another transaction on the pooled connection.
     */
    public void bind() {
        // 没有账号 id 的主体(例如测试替身)只补请求元数据, 不绑空操作人。
        var user = currentUser.get().filter(value -> value.getId() != null);
        String actorId = user.map(value -> value.getId().toString()).orElse(null);
        String actorAccount = user.map(value -> truncate(value.getLoginAccount(), 200)).orElse(null);
        bindIdentity(actorId, actorAccount);
    }

    public void bindActor(UUID actorId) {
        bindActor(actorId, null);
    }

    public void bindActor(UUID actorId, String actorAccount) {
        if (actorId != null || actorAccount != null && !actorAccount.isBlank()) {
            // Identity fields form a pair. A UUID-only rebind must not inherit
            // the previous actor's account label from this same transaction.
            bindIdentity(actorId == null ? "" : actorId.toString(),
                    actorAccount == null ? "" : truncate(actorAccount, 200));
        } else {
            bindIdentity(null, null);
        }
    }

    /**
     * actorId 为 null 表示不改身份(沿用本事务已绑定的系统操作人), 只补请求元数据。
     * 本事务已按同一身份、同一请求绑定过就直接返回。
     */
    private void bindIdentity(String actorId, String actorAccount) {
        HttpServletRequest request = AuditRequestContext.currentRequest();
        String requestId = request == null ? null : AuditRequestContext.ensureRequestId(request).toString();
        Binding binding = Binding.current();
        if (binding != null && binding.covers(actorId, actorAccount, requestId)) return;
        Map<String, String> values = new LinkedHashMap<>();
        if (actorId != null) {
            values.put("app.actor_id", actorId);
            values.put("app.actor_account", actorAccount);
        }
        bindRequestMetadata(values);
        setConfigs(values);
        if (binding != null) binding.record(actorId, actorAccount, requestId);
    }

    /**
     * 本事务已发出的审计会话变量。set_config(..., true) 随事务结束失效、随回滚到保存点撤销,
     * 这里的记录跟着同步: 挂起时解绑、恢复时重绑、回滚到保存点时还原到保存点前的值。
     */
    static final class Binding implements TransactionSynchronization {
        private static final Object RESOURCE = new Object();
        private record Snapshot(boolean actorBound, String actorId, String actorAccount, String requestId) {}
        private final SavepointSnapshots<Snapshot> savepoints = new SavepointSnapshots<>();
        private boolean actorBound;
        private String actorId;
        private String actorAccount;
        private String requestId;

        static Binding current() {
            if (!TransactionSynchronizationManager.isSynchronizationActive()
                    || !TransactionSynchronizationManager.isActualTransactionActive()) return null;
            Binding binding = (Binding) TransactionSynchronizationManager.getResource(RESOURCE);
            if (binding == null) {
                binding = new Binding();
                TransactionSynchronizationManager.bindResource(RESOURCE, binding);
                TransactionSynchronizationManager.registerSynchronization(binding);
            }
            return binding;
        }

        boolean covers(String wantedActor, String wantedAccount, String wantedRequest) {
            boolean identity = wantedActor == null
                    || actorBound && wantedActor.equals(actorId) && Objects.equals(wantedAccount, actorAccount);
            boolean request = wantedRequest == null || wantedRequest.equals(requestId);
            // 两样都不需要时(无登录、无请求)原本就不发任何语句。
            return identity && request;
        }

        void record(String boundActor, String boundAccount, String boundRequest) {
            if (boundActor != null) {
                actorBound = true;
                actorId = boundActor;
                actorAccount = boundAccount;
            }
            if (boundRequest != null) requestId = boundRequest;
        }

        @Override public int getOrder() { return Ordered.HIGHEST_PRECEDENCE; }
        @Override public void savepoint(Object savepoint) {
            savepoints.record(savepoint, new Snapshot(actorBound, actorId, actorAccount, requestId));
        }
        @Override public void savepointRollback(Object savepoint) {
            Snapshot retained = savepoints.rollback(savepoint);
            actorBound = retained != null && retained.actorBound();
            actorId = retained == null ? null : retained.actorId();
            actorAccount = retained == null ? null : retained.actorAccount();
            requestId = retained == null ? null : retained.requestId();
        }
        @Override public void suspend() {
            if (TransactionSynchronizationManager.getResource(RESOURCE) == this) {
                TransactionSynchronizationManager.unbindResource(RESOURCE);
            }
        }
        @Override public void resume() {
            TransactionSynchronizationManager.bindResource(RESOURCE, this);
        }
        @Override public void afterCompletion(int status) {
            if (TransactionSynchronizationManager.getResource(RESOURCE) == this) {
                TransactionSynchronizationManager.unbindResource(RESOURCE);
            }
        }
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

    private void bindRequestMetadata(Map<String, String> values) {
        HttpServletRequest request = AuditRequestContext.currentRequest();
        if (request == null) {
            return;
        }
        values.put("app.audit_request_id",
                AuditRequestContext.ensureRequestId(request).toString());
        values.put("app.audit_ip", truncate(request.getRemoteAddr(), 64));
        String userAgent = request.getHeader("User-Agent");
        if (userAgent != null && !userAgent.isBlank()) {
            values.put("app.audit_user_agent", truncate(userAgent, 1000));
        }
        values.put(
                "app.audit_device_context",
                auditDeviceContext.sessionJson(request));
    }

    /** One round trip per binding, without retaining actor state across calls or transactions. */
    private void setConfigs(Map<String, String> values) {
        if (values.isEmpty()) return;
        List<String> expressions = new ArrayList<>();
        for (int index = 0; index < values.size(); index++) {
            expressions.add("set_config(:name" + index + ", :value" + index + ", true)");
        }
        var query = em.createNativeQuery("SELECT " + String.join(", ", expressions));
        int index = 0;
        for (var entry : values.entrySet()) {
            query.setParameter("name" + index, entry.getKey());
            query.setParameter("value" + index, entry.getValue());
            index++;
        }
        query.getSingleResult();
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

    /** 解密 "<version>:<base64>"；无前缀旧数据始终使用配置的历史版本。 */
    public String decrypt(String cipher) {
        if (cipher == null || cipher.isBlank()) {
            return null;
        }
        VersionedCipher parsed = parse(cipher);
        String key = keyring().get(parsed.version());
        if (key == null) {
            throw new IllegalStateException("密文所需的历史密钥未配置，请核对 uten.crypto.pgp-legacy-keys");
        }
        return (String) em.createNativeQuery(
                        "SELECT pgp_sym_decrypt(decode(:c, 'base64'), :key)")
                .setParameter("c", parsed.body())
                .setParameter("key", key)
                .getSingleResult();
    }

    /**
     * 解密一条可能解不开的密文 (数据损坏、轮换后没配旧密钥)：解不开返回 empty，不抛错，也不连累当前事务。
     *
     * <p>pgp_sym_decrypt 失败会让 PostgreSQL 把整个事务作废，所以这里在保存点里用原生 JDBC 执行，
     * 失败就回滚到保存点；不经 Hibernate 查询，当前事务也不会被标成只能回滚。只给「解不开也不该拦住业务」
     * 的地方用 (补开账号时从证件号派生初始密码、员工详情显示证件号、启动时回填证件号校验结果)，
     * 其它地方仍用 {@link #decrypt}。
     * 密文为空时同样返回 empty，调用方按自己有没有密文区分「没有」和「解不开」。</p>
     */
    public Optional<String> tryDecrypt(String cipher) {
        if (cipher == null || cipher.isBlank()) {
            return Optional.empty();
        }
        final VersionedCipher parsed;
        try {
            parsed = parse(cipher);
        } catch (IllegalArgumentException malformed) {
            return Optional.empty();
        }
        String key = keyring().get(parsed.version());
        if (key == null) {
            return Optional.empty();
        }
        return em.unwrap(Session.class).doReturningWork(connection -> {
            Savepoint savepoint = connection.getAutoCommit() ? null : connection.setSavepoint();
            try (PreparedStatement statement = connection.prepareStatement(
                    "SELECT pgp_sym_decrypt(decode(?, 'base64'), ?)")) {
                statement.setString(1, parsed.body());
                statement.setString(2, key);
                String plain;
                try (ResultSet row = statement.executeQuery()) {
                    plain = row.next() ? row.getString(1) : null;
                }
                if (savepoint != null) {
                    connection.releaseSavepoint(savepoint);
                }
                return Optional.ofNullable(plain);
            } catch (SQLException unreadable) {
                if (savepoint != null) {
                    connection.rollback(savepoint);
                }
                return Optional.empty();
            }
        });
    }

    /** 没有版本前缀的旧密文不能因切换当前版本而改变其原密钥归属。 */
    private VersionedCipher parse(String cipher) {
        var parsed = PgpCipherEnvelope.parse(cipher, crypto.getPgpUnversionedKeyVersion());
        return new VersionedCipher(parsed.version(), parsed.body());
    }

    private record VersionedCipher(String version, String body) {
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
            VersionedCipher parsed = parse(cipher);
            byVersion.computeIfAbsent(parsed.version(), ignored -> new ArrayList<>())
                    .add(new CipherPart(cipher, parsed.body()));
        }

        Map<String, String> decrypted = new HashMap<>();
        Session session = em.unwrap(Session.class);
        for (Map.Entry<String, List<CipherPart>> entry : byVersion.entrySet()) {
            String key = keyring().get(entry.getKey());
            if (key == null) {
                throw new IllegalStateException("密文所需的历史密钥未配置，请核对历史密钥配置");
            }
            List<CipherPart> parts = entry.getValue();
            session.doWork(connection -> {
                String[] raw = parts.stream().map(CipherPart::raw).toArray(String[]::new);
                String[] bodies = parts.stream().map(CipherPart::body).toArray(String[]::new);
                Array rawArray = connection.createArrayOf("text", raw);
                Array bodyArray = connection.createArrayOf("text", bodies);
                // 批里混进解不开的密文 (数据损坏、换密钥后没配旧密钥) 时，PostgreSQL 会把整个
                // 事务作废——调用方的逐条兜底 (tryDecrypt) 连保存点都建不起来。整批语句套一层
                // 保存点，失败回滚到保存点再抛错：异常语义不变，事务本身保住。
                Savepoint savepoint = connection.getAutoCommit() ? null : connection.setSavepoint();
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
                    if (savepoint != null) {
                        connection.releaseSavepoint(savepoint);
                    }
                } catch (SQLException unreadable) {
                    if (savepoint != null) {
                        connection.rollback(savepoint);
                    }
                    throw unreadable;
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

    /**
     * 批量加密一组明文(跳过 null/空白与重复), 一条参数化 SQL, 返回 明文 -&gt; {@code "<version>:<base64>"}
     * (与 {@link #encrypt(String)} 单个加密同一格式, 供 decrypt/decryptAll 读回)。
     */
    public Map<String, String> encryptAll(Collection<String> plains) {
        if (plains == null || plains.isEmpty()) {
            return Map.of();
        }
        LinkedHashSet<String> distinct = new LinkedHashSet<>();
        for (String plain : plains) {
            if (plain != null && !plain.isBlank()) {
                distinct.add(plain);
            }
        }
        if (distinct.isEmpty()) {
            return Map.of();
        }
        Map<String, String> encrypted = new HashMap<>();
        em.unwrap(Session.class).doWork(connection -> {
            Array plainArray = connection.createArrayOf("text", distinct.toArray(String[]::new));
            try (PreparedStatement statement = connection.prepareStatement("""
                         SELECT input.plain, encode(pgp_sym_encrypt(input.plain, ?), 'base64')
                         FROM unnest(?::text[]) AS input(plain)
                         """)) {
                statement.setString(1, crypto.getPgpMasterKey());
                statement.setArray(2, plainArray);
                try (ResultSet rows = statement.executeQuery()) {
                    while (rows.next()) {
                        encrypted.put(rows.getString(1), crypto.getPgpKeyVersion() + ":" + rows.getString(2));
                    }
                }
            } finally {
                plainArray.free();
            }
        });
        return Map.copyOf(encrypted);
    }

    /** HMAC-SHA256(hex)，用于确定性查重（如身份证号）。 */
    public String hmac(String plain) {
        if (plain == null || plain.isBlank()) {
            return null;
        }
        if (crypto.getHmacKey() == null || crypto.getHmacKey().isBlank()) {
            throw new IllegalStateException("缺少 UTEN_HMAC_KEY(在 server/.env 或环境变量配置)");
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
