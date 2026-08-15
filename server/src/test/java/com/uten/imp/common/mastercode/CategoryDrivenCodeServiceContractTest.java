package com.uten.imp.common.mastercode;

import com.uten.imp.common.web.ApiException;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;

import java.util.List;
import java.util.UUID;

import static com.uten.imp.common.mastercode.CategoryDrivenCodeService.MasterType.CLIENT;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class CategoryDrivenCodeServiceContractTest {

    @Test
    void ungroupedNewMasterUsesFallbackPrefixAndAtomicSequence() {
        EntityManager entityManager = mock(EntityManager.class);
        Query lock = fluentQuery();
        Query increment = fluentQuery();
        Query duplicateCheck = fluentQuery();

        when(entityManager.createNativeQuery(anyString()))
                .thenReturn(lock, increment, duplicateCheck);
        when(lock.getResultList()).thenReturn(List.of(41L));
        when(increment.getSingleResult()).thenReturn(42L);
        when(duplicateCheck.getSingleResult()).thenReturn(false);

        CategoryDrivenCodeService service = new CategoryDrivenCodeService(entityManager);
        CategoryCodeAllocation allocation = service.allocate(CLIENT, null, null);

        assertEquals("KH000042", allocation.code());
        assertEquals(42L, allocation.sequence());
        assertNull(allocation.prefixCategoryId());
        assertTrue(allocation.managed());
        verify(duplicateCheck).setParameter("masterDomain", "CLIENT");
        verify(duplicateCheck, never()).setParameter(eq("excludedId"),
                org.mockito.ArgumentMatchers.any());
    }

    @Test
    void autoAllocationSkipsAReservedCrossDomainCandidate() {
        EntityManager entityManager = mock(EntityManager.class);
        Query lock = fluentQuery();
        Query firstIncrement = fluentQuery();
        Query firstGlobalCheck = fluentQuery();
        Query secondIncrement = fluentQuery();
        Query secondGlobalCheck = fluentQuery();

        when(entityManager.createNativeQuery(anyString()))
                .thenReturn(lock, firstIncrement, firstGlobalCheck,
                        secondIncrement, secondGlobalCheck);
        when(lock.getResultList()).thenReturn(List.of(40L));
        when(firstIncrement.getSingleResult()).thenReturn(41L);
        when(firstGlobalCheck.getSingleResult()).thenReturn(true);
        when(secondIncrement.getSingleResult()).thenReturn(42L);
        when(secondGlobalCheck.getSingleResult()).thenReturn(false);

        CategoryCodeAllocation allocation =
                new CategoryDrivenCodeService(entityManager)
                        .allocate(CLIENT, null, null);

        assertEquals("KH000042", allocation.code());
        assertEquals(42L, allocation.sequence());
        verify(firstGlobalCheck).setParameter("code", "KH000041");
        verify(secondGlobalCheck).setParameter("code", "KH000042");
    }

    @Test
    void prefixNormalizationSupportsDigitBearingBusinessPrefix() {
        assertEquals("V6", CategoryDrivenCodeService.normalizePrefix(" v6 "));
        assertEquals("V6000123", CategoryDrivenCodeService.format("V6", 123));
    }

    @Test
    void managedUpdateKeepsSuffixAndMovesToNewEffectivePrefixOwner() {
        EntityManager entityManager = mock(EntityManager.class);
        Query lock = fluentQuery();
        Query effectivePrefix = fluentQuery();
        Query duplicateCheck = fluentQuery();
        UUID entityId = UUID.randomUUID();
        UUID categoryId = UUID.randomUUID();
        UUID ownerId = UUID.randomUUID();

        when(entityManager.createNativeQuery(anyString()))
                .thenReturn(lock, effectivePrefix, duplicateCheck);
        when(lock.getResultList()).thenReturn(List.of(99L));
        when(effectivePrefix.getSingleResult())
                .thenReturn(new Object[]{true, ownerId, "V6"});
        when(duplicateCheck.getSingleResult()).thenReturn(false);

        CategoryDrivenCodeService service = new CategoryDrivenCodeService(entityManager);
        CategoryCodeAllocation allocation = service.allocateForUpdate(
                CLIENT,
                entityId,
                categoryId,
                "KH000007",
                new CategoryCodeAllocation("KH000007", 7L, null, true));

        assertEquals("V6000007", allocation.code());
        assertEquals(7L, allocation.sequence());
        assertEquals(ownerId, allocation.prefixCategoryId());
        assertTrue(allocation.managed());
    }

    @Test
    void unchangedCustomUpdateKeepsStableUniqueSequenceAndCustomStatus() {
        EntityManager entityManager = mock(EntityManager.class);
        Query lock = fluentQuery();
        Query effectivePrefix = fluentQuery();
        Query duplicateCheck = fluentQuery();
        UUID entityId = UUID.randomUUID();
        UUID categoryId = UUID.randomUUID();

        when(entityManager.createNativeQuery(anyString()))
                .thenReturn(lock, effectivePrefix, duplicateCheck);
        when(lock.getResultList()).thenReturn(List.of(99L));
        when(effectivePrefix.getSingleResult())
                .thenReturn(new Object[]{true, categoryId, "V6"});
        when(duplicateCheck.getSingleResult()).thenReturn(false);

        CategoryDrivenCodeService service = new CategoryDrivenCodeService(entityManager);
        CategoryCodeAllocation allocation = service.allocateForUpdate(
                CLIENT,
                entityId,
                categoryId,
                "legacy-x",
                new CategoryCodeAllocation("LEGACY-X", 88L, null, false));

        assertEquals("LEGACY-X", allocation.code());
        assertEquals(88L, allocation.sequence());
        assertNull(allocation.prefixCategoryId());
        org.junit.jupiter.api.Assertions.assertFalse(allocation.managed());
    }

    @Test
    void samePrefixButDifferentOwnerStillUpdatesManagedOwnershipOnCategoryMove() {
        EntityManager entityManager = mock(EntityManager.class);
        Query lock = fluentQuery();
        Query effectivePrefix = fluentQuery();
        Query duplicateCheck = fluentQuery();
        UUID entityId = UUID.randomUUID();
        UUID categoryId = UUID.randomUUID();
        UUID oldOwnerId = UUID.randomUUID();
        UUID newOwnerId = UUID.randomUUID();

        when(entityManager.createNativeQuery(anyString()))
                .thenReturn(lock, effectivePrefix, duplicateCheck);
        when(lock.getResultList()).thenReturn(List.of(99L));
        when(effectivePrefix.getSingleResult())
                .thenReturn(new Object[]{true, newOwnerId, "V6"});
        when(duplicateCheck.getSingleResult()).thenReturn(false);

        CategoryDrivenCodeService service = new CategoryDrivenCodeService(entityManager);
        CategoryCodeAllocation allocation = service.allocateForUpdate(
                CLIENT,
                entityId,
                categoryId,
                "V6000007",
                new CategoryCodeAllocation("V6000007", 7L, oldOwnerId, true));

        assertEquals("V6000007", allocation.code());
        assertEquals(newOwnerId, allocation.prefixCategoryId());
        assertTrue(allocation.managed());
    }

    @Test
    void invalidPrefixIsRejectedBeforeSql() {
        assertThrows(ApiException.class,
                () -> CategoryDrivenCodeService.normalizePrefix("6V"));
        assertThrows(ApiException.class,
                () -> CategoryDrivenCodeService.normalizePrefix("ABCDEFGHI"));
        assertThrows(ApiException.class,
                () -> CategoryDrivenCodeService.normalizePrefix("V-6"));
    }

    private Query fluentQuery() {
        Query query = mock(Query.class);
        when(query.setParameter(anyString(), org.mockito.ArgumentMatchers.any()))
                .thenReturn(query);
        return query;
    }
}
