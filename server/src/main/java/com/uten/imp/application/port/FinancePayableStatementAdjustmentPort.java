package com.uten.imp.application.port;

import com.fasterxml.jackson.annotation.JsonFormat;
import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.*;

/** Approved document-specific debt decisions. Bank fees and cash payment authority remain separate. */
public interface FinancePayableStatementAdjustmentPort {
    enum Decision { STILL_OWED, RELEASED }
    enum FeeKind { HANDLING_FEE, ROUNDING }
    record Line(UUID targetLedgerId,String expectedTargetFingerprint,Decision decision,FeeKind feeKind,
            @JsonFormat(shape=JsonFormat.Shape.STRING)BigDecimal amountOriginal,
            UUID counterpartStyleId,UUID counterpartAuxiliaryId,String attributionReference,
            String sourceReference,String category) { }
    record Context(UUID statementReviewId,String expectedSourceFingerprint) { }
    record Submit(UUID requestId,Context context,List<Line> lines,String expectedPlanHash,String sourceReference,String precisionChoicesJson) {
        public Submit(UUID requestId,Context context,List<Line> lines,String expectedPlanHash,String sourceReference){this(requestId,context,lines,expectedPlanHash,sourceReference,null);}
    }
    record Planned(Line input,String amountLocal,String targetBeforeOriginal,String targetBeforeLocal,
            String targetAfterOriginal,String targetAfterLocal,String targetFingerprint,
            NativeFinancialPostingAccountPort.Account debtAccount,String counterpartAccountCode,UUID counterpartAccountingCurrencyId,
            String targetBillNo,String targetSourceDocNo) { }
    record Preview(String planHash,UUID statementReviewId,String documentSha256,String periodAmountOriginal,
            String releasedOriginal,String releasedLocal,List<Planned> lines,String precisionChoicesJson) { }
    record EffectivePart(String category,String amountOriginal,String amountLocal,UUID sourceClassificationId,
            UUID offsetClassificationId,UUID correctionId,String sourceCategory,String sourceLocal,UUID targetClassificationId) { }
    record Effect(UUID adjustmentId,UUID lineId,UUID targetLedgerId,Decision decision,FeeKind feeKind,
            String category,String amountOriginal,String amountLocal,UUID creditLedgerId,UUID offsetBatchId,
            UUID voucherId,UUID counterpartStyleId,String attributionReference,String sourceReference,
            LocalDate effectiveDate,String status,List<EffectivePart> effectiveParts) {
        public Effect(UUID adjustmentId,UUID lineId,UUID targetLedgerId,Decision decision,FeeKind feeKind,
                String category,String amountOriginal,String amountLocal,UUID creditLedgerId,UUID offsetBatchId,
                UUID voucherId,UUID counterpartStyleId,String attributionReference,String sourceReference,LocalDate effectiveDate,String status){
            this(adjustmentId,lineId,targetLedgerId,decision,feeKind,category,amountOriginal,amountLocal,creditLedgerId,offsetBatchId,
                voucherId,counterpartStyleId,attributionReference,sourceReference,effectiveDate,status,List.of());
        }
    }
    Preview preview(Context context,List<Line> lines);
    UUID submit(Submit request);
    List<Effect> approve(UUID adjustmentId);
    List<Effect> reverse(UUID adjustmentId,String reason);
    /** Exact immutable original only: no entire-supplier balance masquerades as this document's net amount. */
    List<Effect> readConfirmed(Context context);
}
