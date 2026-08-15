package com.uten.imp.common.docnumber;

import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;

import java.util.List;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class DocNumberServiceTest {

    @Test
    void allocatesDatabasePrefixShanghaiDateAndSixDigitDailySequence() {
        EntityManager entityManager = mock(EntityManager.class);
        Query query = fluentQuery();
        when(entityManager.createNativeQuery(anyString())).thenReturn(query);
        when(query.getResultList()).thenReturn(List.<Object[]>of(
                new Object[]{"XD20260814000001", 1L, false}));

        String value = new DocNumberService(entityManager)
                .nextNumber(DocNumberPrefix.SALES_ORDER);

        assertEquals("XD20260814000001", value);
        verify(query).setParameter("namespace", "SALES_ORDER");
        ArgumentCaptor<String> sql = ArgumentCaptor.forClass(String.class);
        verify(entityManager).createNativeQuery(sql.capture());
        assertTrue(sql.getValue().contains("business_identifier_namespaces"));
        assertTrue(sql.getValue().contains("business_document_sequences"));
        assertTrue(sql.getValue().contains("AT TIME ZONE 'Asia/Shanghai'"));
        assertTrue(sql.getValue().contains("ON CONFLICT (namespace_key, sequence_date)"));
        assertTrue(sql.getValue().contains("lpad(advanced.last_seq::text, 6, '0')"));
    }

    @Test
    void skipsACommittedHistoricalGlobalReservation() {
        EntityManager entityManager = mock(EntityManager.class);
        Query first = fluentQuery();
        Query second = fluentQuery();
        when(entityManager.createNativeQuery(anyString())).thenReturn(first, second);
        when(first.getResultList()).thenReturn(List.<Object[]>of(
                new Object[]{"SZ20260814000001", 1L, true}));
        when(second.getResultList()).thenReturn(List.<Object[]>of(
                new Object[]{"SZ20260814000002", 2L, false}));

        String value = new DocNumberService(entityManager)
                .nextNumber(DocNumberPrefix.PRODUCTION_SUBPLAN);

        assertEquals("SZ20260814000002", value);
        verify(first).setParameter("namespace", "PRODUCTION_SUBPLAN");
        verify(second).setParameter("namespace", "PRODUCTION_SUBPLAN");
    }

    @Test
    void missingNamespaceAndOverflowFailClosed() {
        EntityManager missingEntityManager = mock(EntityManager.class);
        Query missing = fluentQuery();
        when(missingEntityManager.createNativeQuery(anyString())).thenReturn(missing);
        when(missing.getResultList()).thenReturn(List.of());
        assertThrows(IllegalStateException.class,
                () -> new DocNumberService(missingEntityManager)
                        .nextNumber(DocNumberPrefix.SALES_ORDER));

        EntityManager overflowEntityManager = mock(EntityManager.class);
        Query overflow = fluentQuery();
        when(overflowEntityManager.createNativeQuery(anyString())).thenReturn(overflow);
        when(overflow.getResultList()).thenReturn(List.<Object[]>of(
                new Object[]{"XD202608141000000", 1_000_000L, false}));
        assertThrows(IllegalStateException.class,
                () -> new DocNumberService(overflowEntityManager)
                        .nextNumber(DocNumberPrefix.SALES_ORDER));
    }

    private static Query fluentQuery() {
        Query query = mock(Query.class);
        when(query.setParameter(anyString(), org.mockito.ArgumentMatchers.any()))
                .thenReturn(query);
        return query;
    }
}
