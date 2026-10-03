package com.uten.imp.application.port;

import java.util.UUID;
import java.util.function.Consumer;

/** FQC's proven pre-stocked lane; every physical posting and exact handoff stays immediate. */
public interface ProductionPreStockedInboundPort {
    void confirmPreStockedFinishedInbound(UUID documentId, String idempotencyKey);

    /**
     * Owns one callback-local batch in the caller's transaction. Each confirmation
     * posts immediately; only the final analysis projection is coalesced after a
     * successful callback. A failed callback must roll back the surrounding command.
     * A failed confirmation poisons the whole batch even if the callback catches
     * its exception; a savepoint rollback cannot turn it into a partial success.
     */
    void withBatch(Consumer<Batch> work);

    @FunctionalInterface
    interface Batch {
        void confirm(UUID documentId, String idempotencyKey);
    }
}
