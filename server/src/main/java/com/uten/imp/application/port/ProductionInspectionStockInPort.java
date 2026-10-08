package com.uten.imp.application.port;

import java.util.List;
import java.util.Objects;
import java.util.UUID;

/** Synchronous production follow-up after all physical postings of one warehouse command. */
public interface ProductionInspectionStockInPort {

    record ReceiptStockIn(
            String receiptType, UUID receiptId, UUID batchId,
            List<UUID> inspectionItemIds) {
        public ReceiptStockIn {
            Objects.requireNonNull(receiptType);
            Objects.requireNonNull(receiptId);
            Objects.requireNonNull(batchId);
            inspectionItemIds = List.copyOf(inspectionItemIds);
        }
    }

    /** Only newly posted batches; replayed commands must not advance production again. */
    void afterInspectionStockInConfirmed(List<ReceiptStockIn> batches);

    /**
     * Completes a newly resolved receipt after its optional automatic stock-in.
     * Advances each physical source once and refreshes the whole receipt's affected analyses,
     * including unstocked FAIL/fallback lines. New batches keep their original allocation identity.
     */
    void afterQualityReceiptResolved(String receiptType, UUID receiptId, List<ReceiptStockIn> batches);
}
