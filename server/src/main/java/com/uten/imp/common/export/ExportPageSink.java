package com.uten.imp.common.export;

import java.util.Objects;
import java.util.function.Consumer;

/** A scoped, synchronous page consumer. A worker owns both the scope and its file writer. */
public final class ExportPageSink implements AutoCloseable {
    private static final ThreadLocal<Consumer<ExportPayload>> CURRENT = new ThreadLocal<>();
    private final Consumer<ExportPayload> previous;
    private final Thread owner = Thread.currentThread();
    private boolean closed;

    private ExportPageSink(Consumer<ExportPayload> sink) {
        previous = CURRENT.get();
        CURRENT.set(Objects.requireNonNull(sink));
    }

    public static ExportPageSink open(Consumer<ExportPayload> sink) { return new ExportPageSink(sink); }
    public static Consumer<ExportPayload> current() { return CURRENT.get(); }

    @Override public void close() {
        if (Thread.currentThread() != owner) throw new IllegalStateException("Export scope belongs to another thread");
        if (closed) return;
        closed = true;
        if (previous == null) CURRENT.remove(); else CURRENT.set(previous);
    }
}
