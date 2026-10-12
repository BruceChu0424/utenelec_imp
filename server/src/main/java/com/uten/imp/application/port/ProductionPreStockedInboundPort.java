package com.uten.imp.application.port;

import java.util.UUID;
import java.util.List;
import java.util.Objects;
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

    record Confirmation(UUID documentId, String idempotencyKey) {
        public Confirmation {
            Objects.requireNonNull(documentId);
            Objects.requireNonNull(idempotencyKey);
        }
    }

    @FunctionalInterface
    interface Batch {
        void confirm(UUID documentId, String idempotencyKey);

        /** Submit an immutable ordered set; the production scope acquires its graph locks together. */
        default void confirmAll(List<Confirmation> confirmations) {
            for (Confirmation confirmation : List.copyOf(confirmations)) {
                confirm(confirmation.documentId(), confirmation.idempotencyKey());
            }
        }
    }
}
