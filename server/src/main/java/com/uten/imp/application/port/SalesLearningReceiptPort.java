package com.uten.imp.application.port;

import java.util.Map;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;
import java.util.function.Supplier;

/** Durable progress for confirmed sales learning. Payload/evidence are never returned to a UI. */
public interface SalesLearningReceiptPort {
    record StepResult(boolean skipped, Map<String,Integer> counts) {
        public static StepResult done() { return new StepResult(false, Map.of()); }
        public static StepResult skippedResult() { return new StepResult(true, Map.of()); }
    }
    void register(SalesMasterLearningPort.SalesLearningRequest request);
    void run(UUID receiptId, String step, UUID jobId, Supplier<StepResult> work);
    Optional<Map<String,Object>> evidence(UUID receiptId, UUID jobId);
    void rememberEvidence(UUID receiptId, UUID jobId, Map<String,Object> result);
    /** Called inside the master-write transaction: serialize by saved document and reject superseded commands. */
    void requireCurrentSource(UUID receiptId);
    boolean canConsume(UUID receiptId);
    Set<UUID> consumableJobs(UUID receiptId);
}
