package com.uten.imp.migration;

import org.flywaydb.core.api.FlywayException;
import org.flywaydb.core.api.callback.Callback;
import org.flywaydb.core.api.callback.Context;
import org.flywaydb.core.api.callback.Event;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.context.annotation.Profile;
import org.springframework.core.io.ClassPathResource;
import org.springframework.stereotype.Component;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.sql.Connection;
import java.sql.SQLException;
import java.sql.Statement;
import java.util.regex.Pattern;

/** Prepares fresh split-role defaults, then verifies runtime ACLs after migrations. */
@Component
@Profile("dev")
public final class LocalRuntimePrivilegesCallback implements Callback {
    private static final Pattern LOCAL_DATABASE = Pattern.compile(
            "jdbc:postgresql://(?:127\\.0\\.0\\.1|localhost|\\[::1\\])(?::[0-9]+)?/uten_imp(?:\\?.*)?");
    private final String runtimeUser;

    public LocalRuntimePrivilegesCallback(@Value("${spring.datasource.username}") String runtimeUser) {
        this.runtimeUser = runtimeUser;
    }

    @Override
    public boolean supports(Event event, Context context) {
        return event == Event.BEFORE_MIGRATE || event == Event.AFTER_MIGRATE;
    }

    @Override
    public boolean canHandleInTransaction(Event event, Context context) {
        return true;
    }

    @Override
    public void handle(Event event, Context context) {
        if (event != Event.BEFORE_MIGRATE && event != Event.AFTER_MIGRATE) {
            return;
        }
        try {
            Connection connection = context.getConnection();
            String migrator = connection.getMetaData().getUserName();
            // Single-account development has no separate runtime ACL to repair.
            if (runtimeUser.equals(migrator)) {
                return;
            }
            if (!"uten".equals(runtimeUser) || !"uten_migrator".equals(migrator)
                    || !LOCAL_DATABASE.matcher(connection.getMetaData().getURL()).matches()) {
                throw new FlywayException("Local runtime ACL reconciliation requires the reviewed loopback split-role database");
            }
            // New functions must inherit their ordinary runtime EXECUTE before
            // an immutable installer captures its catalog seal. Existing or
            // partially migrated application databases retain AFTER_MIGRATE only.
            if (event == Event.BEFORE_MIGRATE && !freshApplicationSchema(connection)) {
                return;
            }
            String sql = new ClassPathResource("db/local-runtime-privileges.sql")
                    .getContentAsString(StandardCharsets.UTF_8);
            try (Statement statement = connection.createStatement()) {
                statement.execute(sql);
            }
        } catch (SQLException | IOException exception) {
            throw new FlywayException("Unable to reconcile local runtime database privileges", exception);
        }
    }

    private static boolean freshApplicationSchema(Connection connection) throws SQLException {
        try (Statement statement = connection.createStatement()) {
            boolean historyAbsent;
            try (var result = statement.executeQuery("""
                    SELECT to_regclass('public.flyway_schema_history') IS NULL,
                           NOT EXISTS (
                             SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
                             WHERE n.nspname='public' AND c.relkind IN ('r','p','v','m','S','f')
                               AND c.relname<>'flyway_schema_history'
                               AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.classid='pg_class'::regclass
                                   AND d.objid=c.oid AND d.deptype='e'))
                    """)) {
                if (!result.next()) throw new SQLException("Missing fresh-schema catalog evidence");
                if (!result.getBoolean(2)) return false;
                historyAbsent = result.getBoolean(1);
            }
            if (historyAbsent) return true;
            try (var result = statement.executeQuery("SELECT NOT EXISTS (SELECT 1 FROM public.flyway_schema_history)")) {
                if (!result.next()) throw new SQLException("Missing fresh-schema migration history evidence");
                return result.getBoolean(1);
            }
        }
    }

    @Override
    public String getCallbackName() {
        return "local-runtime-privileges";
    }
}
