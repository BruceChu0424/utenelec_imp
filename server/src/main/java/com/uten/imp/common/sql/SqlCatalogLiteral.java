package com.uten.imp.common.sql;

import java.util.Objects;

/**
 * PostgreSQL text literals for server-owned SQL catalogs, never ordinary request values.
 * Business values belong in prepared-query parameters. Catalog expressions sometimes
 * need literal CASE arms; escape both quote and backslash explicitly so their meaning
 * does not depend on the connection's standard_conforming_strings setting.
 */
public final class SqlCatalogLiteral {
    private SqlCatalogLiteral() {}

    public static String text(String value) {
        Objects.requireNonNull(value, "catalog text");
        if (value.indexOf('\0') >= 0) {
            throw new IllegalArgumentException("PostgreSQL catalog text cannot contain NUL");
        }
        return "E'" + value.replace("\\", "\\\\").replace("'", "''") + "'";
    }
}
