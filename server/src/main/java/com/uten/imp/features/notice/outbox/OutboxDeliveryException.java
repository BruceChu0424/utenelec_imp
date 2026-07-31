package com.uten.imp.features.notice.outbox;

import java.util.UUID;

public final class OutboxDeliveryException extends RuntimeException {

    private final UUID eventId;

    public OutboxDeliveryException(UUID eventId, Throwable cause) {
        super("Failed to deliver business outbox event " + eventId, cause);
        this.eventId = eventId;
    }

    public UUID eventId() {
        return eventId;
    }
}
