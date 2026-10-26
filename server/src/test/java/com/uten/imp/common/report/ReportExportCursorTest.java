package com.uten.imp.common.report;

import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;
import org.springframework.transaction.support.TransactionSynchronizationManager;

import java.util.List;
import java.util.Set;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.Mockito.*;

class ReportExportCursorTest {
    @AfterEach void clear() { TransactionSynchronizationManager.clear(); }

    @Test void ordinaryReadsKeepTheirExistingQueryWithoutRequiringAHibernateCursor() {
        Query query = mock(Query.class);
        when(query.getResultList()).thenReturn(List.<Object[]>of(new Object[]{"original", 12L}));
        var result = ReportExportCursor.rows(mock(EntityManager.class), query);
        assertThat(result).hasSize(1);assertThat(result.getFirst()).containsExactly("original", 12L);
        verify(query, never()).unwrap(any());
    }

    @Test void cursorCannotBeEnabledOutsideTheWorkerSnapshot() {
        assertThatThrownBy(ReportExportCursor::open).isInstanceOf(IllegalStateException.class);
        TransactionSynchronizationManager.setActualTransactionActive(true);
        TransactionSynchronizationManager.setCurrentTransactionReadOnly(true);
        TransactionSynchronizationManager.setCurrentTransactionIsolationLevel(java.sql.Connection.TRANSACTION_READ_COMMITTED);
        assertThatThrownBy(ReportExportCursor::open).isInstanceOf(IllegalStateException.class);
        TransactionSynchronizationManager.setCurrentTransactionIsolationLevel(java.sql.Connection.TRANSACTION_REPEATABLE_READ);
        TransactionSynchronizationManager.setCurrentTransactionReadOnly(false);
        assertThatThrownBy(ReportExportCursor::open).isInstanceOf(IllegalStateException.class);
    }

    private void snapshot() {
        TransactionSynchronizationManager.setActualTransactionActive(true);
        TransactionSynchronizationManager.setCurrentTransactionReadOnly(true);
        TransactionSynchronizationManager.setCurrentTransactionIsolationLevel(java.sql.Connection.TRANSACTION_REPEATABLE_READ);
    }

    @Test void adjustedQuestionMarkSqlAndMismatchedPageBindingsAreNotAcceptedAsAnApplicationQuery() {
        snapshot();EntityManager em = mock(EntityManager.class);Query first = mock(Query.class), second = mock(Query.class);
        when(em.createNativeQuery(anyString())).thenReturn(first, second);
        var offset = mock(jakarta.persistence.Parameter.class);when(offset.getName()).thenReturn("wrongOffset");
        when(second.getParameters()).thenReturn(Set.of(offset));
        try (var scope = ReportExportCursor.open()) {
            Query adjusted = ReportExportCursor.query(em, "SELECT * FROM facts WHERE owner=? LIMIT ? OFFSET ?");
            assertThatThrownBy(() -> ReportExportCursor.rows(em, adjusted)).hasMessageContaining("pagination suffix");
            Query mismatch = ReportExportCursor.query(em, "SELECT * FROM facts LIMIT :__limit OFFSET :__offset");
            assertThatThrownBy(() -> ReportExportCursor.rows(em, mismatch)).hasMessageContaining("bindings do not match");
            assertThatThrownBy(() -> ReportExportCursor.rows(em, mismatch)).hasMessageContaining("registered application SQL");
        }
        verify(first, never()).getResultList();verify(second, never()).getResultList();
    }

    @SuppressWarnings({"unchecked", "rawtypes"})
    @Test void registrationIsConsumedByIdentityAndCannotPolluteTheNextNativeQuery() {
        snapshot();EntityManager em = mock(EntityManager.class);Query wrong = mock(Query.class), right = mock(Query.class), unpaged = mock(Query.class);
        String badSql = "SELECT 999 FROM facts LIMIT ? OFFSET ?";
        String application = "SELECT qty FROM facts WHERE owner=:owner LIMIT :__limit OFFSET :__offset";
        String whole = "SELECT qty FROM facts WHERE owner=:owner";
        when(em.createNativeQuery(badSql)).thenReturn(wrong);when(em.createNativeQuery(application)).thenReturn(right);
        when(em.createNativeQuery(whole)).thenReturn(unpaged);
        var owner = mock(jakarta.persistence.Parameter.class);when(owner.getName()).thenReturn("owner");
        var limit = mock(jakarta.persistence.Parameter.class);when(limit.getName()).thenReturn("__limit");
        var offset = mock(jakarta.persistence.Parameter.class);when(offset.getName()).thenReturn("__offset");
        when(right.getParameters()).thenReturn(Set.of(owner, limit, offset));
        when(right.getParameterValue("__limit")).thenReturn(500);when(right.getParameterValue("__offset")).thenReturn(0L);
        when(right.getParameterValue(owner)).thenReturn("authorized-owner");
        var nativeRows = mock(org.hibernate.query.NativeQuery.class);
        when(unpaged.unwrap(org.hibernate.query.NativeQuery.class)).thenReturn(nativeRows);
        when(nativeRows.setReadOnly(true)).thenReturn(nativeRows);when(nativeRows.setFetchSize(500)).thenReturn(nativeRows);
        var closed = new java.util.concurrent.atomic.AtomicBoolean();
        when(nativeRows.getResultStream()).thenReturn(java.util.stream.Stream.<Object[]>of(new Object[]{"original-decimal"})
                .onClose(() -> closed.set(true)));
        try (var scope = ReportExportCursor.open()) {
            Query registeredWrong = ReportExportCursor.query(em, badSql);
            Query registeredRight = ReportExportCursor.query(em, application);
            assertThatThrownBy(() -> ReportExportCursor.rows(em, registeredWrong)).hasMessageContaining("pagination suffix");
            var rows = ReportExportCursor.rows(em, registeredRight);
            assertThat(rows).hasSize(1);assertThat(rows.getFirst()).containsExactly("original-decimal");
            assertThat(closed).isTrue();
            assertThatThrownBy(() -> ReportExportCursor.rows(em, registeredRight)).hasMessageContaining("registered application SQL");
        }
        verify(unpaged).setParameter("owner", "authorized-owner");
        verify(em, never()).createNativeQuery("SELECT 999 FROM facts");
    }
}
