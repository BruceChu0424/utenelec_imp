package com.uten.imp.features.notice.outbox;

import java.util.UUID;

/** Transaction-scoped wake-up hint, never a replacement for the durable event. */
public record BusinessOutboxReady(UUID eventId) {
}
