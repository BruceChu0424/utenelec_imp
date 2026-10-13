package com.uten.imp.application.port;

import java.math.BigDecimal;
import java.time.OffsetDateTime;
import java.util.List;
import java.util.UUID;

/** Read-only, permission-scoped price advice. Never changes commercial or inventory facts. */
public interface ProcurementPriceAssessmentPort {
    boolean available(String kind);
    Assessment assess(Request request);

    record Request(String kind, UUID excludeOrderId, List<Line> items) {}
    record Line(String rowKey, UUID goodsId, UUID supplierId, UUID colorId, UUID unitId,
                UUID currencyId, BigDecimal taxRate, BigDecimal quantity, BigDecimal unitPrice,
                BigDecimal totalAmountInput, boolean hasAdditionalCharges, BigDecimal unitRate, BigDecimal giftQuantity) {}
    record Warning(String rowKey, String state, String referencePrice, String averagePrice,
                   String currentPrice, String deviationPercent, String amountImpact,
                   int sampleCount, String confidence, String explanation) {}
    record Assessment(String status, OffsetDateTime checkedAt, List<Warning> items) {
        public Assessment { items = items == null ? List.of() : List.copyOf(items); }
        public static Assessment unavailable() { return new Assessment("UNAVAILABLE", null, List.of()); }
    }
}
