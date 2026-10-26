package com.uten.imp.common.report;

import com.uten.imp.common.util.NativeQueryResults;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.hibernate.query.NativeQuery;
import org.springframework.transaction.support.TransactionSynchronizationManager;

import java.sql.Connection;
import java.util.*;
import java.util.regex.Pattern;
import java.util.stream.Stream;

/**
 * One forward-only export query within the worker's existing snapshot. Domain loaders still map,
 * mask and authorize every returned batch. Ordinary reads retain their original SQL pagination.
 */
public final class ReportExportCursor implements AutoCloseable {
    private static final ThreadLocal<ReportExportCursor> CURRENT = new ThreadLocal<>();
    private static final Pattern PAGE = Pattern.compile(
            "(?is)\\s+LIMIT\\s+:(__limit|__l|limit|__groupLimit)\\s+OFFSET\\s+:(__offset|__o|offset|__groupOffset)\\s*$");
    private final ReportExportCursor previous;
    private final Thread owner = Thread.currentThread();
    private final Map<Query,String> applicationSql = new IdentityHashMap<>();
    private State state;
    private boolean closed;

    private ReportExportCursor() {
        if (!TransactionSynchronizationManager.isActualTransactionActive()
                || !TransactionSynchronizationManager.isCurrentTransactionReadOnly()
                || !Integer.valueOf(Connection.TRANSACTION_REPEATABLE_READ).equals(
                        TransactionSynchronizationManager.getCurrentTransactionIsolationLevel())) {
            throw new IllegalStateException("An export cursor requires its active read-only repeatable-read transaction");
        }
        previous = CURRENT.get();CURRENT.set(this);
    }

    public static ReportExportCursor open() { return new ReportExportCursor(); }

    /** Hibernate getQueryString exposes adjusted positional SQL; retain the application original explicitly. */
    public static Query query(EntityManager em, String sql) {
        Query query = em.createNativeQuery(sql);
        ReportExportCursor cursor = CURRENT.get();
        if (cursor != null) cursor.applicationSql.put(query, sql);
        return query;
    }

    public static List<Object[]> rows(EntityManager em, Query query) {
        ReportExportCursor cursor = CURRENT.get();
        return cursor == null ? NativeQueryResults.objectArrayRows(query) : cursor.read(em, query);
    }

    private List<Object[]> read(EntityManager em, Query query) {
        if (closed) throw new IllegalStateException("Export cursor is closed");
        try {
            if (Thread.currentThread().isInterrupted()) throw new java.util.concurrent.CancellationException();
            String paged = applicationSql.remove(query);
            if (paged == null) throw new IllegalStateException("Export cursor requires registered application SQL");
            var page = PAGE.matcher(paged);
            if (!page.find()) throw new IllegalStateException("Export query has no supported application pagination suffix");
            String limitName = page.group(1), offsetName = page.group(2);
            var parameters = query.getParameters();
            Set<String> names = new HashSet<>();
            for (var parameter : parameters) {
                if (parameter.getName() == null) throw new IllegalStateException("Export queries must use named application parameters");
                names.add(parameter.getName());
            }
            if (!names.contains(limitName) || !names.contains(offsetName)) {
                throw new IllegalStateException("Export query pagination bindings do not match its application SQL");
            }
            long requestedSize = ((Number) query.getParameterValue(limitName)).longValue();
            long offset = ((Number) query.getParameterValue(offsetName)).longValue();
            if (requestedSize < 1 || requestedSize > 500 || offset < 0) throw new IllegalStateException("Export query batch is out of bounds");
            int size = (int) requestedSize;
            String sql = paged.substring(0, page.start());
            Map<String,Object> bindings = new LinkedHashMap<>();
            for (var parameter : parameters) {
                String name = parameter.getName();
                if (name == null) throw new IllegalStateException("Export queries must use named application parameters");
                if (!name.equals(limitName) && !name.equals(offsetName)) {
                    Object value = query.getParameterValue(parameter);
                    if (value instanceof Set<?> set) value = Set.copyOf(set);
                    else if (value instanceof Collection<?> list) value = List.copyOf(list);
                    bindings.put(name, value);
                }
            }
            if (state == null) {
                if (offset != 0) throw new IllegalStateException("Export cursor must start at its first batch");
                Query unpaged = em.createNativeQuery(sql);
                bindings.forEach(unpaged::setParameter);
                NativeQuery<?> nativeQuery = unpaged.unwrap(NativeQuery.class);
                nativeQuery.setReadOnly(true).setFetchSize(500);
                Stream<?> stream = nativeQuery.getResultStream();
                try { state = new State(sql, bindings, size, stream, stream.iterator()); }
                catch (RuntimeException failure) { stream.close();throw failure; }
            }
            if (state.failed || !state.sql.equals(sql) || !state.bindings.equals(bindings)
                    || state.size != size || state.nextOffset != offset) {
                throw new IllegalStateException("Export query conditions or batch sequence changed");
            }
            List<Object[]> rows = new ArrayList<>(size);
            if (!state.exhausted) {
                while (rows.size() < size && state.iterator.hasNext()) {
                    Object row = state.iterator.next();rows.add(row instanceof Object[] array ? array : new Object[]{row});
                }
                if (rows.size() < size || !state.iterator.hasNext()) state.closeStream();
            }
            state.nextOffset += size;
            return rows;
        } catch (RuntimeException failure) {
            if (state != null) { state.failed = true;state.closeStream(); }
            throw failure;
        }
    }

    private static final class State {
        final String sql;
        final Map<String,Object> bindings;
        final int size;
        final Stream<?> stream;
        final Iterator<?> iterator;
        long nextOffset;
        boolean exhausted;
        boolean failed;
        State(String sql, Map<String,Object> bindings, int size, Stream<?> stream, Iterator<?> iterator) {
            this.sql = sql;this.bindings = new LinkedHashMap<>(bindings);this.size = size;
            this.stream = stream;this.iterator = iterator;
        }
        void closeStream() {
            if (!exhausted) { exhausted = true;stream.close(); }
        }
    }

    @Override public void close() {
        if (Thread.currentThread() != owner) throw new IllegalStateException("Export cursor belongs to another thread");
        if (closed) return;
        closed = true;
        try { if (state != null) state.closeStream(); }
        finally {
            applicationSql.clear();
            if (previous == null) CURRENT.remove();else CURRENT.set(previous);
        }
    }
}
