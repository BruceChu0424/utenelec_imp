package com.uten.imp.migration;

import org.flywaydb.core.api.FlywayException;
import org.flywaydb.core.api.MigrationInfo;
import org.flywaydb.core.api.MigrationVersion;
import org.flywaydb.core.api.callback.Context;
import org.flywaydb.core.api.callback.Event;
import org.flywaydb.core.api.configuration.Configuration;
import org.junit.jupiter.api.Test;

import java.sql.Connection;
import java.sql.ResultSet;
import java.sql.Statement;

import static org.junit.jupiter.api.Assertions.assertDoesNotThrow;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

class AuditFreshStartGuardCallbackTest {

    @Test
    void emptyFlywayHistoryAllowsV425DuringTheSameMigrateRun() throws Exception {
        AuditFreshStartGuardCallback callback = new AuditFreshStartGuardCallback();
        Context context = context(0);

        callback.handle(Event.BEFORE_MIGRATE, context);

        assertDoesNotThrow(() -> callback.handle(Event.BEFORE_EACH_MIGRATE, context));
        callback.handle(Event.AFTER_MIGRATE, context);
    }

    @Test
    void anyExistingFlywayHistoryBlocksV425AndThereforeTheFollowingV426() throws Exception {
        AuditFreshStartGuardCallback callback = new AuditFreshStartGuardCallback();
        Context context = context(424);

        callback.handle(Event.BEFORE_MIGRATE, context);

        assertThrows(
                FlywayException.class,
                () -> callback.handle(Event.BEFORE_EACH_MIGRATE, context));
        callback.handle(Event.AFTER_MIGRATE_ERROR, context);
    }

    @Test
    void missingBeforeMigrateStateFailsClosedAndErrorCleanupDoesNotLeak() throws Exception {
        AuditFreshStartGuardCallback callback = new AuditFreshStartGuardCallback();
        Context context = context(0);

        assertThrows(
                FlywayException.class,
                () -> callback.handle(Event.BEFORE_EACH_MIGRATE, context));
        callback.handle(Event.BEFORE_MIGRATE, context);
        callback.handle(Event.AFTER_MIGRATE_ERROR, context);
        assertThrows(
                FlywayException.class,
                () -> callback.handle(Event.BEFORE_EACH_MIGRATE, context));
    }

    @Test
    void missingHistoryTableFailsClosedInsteadOfPretendingTheChainIsFresh()
            throws Exception {
        Context context = context(0);
        when(context.getConnection().createStatement().executeQuery(
                "SELECT count(*) FROM \"public\".\"flyway_schema_history\""))
                .thenThrow(new java.sql.SQLException("missing", "42P01"));

        assertThrows(
                FlywayException.class,
                () -> new AuditFreshStartGuardCallback()
                        .handle(Event.BEFORE_MIGRATE, context));
    }

    @Test
    void historyCountWithoutARowFailsClosed() throws Exception {
        Context context = context(0);
        when(context.getConnection().createStatement().executeQuery(
                "SELECT count(*) FROM \"public\".\"flyway_schema_history\""))
                .thenReturn(mock(ResultSet.class));

        assertThrows(
                FlywayException.class,
                () -> new AuditFreshStartGuardCallback()
                        .handle(Event.BEFORE_MIGRATE, context));
    }

    private Context context(long appliedCount) throws Exception {
        Context context = mock(Context.class);
        Configuration configuration = mock(Configuration.class);
        Connection connection = mock(Connection.class);
        Statement statement = mock(Statement.class);
        ResultSet rows = mock(ResultSet.class);
        MigrationInfo migration = mock(MigrationInfo.class);
        when(context.getConfiguration()).thenReturn(configuration);
        when(configuration.getTable()).thenReturn("flyway_schema_history");
        when(configuration.getDefaultSchema()).thenReturn("public");
        when(context.getConnection()).thenReturn(connection);
        when(connection.createStatement()).thenReturn(statement);
        when(statement.executeQuery(
                "SELECT count(*) FROM \"public\".\"flyway_schema_history\""))
                .thenReturn(rows);
        when(rows.next()).thenReturn(true);
        when(rows.getLong(1)).thenReturn(appliedCount);
        when(context.getMigrationInfo()).thenReturn(migration);
        when(migration.getVersion()).thenReturn(MigrationVersion.fromVersion("425"));
        return context;
    }
}
