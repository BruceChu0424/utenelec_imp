package com.uten.imp.application.port;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.List;
import java.util.UUID;

/** One source-aware plan supplies both the negative AP and its exact original-AP offset. */
public interface ProcurementCreditBookAllocationPort {
    record BookBasis(String sourceKind,UUID sourceId,
            BigDecimal sourceAmountOriginal,BigDecimal sourceAmountLocal,
            BigDecimal beforeOriginal,BigDecimal beforeLocal,
            BigDecimal allocatedOriginal,BigDecimal allocatedLocal,
            BigDecimal afterOriginal,BigDecimal afterLocal) {}

    record BookAllocationPlan(UUID sourceApLedgerId,
            BigDecimal amountOriginal,BigDecimal amountLocal,
            BigDecimal offsetOriginal,BigDecimal offsetLocal,
            BigDecimal creditRemainingOriginal,BigDecimal creditRemainingLocal,
            BigDecimal sourceBeforeOriginal,BigDecimal sourceBeforeLocal,
            BigDecimal sourceAfterOriginal,BigDecimal sourceAfterLocal,
            List<BookBasis> basis) {}

    /** Called with the full procurement prefix held; locks the financial source and excludes existing credit reservations. */
    BookAllocationPlan plan(UUID sourceApLedgerId,BigDecimal actualAmountOriginal);

    /** Consumes the already frozen plan; neither side may independently recalculate a local amount. */
    UUID applyOffset(UUID caseId,UUID creditDocumentId,UUID creditLedgerId,BookAllocationPlan plan,
            LocalDate effectiveDate,String reason);
}
