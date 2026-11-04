package com.uten.imp.common.web;

/** Exact read-only body routes. Goods creates, exports and future commands must not inherit this classification. */
public final class GoodsSearchReadRoutes {
    private GoodsSearchReadRoutes() { }

    public static boolean matches(String method, String path) {
        return "POST".equals(method) && path != null && path.matches(
                "^/api/(?:master|business-references)/goods/(?:search|search-category-ids|facets|facet-values)$");
    }
}
