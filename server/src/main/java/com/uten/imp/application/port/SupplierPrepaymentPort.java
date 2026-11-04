package com.uten.imp.application.port;

import java.time.OffsetDateTime;
import java.util.UUID;

/**
 * Lifecycle hooks for an actual V2 supplier bank payment without AP allocations.
 * The native payment owner retains authorization, bank posting and symmetric PAYMENT
 * GL; this port owns the separately identified advance asset and its consumption.
 * Every write hook must share the native payment transaction.
 */
public interface SupplierPrepaymentPort {
    /** Resolves a maintained asset account; never guesses a payable or inventory account. */
    UUID assetStyle(UUID supplierId,UUID originalCurrencyId);
    /** After approved status flush, before the existing PAYMENT GL writer. Idempotent by payment UUID. */
    void recognize(UUID paymentId);
    /** After existing PAYMENT GL posting; attaches the exact advance auxiliary/original-currency evidence. */
    void posted(UUID paymentId);
    /** Same read-only dependency guard for preflight and the locked actual reversal. */
    void requireReversible(UUID paymentId);
    /** After the original PAYMENT_REV GL exists, before the bank reconciliation is reversed. */
    void reverse(UUID paymentId,OffsetDateTime reversedAt);
}
