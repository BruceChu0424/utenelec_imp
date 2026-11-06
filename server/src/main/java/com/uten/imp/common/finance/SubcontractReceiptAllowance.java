package com.uten.imp.common.finance;

import com.uten.imp.common.util.FinancialExactAmount;
import java.math.BigDecimal;
import java.math.RoundingMode;

/** Subcontract finished allowance: a ceiling, independent of actual material loss. */
public final class SubcontractReceiptAllowance {
    private static final BigDecimal HUNDRED=BigDecimal.valueOf(100);
    public static final int SOURCE_QUANTITY_SCALE=FinancialExactAmount.MAX_FRACTION_DIGITS;
    private static final BigDecimal STEP=BigDecimal.ONE.movePointLeft(SOURCE_QUANTITY_SCALE);
    private SubcontractReceiptAllowance() {}

    /** Same ceiling as fn_subcontract_normal_receipt_limit; never round above the approved percentage. */
    public static BigDecimal normalLimit(BigDecimal target,BigDecimal pct) {
        if(target==null||target.signum()<=0)return BigDecimal.ZERO.setScale(SOURCE_QUANTITY_SCALE);
        return target.multiply(HUNDRED.add(pct==null?BigDecimal.ZERO:pct))
                .movePointLeft(2).setScale(SOURCE_QUANTITY_SCALE,RoundingMode.DOWN);
    }

    /** Smallest legal source-quantity target whose normal allowance covers retained actual receipts. */
    public static BigDecimal minimumTarget(BigDecimal retained,BigDecimal pct) {
        if(retained==null||retained.signum()<=0)return BigDecimal.ZERO.setScale(SOURCE_QUANTITY_SCALE);
        return coveringTarget(retained,BigDecimal.ONE,pct);
    }

    /** Retain the complete frozen order-unit conversion until checking the normal ceiling. */
    public static BigDecimal minimumTargetForRetainedBase(BigDecimal retainedBase,BigDecimal orderUnitRate,BigDecimal pct) {
        return coveringTarget(retainedBase,orderUnitRate,pct);
    }

    /** Combine actual retained finished goods and supplier-held material before the single ceiling. */
    public static BigDecimal minimumTargetForRetainedAndHeld(BigDecimal retainedBase,BigDecimal orderUnitRate,
            BigDecimal heldMaterialQty,BigDecimal baseBomUnitQty,BigDecimal pct) {
        BigDecimal numerator=retainedBase.multiply(baseBomUnitQty)
                .add(heldMaterialQty.multiply(orderUnitRate));
        return coveringTarget(numerator,orderUnitRate.multiply(baseBomUnitQty),pct);
    }

    private static BigDecimal coveringTarget(BigDecimal numerator,BigDecimal denominator,BigDecimal pct) {
        BigDecimal candidate=numerator.multiply(HUNDRED).divide(
                denominator.multiply(HUNDRED.add(pct==null?BigDecimal.ZERO:pct)),SOURCE_QUANTITY_SCALE,RoundingMode.CEILING);
        // The normal maximum is itself truncated to the receipt grid. Check that
        // actual contract without rounding either retained source or held material.
        while(normalLimit(candidate,pct).multiply(denominator).compareTo(numerator)<0)
            candidate=candidate.add(STEP);
        return candidate;
    }
}
