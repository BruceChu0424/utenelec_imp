package com.uten.imp.features.master.history;

import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;

import static org.junit.jupiter.api.Assertions.assertSame;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.mockito.Mockito.*;

class MasterOperationHistoryTransactionPreparationTest {
    private final EntityManager em = mock(EntityManager.class);
    private final MasterOperationHistoryTransactionPreparation preparation =
            new MasterOperationHistoryTransactionPreparation(em);

    @ParameterizedTest
    @ValueSource(strings = {"/api/master/goods", "/api/master/goods/id/bom/edit/preview",
            "/api/master/inline-edit/goods/id", "/api/master/material-categories/id",
            "/api/master/colors-extra", "/api/master/inline-edit/colors-extra/id",
            "/api/master/unknown", "/api/production/where-used"})
    void unrelatedDomainsDoNotAcquireMasterHistoryOrTouchItsSchema(String path) {
        preparation.prepare(path, "PATCH");
        verifyNoInteractions(em);
    }

    @ParameterizedTest
    @ValueSource(strings = {"/api/master/clients/id/addresses", "/api/master/suppliers/id/contact-methods",
            "/api/master/moulds/id", "/api/master/colors", "/api/master/units/id",
            "/api/master/currencies/id", "/api/master/warehouses/id/keepers", "/api/master/accounts",
            "/api/master/client-categories/id", "/api/master/supplier-categories/id",
            "/api/master/mould-categories/id", "/api/master/payment-styles/id",
            "/api/master/reference-methods/settlement", "/api/master/operation-history/id/undo",
            "/api/master/inline-edit/colors/id", "/api/master/inline-edit/clients/id",
            "/api/master/inline-edit/warehouses/id"})
    void managedDomainsKeepTheMandatoryHistoryPreparation(String path) {
        Query query = mock(Query.class);
        when(em.createNativeQuery("SELECT fn_begin_master_history_request()")).thenReturn(query);
        preparation.prepare(path, "POST");
        verify(query).getSingleResult();
    }

    @ParameterizedTest
    @ValueSource(strings = {"GET", "HEAD", "OPTIONS", ""})
    void readsNeverPrepareWriteHistory(String method) {
        preparation.prepare("/api/master/colors", method);
        verifyNoInteractions(em);
    }

    @Test void absentRequestMetadataDoesNotTouchTheDatabase() {
        preparation.prepare(null, "POST");
        preparation.prepare("/api/master/colors", null);
        verifyNoInteractions(em);
    }

    @Test void requiredHistoryFailuresAreNotSwallowedOrTreatedAsOptional() {
        RuntimeException failure = new IllegalStateException("required history function unavailable");
        when(em.createNativeQuery("SELECT fn_begin_master_history_request()")).thenThrow(failure);
        assertSame(failure, assertThrows(RuntimeException.class,
                () -> preparation.prepare("/api/master/colors", "POST")));
    }
}
