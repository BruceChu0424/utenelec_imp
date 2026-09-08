package com.uten.imp.features.stock.valuation;

import com.uten.imp.application.port.InventoryCostSourceEvidencePort.Evidence;
import java.util.Optional;
import java.util.UUID;

/** Each business domain proves its own immutable source; absence never means zero. */
interface InventoryApprovedCostEvidenceReader {
    Optional<Evidence> approved(UUID evidenceId, long version);
}
