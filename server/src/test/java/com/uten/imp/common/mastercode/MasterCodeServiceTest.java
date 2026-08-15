package com.uten.imp.common.mastercode;

import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class MasterCodeServiceTest {

    @Test
    void skipsCrossDomainHistoricalReservationAndKeepsConfiguredWidth() {
        EntityManager entityManager = mock(EntityManager.class);
        Query first = fluentQuery();
        Query second = fluentQuery();
        when(entityManager.createNativeQuery(anyString())).thenReturn(first, second);
        when(first.getSingleResult())
                .thenReturn(new Object[]{"V00000001", 1, true});
        when(second.getSingleResult())
                .thenReturn(new Object[]{"V00000002", 2, false});

        String code = new MasterCodeService(entityManager)
                .nextCode(MasterCodePrefix.VISITOR);

        assertEquals("V00000002", code);
        verify(first).setParameter("prefix", "V");
        verify(first).setParameter("width", 8);
        verify(second).setParameter("prefix", "V");
        ArgumentCaptor<String> sql = ArgumentCaptor.forClass(String.class);
        verify(entityManager, org.mockito.Mockito.times(2))
                .createNativeQuery(sql.capture());
        assertTrue(sql.getAllValues().get(0)
                .contains("business_identifier_reservations"));
    }

    @Test
    void configuredWidthIsAHardExhaustionBoundary() {
        EntityManager entityManager = mock(EntityManager.class);
        Query query = fluentQuery();
        when(entityManager.createNativeQuery(anyString())).thenReturn(query);
        when(query.getSingleResult())
                .thenReturn(new Object[]{"UT10000", 10_000, false});

        assertThrows(IllegalStateException.class,
                () -> new MasterCodeService(entityManager)
                        .nextCode(MasterCodePrefix.EMPLOYEE));

        ArgumentCaptor<String> sql = ArgumentCaptor.forClass(String.class);
        verify(entityManager).createNativeQuery(sql.capture());
        assertTrue(sql.getValue().contains("WHEN length(advanced.last_seq::text) < :width"));
        assertTrue(sql.getValue().contains("ELSE advanced.last_seq::text"));
    }

    @Test
    void executionSegmentUsesItsDedicatedEightDigitNamespace() {
        assertEquals("ZX", MasterCodePrefix.PRODUCTION_EXECUTION_SEGMENT.code());
        assertEquals(8, MasterCodePrefix.PRODUCTION_EXECUTION_SEGMENT.width());
    }

    @Test
    void visitorSequenceExhaustionFailsClosedBeforeReturningANinthDigit() {
        EntityManager entityManager = mock(EntityManager.class);
        Query query = fluentQuery();
        when(entityManager.createNativeQuery(anyString())).thenReturn(query);
        when(query.getSingleResult())
                .thenReturn(new Object[]{"V100000000", 100_000_000, false});

        assertThrows(IllegalStateException.class,
                () -> new MasterCodeService(entityManager)
                        .nextCode(MasterCodePrefix.VISITOR));
    }

    private static Query fluentQuery() {
        Query query = mock(Query.class);
        when(query.setParameter(anyString(), org.mockito.ArgumentMatchers.any()))
                .thenReturn(query);
        return query;
    }
}
