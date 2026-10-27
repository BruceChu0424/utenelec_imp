package com.uten.imp.common.finance;

import java.math.BigDecimal;

/** Signed delivery variance in the order line's recorded unit: received - returned - ordered.
 * Gifts, settled losses and an administrative closure never replace charged delivery facts.
 */
public final class ProcurementDeliveryDifference {
    private ProcurementDeliveryDifference() { }

    /** Signed stage balance. Unrecorded facts remain unknown rather than becoming zero. */
    public static BigDecimal balance(BigDecimal required, BigDecimal fulfilled) {
        return required == null || fulfilled == null ? null : fulfilled.subtract(required);
    }

    /** Request stage counts approved physical orders, never pending orders or deliveries. */
    public static BigDecimal request(String quantitySemantics, BigDecimal requested, BigDecimal gift,
                                     BigDecimal ordered, BigDecimal giftOrdered) {
        if (requested == null || ordered == null || giftOrdered == null) return null;
        if (ProcurementQuantities.isExtraGift(quantitySemantics)) {
            if (gift == null) return null;
            requested = requested.add(gift);
        }
        return balance(requested, ordered.add(giftOrdered));
    }

    public static BigDecimal of(BigDecimal ordered, BigDecimal received, BigDecimal returned) {
        if (ordered == null || received == null || returned == null) return null;
        return balance(ordered, received.subtract(returned));
    }

    /** Arguments are trusted SQL expressions owned by the calling query, never user input. */
    public static String balanceSql(String required, String fulfilled) {
        return "((" + fulfilled + ")-(" + required + "))";
    }

    /** Arguments are trusted SQL expressions owned by the calling query, never user input. */
    public static String sql(String ordered, String received, String returned) {
        return "((" + received + ")-(" + returned + ")-(" + ordered + "))";
    }
}
