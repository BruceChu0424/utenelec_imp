package com.uten.imp.features.notice.outbox;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.security.SecurityContextCurrentUser;
import jakarta.servlet.http.HttpServletRequest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;
import org.springframework.web.context.request.RequestContextHolder;
import org.springframework.web.context.request.ServletRequestAttributes;

import java.util.Map;
import java.util.Objects;
import java.util.UUID;

/**
 * Appends a durable business event to the current transaction.
 *
 * <p>The caller-provided HTTP idempotency key is reused when present. Without
 * one, the guarded document state transition remains the idempotency boundary
 * and this publisher creates a fresh event identity.
 */
@Service
public class BusinessOutboxPublisher {

    public static final String IDEMPOTENCY_HEADER = "X-Idempotency-Key";

    private final JdbcTemplate jdbc;
    private final ObjectMapper objectMapper;
    private final SecurityContextCurrentUser currentUser;

    public BusinessOutboxPublisher(
            JdbcTemplate jdbc,
            ObjectMapper objectMapper,
            SecurityContextCurrentUser currentUser) {
        this.jdbc = jdbc;
        this.objectMapper = objectMapper;
        this.currentUser = currentUser;
    }

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
            return eventId;
        }
        ExistingEvent existing = jdbc.queryForObject("""
                        SELECT id, event_type, aggregate_type, aggregate_id,
                               payload::text
                        FROM business_outbox
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
                    "相同幂等键对应了不同的业务事件，请刷新后重试");
        }
        return existing.id();
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
