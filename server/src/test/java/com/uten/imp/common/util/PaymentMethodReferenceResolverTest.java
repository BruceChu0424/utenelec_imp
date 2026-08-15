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

import java.util.List;
import java.util.Collections;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.when;
import static org.mockito.Mockito.lenient;

@ExtendWith(MockitoExtension.class)
class PaymentMethodReferenceResolverTest {

    @Mock private EntityManager em;
    @Mock private Query query;

    @BeforeEach
    void setUp() {
        lenient().when(em.createNativeQuery(anyString())).thenReturn(query);
        lenient().when(query.setParameter(org.mockito.ArgumentMatchers.eq("direction"), any()))
                .thenReturn(query);
        lenient().when(query.setMaxResults(2)).thenReturn(query);
    }

    @Test
    void uuidIsValidatedAndCanonicalLegacyShadowIsReturned() {
        UUID id = UUID.randomUUID();
        when(query.setParameter("value", id)).thenReturn(query);
        when(query.getResultList()).thenReturn(rows(id, 8));

        var result = PaymentMethodReferenceResolver.resolve(
                em, id, 8, "付款方式", PaymentMethodReferenceResolver.Direction.PAYMENT);

        assertEquals(id, result.id());
        assertEquals(8, result.legacyId());
    }

    @Test
    void conflictingUuidAndLegacyMethodIsRejected() {
        UUID id = UUID.randomUUID();
        when(query.setParameter("value", id)).thenReturn(query);
        when(query.getResultList()).thenReturn(rows(id, 8));

        ApiException error = assertThrows(ApiException.class,
                () -> PaymentMethodReferenceResolver.resolve(
                        em, id, 9, "付款方式", PaymentMethodReferenceResolver.Direction.PAYMENT));

        assertEquals(ErrorCode.CONFLICT, error.getCode());
    }

    @Test
    void legacyOnlyMethodCannotCreateOnlineRelationship() {
        ApiException error = assertThrows(ApiException.class,
                () -> PaymentMethodReferenceResolver.resolve(
                        em, null, 12, "收款方式", PaymentMethodReferenceResolver.Direction.RECEIPT));

        assertEquals(ErrorCode.VALIDATION_FAILED, error.getCode());
    }

    @Test
    void unmappedLegacyDictionaryValueIsNotSilentlyPersisted() {
        ApiException error = assertThrows(ApiException.class,
                () -> PaymentMethodReferenceResolver.resolve(
                        em, null, 99, "收款方式", PaymentMethodReferenceResolver.Direction.RECEIPT));

        assertEquals(ErrorCode.VALIDATION_FAILED, error.getCode());
    }

    @Test
    void absentOptionalMethodStaysNull() {
        assertNull(PaymentMethodReferenceResolver.resolve(
                em, null, null, "收款方式", PaymentMethodReferenceResolver.Direction.RECEIPT));
    }

    private static List<?> rows(UUID id, Integer legacyId) {
        return Collections.singletonList(new Object[]{id, legacyId});
    }
}
