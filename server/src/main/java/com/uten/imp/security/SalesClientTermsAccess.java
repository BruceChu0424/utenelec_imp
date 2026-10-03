package com.uten.imp.security;

/** Narrow read capabilities required by sales document forms, without granting master-data management. */
public final class SalesClientTermsAccess {
    private SalesClientTermsAccess() {}

    public static final String FORM = "hasAnyAuthority('sales_quote:create','sales_quote:edit',"
            + "'sales_order:create','sales_order:edit',"
            + "'sales_shipment:create','sales_shipment:edit',"
            + "'sales_other_shipment:create','sales_other_shipment:edit',"
            + "'sales_return:create','sales_return:edit')";

    /** Preserve the existing order-reader entry while allowing every actual sales form. */
    public static final String READ = "hasAuthority('sales_order:view') or " + FORM;
    public static final String SETTLEMENT_OPTIONS = "hasAuthority('payment_style:view') or " + FORM;
    public static final String CURRENCY_OPTIONS = "hasAuthority('currency:view') or " + FORM;
}
