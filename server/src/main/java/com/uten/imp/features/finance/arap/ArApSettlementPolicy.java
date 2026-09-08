package com.uten.imp.features.finance.arap;

import java.math.BigDecimal;

/** A rounded local zero cannot settle a remaining original-currency debt. */
public final class ArApSettlementPolicy {
    private ArApSettlementPolicy() {}

    public static boolean isSettled(BigDecimal originalBalance,BigDecimal localBalance) {
        // NULL original is an explicit legacy single-currency shape. It is not
        // inferred from a current exchange rate or backfilled with invented money.
        return localBalance!=null && localBalance.signum()==0
                && (originalBalance==null || originalBalance.signum()==0);
    }
}
