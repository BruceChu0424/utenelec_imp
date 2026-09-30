package com.uten.imp.security;

import com.uten.imp.features.master.goods.GoodsController;
import org.junit.jupiter.api.Test;

import static org.assertj.core.api.Assertions.assertThat;

class PermissionCatalogTestSupportTest {
    @Test
    void scansLoadedApplicationClassesAndIncludesKnownControllerGuards() throws Exception {
        // This also runs in the fast suite: it needs no database, and an isolated Maven
        // build must find its own compiled controller rather than a stale target/classes.
        var guards = PermissionCatalogTestSupport.guards();
        assertThat(guards).isNotEmpty();
        assertThat(guards.stream()
                .filter(guard -> guard.type() == GoodsController.class)
                .filter(guard -> guard.method() != null && guard.method().getName().equals("list")))
                .singleElement()
                .satisfies(guard -> {
                    assertThat(guard.codes()).containsExactly("goods:view");
                    assertThat(guard.write()).isFalse();
                });
    }
}
