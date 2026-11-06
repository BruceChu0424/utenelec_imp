package com.uten.imp.common.finance;

import java.math.BigDecimal;
import java.math.RoundingMode;

/** Subcontract finished allowance: a ceiling, independent of actual material loss. */
public final class SubcontractReceiptAllowance {
    private static final BigDecimal HUNDRED=BigDecimal.valueOf(100);
    private static final BigDecimal STEP=new BigDecimal("0.0001");
    private SubcontractReceiptAllowance() {}

    /** Same ceiling as fn_subcontract_normal_receipt_limit; never round above the approved percentage. */
    public static BigDecimal normalLimit(BigDecimal target,BigDecimal pct) {
        if(target==null||target.signum()<=0)return BigDecimal.ZERO.setScale(4);
        return target.multiply(HUNDRED.add(pct==null?BigDecimal.ZERO:pct))
                .movePointLeft(2).setScale(4,RoundingMode.DOWN);
    }

    /** Smallest four-place target whose normal finished allowance covers retained actual receipts. */
    public static BigDecimal minimumTarget(BigDecimal retained,BigDecimal pct) {
        if(retained==null||retained.signum()<=0)return BigDecimal.ZERO.setScale(4);
        BigDecimal required=retained.setScale(4,RoundingMode.CEILING);
        BigDecimal candidate=required.multiply(HUNDRED)
                .divide(HUNDRED.add(pct==null?BigDecimal.ZERO:pct),4,RoundingMode.CEILING);
        while(normalLimit(candidate,pct).compareTo(required)<0)candidate=candidate.add(STEP);
        return candidate;
    }

    /** Combine actual retained finished goods and supplier-held material before the single ceiling. */
    public static BigDecimal minimumTargetForRetainedAndHeld(BigDecimal retainedBase,BigDecimal orderUnitRate,
            BigDecimal heldMaterialQty,BigDecimal baseBomUnitQty,BigDecimal pct) {
        BigDecimal numerator=retainedBase.multiply(baseBomUnitQty)
                .add(heldMaterialQty.multiply(orderUnitRate)).multiply(HUNDRED);
        BigDecimal denominator=orderUnitRate.multiply(baseBomUnitQty)
                .multiply(HUNDRED.add(pct==null?BigDecimal.ZERO:pct));
        return numerator.divide(denominator,4,RoundingMode.CEILING);
    }
}
