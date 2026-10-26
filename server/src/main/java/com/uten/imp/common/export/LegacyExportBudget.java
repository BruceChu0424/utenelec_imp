package com.uten.imp.common.export;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Component;

import java.util.concurrent.CancellationException;
import java.util.concurrent.Semaphore;
import java.util.concurrent.TimeUnit;

/** One synchronous export operation, acquired before request decoding/query work.
 * File/temp limits remain owned by ExportResourceLimits/ExportTemporaryBudget. */
@Component
public final class LegacyExportBudget {
    public static final int MAX_ROWS = 500;
    private static final ThreadLocal<Operation> CURRENT = new ThreadLocal<>();
    private final Semaphore slots;

    public LegacyExportBudget(@Value("${uten.security.export-max-concurrent:2}") int concurrency) {
        slots = new Semaphore(Math.max(1, concurrency), true);
    }

    public Scope open() { return acquire(true, MAX_ROWS); }

    /** Explicit existing single-object file contract, never a client override. */
    public Scope openNatural(int maximumRows) {
        if (maximumRows < 1) throw new IllegalArgumentException("Natural export bound must be positive");
        return acquire(true, maximumRows);
    }

    /** Existing artifact and payroll downloads share the same physical slots,
     * but are not a new 500-row source query. */
    public Scope openDownload() { return acquire(false, Integer.MAX_VALUE); }

    private Scope acquire(boolean legacy, int maximumRows) {
        if (!slots.tryAcquire()) throw new ApiException(ErrorCode.RATE_LIMITED, "导出任务繁忙，请稍后重试；本次尚未开始读取");
        Operation previous = CURRENT.get();
        Operation operation = new Operation(legacy, maximumRows, System.nanoTime());
        CURRENT.set(operation);
        return new Scope(previous, operation);
    }

    public static boolean active() {
        Operation current = CURRENT.get();
        return current != null && current.legacy()
                && ExportPageSink.current() == null && DocumentPageSink.current() == null;
    }

    public static int maximumRows(int configured) { return active() ? Math.min(configured, CURRENT.get().maximumRows()) : configured; }

    public static void requireRows(long actual) {
        checkpoint();
        if (active() && actual > CURRENT.get().maximumRows()) {
            if (CURRENT.get().maximumRows() == MAX_ROWS) throw tooManyRows();
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "单据超过完整文件边界，请核对原业务文件范围；本次未生成文件");
        }
    }

    public static ApiException tooManyRows() {
        return new ApiException(ErrorCode.VALIDATION_FAILED, "同步导出最多 500 行，请使用后台导出任务或收窄筛选；本次未生成文件");
    }

    public static void checkpoint() {
        if (Thread.currentThread().isInterrupted()) throw new CancellationException();
        Operation current = CURRENT.get();
        if (current != null && current.legacy()
                && System.nanoTime() - current.startedAt() > TimeUnit.MINUTES.toNanos(2)) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "同步导出处理超时，请使用后台导出任务；本次未生成文件");
        }
    }

    private record Operation(boolean legacy, int maximumRows, long startedAt) { }

    public final class Scope implements AutoCloseable {
        private final Operation previous, operation;
        private boolean closed;
        private Scope(Operation previous, Operation operation) { this.previous = previous; this.operation = operation; }
        @Override public void close() {
            if (closed) return;
            closed = true;
            if (CURRENT.get() == operation) {
                if (previous == null) CURRENT.remove(); else CURRENT.set(previous);
            }
            slots.release();
        }
    }
}
