package com.uten.imp.features.production.fulfillment;

import java.math.BigDecimal;

/** The physical increment admitted by a frozen demand; shared by promotion and read-only previews. */
public final class ContinuousSupplyBudget {
    private ContinuousSupplyBudget() {}

    public record Increment(BigDecimal quantity, BigDecimal sharedQuantity) {}

    public static Increment calculate(BigDecimal required, BigDecimal covered, BigDecimal future,
            BigDecimal available, BigDecimal alreadyClaimed, BigDecimal privateCustody,
            BigDecimal received, BigDecimal privateReceipt, boolean reclaimReturnedCustody) {
        BigDecimal remaining = required.subtract(covered).max(BigDecimal.ZERO);
        BigDecimal custody = privateCustody.min(remaining);
        BigDecimal otherFuture = future.subtract(privateReceipt).max(BigDecimal.ZERO);
        BigDecimal privateTake = reclaimReturnedCustody
                ? custody.min(remaining.subtract(otherFuture).max(BigDecimal.ZERO)) : BigDecimal.ZERO;
        BigDecimal budget = remaining.subtract(custody).subtract(otherFuture).add(received).max(BigDecimal.ZERO);
        BigDecimal shared = remaining.subtract(privateTake).min(budget)
                .min(available.subtract(alreadyClaimed).max(BigDecimal.ZERO));
        return new Increment(privateTake.add(shared), shared);
    }
}
