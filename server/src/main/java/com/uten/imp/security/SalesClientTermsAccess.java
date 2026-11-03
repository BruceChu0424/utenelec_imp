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
    private static final String BUSINESS_TERMS = " or @businessMasterReferenceAccess.canRead('terms')";
    public static final String SETTLEMENT_OPTIONS = "hasAnyAuthority('payment_style:view','client:finance') or " + FORM + BUSINESS_TERMS;
    // Selling-price maintainers need the same currency choices without gaining
    // currency list/detail/create/edit/delete management capabilities.
    public static final String CURRENCY_OPTIONS = "hasAnyAuthority('currency:view','client:finance','goods:price:edit') or " + FORM + BUSINESS_TERMS;
}
