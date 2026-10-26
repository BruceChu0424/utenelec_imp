package com.uten.imp.common.report;

import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.function.Consumer;

/** Retains one bounded page while a calculated report walks its complete authority. */
public final class ReportRowWindow implements Consumer<Map<String, Object>> {
    private final int page;
    private final int size;
    private final long offset;
    private final List<Map<String, Object>> rows;
    private long count;

    public ReportRowWindow(int page, int size) {
        this.page = Math.max(1, page);
        this.size = Math.min(500, Math.max(1, size));
        offset = (long) (this.page - 1) * this.size;
        rows = new ArrayList<>(this.size);
    }

    @Override public void accept(Map<String, Object> row) {
        if (count >= offset && count < offset + size) rows.add(row);
        count++;
    }

    public List<Map<String, Object>> rows() { return List.copyOf(rows); }
    public int page() { return page; }
    public int size() { return size; }
    public long count() { return count; }
}
