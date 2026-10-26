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
        validate(projection,scope);
        List<ExportDocument.Section> sections = new ArrayList<>();
        for (var section : document.sections()) {
            if (!section.name().equals(sectionName)) { sections.add(section); continue; }
            var result=projectSection(section.columns(),section.rows(),projection,scope);
            sections.add(new ExportDocument.Section(section.name(),result.columns(),result.rows()));
        }
        return new ExportDocument(document.title(),document.metadata(),sections);
    }
    private static void validate(TableColumnProjection projection,String scope) {
        if (scope == null || !scope.startsWith("view_")) throw new IllegalArgumentException("Frozen document projection requires a display scope");
        if (projection.columns() == null || projection.columns().isEmpty() || projection.columns().size() > 160)
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "请至少选择一列导出，最多 160 列");
        if (projection.columns().stream().anyMatch(column -> column == null || column.key() == null))
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "导出列无效");
    }
    private ExportPayload projectSection(List<ExportColumn> columns,List<Map<String,Object>> rows,TableColumnProjection projection,String scope) {
            Map<String, ExportColumn> available = new HashMap<>(); columns.forEach(c -> available.put(c.key(), c));
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
            return projections.project(columns, rows,
                    new TableColumnProjection(projection.tableKey(), projection.scope(), selected), scope);
    }
    /** The same frozen-fact projection, applied to bounded pages of only the original target section. */
    public DocumentPageSink.Consumer stream(DocumentPageSink.Consumer destination,TableColumnProjection projection,String sectionName,String scope) {
        if(projection==null)return destination;
        validate(projection,scope);
        return new DocumentPageSink.Consumer() {
            private final Map<String,DocumentPageSink.Section> sources=new HashMap<>();
            private final Map<String,List<ExportColumn>> projectedColumns=new HashMap<>();
            private boolean begun;
            public void begin(DocumentPageSink.Header header) {
                if(begun)throw new IllegalStateException("Document projection header already supplied");begun=true;
                List<DocumentPageSink.Section> sections=new ArrayList<>();
                for(var section:header.sections()) {
                    sources.put(section.id(),section);
                    if(!section.name().equals(sectionName)) {sections.add(section);continue;}
                    var selected=projectSection(section.columns(),List.of(),projection,scope).columns();
                    projectedColumns.put(section.id(),selected);
                    sections.add(new DocumentPageSink.Section(section.id(),section.name(),selected,section.primary(),section.omitIfEmpty()));
                }
                destination.begin(new DocumentPageSink.Header(header.title(),header.metadata(),sections,header.expectedPrimaryRows()));
            }
            public void accept(DocumentPageSink.Page page) {
                var original=sources.get(page.sectionId());
                if(!begun||original==null)throw new IllegalStateException("Document projection source section is unknown");
                if(!projectedColumns.containsKey(page.sectionId())) {destination.accept(page);return;}
                var selected=projectSection(original.columns(),page.rows(),projection,scope);
                if(!projectedColumns.get(page.sectionId()).equals(selected.columns()))throw new IllegalStateException("Document projection columns changed");
                destination.accept(new DocumentPageSink.Page(page.sectionId(),selected.rows()));
            }
        };
    }
}
