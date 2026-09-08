package com.uten.imp.application.port;

import com.uten.imp.application.port.InventoryValuationPort.EventContext;
import com.uten.imp.application.port.InventoryValuationPort.PoolKey;
import com.uten.imp.application.port.InventoryValuationPort.State;
import java.math.BigDecimal;
import java.time.OffsetDateTime;
import java.util.UUID;

/** Explicit legacy value admission. Opening callers hold the inventory mutex and own the approval policy.
 * Legacy notes/closure only change the case ledger; they lock that case, never physical stock.
 */
public interface InventoryOpeningPort {
    enum LegacyState { OPEN, RESOLVED }
    /** Controlled opening of an existing positive physical balance; it never creates a movement or changes quantity. */
    record Opening(EventContext context, PoolKey pool, BigDecimal expectedQtyBase,
                   BigDecimal expectedRecordedValueLocal, BigDecimal knownCostLocal,
                   boolean costFinal, String reason) {}

    record OpeningValue(UUID eventId, UUID poolId, UUID sourceCostNodeId, UUID poolHeadId,
                        BigDecimal qtyBase, BigDecimal knownValueLocal, State state, boolean replayed) {}

    /** Start a clean physical empty pool while retaining its old amount in a separate unresolved case. */
    record EmptyCycle(EventContext context, PoolKey pool, BigDecimal expectedRecordedValueLocal, String reason) {}
    record EmptyCycleValue(OpeningValue currentOpening, UUID legacyCaseId, LegacyState legacyState) {}
    record LegacyCaseView(UUID id, PoolKey pool, UUID openingEventId, BigDecimal oldRecordedValueLocal,
                          LegacyState state, long version, UUID resolutionDecisionId, OffsetDateTime createdAt) {}
    record LegacyCaseAction(UUID eventId, UUID caseId, LegacyState state, boolean replayed) {}

    OpeningValue open(Opening command);
    EmptyCycleValue startEmptyCycle(EmptyCycle command);
    LegacyCaseView legacyCase(UUID caseId);
    LegacyCaseAction noteLegacyCase(EventContext context, UUID caseId, String note);
    LegacyCaseAction closeLegacyCase(EventContext context, UUID caseId, UUID approvedResolutionDecisionId);
}
