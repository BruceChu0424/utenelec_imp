package com.uten.imp.features.notice.outbox;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.features.notice.ChainNoticeService;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import java.util.List;
import java.util.UUID;

/**
 * Claims one event with {@code FOR UPDATE SKIP LOCKED}. Notice inserts and the
 * delivered marker share this transaction, giving crash-safe at-least-once
 * processing without duplicate committed notices.
 */
@Service
public class BusinessOutboxProcessor {

    private final JdbcTemplate jdbc;
    private final ObjectMapper objectMapper;
    private final ChainNoticeService chainNotice;

    public BusinessOutboxProcessor(
            JdbcTemplate jdbc,
            ObjectMapper objectMapper,
            ChainNoticeService chainNotice) {
        this.jdbc = jdbc;
        this.objectMapper = objectMapper;
        this.chainNotice = chainNotice;
    }

    @Transactional(propagation = Propagation.REQUIRES_NEW)
    public boolean processNext() {
        List<PendingEvent> events = jdbc.query("""
                SELECT id, event_type, aggregate_id, payload::text
                FROM business_outbox
                WHERE status = 0 AND available_at <= now()
                ORDER BY available_at, created_at, id
                FOR UPDATE SKIP LOCKED
                LIMIT 1
                """, (rs, rowNum) -> new PendingEvent(
                rs.getObject("id", UUID.class),
                rs.getString("event_type"),
                rs.getObject("aggregate_id", UUID.class),
                rs.getString("payload")));
        if (events.isEmpty()) {
            return false;
        }

        PendingEvent event = events.get(0);
        try {
            JsonNode payload = objectMapper.readTree(event.payload());
            chainNotice.deliverOutboxEvent(
                    event.eventType(),
                    event.aggregateId(),
                    payload);
            jdbc.update("""
                    UPDATE business_outbox
                    SET status = 1,
                        processed_at = now(),
                        last_error = NULL
                    WHERE id = ? AND status = 0
                    """, event.id());
            return true;
        } catch (Exception error) {
            throw new OutboxDeliveryException(event.id(), error);
        }
    }

    private record PendingEvent(
            UUID id,
            String eventType,
            UUID aggregateId,
            String payload) {
    }
}
