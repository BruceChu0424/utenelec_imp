package com.uten.imp.common.finance;

import java.math.BigDecimal;

/** Signed delivery variance in the order line's recorded unit: received - returned - ordered.
 * Gifts, settled losses and an administrative closure never replace charged delivery facts.
 */
public final class ProcurementDeliveryDifference {
    private ProcurementDeliveryDifference() { }

    public static BigDecimal of(BigDecimal ordered, BigDecimal received, BigDecimal returned) {
        if (ordered == null || received == null || returned == null) return null;
        return received.subtract(returned).subtract(ordered);
    }

    /** Arguments are trusted SQL expressions owned by the calling query, never user input. */
    public static String sql(String ordered, String received, String returned) {
        return "((" + received + ")-(" + returned + ")-(" + ordered + "))";
    }
}
