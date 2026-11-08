package com.uten.imp.features.notice.outbox;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.BusinessEventPublisher;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.security.SecurityContextCurrentUser;
import jakarta.servlet.http.HttpServletRequest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.context.ApplicationEventPublisher;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;
import org.springframework.web.context.request.RequestContextHolder;
import org.springframework.web.context.request.ServletRequestAttributes;

import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.UUID;

/**
 * Appends a durable business event to the current transaction.
 *
 * <p>The caller-provided HTTP idempotency key is reused when present. Without
 * one, the guarded document state transition remains the idempotency boundary
 * and this publisher creates a fresh event identity.
 *
 * <p>Duplicate reads use {@code v_business_outbox_full}: after payload tiering
 * (V953) the equivalence check still compares the full original payload from
 * the history tier, so a replayed key behaves exactly as before tiering.
 */
@Service
public class BusinessOutboxPublisher implements BusinessEventPublisher {

    public static final String IDEMPOTENCY_HEADER = "X-Idempotency-Key";

    private final JdbcTemplate jdbc;
    private final ObjectMapper objectMapper;
    private final SecurityContextCurrentUser currentUser;
    private final ApplicationEventPublisher events;

    /** Compatibility for explicitly constructed processors without Spring scheduling. */
    public BusinessOutboxPublisher(
            JdbcTemplate jdbc,
            ObjectMapper objectMapper,
            SecurityContextCurrentUser currentUser) {
        this(jdbc, objectMapper, currentUser, null);
    }

    @Autowired
    public BusinessOutboxPublisher(
            JdbcTemplate jdbc,
            ObjectMapper objectMapper,
            SecurityContextCurrentUser currentUser,
            ApplicationEventPublisher events) {
        this.jdbc = jdbc;
        this.objectMapper = objectMapper;
        this.currentUser = currentUser;
        this.events = events;
    }

    @Override
    @Transactional
    public UUID publish(
            String eventType,
            String aggregateType,
            UUID aggregateId,
            Map<String, ?> payload) {
        return publishOnce(
                eventType,
                aggregateType,
                aggregateId,
                payload,
                requestDedupeKey(eventType, aggregateId));
    }

    @Override
    @Transactional
    public UUID publishOnce(
            String eventType,
            String aggregateType,
            UUID aggregateId,
            Map<String, ?> payload,
            String dedupeKey) {
        UUID eventId = UUID.randomUUID();
        UUID actorId = currentUser.get().map(u -> u.getId()).orElse(null);
        String json = toJson(payload == null ? Map.of() : payload);
        String normalizedEventType = requireToken(eventType, "eventType");
        String normalizedAggregateType = requireToken(aggregateType, "aggregateType");
        String normalizedDedupeKey = requireDedupeKey(dedupeKey);
        int inserted = jdbc.update("""
                INSERT INTO business_outbox(
                    id, event_type, aggregate_type, aggregate_id, payload,
                    dedupe_key, created_by
                )
                VALUES (?, ?, ?, ?, CAST(? AS jsonb), ?, ?)
                ON CONFLICT (dedupe_key) DO NOTHING
                """,
                eventId,
                normalizedEventType,
                normalizedAggregateType,
                aggregateId,
                json,
                normalizedDedupeKey,
                actorId);
        if (inserted == 1) {
            // The listener only enqueues AFTER_COMMIT. The durable row remains
            // authoritative if shutdown or a lost wake-up prevents immediate work.
            if (events != null) events.publishEvent(new BusinessOutboxReady(eventId));
            return eventId;
        }
        ExistingEvent existing = jdbc.queryForObject("""
                        SELECT id, event_type, aggregate_type, aggregate_id,
                               payload::text
                        FROM v_business_outbox_full
                        WHERE dedupe_key = ?
                        """,
                (rs, rowNum) -> new ExistingEvent(
                        rs.getObject("id", UUID.class),
                        rs.getString("event_type"),
                        rs.getString("aggregate_type"),
                        rs.getObject("aggregate_id", UUID.class),
                        rs.getString("payload")),
                normalizedDedupeKey);
        if (existing == null
                || !normalizedEventType.equals(existing.eventType())
                || !normalizedAggregateType.equals(existing.aggregateType())
                || !Objects.equals(aggregateId, existing.aggregateId())
                || !sameJson(json, existing.payload())) {
            throw new ApiException(
                    ErrorCode.CONFLICT,
                    "这个提交标识已用于其他内容，请刷新后查看结果再操作");
        }
        return existing.id();
    }

    /**
     * W6-F (2026-11-08) 批量落事件：一条多行 INSERT ... ON CONFLICT (dedupe_key) DO NOTHING
     * RETURNING 代替逐事件往返。没插进去的键（并发同键或幂等重放）按 publishOnce 同一口径
     * 在 v_business_outbox_full 上核对身份，同体取既有 id，异体同句 409——语义与逐条完全一致。
     */
    @Override
    @Transactional
    public java.util.List<UUID> publishOnceBatch(
            java.util.List<com.uten.imp.application.port.BusinessEventPublisher.OutboxEvent> batch) {
        if (batch == null || batch.isEmpty()) return java.util.List.of();
        var specs = batch.stream().map(spec -> new com.uten.imp.application.port.BusinessEventPublisher.OutboxEvent(
                requireToken(spec.eventType(), "eventType"),
                requireToken(spec.aggregateType(), "aggregateType"),
                spec.aggregateId(),
                spec.payload() == null ? Map.of() : spec.payload(),
                requireDedupeKey(spec.dedupeKey()))).toList();
        UUID actorId = currentUser.get().map(u -> u.getId()).orElse(null);
        var rows = objectMapper.createArrayNode();
        Map<String, com.uten.imp.application.port.BusinessEventPublisher.OutboxEvent> byKey = new java.util.LinkedHashMap<>();
        for (var spec : specs) {
            if (byKey.put(spec.dedupeKey(), spec) != null) {
                throw new IllegalArgumentException("dedupeKey must be unique inside one batch: " + spec.dedupeKey());
            }
            var row = rows.addObject();
            row.put("event_id", UUID.randomUUID().toString());
            row.put("event_type", spec.eventType());
            row.put("aggregate_type", spec.aggregateType());
            if (spec.aggregateId() != null) row.put("aggregate_id", spec.aggregateId().toString());
            row.put("payload", toJson(spec.payload()));
            row.put("dedupe_key", spec.dedupeKey());
        }
        List<Object[]> inserted = jdbc.query("""
                INSERT INTO business_outbox(id, event_type, aggregate_type, aggregate_id, payload, dedupe_key, created_by)
                SELECT CAST(row.event_id AS uuid), row.event_type, row.aggregate_type, CAST(row.aggregate_id AS uuid),
                       CAST(row.payload AS jsonb), row.dedupe_key, ?
                FROM jsonb_to_recordset(CAST(? AS jsonb)) AS row(
                       event_id text, event_type text, aggregate_type text, aggregate_id text,
                       payload text, dedupe_key text)
                ON CONFLICT (dedupe_key) DO NOTHING
                RETURNING id, dedupe_key
                """,
                (rs, rowNum) -> new Object[]{rs.getObject(1, UUID.class), rs.getString(2)},
                actorId, rows.toString());
        List<UUID> result = new java.util.ArrayList<>(specs.size());
        for (Object[] row : inserted) {
            byKey.remove((String) row[1]);
            // 与逐条路径同一约定: 监听器只在 AFTER_COMMIT 入队, 持久行始终权威。
            if (events != null) events.publishEvent(new BusinessOutboxReady((UUID) row[0]));
            result.add((UUID) row[0]);
        }
        if (byKey.isEmpty()) return result;
        // 冲突键: 一次取齐既有行, 逐键按 publishOnce 同一恒等式核对。
        String placeholders = String.join(",", java.util.Collections.nCopies(byKey.size(), "?"));
        Map<String, ExistingEvent> existing = new java.util.HashMap<>();
        jdbc.query("SELECT id, event_type, aggregate_type, aggregate_id, payload::text, dedupe_key"
                        + " FROM v_business_outbox_full WHERE dedupe_key IN (" + placeholders + ")",
                rs -> {
                    existing.put(rs.getString("dedupe_key"), new ExistingEvent(
                            rs.getObject("id", UUID.class), rs.getString("event_type"),
                            rs.getString("aggregate_type"), rs.getObject("aggregate_id", UUID.class),
                            rs.getString("payload")));
                },
                byKey.keySet().toArray());
        for (var spec : byKey.values()) {
            ExistingEvent row = existing.get(spec.dedupeKey());
            if (row == null
                    || !spec.eventType().equals(row.eventType())
                    || !spec.aggregateType().equals(row.aggregateType())
                    || !Objects.equals(spec.aggregateId(), row.aggregateId())
                    || !sameJson(toJson(spec.payload()), row.payload())) {
                throw new ApiException(
                        ErrorCode.CONFLICT,
                        "这个提交标识已用于其他内容，请刷新后查看结果再操作");
            }
            result.add(row.id());
        }
        return result;
    }

    private String requestDedupeKey(String eventType, UUID aggregateId) {
        HttpServletRequest request = currentRequest();
        String clientKey = request == null ? null : request.getHeader(IDEMPOTENCY_HEADER);
        String suffix = clientKey == null || clientKey.isBlank()
                ? UUID.randomUUID().toString()
                : clientKey.trim();
        return eventType + ':' + (aggregateId == null ? "none" : aggregateId) + ':' + suffix;
    }

    private HttpServletRequest currentRequest() {
        var attributes = RequestContextHolder.getRequestAttributes();
        return attributes instanceof ServletRequestAttributes servlet
                ? servlet.getRequest()
                : null;
    }

    private String requireToken(String value, String field) {
        if (value == null || value.isBlank() || value.length() > 80) {
            throw new IllegalArgumentException(field + " must contain 1-80 characters");
        }
        return value;
    }

    private String requireDedupeKey(String value) {
        if (value == null || value.isBlank() || value.length() > 240) {
            throw new IllegalArgumentException("dedupeKey must contain 1-240 characters");
        }
        return value;
    }

    private String toJson(Map<String, ?> payload) {
        try {
            return objectMapper.writeValueAsString(payload);
        } catch (JsonProcessingException error) {
            throw new IllegalArgumentException("Business event payload is not serializable", error);
        }
    }

    private boolean sameJson(String left, String right) {
        try {
            JsonNode leftNode = objectMapper.readTree(left);
            JsonNode rightNode = objectMapper.readTree(right);
            return Objects.equals(leftNode, rightNode);
        } catch (JsonProcessingException error) {
            throw new IllegalStateException("Stored business event payload is invalid", error);
        }
    }

    private record ExistingEvent(
            UUID id, String eventType, String aggregateType,
            UUID aggregateId, String payload) {
    }
}
