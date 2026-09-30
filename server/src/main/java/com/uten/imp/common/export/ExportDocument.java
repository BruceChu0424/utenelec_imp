package com.uten.imp.common.export;

import java.util.List;
import java.util.Map;
import java.util.Objects;

/** An already-authorized, immutable tabular snapshot shared by Excel and PDF. */
public record ExportDocument(String title, List<String> metadata, List<Section> sections) {
    public ExportDocument {
        title = Objects.requireNonNull(title);
        metadata = List.copyOf(metadata);
        sections = List.copyOf(sections);
        if (sections.isEmpty() || sections.size() > 16) throw new IllegalArgumentException("导出分表数应为 1 到 16");
    }

    public record Section(String name, List<ExportColumn> columns, List<Map<String, Object>> rows) {
        public Section {
            name = Objects.requireNonNull(name);
            columns = List.copyOf(columns);
            if (columns.isEmpty() || columns.size() > 160) throw new IllegalArgumentException("导出列数应为 1 到 160");
            if (rows.size() > 50_000) throw new IllegalArgumentException("单次导出最多 50000 行");
            // Null cell values are meaningful (unknown amounts), so Map.copyOf is inappropriate.
            rows = rows.stream().map(row -> java.util.Collections.unmodifiableMap(
                    new java.util.LinkedHashMap<>(row))).toList();
        }
    }
}
