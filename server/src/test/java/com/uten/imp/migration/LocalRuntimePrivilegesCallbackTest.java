package com.uten.imp.migration;

import org.flywaydb.core.api.FlywayException;
import org.flywaydb.core.api.callback.Context;
import org.flywaydb.core.api.callback.Event;
import org.junit.jupiter.api.Test;

import java.sql.Connection;
import java.sql.DatabaseMetaData;
import java.sql.Statement;

import static org.assertj.core.api.Assertions.assertThat;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.mockito.ArgumentMatchers.contains;
import static org.mockito.Mockito.*;

class LocalRuntimePrivilegesCallbackTest {
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
        Statement statement = mock(Statement.class);
        when(context.getConnection()).thenReturn(connection);
        when(connection.getMetaData()).thenReturn(metadata);
        when(metadata.getUserName()).thenReturn(user);
        when(metadata.getURL()).thenReturn(url);
        when(connection.createStatement()).thenReturn(statement);
        return new Fixture(context, connection, statement);
    }

    private record Fixture(Context context, Connection connection, Statement statement) { }
}
