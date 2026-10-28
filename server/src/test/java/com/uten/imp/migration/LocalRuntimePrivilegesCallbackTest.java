package com.uten.imp.migration;

import org.flywaydb.core.api.FlywayException;
import org.flywaydb.core.api.callback.Context;
import org.flywaydb.core.api.callback.Event;
import org.junit.jupiter.api.Test;

import java.sql.Connection;
import java.sql.DatabaseMetaData;
import java.sql.Statement;
import java.sql.ResultSet;
import java.util.HashMap;
import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.mockito.ArgumentMatchers.contains;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.*;

class LocalRuntimePrivilegesCallbackTest {
    @Test
    void preparesDefaultsBeforeAnEmptyNewSchemaCanFreezeFunctionAcls() throws Exception {
        Fixture fixture = fixture("uten_migrator", "jdbc:postgresql://127.0.0.1:5434/uten_imp");
        freshCatalog(fixture, true, true, true);
        var callback = new LocalRuntimePrivilegesCallback("uten");
        assertThat(callback.supports(Event.BEFORE_MIGRATE, fixture.context)).isTrue();
        callback.handle(Event.BEFORE_MIGRATE, fixture.context);
        verify(fixture.statement).execute(contains("$local_runtime_privileges$"));
        verify(fixture.results.get("catalog")).close();
        verify(fixture.results.get("history"), never()).close();
    }

    @Test
    void anEmptyFlywayHistoryTableStillBelongsToTheFirstMigration() throws Exception {
        Fixture fixture = fixture("uten_migrator", "jdbc:postgresql://127.0.0.1:5434/uten_imp");
        freshCatalog(fixture, false, true, true);
        new LocalRuntimePrivilegesCallback("uten").handle(Event.BEFORE_MIGRATE, fixture.context);
        verify(fixture.statement).execute(contains("$local_runtime_privileges$"));
        verify(fixture.results.get("catalog")).close();
        verify(fixture.results.get("history")).close();
    }

    @Test
    void existingApplicationObjectsOrMigrationHistoryNeverReceivePreMigrationAclWrites() throws Exception {
        Fixture existing = fixture("uten_migrator", "jdbc:postgresql://127.0.0.1:5434/uten_imp");
        freshCatalog(existing, true, false, true);
        new LocalRuntimePrivilegesCallback("uten").handle(Event.BEFORE_MIGRATE, existing.context);
        verify(existing.statement, never()).execute(anyString());
        verify(existing.results.get("catalog")).close();
        verify(existing.results.get("history"), never()).close();
        Fixture historical = fixture("uten_migrator", "jdbc:postgresql://127.0.0.1:5434/uten_imp");
        freshCatalog(historical, false, true, false);
        new LocalRuntimePrivilegesCallback("uten").handle(Event.BEFORE_MIGRATE, historical.context);
        verify(historical.statement, never()).execute(anyString());
        verify(historical.results.get("catalog")).close();
        verify(historical.results.get("history")).close();
    }

    @Test
    void runsAfterNoOpMigrateBeforeApplicationReadsPermissionCatalog() throws Exception {
        Fixture fixture = fixture("uten_migrator", "jdbc:postgresql://127.0.0.1:5434/uten_imp");
        LocalRuntimePrivilegesCallback callback = new LocalRuntimePrivilegesCallback("uten");
        assertThat(callback.supports(Event.AFTER_MIGRATE, fixture.context)).isTrue();
        assertThat(callback.supports(Event.AFTER_MIGRATE_ERROR, fixture.context)).isFalse();
        callback.handle(Event.AFTER_MIGRATE, fixture.context);
        verify(fixture.statement).execute(contains("$local_runtime_privileges$"));
    }

    @Test
    void leavesSingleAccountDevelopmentUnchanged() throws Exception {
        Fixture fixture = fixture("uten", "jdbc:postgresql://127.0.0.1:5434/uten_imp");
        new LocalRuntimePrivilegesCallback("uten").handle(Event.AFTER_MIGRATE, fixture.context);
        verify(fixture.connection, never()).createStatement();
    }

    @Test
    void refusesRemoteDatabaseBeforeAnyAclWrite() throws Exception {
        Fixture fixture = fixture("uten_migrator", "jdbc:postgresql://company.example:5432/uten_imp");
        assertThrows(FlywayException.class, () -> new LocalRuntimePrivilegesCallback("uten")
                .handle(Event.AFTER_MIGRATE, fixture.context));
        verify(fixture.connection, never()).createStatement();
    }

    @Test
    void refusesDifferentDatabaseAndUnreviewedRolePairs() throws Exception {
        for (String url : new String[]{"jdbc:postgresql://127.0.0.1:5434/another_db",
                "jdbc:postgresql://127.0.0.1.evil.example/uten_imp"}) {
            Fixture fixture = fixture("uten_migrator", url);
            assertThrows(FlywayException.class, () -> new LocalRuntimePrivilegesCallback("uten")
                    .handle(Event.AFTER_MIGRATE, fixture.context));
            verify(fixture.connection, never()).createStatement();
        }
        Fixture fixture = fixture("postgres", "jdbc:postgresql://127.0.0.1:5434/uten_imp");
        assertThrows(FlywayException.class, () -> new LocalRuntimePrivilegesCallback("uten")
                .handle(Event.AFTER_MIGRATE, fixture.context));
        verify(fixture.connection, never()).createStatement();
    }

    @Test
    void failedMigrationsNeverRunTheGrantReconciliation() throws Exception {
        Fixture fixture = fixture("uten_migrator", "jdbc:postgresql://127.0.0.1:5434/uten_imp");
        new LocalRuntimePrivilegesCallback("uten").handle(Event.AFTER_MIGRATE_ERROR, fixture.context);
        verify(fixture.connection, never()).getMetaData();
        verify(fixture.connection, never()).createStatement();
    }

    private Fixture fixture(String user, String url) throws Exception {
        Context context = mock(Context.class);
        Connection connection = mock(Connection.class);
        DatabaseMetaData metadata = mock(DatabaseMetaData.class);
        Map<String, ResultSet> results = new HashMap<>();
        Statement statement = mock(Statement.class, call -> {
            if (call.getMethod().getName().equals("executeQuery")) {
                String sql = call.getArgument(0);
                if (sql.contains("to_regclass")) {
                    return results.get("catalog");
                }
                if (sql.contains("FROM public.flyway_schema_history")) {
                    return results.get("history");
                }
                throw new AssertionError("Unexpected schema probe: " + sql);
            }
            return RETURNS_DEFAULTS.answer(call);
        });
        when(context.getConnection()).thenReturn(connection);
        when(connection.getMetaData()).thenReturn(metadata);
        when(metadata.getUserName()).thenReturn(user);
        when(metadata.getURL()).thenReturn(url);
        when(connection.createStatement()).thenReturn(statement);
        return new Fixture(context, connection, statement, results);
    }

    private void freshCatalog(Fixture fixture, boolean historyAbsent, boolean emptySchema,
            boolean emptyHistory) throws Exception {
        ResultSet catalog = mock(ResultSet.class);
        when(catalog.next()).thenReturn(true);
        when(catalog.getBoolean(1)).thenReturn(historyAbsent);
        when(catalog.getBoolean(2)).thenReturn(emptySchema);
        ResultSet history = mock(ResultSet.class);
        when(history.next()).thenReturn(true);
        when(history.getBoolean(1)).thenReturn(emptyHistory);
        fixture.results.put("catalog", catalog);
        fixture.results.put("history", history);
    }

    private record Fixture(Context context, Connection connection, Statement statement, Map<String, ResultSet> results) { }
}
