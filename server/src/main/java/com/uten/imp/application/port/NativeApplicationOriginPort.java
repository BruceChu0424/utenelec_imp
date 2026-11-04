package com.uten.imp.application.port;

import java.math.BigDecimal;
import java.util.List;
import java.util.Map;
import java.util.UUID;

/** Read-only provenance supplied by the source feature after a controlled
 * continuation. Original and local amounts are never interchangeable. */
public interface NativeApplicationOriginPort {
    enum AmountBasis { ORIGINAL,LOCAL,NOT_APPLICABLE }
    record Obligation(UUID ledgerId,BigDecimal amountOriginal) { }
    record Origin(UUID originId,String sourceNo,String originalKind,String requestedDate,
            UUID currencyId,String currencyCode,String currencyName,boolean baseCurrency,
            AmountBasis amountBasis,BigDecimal amount,List<Obligation> obligations,
            Map<String,Object> sourceFields) {
        public Origin {obligations=obligations==null?List.of():List.copyOf(obligations);sourceFields=sourceFields==null?Map.of():java.util.Collections.unmodifiableMap(new java.util.LinkedHashMap<>(sourceFields));}
    }
    Origin origin(String nativeType,UUID nativeId);
    void requireReady(String nativeType,UUID nativeId);
    default void requireCurrentValues(String nativeType,UUID nativeId,BigDecimal amount,UUID supplierId) { }
    /** Owner already proved native object access before requesting this projection. */
    Map<String,Object> originalView(String nativeType,UUID nativeId);
}
