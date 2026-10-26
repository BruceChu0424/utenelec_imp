package com.uten.imp.security;

import org.junit.jupiter.api.Test;
import org.springframework.test.util.ReflectionTestUtils;
import java.util.Set;
import java.util.UUID;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.*;

class GoodsReadScopePolicyTest {
    @Test void defaultFeatureAccessAndVersionUseTheSameSingleConfiguration(){
        OwnerVisibility owners=mock(OwnerVisibility.class);
        var policy=new GoodsReadScopePolicy(owners);
        assertThat(policy.evaluate().seeAll()).isTrue();
        assertThat(policy.versionedReadScope()).isNull();
        verifyNoInteractions(owners);
        var allowed=new OwnerVisibility.OwnerScope(false,Set.of(UUID.randomUUID()),Set.of());
        ReflectionTestUtils.setField(policy,"ownerScopeEnabled",true);
        when(owners.evaluate("goods","goods:view:all")).thenReturn(allowed);
        assertThat(policy.evaluate()).isSameAs(allowed);
        assertThat(policy.versionedReadScope()).isSameAs(allowed);
        assertThat(policy.evaluate().writableOwners()).isEmpty();
    }
}
