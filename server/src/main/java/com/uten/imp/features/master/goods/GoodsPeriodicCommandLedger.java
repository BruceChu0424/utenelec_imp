package com.uten.imp.features.master.goods;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.security.SecurityContextCurrentUser;
import org.springframework.jdbc.core.namedparam.MapSqlParameterSource;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.stereotype.Component;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.HexFormat;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import java.util.function.Supplier;
import java.util.regex.Pattern;

/**
 * 基础资料里整批领料命令 (发料方式切换、上线准备) 的幂等 (ADR-131 §4 通用约定, 规格 §1.1、§2.4)。
 *
 * <p>与车间内料仓的写命令同一本账 ({@code workshop_material_commands}, 按操作人 + 请求号唯一): 先取
 * (操作人, 请求号) 的事务级顾问锁再查账, 同号同内容返回原结果, 同号不同内容拒绝; 查不到才执行,
 * 在同一事务最后写一次账本行。账本是表, 这里只按表读写, 不引用内料仓的 Java 代码 (ADR-017)。
 */
@Component
public class GoodsPeriodicCommandLedger {

    private static final Pattern KEY = Pattern.compile("^[A-Za-z0-9._:-]{8,128}$");
    private static final Pattern KIND = Pattern.compile("^[A-Z_]{3,40}$");

    private final NamedParameterJdbcTemplate db;
    private final ObjectMapper json;
    private final SecurityContextCurrentUser currentUser;

    public GoodsPeriodicCommandLedger(NamedParameterJdbcTemplate db, ObjectMapper json,
                                      SecurityContextCurrentUser currentUser) {
        this.db = db;
        this.json = json;
        this.currentUser = currentUser;
    }

    /** 校验请求号格式 (8-128 位字母数字与 . _ : -)。 */
    static String requireKey(String idempotencyKey) {
        if (idempotencyKey == null || !KEY.matcher(idempotencyKey).matches()) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "请求号格式不对, 请刷新页面后重试");
        }
        return idempotencyKey;
    }

    /**
     * 由本命令的请求号派生另一本账的请求号 (本命令里再调认料端口时用; 同号重放时本命令先返回, 不会再调)。
     */
    static String derivedKey(String prefix, String idempotencyKey) {
        try {
            byte[] digest = MessageDigest.getInstance("SHA-256")
                    .digest(requireKey(idempotencyKey).getBytes(StandardCharsets.UTF_8));
            return prefix + "-" + HexFormat.of().formatHex(digest).substring(0, 40);
        } catch (NoSuchAlgorithmException error) {
            throw new IllegalStateException("请求号摘要计算失败", error);
        }
    }

    @Transactional(propagation = Propagation.MANDATORY)
    public <T> T execute(String kind, String idempotencyKey, Object request, Class<T> resultType,
                         Supplier<T> work) {
        if (kind == null || !KIND.matcher(kind).matches()) {
            throw new IllegalArgumentException("invalid goods periodic command kind");
        }
        String key = requireKey(idempotencyKey);
        UUID actor = currentUser.requireId();
        String hash = hash(kind, request);
        db.queryForObject("""
                        SELECT count(*) FROM (SELECT pg_advisory_xact_lock(hashtextextended(:lockKey, 740))) acquired
                        """, Map.of("lockKey", "WM-CMD:" + actor + ":" + key), Long.class);
        List<Map<String, Object>> existing = db.queryForList("""
                        SELECT request_hash, CAST(result AS text) AS result
                        FROM workshop_material_commands
                        WHERE created_by = :actor AND idempotency_key = :key
                        """, Map.of("actor", actor, "key", key));
        if (!existing.isEmpty()) {
            Map<String, Object> row = existing.getFirst();
            if (!hash.equals(row.get("request_hash"))) {
                throw new ApiException(ErrorCode.CONFLICT, "同一请求号已用于不同的操作, 请刷新页面后重试");
            }
            return read((String) row.get("result"), resultType);
        }
        T result = work.get();
        db.update("""
                        INSERT INTO workshop_material_commands(
                            command_kind, created_by, idempotency_key, request_hash, target_id, result)
                        VALUES (:kind, :actor, :key, :hash, NULL, CAST(:result AS jsonb))
                        """, new MapSqlParameterSource()
                        .addValue("kind", kind)
                        .addValue("actor", actor)
                        .addValue("key", key)
                        .addValue("hash", hash)
                        .addValue("result", write(result)));
        return result;
    }

    private String hash(String kind, Object request) {
        try {
            byte[] digest = MessageDigest.getInstance("SHA-256")
                    .digest((kind + "|" + json.writeValueAsString(request)).getBytes(StandardCharsets.UTF_8));
            return HexFormat.of().formatHex(digest);
        } catch (NoSuchAlgorithmException | JsonProcessingException error) {
            throw new IllegalStateException("命令摘要计算失败", error);
        }
    }

    private String write(Object result) {
        try {
            return result == null ? "{}" : json.writeValueAsString(result);
        } catch (JsonProcessingException error) {
            throw new IllegalStateException("命令结果无法记录", error);
        }
    }

    private <T> T read(String stored, Class<T> resultType) {
        try {
            return json.readValue(stored == null ? "{}" : stored, resultType);
        } catch (JsonProcessingException error) {
            throw new IllegalStateException("命令的原结果无法读取", error);
        }
    }
}
