package com.uten.imp.application.port;

import java.util.List;
import java.util.Map;
import java.util.UUID;

/** Neutral application port for transactionally appending durable business events. */
public interface BusinessEventPublisher {

    UUID publish(
        String eventType,
        String aggregateType,
        UUID aggregateId,
        Map<String, ?> payload);

    UUID publishOnce(
        String eventType,
        String aggregateType,
        UUID aggregateId,
        Map<String, ?> payload,
        String dedupeKey);

    /** One batched durable append: same dedupe and equivalence semantics as {@link #publishOnce}. */
    default List<UUID> publishOnceBatch(List<OutboxEvent> batch) {
        return batch.stream()
                .map(event -> publishOnce(event.eventType(), event.aggregateType(),
                        event.aggregateId(), event.payload(), event.dedupeKey()))
                .toList();
    }

    /** A single durable event spec inside one batched append. */
    record OutboxEvent(String eventType, String aggregateType, UUID aggregateId,
                       Map<String, ?> payload, String dedupeKey) { }
}
