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

    /**
     * Native queries that select a single column return the scalar itself instead of a
     * one-element array; such rows are wrapped so callers can always index row[0].
     */
    public static List<Object[]> objectArrayRows(Query query) {
        List<?> rawRows = query.getResultList();
        List<Object[]> rows = new ArrayList<>(rawRows.size());
        for (Object rawRow : rawRows) {
            rows.add(rawRow instanceof Object[] array ? array : new Object[] {rawRow});
        }
        return rows;
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
