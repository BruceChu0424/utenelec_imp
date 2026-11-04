package com.uten.imp.common.web;

import org.junit.jupiter.api.Test;
import static org.junit.jupiter.api.Assertions.*;

class GoodsSearchReadRoutesTest {
    @Test void onlyExactReadBodiesAreClassified() {
        for (String prefix : new String[]{"/api/master/goods/", "/api/business-references/goods/"}) {
            for (String action : new String[]{"search", "search-category-ids", "facets", "facet-values"}) {
                assertTrue(GoodsSearchReadRoutes.matches("POST", prefix + action));
                assertFalse(GoodsSearchReadRoutes.matches("PUT", prefix + action));
                assertFalse(GoodsSearchReadRoutes.matches("POST", prefix + action + "/save"));
            }
            assertFalse(GoodsSearchReadRoutes.matches("POST", prefix + "export"));
            assertFalse(GoodsSearchReadRoutes.matches("POST", prefix));
        }
        assertFalse(GoodsSearchReadRoutes.matches("POST", "/api/master/clients/facets"));
        assertFalse(GoodsSearchReadRoutes.matches("POST", null));
    }
}
