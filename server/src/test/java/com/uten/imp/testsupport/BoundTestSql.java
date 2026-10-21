package com.uten.imp.testsupport;

import java.sql.PreparedStatement;
import java.sql.SQLException;
import java.sql.Statement;

/** Binds fixture values on the caller's existing transaction without owning its connection. */
public final class BoundTestSql {
    private BoundTestSql() { }

    /** The caller must close the returned statement, normally in its result-set resource scope. */
    public static PreparedStatement prepare(Statement context, String sql, Object... values) throws SQLException {
        PreparedStatement bound = context.getConnection().prepareStatement(sql);
        try {
            for (int index = 0; index < values.length; index++) {
                bound.setObject(index + 1, values[index]);
            }
            return bound;
        } catch (SQLException | RuntimeException | Error failure) {
            try {
                bound.close();
            } catch (SQLException cleanup) {
                failure.addSuppressed(cleanup);
            }
            throw failure;
        }
    }

    public static boolean execute(Statement context, String sql, Object... values) throws SQLException {
        try (var bound = prepare(context, sql, values)) {
            return bound.execute();
        }
    }
}
