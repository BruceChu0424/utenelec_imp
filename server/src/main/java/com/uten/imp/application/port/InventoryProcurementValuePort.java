package com.uten.imp.application.port;

import java.math.BigDecimal;
import java.util.UUID;
import com.uten.imp.application.port.InventoryValuationPort.PoolKey;
import com.uten.imp.application.port.InventoryValuationPort.State;

/** Read-only exact procurement fee custody, separate from company-owned materials and GL styles. */
public interface InventoryProcurementValuePort {
    record FailureReference(UUID failureCaseId,UUID qualityPartId,UUID fundingSliceId,UUID sourceApLedgerId) {}
    /**
     * Missing valuation lineage is LEGACY_UNVERIFIED with null value/position;
     * it is never a confirmed zero. costSourceId is this consideration part's
     * acquisition source; carried funding remains referenced by the V510 part.
     * knownFeeLocal is the existing finite projection, not authority for a new
     * credit/FX/loss amount; exact source/quantity references remain decisive.
     */
    record FailureValue(FailureReference reference,UUID considerationPartId,
                        UUID failedPositionId,UUID costSourceId,PoolKey pool,
                        BigDecimal remainingQtyBase,BigDecimal knownFeeLocal,State state) {}
    FailureValue resolveFailure(FailureReference reference);
}
