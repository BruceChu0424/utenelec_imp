package com.uten.imp.features.finance.statement;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.*;

/** Amounts are exact source assignments; the server validates each original/local axis independently. */
public final class FinanceOpenItemClassificationContracts {
    private FinanceOpenItemClassificationContracts() { }
    public record Part(String category,BigDecimal amountOriginal,BigDecimal amountLocal) { }
    public record SourceInput(UUID requestId,long expectedRevision,LocalDate effectiveFrom,String sourceReference,List<Part> parts) { }
    public record PaymentPart(String category,BigDecimal amountOriginal,BigDecimal cashLocal,BigDecimal bookLocal) { }
    public record PaymentInput(UUID requestId,long expectedRevision,UUID sourceClassificationId,String sourceReference,List<PaymentPart> parts) { }
    public record OffsetPart(String sourceCategory,String targetCategory,BigDecimal amountOriginal,BigDecimal sourceLocal,BigDecimal targetLocal) { }
    public record OffsetInput(UUID requestId,long expectedRevision,UUID sourceClassificationId,UUID targetClassificationId,String sourceReference,List<OffsetPart> parts) { }
    public record Result(UUID batchId,long revision,String status) { }
}
