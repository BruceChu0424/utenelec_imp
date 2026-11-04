package com.uten.imp.application.port;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.List;
import java.util.Map;
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
            List<BookBasis> basis,
            @com.fasterxml.jackson.annotation.JsonInclude(com.fasterxml.jackson.annotation.JsonInclude.Include.NON_NULL)
            UUID sourceCandidateId,
            @com.fasterxml.jackson.annotation.JsonInclude(com.fasterxml.jackson.annotation.JsonInclude.Include.NON_NULL)
            Map<String,Object> precisionPolicy) {
        public BookAllocationPlan(UUID sourceApLedgerId,BigDecimal amountOriginal,BigDecimal amountLocal,
                BigDecimal offsetOriginal,BigDecimal offsetLocal,BigDecimal creditRemainingOriginal,BigDecimal creditRemainingLocal,
                BigDecimal sourceBeforeOriginal,BigDecimal sourceBeforeLocal,BigDecimal sourceAfterOriginal,BigDecimal sourceAfterLocal,List<BookBasis> basis){
            this(sourceApLedgerId,amountOriginal,amountLocal,offsetOriginal,offsetLocal,creditRemainingOriginal,creditRemainingLocal,
                    sourceBeforeOriginal,sourceBeforeLocal,sourceAfterOriginal,sourceAfterLocal,basis,null,null);
        }
        public BookAllocationPlan(UUID sourceApLedgerId,BigDecimal amountOriginal,BigDecimal amountLocal,
                BigDecimal offsetOriginal,BigDecimal offsetLocal,BigDecimal creditRemainingOriginal,BigDecimal creditRemainingLocal,
                BigDecimal sourceBeforeOriginal,BigDecimal sourceBeforeLocal,BigDecimal sourceAfterOriginal,BigDecimal sourceAfterLocal,List<BookBasis> basis,UUID sourceCandidateId){
            this(sourceApLedgerId,amountOriginal,amountLocal,offsetOriginal,offsetLocal,creditRemainingOriginal,creditRemainingLocal,
                    sourceBeforeOriginal,sourceBeforeLocal,sourceAfterOriginal,sourceAfterLocal,basis,sourceCandidateId,null);
        }
    }

    /** Called with the full procurement prefix held; locks the financial source and excludes existing credit reservations. */
    BookAllocationPlan plan(UUID sourceApLedgerId,BigDecimal actualAmountOriginal);

    /** A real pending receipt is explicitly typed and cannot be passed as sourceApLedgerId. No fake positive AP is created. */
    default BookAllocationPlan planPending(UUID sourceCandidateId,BigDecimal actualAmountOriginal){
        throw new com.uten.imp.common.web.ApiException(com.uten.imp.common.web.ErrorCode.CONFLICT,"当前账面分配尚未接入原暂估来源");
    }

    /** Consumes the already frozen plan; neither side may independently recalculate a local amount. */
    UUID applyOffset(UUID caseId,UUID creditDocumentId,UUID creditLedgerId,BookAllocationPlan plan,
            LocalDate effectiveDate,String reason);
}
