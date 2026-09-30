package com.uten.imp.features.master.goods.costing;

import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import org.junit.jupiter.api.Test;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.*;

class GoodsCostDisplayColumnsConfigurationTest {
    @Test void sellingPricePermissionDoesNotGrantCostDefinitionOrValueAccess() {
        var current = mock(SecurityContextCurrentUser.class);
        var user = mock(AuthUser.class);
        when(current.get()).thenReturn(Optional.of(user));
        when(user.getPermissions()).thenReturn(Set.of("goods:view", "goods:price:view"));
        var adapter = new GoodsCostDisplayColumnsConfiguration().goodsCostDisplayColumns(current);
        assertThat(adapter.scope()).isEqualTo("view_goods_cost");
        assertThatThrownBy(() -> adapter.requireDefinitionAccess(false)).isInstanceOf(com.uten.imp.common.web.ApiException.class);
        assertThat(adapter.canViewPrice()).isFalse();
        when(user.getPermissions()).thenReturn(Set.of("goods:view", "goods:cost:view"));
        adapter.requireDefinitionAccess(false);
        assertThat(adapter.canViewPrice()).isTrue();
        assertThat(adapter.canWrite()).isFalse();
        assertThat(adapter.supportsValues()).isFalse();
        assertThat(adapter.personalDefinitions()).isTrue();
        assertThat(adapter.facts()).anyMatch(f -> f.key().equals("amount") && f.priceProtected());
        assertThatThrownBy(() -> adapter.authorize(Set.of(UUID.randomUUID()), false)).hasMessageContaining("汇总视图");
    }
}
