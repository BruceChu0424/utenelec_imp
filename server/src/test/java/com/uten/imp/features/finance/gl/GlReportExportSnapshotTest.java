package com.uten.imp.features.finance.gl;

import com.uten.imp.common.export.ExportPageSink;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.finance.report.ReportTableResponse;
import com.uten.imp.security.AuthUser;
import jakarta.persistence.EntityManager;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.transaction.support.TransactionSynchronizationManager;

import java.time.LocalDate;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.Mockito.*;

class GlReportExportSnapshotTest {
    private final LocalDate date = LocalDate.of(2026, 10, 25);
    private final GlReportService service = spy(new GlReportService(mock(EntityManager.class), mock(GlReportLineSource.class),com.uten.imp.support.FinanceReportTestAccess.company()));

    @AfterEach void clear() {
        TransactionSynchronizationManager.clear();
        SecurityContextHolder.clearContext();
    }

    private void context(Set<String> permissions, boolean active, boolean readOnly, Integer isolation) {
        TransactionSynchronizationManager.setActualTransactionActive(active);
        TransactionSynchronizationManager.setCurrentTransactionReadOnly(readOnly);
        TransactionSynchronizationManager.setCurrentTransactionIsolationLevel(isolation);
        var user = new AuthUser(UUID.randomUUID(), UUID.randomUUID(), "export-user", permissions, false, true, false);
        SecurityContextHolder.getContext().setAuthentication(
                new UsernamePasswordAuthenticationToken(user, null, user.getAuthorities()));
    }

    @Test void bridgeRequiresTheWorkerScopeAndItsReadOnlyRepeatableReadTransaction() {
        var permissions = Set.of("finance_report:view", "finance_report:export", "finance:view:all");
        context(permissions, true, true, java.sql.Connection.TRANSACTION_REPEATABLE_READ);
        assertThatThrownBy(() -> service.exportInCurrentSnapshot("gl/balance-sheet", date, 2026, 10))
                .isInstanceOf(IllegalStateException.class);
        try (var sink = ExportPageSink.open(page -> { })) {
            for (var invalid : List.of(new Object[]{false, true, java.sql.Connection.TRANSACTION_REPEATABLE_READ},
                    new Object[]{true, false, java.sql.Connection.TRANSACTION_REPEATABLE_READ},
                    new Object[]{true, true, java.sql.Connection.TRANSACTION_READ_COMMITTED})) {
                context(permissions, (boolean) invalid[0], (boolean) invalid[1], (int) invalid[2]);
                assertThatThrownBy(() -> service.exportInCurrentSnapshot("gl/balance-sheet", date, 2026, 10))
                        .isInstanceOf(IllegalStateException.class);
            }
        }
    }

    @Test void bridgeStillRequiresFullFinanceAndExportAuthorityBeforeReadingFacts() {
        try (var sink = ExportPageSink.open(page -> { })) {
            context(Set.of("finance_report:view", "finance_report:export"), true, true,
                    java.sql.Connection.TRANSACTION_REPEATABLE_READ);
            assertThatThrownBy(() -> service.exportInCurrentSnapshot("gl/balance-sheet", date, 2026, 10))
                    .isInstanceOf(ApiException.class);
            verify(service, never()).balanceSheet(any());
        }
    }

    @Test void everyFixedReportReusesItsExistingAuthorityWithinTheSameTransaction() {
        context(Set.of("finance_report:view", "finance_report:export", "finance:view:all"), true, true,
                java.sql.Connection.TRANSACTION_REPEATABLE_READ);
        var expected = new ReportTableResponse(List.of(), List.of(), Map.of(), 1, 1, 0, 0);
        doReturn(expected).when(service).balanceSheet(date);
        doReturn(expected).when(service).profitAnnual(2026);
        doReturn(expected).when(service).profitMonthly(2026, 10);
        doReturn(expected).when(service).manufacturingExpense(2026);
        doReturn(expected).when(service).adminExpense(2026);
        doReturn(expected).when(service).salesExpense(2026);
        doReturn(expected).when(service).operatingPl(2026, 10);
        try (var sink = ExportPageSink.open(page -> { })) {
            for (String report : List.of("gl/balance-sheet", "gl/profit-annual", "gl/profit-monthly",
                    "gl/manufacturing-expense", "gl/admin-expense", "gl/sales-expense", "gl/operating-pl")) {
                assertThat(service.exportInCurrentSnapshot(report, date, 2026, 10)).isSameAs(expected);
                assertThat(TransactionSynchronizationManager.getCurrentTransactionIsolationLevel())
                        .isEqualTo(java.sql.Connection.TRANSACTION_REPEATABLE_READ);
            }
        }
        verify(service).balanceSheet(date);
        verify(service).profitAnnual(2026);
        verify(service).profitMonthly(2026, 10);
        verify(service).manufacturingExpense(2026);
        verify(service).adminExpense(2026);
        verify(service).salesExpense(2026);
        verify(service).operatingPl(2026, 10);
    }
}
