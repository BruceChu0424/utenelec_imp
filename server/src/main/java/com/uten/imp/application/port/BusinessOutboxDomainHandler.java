package com.uten.imp.application.port;

import com.fasterxml.jackson.databind.JsonNode;

import java.util.UUID;

/**
 * Neutral application port for transactional domain projections executed by
 * the business-outbox worker before notice delivery and completion marking.
 */
public interface BusinessOutboxDomainHandler {
    boolean supports(String eventType);

    void handle(
            UUID outboxEventId,
            String eventType,
            UUID aggregateId,
            JsonNode payload,
            UUID createdBy);
}
