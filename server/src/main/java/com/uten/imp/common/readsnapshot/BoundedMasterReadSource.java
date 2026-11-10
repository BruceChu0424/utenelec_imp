package com.uten.imp.common.readsnapshot;

import com.uten.imp.common.export.TableColumnProjection;
import jakarta.persistence.EntityManager;
import org.springframework.data.domain.*;
import org.springframework.data.jpa.domain.Specification;
import org.springframework.data.jpa.repository.JpaSpecificationExecutor;
import org.springframework.data.jpa.repository.query.QueryUtils;
import org.springframework.transaction.support.TransactionSynchronizationManager;

import java.sql.Connection;
import java.util.*;
import java.util.function.LongConsumer;
import java.util.stream.Stream;

/** One counted, sorted database cursor shared by complete reads and exports.
 * Each owner supplies its own authority, deadline and total-row policy. Each
 * batch continues exactly where the cursor stands: exports keep 100-row batches,
 * progressive complete reads take 50, 50, 100, 200s, then 1000 rows per batch. */
public final class BoundedMasterReadSource {
    public static final int BATCH_ROWS = 100;
    public static final int MAX_BATCH_ROWS = com.uten.imp.common.web.CompleteReadBatchPlan.MAX_BATCH_SIZE;
    private static final ThreadLocal<Session> CURRENT = new ThreadLocal<>();
    private BoundedMasterReadSource() { }

    public static boolean active() { return CURRENT.get() != null; }

    public static Session open(EntityManager em, Runnable checkpoint, LongConsumer countPolicy) {
        if (active()) throw new IllegalStateException("A master read cannot nest another source");
        Session session = new Session(em, checkpoint, countPolicy);
        CURRENT.set(session);
        return session;
    }

    public static <T> Page<T> page(JpaSpecificationExecutor<T> repository, EntityManager em,
            Class<T> type, Specification<T> specification, Pageable pageable, Object filter) {
        Session cursor = CURRENT.get();
        return cursor == null ? repository.findAll(specification, pageable)
                : cursor.read(repository, em, type, specification, pageable, filter);
    }

    /**
     * Stream-invariant facts of one counted cursor (scope, category subtree, keyword
     * plan) are computed once per snapshot instead of once per 100-row batch. The
     * cursor already rejects any filter change, and the repeatable-read snapshot
     * keeps the facts stable. Outside a cursor the supplier runs every time.
     */
    @SuppressWarnings("unchecked")
    public static <V> V memo(Object key, java.util.function.Supplier<V> supplier) {
        Session cursor = CURRENT.get();
        if (cursor == null) return supplier.get();
        if (Thread.currentThread() != cursor.owner) throw new IllegalStateException("Master read owner changed");
        if (cursor.memo.containsKey(key)) return (V) cursor.memo.get(key);
        V value = supplier.get();
        cursor.memo.put(key, value);
        return value;
    }

    /**
     * Id-to-label lookups reuse what earlier batches of the same snapshot loaded and
     * query only the ids not seen yet (misses are remembered too). Values must be
     * plain facts, never managed entities: each batch clears the persistence context.
     */
    @SuppressWarnings("unchecked")
    public static <K, V> Map<K, V> lookup(Object domain, Collection<K> keys,
            java.util.function.Function<Collection<K>, Map<K, V>> loader) {
        Session cursor = CURRENT.get();
        if (cursor == null) return loader.apply(keys);
        if (Thread.currentThread() != cursor.owner) throw new IllegalStateException("Master read owner changed");
        Map<K, V> cache = (Map<K, V>) cursor.lookups.computeIfAbsent(domain, ignored -> new HashMap<>());
        List<K> missing = keys.stream().filter(Objects::nonNull).filter(key -> !cache.containsKey(key)).distinct().toList();
        if (!missing.isEmpty()) {
            Map<K, V> loaded = loader.apply(missing);
            for (K key : missing) cache.put(key, loaded.get(key));
        }
        Map<K, V> result = new HashMap<>();
        for (K key : keys) {
            if (key == null) continue;
            V value = cache.get(key);
            if (value != null) result.put(key, value);
        }
        return result;
    }

    public static final class Session implements AutoCloseable {
        final EntityManager em;
        final Runnable checkpoint;
        final LongConsumer countPolicy;
        final Thread owner = Thread.currentThread();
        final Map<Object, Object> memo = new HashMap<>();
        final Map<Object, Map<?, ?>> lookups = new HashMap<>();
        Class<?> type;
        Sort sort;
        Object filter;
        Stream<?> stream;
        Iterator<?> iterator;
        long total, consumed;
        boolean failed, closed;

        private Session(EntityManager em, Runnable checkpoint, LongConsumer countPolicy) {
            if (!TransactionSynchronizationManager.isActualTransactionActive()
                    || !TransactionSynchronizationManager.isCurrentTransactionReadOnly()
                    || !Integer.valueOf(Connection.TRANSACTION_REPEATABLE_READ).equals(
                            TransactionSynchronizationManager.getCurrentTransactionIsolationLevel()))
                throw new IllegalStateException("A master read requires its read-only repeatable-read snapshot");
            this.em = Objects.requireNonNull(em);
            this.checkpoint = Objects.requireNonNull(checkpoint);
            this.countPolicy = Objects.requireNonNull(countPolicy);
        }

        @SuppressWarnings("unchecked")
        <T> Page<T> read(JpaSpecificationExecutor<T> repository, EntityManager requestedEm, Class<T> requestedType,
                Specification<T> specification, Pageable pageable, Object requestedFilter) {
            checkpoint.run();
            // The next batch must start exactly at the cursor: no skipped or repeated row.
            if (closed || failed || Thread.currentThread() != owner || requestedEm != em
                    || pageable.getOffset() != consumed || pageable.getPageSize() < 1
                    || pageable.getPageSize() > MAX_BATCH_ROWS)
                throw new IllegalStateException("Master read cursor sequence changed");
            try {
                if (type == null) {
                    type = requestedType; sort = pageable.getSort(); filter = freeze(requestedFilter);
                    total = repository.count(specification);
                    if (total < 0) throw new IllegalStateException("Master read requires its initial count");
                    countPolicy.accept(total);
                    checkpoint.run();
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
                        nativeQuery.setReadOnly(true).setCacheable(false).setFetchSize(BATCH_ROWS);
                        stream = nativeQuery.getResultStream();
                        iterator = stream.iterator();
                    }
                } else if (requestedType != type || !sort.equals(pageable.getSort())
                        || !Objects.equals(filter, freeze(requestedFilter))) {
                    throw new IllegalStateException("Master read cursor conditions changed");
                }
                int count = (int)Math.min(pageable.getPageSize(), total - consumed);
                List<T> rows = new ArrayList<>(Math.max(count, 0));
                for (int index = 0; index < count; index++) {
                    checkpoint.run();
                    if (!iterator.hasNext()) throw new IllegalStateException("Master read cursor ended early");
                    rows.add((T)iterator.next());
                }
                consumed += rows.size();
                // Do not prefetch an entity across the owner's em.clear() boundary.
                if (consumed == total && stream != null) {
                    if (iterator.hasNext()) throw new IllegalStateException("Master read count differs from its cursor");
                    closeStream();
                }
                return new PageImpl<>(rows, pageable, total);
            } catch (RuntimeException failure) {
                failed = true;
                closeStream();
                throw failure;
            }
        }

        /** Call only after the owning DTO mapper and consumer finish the batch. */
        public void clearBatch() {
            if (closed || Thread.currentThread() != owner) throw new IllegalStateException("Master read owner changed");
            checkpoint.run();
            em.clear();
        }

        private void closeStream() {
            if (stream != null) {
                Stream<?> current = stream; stream = null; current.close();
            }
        }
        @Override public void close() {
            if (Thread.currentThread() != owner) throw new IllegalStateException("Master read cursor belongs to another thread");
            if (closed) return;
            closed = true;
            try { closeStream(); }
            finally {
                try { em.clear(); }
                finally { if (CURRENT.get() == this) CURRENT.remove(); }
            }
        }
    }

    /** Freeze parameters only. Business predicates remain in their original owners. */
    private static Object freeze(Object value) {
        if (value == null || value instanceof String || value instanceof Number || value instanceof Boolean
                || value instanceof UUID || value instanceof Enum<?>) return value;
        if (value instanceof Set<?> set) {
            Set<Object> copy = new LinkedHashSet<>(); set.forEach(item -> copy.add(freeze(item)));
            return Collections.unmodifiableSet(copy);
        }
        if (value instanceof Map<?,?> map) {
            Map<Object,Object> copy = new LinkedHashMap<>(); map.forEach((key,item) -> copy.put(freeze(key),freeze(item)));
            return Collections.unmodifiableMap(copy);
        }
        if (value instanceof List<?> list) return Collections.unmodifiableList(list.stream().map(BoundedMasterReadSource::freeze).toList());
        if (value instanceof TableColumnProjection projection) {
            List<Object> fields = new ArrayList<>(); fields.add(projection.getClass().getName());
            fields.add(freeze(projection.tableKey())); fields.add(freeze(projection.scope()));
            fields.add(freeze(projection.columns())); fields.add(freeze(projection.rowSelection()));
            return Collections.unmodifiableList(fields);
        }
        if (value instanceof Record record) {
            List<Object> fields = new ArrayList<>(); fields.add(record.getClass().getName());
            try {
                for (var component : record.getClass().getRecordComponents()) {
                    var accessor = component.getAccessor();
                    if (!accessor.canAccess(record) && !accessor.trySetAccessible())
                        throw new IllegalArgumentException("Master filter record accessor is unavailable");
                    fields.add(freeze(accessor.invoke(record)));
                }
                return Collections.unmodifiableList(fields);
            } catch (ReflectiveOperationException failure) { throw new IllegalArgumentException("Master filter identity cannot be frozen"); }
        }
        throw new IllegalArgumentException("Unsupported master filter identity");
    }
}
