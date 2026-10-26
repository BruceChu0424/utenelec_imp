package com.uten.imp.common.export;

import java.util.Objects;
import java.util.concurrent.CancellationException;
import java.util.concurrent.TimeUnit;

/** Heartbeats long source validation/hash passes without inventing output rows or another authority. */
public final class ExportOperationCheckpoint implements AutoCloseable {
    private static final ThreadLocal<ExportOperationCheckpoint> CURRENT=new ThreadLocal<>();
    private final ExportOperationCheckpoint previous;
    private final Thread owner=Thread.currentThread();
    private final Runnable checkpoint;
    private final java.util.function.LongSupplier clock;
    private long lastCheck;
    private boolean closed,checked;
    private ExportOperationCheckpoint(Runnable checkpoint,java.util.function.LongSupplier clock) {
        this.checkpoint=Objects.requireNonNull(checkpoint);this.clock=Objects.requireNonNull(clock);previous=CURRENT.get();CURRENT.set(this);
    }
    public static ExportOperationCheckpoint open(Runnable checkpoint){return new ExportOperationCheckpoint(checkpoint,System::nanoTime);}
    static ExportOperationCheckpoint open(Runnable checkpoint,java.util.function.LongSupplier clock){return new ExportOperationCheckpoint(checkpoint,clock);}
    public static void check() {
        if(Thread.currentThread().isInterrupted())throw new CancellationException();
        LegacyExportBudget.checkpoint();
        var scope=CURRENT.get();
        if(scope==null)return;
        long now=scope.clock.getAsLong();
        if(!scope.checked||now-scope.lastCheck>=TimeUnit.SECONDS.toNanos(1)){
            scope.checkpoint.run();scope.lastCheck=now;scope.checked=true;
        }
    }
    @Override public void close() {
        if(Thread.currentThread()!=owner)throw new IllegalStateException("Export checkpoint belongs to another thread");
        if(closed)return;closed=true;
        if(previous==null)CURRENT.remove();else CURRENT.set(previous);
    }
}
