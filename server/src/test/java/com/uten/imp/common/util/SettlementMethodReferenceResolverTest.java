package com.uten.imp.common.util;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;

import java.util.Collections;
import java.util.List;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.lenient;
import static org.mockito.Mockito.when;

@ExtendWith(MockitoExtension.class)
class SettlementMethodReferenceResolverTest {
    @Mock private EntityManager em;
    @Mock private Query query;

    @BeforeEach
    void setUp() {
        lenient().when(em.createNativeQuery(anyString())).thenReturn(query);
        lenient().when(query.setMaxResults(2)).thenReturn(query);
    }

    @Test
    void legacyOnlyKeyCannotCreateOnlineRelationship() {
        ApiException error = assertThrows(ApiException.class,
                () -> SettlementMethodReferenceResolver.resolve(em, null, 7, "结帐方式"));

        assertEquals(ErrorCode.VALIDATION_FAILED, error.getCode());
    }

    @Test
    void uuidAndLegacyConflictIsRejected() {
        UUID id = UUID.randomUUID();
        when(query.setParameter("value", id)).thenReturn(query);
        when(query.getResultList()).thenReturn(rows(id, 6, null));

        ApiException error = assertThrows(ApiException.class,
                () -> SettlementMethodReferenceResolver.resolve(em, id, 7, "结帐方式"));

        assertEquals(ErrorCode.CONFLICT, error.getCode());
    }

    @Test
    void unknownLegacyValueCannotRemainNormalWriteTruth() {
        ApiException error = assertThrows(ApiException.class,
                () -> SettlementMethodReferenceResolver.resolve(em, null, 99, "结帐方式"));

        assertEquals(ErrorCode.VALIDATION_FAILED, error.getCode());
    }

    @Test
    void uuidResolutionCarriesStableSystemRole() {
        UUID id = UUID.randomUUID();
        when(query.setParameter("value", id)).thenReturn(query);
        when(query.getResultList()).thenReturn(rows(id, 1, "CASH"));

        var resolved = SettlementMethodReferenceResolver.resolve(
                em, id, 1, "结帐方式");

        assertEquals("CASH", resolved.systemRole());
    }

    private static List<?> rows(UUID id, int legacyId, String systemRole) {
        return Collections.singletonList(
                new Object[]{id, legacyId, "BPS-0001", "现金", systemRole});
    }
}
