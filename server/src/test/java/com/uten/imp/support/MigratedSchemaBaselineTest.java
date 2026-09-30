package com.uten.imp.support;

import org.junit.jupiter.api.Test;
import org.testcontainers.containers.Container;
import org.testcontainers.containers.PostgreSQLContainer;

import java.sql.SQLException;
import java.util.concurrent.atomic.AtomicInteger;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.*;

class MigratedSchemaBaselineTest {
    @Test
    void leaseClosureNeverStopsTheTemplateAndPoolClosureStopsItExactlyOnce() throws Exception {
        var postgres = postgres();
        var migrations = new AtomicInteger();
        var pool = new MigratedSchemaBaseline.TemplatePool(() -> postgres, ignored -> migrations.incrementAndGet());
        var first = pool.open("first");
        var second = pool.open("second");
        first.close();
        first.close();
        verify(postgres, never()).stop();
        assertDoesNotThrow(second::getJdbcUrl);
        assertEquals(1, migrations.get());
        verify(postgres, times(1)).start();
        pool.close();
        pool.close();
        second.close();
        verify(postgres, times(1)).stop();
        assertThrows(IllegalStateException.class, second::getJdbcUrl);
        assertThrows(IllegalStateException.class, () -> pool.open("late"));
    }

    @Test
    void failedMigrationClosesTheFailedContainerAndCanOnlyRetryWithAFreshTemplate() throws Exception {
        var failed = postgres();
        var replacement = postgres();
        var attempts = new AtomicInteger();
        var pool = new MigratedSchemaBaseline.TemplatePool(
                () -> attempts.get() == 0 ? failed : replacement,
                ignored -> { if (attempts.getAndIncrement() == 0) throw new IllegalStateException("migration failed"); });
        try (pool) {
            assertThrows(IllegalStateException.class, () -> pool.open("failed"));
            verify(failed).stop();
            assertEquals(0, pool.migrationCount());
            try (var lease = pool.open("retry")) {
                assertEquals(1, pool.migrationCount());
                verify(replacement).start();
            }
        }
        verify(replacement).stop();
    }

    @Test
    void createdbFailureDoesNotFallThroughToAnExistingDatabase() throws Exception {
        var postgres = postgres();
        when(postgres.execInContainer(any(String[].class)))
                .thenReturn(execResult(1, "", "database already exists"));
        SQLException failure = assertThrows(SQLException.class,
                () -> MigratedSchemaBaseline.cloneConnection(postgres, "existing"));
        assertTrue(failure.getMessage().contains("createdb failed (exit 1)"));
        verify(postgres, never()).getJdbcUrl();
    }

    @Test
    void failedCloneDoesNotExposeALeaseOrDiscardTheHealthyTemplate() throws Exception {
        var postgres = postgres();
        when(postgres.execInContainer(any(String[].class)))
                .thenReturn(execResult(1, "", "template busy"))
                .thenReturn(execResult(0, "", ""));
        try (var pool = new MigratedSchemaBaseline.TemplatePool(() -> postgres, ignored -> {})) {
            assertThrows(SQLException.class, () -> pool.open("failed_clone"));
            verify(postgres, never()).stop();
            try (var lease = pool.open("working_clone")) {
                assertEquals(1, pool.migrationCount());
                verify(postgres, times(1)).start();
            }
        }
    }

    @Test
    void failedDropIsReportedAndCanBeRetried() throws Exception {
        var postgres = postgres();
        when(postgres.execInContainer(any(String[].class)))
                .thenReturn(execResult(0, "", ""))
                .thenReturn(execResult(1, "", "prepared transaction still exists"))
                .thenReturn(execResult(0, "", ""));
        try (var pool = new MigratedSchemaBaseline.TemplatePool(() -> postgres, ignored -> {})) {
            var lease = pool.open("drop_retry");
            assertThrows(SQLException.class, lease::close);
            assertDoesNotThrow(lease::getJdbcUrl);
            lease.close();
            assertThrows(IllegalStateException.class, lease::getJdbcUrl);
        }
    }

    @Test
    void interruptedClonePreservesTheInterruptAndDoesNotConnect() throws Exception {
        var postgres = postgres();
        when(postgres.execInContainer(any(String[].class))).thenThrow(new InterruptedException("cancelled"));
        try {
            assertThrows(SQLException.class, () -> MigratedSchemaBaseline.cloneConnection(postgres, "interrupted"));
            assertTrue(Thread.currentThread().isInterrupted());
            verify(postgres, never()).getJdbcUrl();
        } finally {
            Thread.interrupted();
        }
    }

    @Test
    void invalidLabelsCannotStartContainersOrEscapeDatabaseArguments() throws Exception {
        var postgres = postgres();
        try (var pool = new MigratedSchemaBaseline.TemplatePool(() -> postgres, ignored -> {})) {
            for (String label : new String[] {"", "--help", "../db", "a".repeat(31), "UPPER"}) {
                assertThrows(IllegalArgumentException.class, () -> pool.open(label));
            }
            verify(postgres, never()).start();
        }
        assertThrows(IllegalArgumentException.class,
                () -> MigratedSchemaBaseline.cloneConnection(postgres, postgres.getDatabaseName()));
        verify(postgres, never()).execInContainer(any(String[].class));
    }

    private static Container.ExecResult execResult(int code, String stdout, String stderr) {
        return mock(Container.ExecResult.class, invocation -> switch (invocation.getMethod().getName()) {
            case "getExitCode" -> code;
            case "getStdout" -> stdout;
            case "getStderr" -> stderr;
            default -> RETURNS_DEFAULTS.answer(invocation);
        });
    }

    private static PostgreSQLContainer<?> postgres() throws Exception {
        PostgreSQLContainer<?> postgres = mock(PostgreSQLContainer.class);
        when(postgres.getDatabaseName()).thenReturn("template");
        when(postgres.getJdbcUrl()).thenReturn("jdbc:postgresql://localhost:54321/template?loggerLevel=OFF");
        when(postgres.getUsername()).thenReturn("test");
        when(postgres.getPassword()).thenReturn("test");
        when(postgres.execInContainer(any(String[].class))).thenReturn(execResult(0, "", ""));
        return postgres;
    }
}
