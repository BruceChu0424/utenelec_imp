package com.uten.imp.features.warehouse.inbound.dto;

import java.math.BigDecimal;
import java.time.OffsetDateTime;
import java.util.List;
import java.util.UUID;

/** Read-only original IQC report result. Only COMMITTED confirms all original actor/hash/member facts. */
public record InspectionCommandResolution(String state, String requestHash, List<Event> events) {
    public InspectionCommandResolution { events = List.copyOf(events); }
    public record Event(UUID eventId, UUID inspectionItemId, String action, BigDecimal baseQty,
                        String reason, OffsetDateTime occurredAt) {}
}
