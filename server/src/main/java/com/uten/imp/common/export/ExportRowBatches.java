package com.uten.imp.common.export;

import com.uten.imp.common.report.ReportQueryKit;

import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.concurrent.CancellationException;
import java.util.function.Consumer;

/** Bounded output for calculated reports which produce rows rather than return SQL pages. */
public final class ExportRowBatches implements Consumer<Map<String, Object>> {
    private final List<ExportColumn> columns;
    private final int maximum;
    private final Consumer<ExportPayload> sink;
    private final List<Map<String, Object>> buffer = new ArrayList<>(500);
    private int total;
    private boolean finished;

    public ExportRowBatches(List<ExportColumn> columns, int maximum) {
        ReportQueryKit.requireExportRowCount(maximum, 0);
        this.columns = List.copyOf(columns);
        this.maximum = maximum;
        sink = Objects.requireNonNull(ExportPageSink.current(), "Calculated report export needs an active sink");
    }

    @Override public void accept(Map<String, Object> row) {
        if (finished) throw new IllegalStateException("Report output is already finished");
        try {
            if (Thread.currentThread().isInterrupted()) throw new CancellationException();
            ReportQueryKit.requireExportRowCount(maximum, (long) total + 1);
            buffer.add(row);total++;
            if (buffer.size() == 500) flush();
        } catch (RuntimeException failure) {
            finished = true;buffer.clear();throw failure;
        }
    }

    private void flush() {
        sink.accept(new ExportPayload(columns, List.copyOf(buffer), total));
        buffer.clear();
    }

    public int finish() {
        if (finished) throw new IllegalStateException("Report output is already finished");
        finished = true;
        if (!buffer.isEmpty() || total == 0) flush();
        return total;
    }
}
