package com.uten.imp.features.master.reference;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.security.OwnerVisibility;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.mockito.ArgumentCaptor;
import org.junit.jupiter.api.Test;

import java.lang.reflect.Field;
import java.math.BigDecimal;
import java.util.List;
import java.util.Set;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class MasterReferenceValidationAdapterTest {

    @Test
    void rejectsGoodsOwnedOutsideTheCurrentScope() throws Exception {
        EntityManager em = mock(EntityManager.class);
        OwnerVisibility visibility = mock(OwnerVisibility.class);
        tupleQuery(em, new Object[]{
                false, UUID.randomUUID(), UUID.randomUUID(), false, "使用", false, "使用"});
        when(visibility.evaluate("goods", "goods:view:all"))
                .thenReturn(new OwnerVisibility.OwnerScope(false, Set.of(UUID.randomUUID())));
        MasterReferenceValidationAdapter adapter = adapter(em, visibility, true);

        ApiException error = assertThrows(
                ApiException.class,
                () -> adapter.requireVisibleActiveGoods(UUID.randomUUID()));

        assertEquals(ErrorCode.NOT_FOUND, error.getCode());
        ArgumentCaptor<String> sql = ArgumentCaptor.forClass(String.class);
        verify(em).createNativeQuery(sql.capture());
        assertTrue(sql.getValue().contains("current_unit.id = g.unit_id"));
        assertTrue(!sql.getValue().contains("legacy_unit"));
        assertTrue(!sql.getValue().contains("unit_legacy_id"));
    }

    @Test
    void visibleGoodsProbeIgnoresLifecycleStateSoExistingLinksRemainCleanable() throws Exception {
        EntityManager em = mock(EntityManager.class);
        OwnerVisibility visibility = mock(OwnerVisibility.class);
        UUID goodsId = UUID.randomUUID();
        UUID owner = UUID.randomUUID();
        tupleQuery(em, new Object[]{goodsId, owner});
        when(visibility.evaluate("goods", "goods:view:all"))
                .thenReturn(new OwnerVisibility.OwnerScope(false, Set.of(owner)));
        MasterReferenceValidationAdapter adapter = adapter(em, visibility, true);

        assertTrue(adapter.canViewGoods(goodsId));

        ArgumentCaptor<String> sql = ArgumentCaptor.forClass(String.class);
        verify(em).createNativeQuery(sql.capture());
        assertTrue(!sql.getValue().contains("is_deleted"));
        assertTrue(!sql.getValue().contains("status"));
        assertTrue(!sql.getValue().contains("auto_created"));
    }

    @Test
    void visibleGoodsGuardHidesOutOfScopeTargets() throws Exception {
        EntityManager em = mock(EntityManager.class);
        OwnerVisibility visibility = mock(OwnerVisibility.class);
        UUID goodsId = UUID.randomUUID();
        tupleQuery(em, new Object[]{goodsId, UUID.randomUUID()});
        when(visibility.evaluate("goods", "goods:view:all"))
                .thenReturn(new OwnerVisibility.OwnerScope(false, Set.of(UUID.randomUUID())));
        MasterReferenceValidationAdapter adapter = adapter(em, visibility, true);

        ApiException error = assertThrows(
                ApiException.class,
                () -> adapter.requireVisibleGoods(goodsId));

        assertEquals(ErrorCode.NOT_FOUND, error.getCode());
    }

    @Test
    void rejectsClientOwnedOutsideTheCurrentScope() throws Exception {
        EntityManager em = mock(EntityManager.class);
        OwnerVisibility visibility = mock(OwnerVisibility.class);
        tupleQuery(em, new Object[]{false, UUID.randomUUID(), "使用"});
        when(visibility.evaluate("client", "client:view:all"))
                .thenReturn(new OwnerVisibility.OwnerScope(false, Set.of(UUID.randomUUID())));
        MasterReferenceValidationAdapter adapter = adapter(em, visibility, false);

        ApiException error = assertThrows(
                ApiException.class,
                () -> adapter.requireVisibleActiveClient(UUID.randomUUID()));

        assertEquals(ErrorCode.NOT_FOUND, error.getCode());
    }

    @Test
    void normalizesTheVisibleGoodsBaseUnitToRateOne() throws Exception {
        EntityManager em = mock(EntityManager.class);
        OwnerVisibility visibility = mock(OwnerVisibility.class);
        UUID owner = UUID.randomUUID();
        UUID baseUnit = UUID.randomUUID();
        tupleQuery(em, new Object[]{false, owner, baseUnit, false, "使用", false, "使用"});
        when(visibility.evaluate("goods", "goods:view:all"))
                .thenReturn(new OwnerVisibility.OwnerScope(false, Set.of(owner)));
        MasterReferenceValidationAdapter adapter = adapter(em, visibility, true);

        var resolved = adapter.resolveVisibleActiveGoodsUnit(
                UUID.randomUUID(), baseUnit, null, 1);

        assertEquals(baseUnit, resolved.unitId());
        assertEquals(0, BigDecimal.ONE.compareTo(resolved.unitRate()));
    }

    @Test
    void rejectsLegacyOnlyGoodsUnitInsteadOfManufacturingAUuid() throws Exception {
        EntityManager em = mock(EntityManager.class);
        OwnerVisibility visibility = mock(OwnerVisibility.class);
        tupleQuery(em, new Object[]{
                false, null, null, true, "使用", false, null});
        MasterReferenceValidationAdapter adapter = adapter(em, visibility, false);

        ApiException error = assertThrows(
                ApiException.class,
                () -> adapter.resolveVisibleActiveGoodsUnit(
                        UUID.randomUUID(), null, null, 1));

        assertEquals(ErrorCode.CONFLICT, error.getCode());
        assertEquals("第 1 行货品未维护有效基本单位", error.getMessage());
    }

    @Test
    void rejectsMissingClientReference() throws Exception {
        EntityManager em = mock(EntityManager.class);
        OwnerVisibility visibility = mock(OwnerVisibility.class);
        MasterReferenceValidationAdapter adapter = adapter(em, visibility, false);

        ApiException error = assertThrows(
                ApiException.class,
                () -> adapter.requireVisibleActiveClient(null));

        assertEquals(ErrorCode.VALIDATION_FAILED, error.getCode());
    }

    @Test
    void rejectsDisabledClientEvenWhenItIsVisible() throws Exception {
        EntityManager em = mock(EntityManager.class);
        OwnerVisibility visibility = mock(OwnerVisibility.class);
        tupleQuery(em, new Object[]{false, null, "禁用"});
        when(visibility.evaluate("client", "client:view:all"))
                .thenReturn(new OwnerVisibility.OwnerScope(true, Set.of()));
        MasterReferenceValidationAdapter adapter = adapter(em, visibility, false);

        ApiException error = assertThrows(
                ApiException.class,
                () -> adapter.requireVisibleActiveClient(UUID.randomUUID()));

        assertEquals(ErrorCode.CONFLICT, error.getCode());
    }

    @Test
    void rejectsMigrationStubGoodsFromNewBusiness() throws Exception {
        EntityManager em = mock(EntityManager.class);
        OwnerVisibility visibility = mock(OwnerVisibility.class);
        tupleQuery(em, new Object[]{
                false, null, UUID.randomUUID(), false, "使用", true, "使用"});
        MasterReferenceValidationAdapter adapter = adapter(em, visibility, false);

        ApiException error = assertThrows(
                ApiException.class,
                () -> adapter.requireVisibleActiveGoods(UUID.randomUUID()));

        assertEquals(ErrorCode.CONFLICT, error.getCode());
    }

    private static Query tupleQuery(EntityManager em, Object[] tuple) {
        Query query = mock(Query.class);
        when(em.createNativeQuery(anyString())).thenReturn(query);
        when(query.setParameter(anyString(), any())).thenReturn(query);
        when(query.getResultList()).thenReturn(List.<Object[]>of(tuple));
        return query;
    }

    private static MasterReferenceValidationAdapter adapter(
            EntityManager em,
            OwnerVisibility visibility,
            boolean goodsScopeEnabled) throws Exception {
        MasterReferenceValidationAdapter adapter =
                new MasterReferenceValidationAdapter(em, visibility);
        Field field = MasterReferenceValidationAdapter.class
                .getDeclaredField("goodsOwnerScopeEnabled");
        field.setAccessible(true);
        field.setBoolean(adapter, goodsScopeEnabled);
        return adapter;
    }
}
