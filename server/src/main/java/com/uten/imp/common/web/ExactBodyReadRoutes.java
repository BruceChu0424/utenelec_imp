package com.uten.imp.common.web;

/** Exact read-only body routes across features. Exports, saves and other selection routes must not inherit this classification. */
public final class ExactBodyReadRoutes {
    private ExactBodyReadRoutes() { }

    public static boolean matches(String method, String path) {
        return "POST".equals(method) && path != null && path.matches(
                "^/api/(?:master/(?:clients|suppliers)/search-context"
                        + "|master/(?:clients|suppliers|moulds|colors|units|currencies|accounts)/summaries"
                        + "|master/reference-methods/settlement-admin/summaries"
                        + "|business-references/(?:clients|suppliers|goods)/summaries"
                        + "|business-references/(?:clients|suppliers)/(?:search-context|search)"
                        + "|stock/instant-inventory/summaries"
                        + "|sales/orders/(?:shippable-lines/selection|delivery-preview)"
                        + "|quality/pending-disposals/query"
                        + "|production/daily-reports/draft-claims/query)$");
    }
}
