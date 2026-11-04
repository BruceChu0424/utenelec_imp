package com.uten.imp.common.web;

import java.util.Set;

/** Exact read-only body routes across features. Exports, saves and other selection routes must not inherit this classification. */
public final class ExactBodyReadRoutes {
    private ExactBodyReadRoutes() { }

    private static final Set<String> POST_READ_ROUTES = Set.of(
            "/api/master/clients/search-context",
            "/api/business-references/clients/search-context", "/api/business-references/suppliers/search-context",
            "/api/business-references/clients/search", "/api/business-references/suppliers/search",
            "/api/master/suppliers/search-context", "/api/sales/orders/shippable-lines/selection",
            "/api/quality/pending-disposals/query");

    public static boolean matches(String method, String path) {
        return "POST".equals(method) && path != null && POST_READ_ROUTES.contains(path);
    }
}
