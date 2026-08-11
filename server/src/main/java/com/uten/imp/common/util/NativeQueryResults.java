package com.uten.imp.common.util;

import jakarta.persistence.Query;

import java.util.ArrayList;
import java.util.List;

/**
 * Type-checks the raw result lists exposed by JPA native queries at their boundary.
 */
public final class NativeQueryResults {

    private NativeQueryResults() {
    }

    public static List<Object[]> objectArrayRows(Query query) {
        return typedRows(query, Object[].class);
    }

    public static <T> List<T> typedRows(Query query, Class<T> rowType) {
        List<?> rawRows = query.getResultList();
        List<T> rows = new ArrayList<>(rawRows.size());
        for (Object rawRow : rawRows) {
            rows.add(rowType.cast(rawRow));
        }
        return rows;
    }
}
