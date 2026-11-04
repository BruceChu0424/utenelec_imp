package com.uten.imp.application.port;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.*;

/** Immutable approved statement evidence, never a reconstruction from the
 * customer's current name, a bill number or the supplier's entire balance. */
public interface FinanceStatementOriginalReadPort {
    record SourceDocument(String sourceType,UUID sourceId,List<UUID> itemIds){
        public SourceDocument{itemIds=List.copyOf(itemIds);}
    }
    record Original(UUID reviewId,String templateKey,String partyRole,UUID partyId,UUID currencyId,
        LocalDate dateFrom,LocalDate dateTo,String sourceFingerprint,String documentSha256,
        BigDecimal periodAmount,List<SourceDocument> sources){
        public Original{sources=List.copyOf(sources);}
    }
    /** The original keeps its SHA after a later legitimate AP recognition or
     * adjustment. Its exact native source identity and target remain validated
     * by the writing domain before any money changes. */
    Original requireConfirmed(UUID reviewId,String expectedSourceFingerprint);
}
