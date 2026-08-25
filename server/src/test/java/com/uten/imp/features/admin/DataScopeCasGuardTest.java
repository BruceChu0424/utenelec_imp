package com.uten.imp.features.admin;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

import java.util.List;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertDoesNotThrow;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

class DataScopeCasGuardTest {

    private final EntityManager em = mock(EntityManager.class);
    private final Query query = mock(Query.class);
    private final DataScopeCasGuard guard = new DataScopeCasGuard(em);

    @BeforeEach
    void queries() {
        when(em.createNativeQuery(anyString())).thenReturn(query);
        when(query.setParameter(anyString(), any())).thenReturn(query);
        when(query.getSingleResult()).thenReturn(0L);
    }

    @Test
    void matchingExpectedSetMayProceedRegardlessOfOrder() {
        UUID first = UUID.randomUUID();
        UUID second = UUID.randomUUID();
        when(query.getResultList()).thenReturn(List.of(first, second));

        assertDoesNotThrow(() -> guard.lockAndVerify(
                UUID.randomUUID(), "client", List.of(second, first)));
    }

    @Test
    void staleExpectedSetFailsWithConflict() {
        UUID current = UUID.randomUUID();
        when(query.getResultList()).thenReturn(List.of(current));

        ApiException error = assertThrows(ApiException.class, () -> guard.lockAndVerify(
                UUID.randomUUID(), "client", List.of()));

        assertEquals(ErrorCode.CONFLICT, error.getCode());
    }

    @Test
    void missingExpectedSetFailsClosed() {
        ApiException error = assertThrows(ApiException.class, () -> guard.lockAndVerify(
                UUID.randomUUID(), "client", null));

        assertEquals(ErrorCode.VALIDATION_FAILED, error.getCode());
    }
}
