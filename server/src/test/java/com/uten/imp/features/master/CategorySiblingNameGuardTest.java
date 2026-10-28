package com.uten.imp.features.master;

import com.uten.imp.common.web.ApiException;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.EnumSource;

import java.util.List;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.*;

class CategorySiblingNameGuardTest {
    @ParameterizedTest
    @EnumSource(CategorySiblingNameGuard.Kind.class)
    void hierarchyLockKeyIsBoundAsDataWithoutChangingTheDomainLock(CategorySiblingNameGuard.Kind kind) {
        var em=mock(EntityManager.class);
        var query=mock(Query.class,RETURNS_SELF);
        when(em.createNativeQuery(anyString())).thenReturn(query);
        CategorySiblingNameGuard.lockHierarchy(em,kind);
        verify(em).createNativeQuery("SELECT pg_advisory_xact_lock(hashtextextended(:hierarchyLockKey,0))");
        verify(query).setParameter("hierarchyLockKey",switch(kind) {
            case MATERIAL -> "MATERIAL_CATEGORY_HIERARCHY";
            case CLIENT -> "CLIENT_CATEGORY_HIERARCHY";
            case SUPPLIER -> "SUPPLIER_CATEGORY_HIERARCHY";
            case MOULD -> "MOULD_CATEGORY_HIERARCHY";
            case PAYMENT_STYLE -> "PAYMENT_STYLE_HIERARCHY";
        });
        verify(query).getSingleResult();
    }

    @ParameterizedTest
    @EnumSource(CategorySiblingNameGuard.Kind.class)
    void checksNormalizedNameWithinTheSelectedParentAndExcludesSelf(CategorySiblingNameGuard.Kind kind) {
        var em = mock(EntityManager.class);
        var query = mock(Query.class);
        when(em.createNativeQuery(anyString())).thenReturn(query);
        when(query.getResultList()).thenReturn(List.of());
        UUID parent = UUID.randomUUID(), self = UUID.randomUUID();
        CategorySiblingNameGuard.requireAvailable(em, kind, "  1分类  ", parent, self, "EXPENSE");
        verify(query).setParameter("name", "1分类");
        verify(query).setParameter("parentId", parent);
        verify(query).setParameter("excludingId", self);
        if (kind == CategorySiblingNameGuard.Kind.PAYMENT_STYLE) verify(query).setParameter("category", "EXPENSE");
        else verify(query, never()).setParameter(eq("category"), any());
    }

    @ParameterizedTest
    @EnumSource(CategorySiblingNameGuard.Kind.class)
    void rejectsExistingSiblingIncludingTopLevel(CategorySiblingNameGuard.Kind kind) {
        var em = mock(EntityManager.class);
        var query = mock(Query.class);
        when(em.createNativeQuery(anyString())).thenReturn(query);
        when(query.getResultList()).thenReturn(List.of(UUID.randomUUID()));
        var error = assertThrows(ApiException.class, () -> CategorySiblingNameGuard.requireAvailable(
                em, kind, "1分类", null, null, "EXPENSE"));
        assertThat(error.getMessage()).contains("同一上级").contains("1分类");
    }
}
