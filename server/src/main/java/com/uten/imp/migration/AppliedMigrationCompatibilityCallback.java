package com.uten.imp.migration;

import org.flywaydb.core.api.FlywayException;
import org.flywaydb.core.api.MigrationInfo;
import org.flywaydb.core.api.callback.Callback;
import org.flywaydb.core.api.callback.Context;
import org.flywaydb.core.api.callback.Event;
import org.springframework.stereotype.Component;

import java.sql.SQLException;
import java.sql.Statement;
import java.util.Set;

/**
 * Preserves immutable migration bytes while safely rehearsing trigger-heavy upgrades.
 *
 * <p>V260, V263 and V273 were applied before their non-empty upgrade edge cases were
 * discovered. Their checksums are therefore immutable. For only those migration
 * transactions, deferred constraint triggers run immediately and V201's existing
 * transaction-local arrival-decision window authorizes migration-owned snapshot or
 * reference backfills. No trigger or constraint is disabled.</p>
 */
@Component
public final class AppliedMigrationCompatibilityCallback implements Callback {

    private static final Set<String> GUARDED_MIGRATIONS = Set.of("260", "263", "273");

    @Override
    public boolean supports(Event event, Context context) {
        if (event != Event.BEFORE_EACH_MIGRATE) {
            return false;
        }
        MigrationInfo migration = context.getMigrationInfo();
        return migration != null
                && migration.getVersion() != null
                && GUARDED_MIGRATIONS.contains(migration.getVersion().getVersion());
    }

    @Override
    public boolean canHandleInTransaction(Event event, Context context) {
        return true;
    }

    @Override
    public void handle(Event event, Context context) {
        try (Statement statement = context.getConnection().createStatement()) {
            statement.execute("SET CONSTRAINTS ALL IMMEDIATE");
            statement.execute(
                    "SELECT set_config('app.procurement_arrival_decision', 'on', true)");
        } catch (SQLException exception) {
            throw new FlywayException(
                    "Unable to prepare the immutable trigger-heavy migration transaction",
                    exception);
        }
    }

    @Override
    public String getCallbackName() {
        return "applied-migration-trigger-compatibility";
    }
}
