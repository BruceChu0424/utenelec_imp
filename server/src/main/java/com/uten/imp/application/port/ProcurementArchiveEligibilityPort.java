package com.uten.imp.application.port;

import java.util.Collection;
import java.util.Map;
import java.util.UUID;

/** Read-only finance facts for the non-destructive purchase archive pilot. */
public interface ProcurementArchiveEligibilityPort {
    record Facts(long references, long pendingRecognition, long unsettledPayables) { }

    /** Exact receipt/return identities only; one bounded read for the current scan batch. */
    Map<UUID, Facts> purchaseOrderFacts(Collection<UUID> orderIds);
}
