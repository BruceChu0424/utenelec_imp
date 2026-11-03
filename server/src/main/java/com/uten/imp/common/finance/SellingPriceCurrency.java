package com.uten.imp.common.finance;

import java.math.BigDecimal;
import java.util.UUID;

/** Currency boundary for defaults into existing base-currency pricing workflows. */
public final class SellingPriceCurrency {
    private SellingPriceCurrency() {}

    /**
     * Unregistered historical prices retain their established behavior. An
     * explicitly foreign price requires separate pricing; this never converts
     * using a reference rate or rewrites a saved document/BOM price.
     */
    public static BigDecimal forBaseCurrency(BigDecimal price, UUID currencyId, boolean baseCurrency) {
        return currencyId == null || baseCurrency ? price : null;
    }

    /** Fixed server-owned aliases only; values and currency identity stay in the database. */
    public static String forBaseCurrencySql(String alias) {
        if (!alias.matches("[a-z_]+")) throw new IllegalArgumentException("Invalid server SQL alias");
        return "CASE WHEN " + alias + ".currency_id IS NULL OR EXISTS (SELECT 1 FROM currencies selling_currency"
                + " WHERE selling_currency.id=" + alias + ".currency_id AND selling_currency.is_base_currency)"
                + " THEN " + alias + ".price END";
    }
}
