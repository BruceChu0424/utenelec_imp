package com.uten.imp.features.finance.asset;

import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;

import java.util.Collections;
import java.util.List;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.argThat;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class FixedAssetPaginationTest {

    private EntityManager entityManager;
    private Query countQuery;
    private Query dataQuery;
    private FixedAssetService service;

    @BeforeEach
    void setUp() {
        entityManager = mock(EntityManager.class);
        countQuery = mock(Query.class);
        dataQuery = mock(Query.class);
        service = new FixedAssetService(entityManager, mock(TxSessionVars.class));

        when(entityManager.createNativeQuery(argThat(
                sql -> sql != null && sql.toUpperCase().contains("COUNT(*)"))))
                .thenReturn(countQuery);
        when(entityManager.createNativeQuery(argThat(
                sql -> sql != null && !sql.toUpperCase().contains("COUNT(*)"))))
                .thenReturn(dataQuery);
        when(dataQuery.setParameter(anyString(), org.mockito.ArgumentMatchers.any()))
                .thenReturn(dataQuery);
    }

    @Test
    void assetsClampExtremePageAndSizeAtTheDatabaseBoundary() {
        when(countQuery.getSingleResult()).thenReturn(501L);
        when(dataQuery.getResultList()).thenReturn(Collections.singletonList(new Object[]{
                "id", "FA-001", "设备", "生产部", null, null,
                1000, 0.05, 60, "2026-01", "在用", null
        }));

        var response = service.listAssets(Integer.MIN_VALUE, Integer.MAX_VALUE);

        assertEquals(1, response.getPage());
        assertEquals(100, response.getSize());
        assertEquals(501, response.getTotal());
        assertEquals(6, response.getTotalPages());
        assertEquals("FA-001", response.getItems().getFirst().get("code"));
        verify(dataQuery).setParameter("__limit", 100);
        verify(dataQuery).setParameter("__offset", 0L);
        assertStablePagedSql();
    }

    @Test
    void deferredReturnsRequestedServerPageWithoutLoadingAllRows() {
        when(countQuery.getSingleResult()).thenReturn(45L);
        when(dataQuery.getResultList()).thenReturn(List.of());

        var response = service.listDeferred(3, 20);

        assertEquals(3, response.getPage());
        assertEquals(20, response.getSize());
        assertEquals(45, response.getTotal());
        assertEquals(3, response.getTotalPages());
        verify(dataQuery).setParameter("__limit", 20);
        verify(dataQuery).setParameter("__offset", 40L);
        assertStablePagedSql();
    }

    private void assertStablePagedSql() {
        ArgumentCaptor<String> sql = ArgumentCaptor.forClass(String.class);
        verify(entityManager, org.mockito.Mockito.atLeastOnce())
                .createNativeQuery(sql.capture());
        String dataSql = sql.getAllValues().stream()
                .filter(value -> !value.toUpperCase().contains("COUNT(*)"))
                .findFirst()
                .orElseThrow();
        assertTrue(dataSql.contains("ORDER BY a.code, a.id"));
        assertTrue(dataSql.contains("LIMIT :__limit OFFSET :__offset"));
    }
}
