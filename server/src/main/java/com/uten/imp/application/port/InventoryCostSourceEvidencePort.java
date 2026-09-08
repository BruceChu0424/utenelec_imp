package com.uten.imp.application.port;

import java.math.BigDecimal;
import java.util.Optional;
import java.util.UUID;

/**
 * Read-only authority for a new acquisition component. The caller already holds
 * its business-source locks; this lookup must neither acquire late locks nor
 * create AP/GL. Supplier consideration excludes company-owned materials.
 */
public interface InventoryCostSourceEvidencePort {
    record Evidence(UUID id, long version, InventoryValuationPort.PoolKey pool,
                    BigDecimal qtyBase, BigDecimal carriedQtyBase,
                    BigDecimal knownValueLocal, boolean complete,
                    String authorityType, UUID authorityId, long authorityVersion,
                    String evidenceHash) {}

    /** Missing, unapproved or unclassified history is absent, never a confirmed zero. */
    Optional<Evidence> approved(UUID evidenceId, long version);
}
