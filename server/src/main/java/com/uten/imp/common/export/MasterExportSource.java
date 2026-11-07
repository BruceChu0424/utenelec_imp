package com.uten.imp.common.export;

import com.uten.imp.common.report.ReportQueryKit;
import com.uten.imp.common.readsnapshot.BoundedMasterReadSource;
import com.uten.imp.common.web.PageResponse;
import jakarta.persistence.EntityManager;
import org.springframework.data.domain.*;
import org.springframework.data.jpa.domain.Specification;
import org.springframework.data.jpa.repository.JpaSpecificationExecutor;
import org.springframework.transaction.support.TransactionSynchronizationManager;

import java.util.*;
import java.util.function.BiFunction;
import java.util.function.Function;

/** Reuse each master's original list predicate and DTO mapper without collecting its complete result. */
public final class MasterExportSource {
    public static final int PAGE_ROWS = BoundedMasterReadSource.BATCH_ROWS;
    private MasterExportSource() { }

    /** Ordinary list requests keep their existing repository implementation and Page contract. */
    public static <T> Page<T> page(JpaSpecificationExecutor<T> repository, EntityManager em,
                                  Class<T> type, Specification<T> specification, Pageable pageable) {
        return page(repository, em, type, specification, pageable, null);
    }

    public static <T> Page<T> page(JpaSpecificationExecutor<T> repository, EntityManager em,
                                  Class<T> type, Specification<T> specification, Pageable pageable, Object filter) {
        specification = MasterExportSelection.intersect(specification);
        return BoundedMasterReadSource.page(repository, em, type, specification, pageable, filter);
    }

    /** A worker's ExportPageSink consumes each immutable DTO batch before the next is read. */
    public static <T> ExportPayload exportEntities(EntityManager em, List<ExportColumn> columns,
            BiFunction<Integer, Integer, PageResponse<T>> loader, Function<T, Map<String,Object>> mapper) {
        Objects.requireNonNull(em); Objects.requireNonNull(loader); Objects.requireNonNull(mapper);
        List<ExportColumn> frozenColumns = List.copyOf(columns);
        ReportQueryKit.requireExportRowCount(0);
        if (TransactionSynchronizationManager.isActualTransactionActive()
                && !TransactionSynchronizationManager.isCurrentTransactionReadOnly())
            throw new IllegalStateException("A master export cannot join a write transaction");
        var sink = ExportPageSink.current();
        if (BoundedMasterReadSource.active()) throw new IllegalStateException("A master export cannot nest another source");
        BoundedMasterReadSource.Session cursor = sink != null || TransactionSynchronizationManager.isActualTransactionActive()
                ? BoundedMasterReadSource.open(em, MasterExportSource::interrupted, total -> {
                    MasterExportSelection.requireComplete(total);
                    ReportQueryKit.requireExportRowCount(total);
                }) : null;
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
                    MasterExportSelection.requireComplete(expected);
                    ReportQueryKit.requireExportRowCount(expected);
                } else if (result.getTotal() != expected) {
                    throw new IllegalStateException("Master export source count changed");
                }
                List<Map<String,Object>> rows = new ArrayList<>(result.getItems().size());
                for (T item : result.getItems()) {
                    interrupted();
                    rows.add(Collections.unmodifiableMap(new LinkedHashMap<>(mapper.apply(item))));
                }
                seen = Math.addExact(seen, rows.size());
                ReportQueryKit.requireExportRowCount(seen);
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
            if (cursor != null) cursor.close();
        }
    }

    private static void interrupted() {
        LegacyExportBudget.checkpoint();
    }

}
