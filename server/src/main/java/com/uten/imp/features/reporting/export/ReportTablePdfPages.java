package com.uten.imp.features.reporting.export;

import com.uten.imp.common.export.*;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import org.springframework.stereotype.Component;

import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.function.Consumer;

/** Adapts authoritative table batches to the existing disk-backed PDF writer. */
@Component
public class ReportTablePdfPages {
    private final ExportTableProjectionService projections;

    public ReportTablePdfPages(ExportTableProjectionService projections) { this.projections=projections; }

    public Pages open(StreamingDocumentWriter writer,TableColumnProjection projection,String scope,String title) {
        return new Pages(writer,projection,scope,title);
    }

    public final class Pages implements Consumer<ExportPayload> {
        private final StreamingDocumentWriter writer;
        private final TableColumnProjection projection;
        private final ExportRowSelection selection;
        private final String scope,title;
        private List<ExportColumn> columns;
        private Map<String,Object> metadata;
        private boolean completed;

        private Pages(StreamingDocumentWriter writer,TableColumnProjection projection,String scope,String title) {
            this.writer=Objects.requireNonNull(writer);this.projection=projection;
            this.selection=new ExportRowSelection(projection);this.scope=scope;this.title=title;
        }

        @Override public void accept(ExportPayload page) {
            if(completed)throw new IllegalStateException("PDF table source has ended");
            if(page.layout()!=null)throw new ApiException(ErrorCode.VALIDATION_FAILED,"原件版式请使用Excel格式导出");
            var rows=selection.select(page.columns(),page.rows());
            ExportPayload projected=projection==null?new ExportPayload(page.columns(),rows,rows.size())
                    :projections.project(page.columns(),rows,projection,scope);
            if(columns==null) {
                columns=List.copyOf(projected.columns());metadata=page.documentMetadata();
                writer.begin(new DocumentPageSink.Header(title,
                        metadata.entrySet().stream().map(entry->entry.getKey()+"："+Objects.toString(entry.getValue(),"")).toList(),
                        List.of(new DocumentPageSink.Section("data","明细",columns,true,false))));
            } else if(!columns.equals(projected.columns())||!metadata.equals(page.documentMetadata()))
                throw new IllegalStateException("PDF table columns or document metadata changed during export");
            for(int start=0;start<projected.rows().size();start+=200)
                writer.accept(new DocumentPageSink.Page("data",projected.rows().subList(start,Math.min(start+200,projected.rows().size()))));
        }

        public boolean begun() { return columns!=null; }

        public void complete() {
            if(completed)return;
            selection.verifyComplete();
            if(!begun())throw new IllegalStateException("PDF table source did not provide its columns");
            completed=true;
        }
    }
}
