package com.uten.imp.features.finance.application;

import java.util.Map;
import java.util.UUID;

/** Explicit review commands never replace an earlier SAVE request body. */
public final class FinanceApplicationContinuationContracts {
    private FinanceApplicationContinuationContracts() { }
    public record Review(UUID originId,UUID originalRequestId,String originalCommand,
            Long expectedVersion,String selectedBusinessKind,Map<String,String> fields,
            UUID travelApplicationId,String travelApplicationSourceKind,UUID reviewedCurrencyId) {
        public Review(UUID originId,UUID originalRequestId,String originalCommand,Long expectedVersion,String selectedBusinessKind,Map<String,String> fields,UUID travelApplicationId,String travelApplicationSourceKind){this(originId,originalRequestId,originalCommand,expectedVersion,selectedBusinessKind,fields,travelApplicationId,travelApplicationSourceKind,null);}
    }
    public record Confirm(UUID requestId,UUID reviewId,String reviewedFingerprint) { }
}
