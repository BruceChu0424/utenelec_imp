package com.uten.imp.common.export;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

/** Display formulas may read frozen document facts, never current business record values. */
@Service
@RequiredArgsConstructor
public class ExportDocumentProjectionService {
    private final ExportTableProjectionService projections;
    public ExportDocument project(ExportDocument document, TableColumnProjection projection, String sectionName, String scope) {
        if (projection == null) return document;
        if (scope == null || !scope.startsWith("view_")) throw new IllegalArgumentException("Frozen document projection requires a display scope");
        if (projection.columns() == null || projection.columns().isEmpty() || projection.columns().size() > 160)
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "请至少选择一列导出，最多 160 列");
        if (projection.columns().stream().anyMatch(column -> column == null || column.key() == null))
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "导出列无效");
        List<ExportDocument.Section> sections = new ArrayList<>();
        for (var section : document.sections()) {
            if (!section.name().equals(sectionName)) { sections.add(section); continue; }
            Map<String, ExportColumn> available = new HashMap<>(); section.columns().forEach(c -> available.put(c.key(), c));
            List<TableColumnProjection.Column> selected = new ArrayList<>();
            for (var column : projection.columns()) {
                if (column.key().startsWith("platform:")) selected.add(new TableColumnProjection.Column(
                        column.key(), null, column.width(), null, null));
                else if (available.containsKey(column.key())) {
                    var canonical = available.get(column.key());
                    selected.add(new TableColumnProjection.Column(canonical.key(), canonical.label(), column.width(), canonical.type(), null));
                }
            }
            if (selected.isEmpty()) throw new ApiException(ErrorCode.VALIDATION_FAILED, "下载表头与成本快照不匹配");
            var result = projections.project(section.columns(), section.rows(),
                    new TableColumnProjection(projection.tableKey(), projection.scope(), selected), scope);
            sections.add(new ExportDocument.Section(section.name(), result.columns(), result.rows()));
        }
        return new ExportDocument(document.title(), document.metadata(), sections);
    }
}
