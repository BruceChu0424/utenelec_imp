package com.uten.imp.application.port;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.List;
import java.util.UUID;

/** Approved forward correction evidence; no mutation of an original AP or GL line. */
public interface ProcurementConsiderationCorrectionEvidencePort {
    record FeeComponent(
            UUID considerationPartId,
            UUID fundingSliceId,
            UUID replacementAllocationId,
            UUID originalDebitGlLineId,
            UUID originalDebitStyleId,
            UUID correctionDebitStyleId,
            String originalPostingSourceType,
            String originalSourceVersion,
            String originalDebitFactType,
            UUID originalDebitFactId,
            UUID legacyValueCaseId,
            BigDecimal amountOriginal,
            BigDecimal amountLocal) {
    }

    record ApprovedCorrection(
            UUID reviewId,
            long reviewVersion,
            String evidenceFingerprint,
            String receiptType,
            UUID receiptId,
            UUID erroneousApLedgerId,
            UUID supplierId,
            UUID currencyId,
            BigDecimal exchangeRate,
            UUID settlementMethodId,
            LocalDate effectiveDate,
            BigDecimal amountOriginal,
            BigDecimal amountLocal,
            List<FeeComponent> components,
            String reason) {
    }

    /** Read the exact immutable approved revision inside the caller's transaction. */
    ApprovedCorrection approved(UUID reviewId,long expectedVersion);

    /** Bind one append-only correction result after accounting has posted it. */
    void recordCorrection(UUID reviewId,long expectedVersion,UUID correctionSourceId,UUID negativeApLedgerId);
}
