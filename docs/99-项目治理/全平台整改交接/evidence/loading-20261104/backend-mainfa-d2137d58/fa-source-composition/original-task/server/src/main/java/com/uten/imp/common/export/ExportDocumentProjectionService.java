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
        var selection=new ExportRowSelection(projection);
        List<ExportDocument.Section> sections = new ArrayList<>();
        int targets=0;
        for (var section : document.sections()) {
            if (!section.name().equals(sectionName)) { if(!selection.active())sections.add(section); continue; }
            targets++;
            if(selection.active()&&targets>1)throw invalidSelection();
            var result=projectSection(section.columns(),selection.select(section.columns(),section.rows()),projection,scope);
            sections.add(new ExportDocument.Section(section.name(),result.columns(),result.rows()));
        }
        selection.verifyComplete();
        if(selection.active()&&targets!=1)throw invalidSelection();
        return new ExportDocument(selection.active()?selectedTitle(document.title(),projection):document.title(),
                selection.active()?selectedMetadata(document.metadata(),projection):document.metadata(),sections);
    }
    private static String selectedTitle(String title,TableColumnProjection projection) {return title+"（已选 "+projection.rowSelection().size()+" 项）";}
    private static List<String> selectedMetadata(List<String> original,TableColumnProjection projection) {
        List<String> result=new ArrayList<>(original);result.add("输出范围：仅选中 "+projection.rowSelection().size()+" 项");return List.copyOf(result);
    }
    private static ApiException invalidSelection() {return new ApiException(ErrorCode.VALIDATION_FAILED,"选中行的目标分表不存在或不唯一，请刷新后重选");}
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
        var selection=new ExportRowSelection(projection);
        return new DocumentPageSink.Consumer() {
            private final Map<String,DocumentPageSink.Section> sources=new HashMap<>();
            private final Map<String,List<ExportColumn>> projectedColumns=new HashMap<>();
            private boolean begun,completed,failed;
            @Override
            public void begin(DocumentPageSink.Header header) {
                if(begun)throw new IllegalStateException("Document projection header already supplied");begun=true;
                List<DocumentPageSink.Section> sections=new ArrayList<>();
                int targets=0;
                for(var section:header.sections()) {
                    sources.put(section.id(),section);
                    if(!section.name().equals(sectionName)) {if(!selection.active())sections.add(section);continue;}
                    targets++;
                    if(selection.active()&&targets>1)throw invalidSelection();
                    var selected=projectSection(section.columns(),List.of(),projection,scope).columns();
                    projectedColumns.put(section.id(),selected);
                    sections.add(new DocumentPageSink.Section(section.id(),section.name(),selected,selection.active()||section.primary(),selection.active()?false:section.omitIfEmpty()));
                }
                if(selection.active()&&targets!=1)throw invalidSelection();
                destination.begin(new DocumentPageSink.Header(selection.active()?selectedTitle(header.title(),projection):header.title(),
                        selection.active()?selectedMetadata(header.metadata(),projection):header.metadata(),sections,
                        selection.active()?projection.rowSelection().size():header.expectedPrimaryRows()));
            }
            @Override
            public void accept(DocumentPageSink.Page page) {
                var original=sources.get(page.sectionId());
                if(!begun||completed||failed||original==null)throw new IllegalStateException("Document projection source section is unknown or ended");
                if(!projectedColumns.containsKey(page.sectionId())) {if(!selection.active())destination.accept(page);return;}
                ExportPayload selected;
                try {selected=projectSection(original.columns(),selection.select(original.columns(),page.rows()),projection,scope);}
                catch(RuntimeException failure){failed=true;throw failure;}
                if(!projectedColumns.get(page.sectionId()).equals(selected.columns()))throw new IllegalStateException("Document projection columns changed");
                destination.accept(new DocumentPageSink.Page(page.sectionId(),selected.rows()));
            }
            @Override public void complete() {
                if(completed)return;completed=true;
                if(failed)throw new ApiException(ErrorCode.VALIDATION_FAILED,"选中行输出未完成，不能生成文件，请刷新后重选");
                if(!begun)throw new IllegalStateException("Document projection header was not supplied");
                selection.verifyComplete();destination.complete();
            }
        };
    }
}
