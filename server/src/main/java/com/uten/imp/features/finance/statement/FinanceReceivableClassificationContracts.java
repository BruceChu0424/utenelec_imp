package com.uten.imp.features.finance.statement;

import com.fasterxml.jackson.annotation.JsonFormat;
import java.math.BigDecimal;
import java.util.*;

/** Separate actual cash, write-off and invoice book axes; none is inferred from another. */
public final class FinanceReceivableClassificationContracts {
    private FinanceReceivableClassificationContracts(){ }
    public record ReceiptPart(String category,
        @JsonFormat(shape=JsonFormat.Shape.STRING)BigDecimal amountOriginal,
        @JsonFormat(shape=JsonFormat.Shape.STRING)BigDecimal writeOffOriginal,
        @JsonFormat(shape=JsonFormat.Shape.STRING)BigDecimal cashLocal,
        @JsonFormat(shape=JsonFormat.Shape.STRING)BigDecimal writeOffLocal,
        @JsonFormat(shape=JsonFormat.Shape.STRING)BigDecimal bookLocal){ }
    public record ReceiptInput(UUID requestId,long expectedRevision,UUID sourceClassificationId,String sourceReference,List<ReceiptPart> parts){ }
    public record CustomerOffsetInput(UUID requestId,long expectedRevision,UUID sourceClassificationId,
        UUID targetClassificationId,String sourceReference,List<FinanceOpenItemClassificationContracts.OffsetPart> parts){ }
}
