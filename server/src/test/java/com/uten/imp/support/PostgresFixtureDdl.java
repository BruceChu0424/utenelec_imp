package com.uten.imp.support;

import org.springframework.jdbc.core.ConnectionCallback;
import org.springframework.jdbc.core.JdbcTemplate;

import java.sql.Connection;
import java.sql.SQLException;
import java.util.Arrays;

/** Test-only DDL from reviewed literal templates; PostgreSQL quotes every identifier/value. */
public final class PostgresFixtureDdl {
    private PostgresFixtureDdl() { }

    public static void execute(JdbcTemplate database, String template, Object... values) {
        database.execute((ConnectionCallback<Void>) connection -> {
            execute(connection, template, values);
            return null;
        });
    }

    public static void execute(Connection connection, String template, Object... values) throws SQLException {
        int parameters = 0;
        for (int i = 0; i < template.length(); i++) {
            if (template.charAt(i) != '%') continue;
            if (++i == template.length()) throw new IllegalArgumentException("Incomplete fixture DDL directive");
            char directive = template.charAt(i);
            if (directive == '%') continue;
            if (directive != 'I' && directive != 'L') {
                throw new IllegalArgumentException("Fixture DDL permits only quoted %I/%L directives");
            }
            parameters++;
        }
        if (parameters != values.length) throw new IllegalArgumentException("Fixture DDL argument count mismatch");
        String[] arguments = Arrays.stream(values).map(value -> value == null ? null : value.toString())
                .toArray(String[]::new);
        var array = connection.createArrayOf("text", arguments);
        String ddl;
        try (var formatter = connection.prepareStatement("SELECT format(?::text, VARIADIC ?::text[])")) {
            formatter.setString(1, template);
            formatter.setArray(2, array);
            try (var row = formatter.executeQuery()) {
                if (!row.next()) throw new SQLException("PostgreSQL fixture DDL formatter returned no row");
                ddl = row.getString(1);
            }
        } finally {
            array.free();
        }
        try (var statement = connection.createStatement()) {
            statement.execute(ddl);
        }
    }
}
