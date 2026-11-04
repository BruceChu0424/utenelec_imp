package com.uten.imp.application.port;

import com.fasterxml.jackson.annotation.JsonFormat;
import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.*;

/**
 * Shared settlement capacity over actual posted GL, not another amount ledger.
 * Callers authorize their own business action before invoking this trusted port.
 */
public interface FinanceGlSettlementCapacityPort {
    enum Mode { AUXILIARY_BALANCE_POOL, EXPLICIT_GL_SOURCE, CONFIRMED_AGGREGATE_LIABILITY }
    /** Accounting currency is an account attribute; original currency is the amount's unit. */
    record Scope(UUID styleId,String accountCode,UUID auxiliaryId,UUID accountingCurrencyId,
            UUID originalCurrencyId,int naturalDirection,LocalDate asOf,String expectedAuxiliaryRole) {
        public Scope(UUID styleId,String accountCode,UUID auxiliaryId,UUID accountingCurrencyId,UUID originalCurrencyId,int naturalDirection,LocalDate asOf){
            this(styleId,accountCode,auxiliaryId,accountingCurrencyId,originalCurrencyId,naturalDirection,asOf,auxiliaryId==null?null:"EMPLOYEE");
        }
    }
    record Owner(String kind,UUID id,UUID actorId) { }
    record SourceRef(UUID entryId,int allocationNo) { }
    record SourceAmount(SourceRef source,
            @JsonFormat(shape=JsonFormat.Shape.STRING) BigDecimal amountLocal,
            @JsonFormat(shape=JsonFormat.Shape.STRING) BigDecimal amountOriginal) { }
    record Issue(String field,String message) { }
    record Preview(String fingerprint,
            @JsonFormat(shape=JsonFormat.Shape.STRING) BigDecimal availableLocal,
            @JsonFormat(shape=JsonFormat.Shape.STRING) BigDecimal availableOriginal,
            List<SourceAmount> sources,List<Issue> issues,String basis) {
        public boolean ready(){return issues.isEmpty();}
    }
    record Reservation(UUID requestId,Owner owner,Scope scope,Mode mode,String expectedFingerprint,
            @JsonFormat(shape=JsonFormat.Shape.STRING) BigDecimal amountLocal,
            @JsonFormat(shape=JsonFormat.Shape.STRING) BigDecimal amountOriginal,
            List<SourceAmount> sources,String sourceReference) { }
    /** One real clearing allocation may belong to only one reservation. */
    record Clearing(UUID entryId,int allocationNo,SourceRef original) { }
    record Commit(UUID requestId,Owner owner,UUID reservationId,List<Clearing> clearings) { }
    /** The new allocation must be in the symmetric reversal of the original clearing voucher. */
    record Reversal(UUID entryId,int allocationNo,UUID originalEntryId,int originalAllocationNo) { }
    record Release(UUID requestId,Owner owner,UUID reservationId,List<Reversal> reversals,String reason) { }
    record Cancel(UUID requestId,Owner owner,UUID reservationId,String reason) { }
    record Receipt(UUID reservationId,UUID requestId,String status,String scopeFingerprint) { }

    Preview preview(Scope scope,Mode mode,List<SourceRef> sources);
    /** Trusted native prepayment owners keep their original asset source partition. */
    default Preview preview(Scope scope,Mode mode,List<SourceRef> sources,Owner owner){return preview(scope,mode,sources);}
    Receipt reserve(Reservation command);
    Receipt commit(Commit command);
    Receipt release(Release command);
    Receipt cancel(Cancel command);
    Receipt receipt(UUID reservationId,Owner owner);
}
