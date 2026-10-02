package com.uten.imp.common.platformcolumns;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;
import java.util.*;
import java.util.function.Function;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.*;

class DocumentPlatformHistoryAccessTest {
    EntityManager em=mock(EntityManager.class);
    SecurityContextCurrentUser current=mock(SecurityContextCurrentUser.class);
    UUID item=UUID.randomUUID(),parent=UUID.randomUUID();
    @Test void retiredIdentityDoesNotNeedTodaysItemsAndCannotUseTodaysFactsOrWrites() {
        signIn(Set.of("row:view","row:price"));Query lookup=mock(Query.class);
        when(em.createNativeQuery("fixed-identity-and-live-parent-lookup")).thenReturn(lookup);
        when(lookup.setParameter("ids",Set.of(item))).thenReturn(lookup);
        when(lookup.getResultList()).thenReturn(Collections.singletonList(new Object[]{item,parent}));
        var adapter=adapter().history(id->Map.of("id",id.toString(),"qty",999),"fixed-identity-and-live-parent-lookup");
        var grant=adapter.authorizeHistory(Set.of(item)).get(item);
        assertThat(grant.canWrite()).isFalse();assertThat(grant.facts()).isEmpty();assertThat(grant.priceVisible()).isTrue();
    }
    @Test void nativePriceMaskRemainsEffectiveEvenWithTheFunctionalPriceCode() {
        signIn(Set.of("row:view","row:price"));
        var adapter=header().history(id->Map.of("id",id.toString(),"priceMasked",true),null);
        assertThat(adapter.authorizeHistory(Set.of(parent)).get(parent).priceVisible()).isFalse();
    }
    @Test @SuppressWarnings("unchecked") void revokedCurrentReadAuthorityIsDeniedBeforeHistoricalContentLoading() {
        signIn(Set.of("row:price"));Function<UUID,Object> nativeHistory=mock(Function.class);
        var adapter=header().history(nativeHistory,null);
        assertThatThrownBy(()->adapter.authorizeHistory(Set.of(parent))).isInstanceOf(ApiException.class);
        verifyNoInteractions(nativeHistory,em);
    }
    @Test @SuppressWarnings("unchecked") void conflictingOriginalParentsCannotUseAnArbitraryWinningParent() {
        signIn(Set.of("row:view"));Query lookup=mock(Query.class);
        when(em.createNativeQuery("fixed-lookup")).thenReturn(lookup);when(lookup.setParameter("ids",Set.of(item))).thenReturn(lookup);
        when(lookup.getResultList()).thenReturn(Arrays.asList(new Object[]{item,parent},new Object[]{item,UUID.randomUUID()}));
        Function<UUID,Object> loader=mock(Function.class);var adapter=adapter().history(loader,"fixed-lookup");
        assertThatThrownBy(()->adapter.authorizeHistory(Set.of(item))).isInstanceOf(ApiException.class);verifyNoInteractions(loader);
    }
    DocumentPlatformColumnAdapter adapter(){return create("active-parent-lookup");}
    DocumentPlatformColumnAdapter header(){return create(null);}
    DocumentPlatformColumnAdapter create(String lookup){return new DocumentPlatformColumnAdapter("test_rows","测试业务",current,em,new ObjectMapper(),
        Set.of("row:view"),Set.of("row:edit"),Set.of("row:price"),Object.class,lookup,id->{throw new AssertionError("history cannot use active detail");},
        (id,body)->true,List.of(new PlatformColumnResourceAdapter.FactDefinition("qty","数量",false)));}
    void signIn(Set<String> codes){when(current.get()).thenReturn(Optional.of(new AuthUser(UUID.randomUUID(),UUID.randomUUID(),"history",codes,false,true,false)));}
}
