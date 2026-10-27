package com.uten.imp.common.export;

import com.uten.imp.common.report.ReportQueryKit;
import com.uten.imp.common.web.PageResponse;
import jakarta.persistence.EntityManager;
import org.springframework.data.domain.*;
import org.springframework.data.jpa.domain.Specification;
import org.springframework.data.jpa.repository.JpaSpecificationExecutor;
import org.springframework.data.jpa.repository.query.QueryUtils;
import org.springframework.transaction.support.TransactionSynchronizationManager;

import java.sql.Connection;
import java.util.*;
import java.util.function.BiFunction;
import java.util.function.Function;
import java.util.stream.Stream;

/** Reuse each master's original list predicate and DTO mapper without collecting its complete result. */
public final class MasterExportSource {
    public static final int PAGE_ROWS = 100;
    public static final int SYNCHRONOUS_MAX_ROWS = LegacyExportBudget.MAX_ROWS;
    private static final ThreadLocal<Cursor> CURRENT = new ThreadLocal<>();
    private MasterExportSource() { }

    /** Ordinary list requests keep their existing repository implementation and Page contract. */
    public static <T> Page<T> page(JpaSpecificationExecutor<T> repository, EntityManager em,
                                  Class<T> type, Specification<T> specification, Pageable pageable) {
        return page(repository, em, type, specification, pageable, null);
    }

    public static <T> Page<T> page(JpaSpecificationExecutor<T> repository, EntityManager em,
                                  Class<T> type, Specification<T> specification, Pageable pageable, Object filter) {
        Cursor cursor = CURRENT.get();
        return cursor == null ? repository.findAll(specification, pageable)
                : cursor.read(repository, em, type, specification, pageable, filter);
    }

    /** A worker's ExportPageSink consumes each immutable DTO batch before the next is read. */
    public static <T> ExportPayload exportEntities(EntityManager em, List<ExportColumn> columns, int maxRows,
            BiFunction<Integer, Integer, PageResponse<T>> loader, Function<T, Map<String,Object>> mapper) {
        Objects.requireNonNull(em); Objects.requireNonNull(loader); Objects.requireNonNull(mapper);
        List<ExportColumn> frozenColumns = List.copyOf(columns);
        ReportQueryKit.requireExportRowCount(maxRows, 0);
        if (TransactionSynchronizationManager.isActualTransactionActive()
                && !TransactionSynchronizationManager.isCurrentTransactionReadOnly())
            throw new IllegalStateException("A master export cannot join a write transaction");
        var sink = ExportPageSink.current();
        if (CURRENT.get() != null) throw new IllegalStateException("A master export cannot nest another source");
        Cursor cursor = sink != null || TransactionSynchronizationManager.isActualTransactionActive()
                ? new Cursor(em, maxRows, sink == null) : null;
        if (cursor != null) CURRENT.set(cursor);
        try {
            List<Map<String,Object>> collected = sink == null ? new ArrayList<>() : null;
            long expected = -1;
            int seen = 0;
            for (int page = 1; ; page++) {
                interrupted();
                PageResponse<T> result = loader.apply(page, PAGE_ROWS);
                if (result.getPage() != page || result.getSize() != PAGE_ROWS || result.getItems().size() > PAGE_ROWS)
                    throw new IllegalStateException("Master export pagination changed");
                if (expected < 0) {
                    expected = result.getTotal();
                    if (expected < 0) throw new IllegalStateException("Master export requires its initial count");
                    ReportQueryKit.requireExportRowCount(maxRows, expected);
                    if (sink == null && expected > SYNCHRONOUS_MAX_ROWS)
                        throw LegacyExportBudget.tooManyRows();
                } else if (result.getTotal() != expected) {
                    throw new IllegalStateException("Master export source count changed");
                }
                List<Map<String,Object>> rows = new ArrayList<>(result.getItems().size());
                for (T item : result.getItems()) {
                    interrupted();
                    rows.add(Collections.unmodifiableMap(new LinkedHashMap<>(mapper.apply(item))));
                }
                seen = Math.addExact(seen, rows.size());
                ReportQueryKit.requireExportRowCount(maxRows, seen);
                if (seen > expected || (rows.isEmpty() && seen < expected))
                    throw new IllegalStateException("Master export source is incomplete");
                if (sink == null) collected.addAll(rows);
                else sink.accept(new ExportPayload(frozenColumns, rows, seen));
                // All relationships have been resolved by the unchanged list DTO mapper.
                // Do not keep every exported entity in Hibernate's first-level cache.
                if (cursor != null) em.clear();
                if (seen == expected) return new ExportPayload(frozenColumns,
                        sink == null ? List.copyOf(collected) : List.of(), seen);
                if (rows.size() != PAGE_ROWS) throw new IllegalStateException("Master export source ended early");
            }
        } finally {
            try { if (cursor != null) cursor.close(); }
            finally { if (cursor != null) CURRENT.remove(); }
        }
    }

    private static void interrupted() {
        LegacyExportBudget.checkpoint();
    }

    private static final class Cursor implements AutoCloseable {
        final EntityManager em;
        final int maximum;
        final boolean synchronous;
        final Thread owner = Thread.currentThread();
        Class<?> type;
        Sort sort;
        Object filter;
        Stream<?> stream;
        Iterator<?> iterator;
        long total, consumed;
        int nextPage;
        boolean failed, closed;

        Cursor(EntityManager em, int maximum, boolean synchronous) {
            if (!TransactionSynchronizationManager.isActualTransactionActive()
                    || !TransactionSynchronizationManager.isCurrentTransactionReadOnly()
                    || !Integer.valueOf(Connection.TRANSACTION_REPEATABLE_READ).equals(
                            TransactionSynchronizationManager.getCurrentTransactionIsolationLevel()))
                throw new IllegalStateException("A master export requires its read-only repeatable-read snapshot");
            this.em = em; this.maximum = maximum; this.synchronous = synchronous;
        }

        @SuppressWarnings("unchecked")
        <T> Page<T> read(JpaSpecificationExecutor<T> repository, EntityManager requestedEm, Class<T> requestedType,
                         Specification<T> specification, Pageable pageable, Object requestedFilter) {
            interrupted();
            if (closed || failed || Thread.currentThread() != owner || requestedEm != em
                    || pageable.getPageNumber() != nextPage || pageable.getPageSize() != PAGE_ROWS)
                throw new IllegalStateException("Master export cursor sequence changed");
            try {
                if (type == null) {
                    type = requestedType; sort = pageable.getSort(); filter = freeze(requestedFilter);
                    total = repository.count(specification);
                    ReportQueryKit.requireExportRowCount(maximum, total);
                    if (synchronous && total > SYNCHRONOUS_MAX_ROWS) throw LegacyExportBudget.tooManyRows();
                    if (total > 0) {
                        var cb = em.getCriteriaBuilder();
                        var query = cb.createQuery(requestedType);
                        var root = query.from(requestedType);
                        var predicate = specification == null ? null : specification.toPredicate(root, query, cb);
                        query.select(root);
                        if (predicate != null) query.where(predicate);
                        if (sort.isSorted()) query.orderBy(QueryUtils.toOrders(sort, root, cb));
                        var orders = new ArrayList<>(query.getOrderList());
                        var identity = root.get("id");
                        if (orders.stream().noneMatch(order -> identity.equals(order.getExpression())))
                            orders.add(cb.asc(identity));
                        query.orderBy(orders);
                        var nativeQuery = em.createQuery(query).unwrap(org.hibernate.query.Query.class);
                        nativeQuery.setReadOnly(true).setCacheable(false).setFetchSize(PAGE_ROWS);
                        stream = nativeQuery.getResultStream();
                        iterator = stream.iterator();
                    }
                } else if (requestedType != type || !sort.equals(pageable.getSort()) || !Objects.equals(filter,freeze(requestedFilter))) {
                    throw new IllegalStateException("Master export cursor conditions changed");
                }
                List<T> rows = new ArrayList<>(PAGE_ROWS);
                int count = (int)Math.min(PAGE_ROWS, total - consumed);
                for (int index = 0; index < count; index++) {
                    interrupted();
                    if (!iterator.hasNext()) throw new IllegalStateException("Master export cursor ended early");
                    rows.add((T)iterator.next());
                }
                consumed += rows.size();
                // Never prefetch the next page's entity before em.clear(). It could
                // otherwise become detached before its lazy DTO fields are read.
                if (consumed == total && stream != null) {
                    if (iterator.hasNext()) throw new IllegalStateException("Master export count differs from its cursor");
                    stream.close(); stream = null;
                }
                nextPage++;
                return new PageImpl<>(rows, pageable, total);
            } catch (RuntimeException failure) {
                failed = true;
                closeStream();
                throw failure;
            }
        }

        private void closeStream() {
            if (stream != null) {
                Stream<?> current = stream; stream = null; current.close();
            }
        }
        @Override public void close() {
            if (Thread.currentThread() != owner) throw new IllegalStateException("Master export cursor belongs to another thread");
            if (closed) return;
            closed = true;
            try { closeStream(); } finally { em.clear(); }
        }
    }

    /** Freeze only parameter identity, never a second implementation of a business predicate. */
    private static Object freeze(Object value) {
        if (value == null || value instanceof String || value instanceof Number || value instanceof Boolean
                || value instanceof UUID || value instanceof Enum<?>) return value;
        if (value instanceof Set<?> set) {
            Set<Object> copy=new LinkedHashSet<>(); set.forEach(item->copy.add(freeze(item)));
            return Collections.unmodifiableSet(copy);
        }
        if (value instanceof Map<?,?> map) {
            Map<Object,Object> copy=new LinkedHashMap<>(); map.forEach((key,item)->copy.put(freeze(key),freeze(item)));
            return Collections.unmodifiableMap(copy);
        }
        if (value instanceof List<?> list) return Collections.unmodifiableList(list.stream().map(MasterExportSource::freeze).toList());
        if (value instanceof TableColumnProjection projection) {
            // Preserve the previous record's exact parameter identity. This
            // immutable selection DTO is the only non-record object admitted.
            List<Object> fields=new ArrayList<>(); fields.add(TableColumnProjection.class.getName());
            fields.add(freeze(projection.tableKey()));
            fields.add(freeze(projection.scope()));
            fields.add(freeze(projection.columns()));
            return Collections.unmodifiableList(fields);
        }
        if (value instanceof Record record) {
            List<Object> fields=new ArrayList<>(); fields.add(record.getClass().getName());
            try {
                for(var component:record.getClass().getRecordComponents()) fields.add(freeze(component.getAccessor().invoke(record)));
                return Collections.unmodifiableList(fields);
            } catch(ReflectiveOperationException failure) { throw new IllegalArgumentException("Master filter identity cannot be frozen"); }
        }
        throw new IllegalArgumentException("Unsupported master filter identity");
    }
}
