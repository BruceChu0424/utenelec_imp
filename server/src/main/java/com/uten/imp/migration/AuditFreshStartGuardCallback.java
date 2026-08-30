package com.uten.imp.migration;

import org.flywaydb.core.api.FlywayException;
import org.flywaydb.core.api.MigrationInfo;
import org.flywaydb.core.api.callback.Callback;
import org.flywaydb.core.api.callback.Context;
import org.flywaydb.core.api.callback.Event;
import org.springframework.stereotype.Component;

import java.sql.ResultSet;
import java.sql.SQLException;
import java.sql.Statement;
import java.util.Set;

/**
 * Fails closed before destructive V425 unless this migrate run started from a
 * genuinely empty Flyway history. There is intentionally no environment flag
 * or runtime authorization bypass.
 */
@Component
public final class AuditFreshStartGuardCallback implements Callback {

    private static final String GUARDED_VERSION = "425";
    private static final Set<Event> CLEANUP_EVENTS = Set.of(
            Event.AFTER_MIGRATE,
            Event.AFTER_MIGRATE_ERROR,
            Event.AFTER_MIGRATE_OPERATION_FINISH);
    private final ThreadLocal<Boolean> freshChain = new ThreadLocal<>();

    @Override
    public boolean supports(Event event, Context context) {
        if (event == Event.BEFORE_MIGRATE || CLEANUP_EVENTS.contains(event)) {
            return true;
        }
        if (event != Event.BEFORE_EACH_MIGRATE) {
            return false;
        }
        MigrationInfo migration = context.getMigrationInfo();
        return migration != null
                && migration.getVersion() != null
                && GUARDED_VERSION.equals(migration.getVersion().getVersion());
    }

    @Override
    public boolean canHandleInTransaction(Event event, Context context) {
        return false;
    }

    @Override
    public void handle(Event event, Context context) {
        if (event == Event.BEFORE_MIGRATE) {
            freshChain.remove();
            freshChain.set(appliedMigrationCount(context) == 0);
            return;
        }
        if (CLEANUP_EVENTS.contains(event)) {
            freshChain.remove();
            return;
        }
        if (event == Event.BEFORE_EACH_MIGRATE
                && !Boolean.TRUE.equals(freshChain.get())) {
            throw new FlywayException(
                    "V425 audit fresh-start is allowed only when this migrate run "
                            + "started with zero applied Flyway migrations");
        }
    }

    private long appliedMigrationCount(Context context) {
        String table = safeIdentifier(context.getConfiguration().getTable());
        String schema = context.getConfiguration().getDefaultSchema();
        String qualified = schema == null || schema.isBlank()
                ? quote(table)
                : quote(safeIdentifier(schema)) + "." + quote(table);
        try (Statement statement = context.getConnection().createStatement();
             ResultSet rows = statement.executeQuery(
                     "SELECT count(*) FROM " + qualified)) {
            if (!rows.next()) {
                throw new FlywayException(
                        "Flyway history count query returned no row");
            }
            return rows.getLong(1);
        } catch (SQLException exception) {
            throw new FlywayException(
                    "Unable to verify Flyway history before guarded audit migration",
                    exception);
        }
    }

    private String safeIdentifier(String value) {
        if (value == null || !value.matches("[A-Za-z_][A-Za-z0-9_]*")) {
            throw new FlywayException("Unsafe Flyway history identifier");
        }
        return value;
    }

    private String quote(String value) {
        return "\"" + value + "\"";
    }

    @Override
    public String getCallbackName() {
        return "audit-fresh-start-guard";
    }
}
