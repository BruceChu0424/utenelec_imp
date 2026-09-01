package com.uten.imp.features.finance.payables;

import com.fasterxml.jackson.databind.JsonNode;
import com.uten.imp.application.port.BusinessOutboxDomainHandler;
import com.uten.imp.application.port.ProcurementIqcRejectionPort;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;

import java.util.UUID;

/** Projects a quality-owned FAIL event into the finance-side rejection case. */
@Component
@RequiredArgsConstructor
public class ProcurementIqcRejectionOutboxHandler
        implements BusinessOutboxDomainHandler {
    public static final String EVENT_DETECTED =
            "PROCUREMENT_IQC_REJECTION_DETECTED";

    private final ProcurementIqcRejectionPort rejection;

    @Override
    public boolean supports(String eventType) {
        return EVENT_DETECTED.equals(eventType);
    }

    @Override
    public void handle(
            UUID outboxEventId,
            String eventType,
            UUID aggregateId,
            JsonNode payload,
            UUID createdBy) {
        if (aggregateId == null || payload == null) {
            throw new IllegalArgumentException("IQC rejection detection identity is incomplete");
        }
        rejection.projectDetected(
                outboxEventId,
                requiredText(payload, "receiptType"),
                requiredUuid(payload, "receiptId"),
                aggregateId,
                requiredUuid(payload, "inspectionEventId"),
                createdBy);
    }

    private static String requiredText(JsonNode payload, String field) {
        JsonNode value = payload.get(field);
        if (value == null || !value.isTextual() || value.asText().isBlank()) {
            throw new IllegalArgumentException(
                    "IQC rejection detection payload misses " + field);
        }
        return value.asText();
    }

    private static UUID requiredUuid(JsonNode payload, String field) {
        try {
            return UUID.fromString(requiredText(payload, field));
        } catch (IllegalArgumentException error) {
            throw new IllegalArgumentException(
                    "IQC rejection detection payload has invalid " + field, error);
        }
    }
}
