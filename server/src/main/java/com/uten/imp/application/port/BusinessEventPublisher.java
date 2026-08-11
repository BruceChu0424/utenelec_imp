package com.uten.imp.application.port;

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
}
