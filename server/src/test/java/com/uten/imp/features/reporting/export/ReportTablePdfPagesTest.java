package com.uten.imp.features.reporting.export;

import com.uten.imp.common.export.*;
import com.uten.imp.common.platformcolumns.PlatformColumnService;
import com.uten.imp.common.web.ApiException;
import org.apache.pdfbox.Loader;
import org.apache.pdfbox.text.PDFTextStripper;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.OutputStream;
import java.math.BigDecimal;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.stream.IntStream;

import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.mock;

class ReportTablePdfPagesTest {
    @TempDir Path directory;
    private static final List<ExportColumn> COLUMNS=List.of(
            new ExportColumn("id","系统标识",ExportColumn.TEXT),
            new ExportColumn("name","名称",ExportColumn.TEXT),
            new ExportColumn("quantity","原始数量",ExportColumn.QTY));
    private final ReportTablePdfPages adapter=new ReportTablePdfPages(new ExportTableProjectionService(mock(PlatformColumnService.class)));

    private static List<Map<String,Object>> rows(int from,int to) {
        return IntStream.range(from,to).mapToObj(i->Map.<String,Object>of("id",Integer.toString(i),
                "name","货品-"+i,"quantity",new BigDecimal("12345678901234567890.123456789"))).toList();
    }

    @Test void moreThanFiveHundredRowsRetainEveryIdentityAndExactProjectionInBoundedPages() {
        var writer=new CapturedWriter();
        var projection=new TableColumnProjection("master.goods","master_goods",List.of(
                new TableColumnProjection.Column("name","货品原文",180d,ExportColumn.TEXT,null),
                new TableColumnProjection.Column("quantity","原始数量",200d,ExportColumn.QTY,null)));
        var pages=adapter.open(writer,projection,"master_goods","货品资料");
        for(int start=0;start<1001;start+=500)pages.accept(new ExportPayload(COLUMNS,rows(start,Math.min(start+500,1001)),1001));
        pages.complete();
        assertThat(writer.header.sections().getFirst().columns()).extracting(ExportColumn::key).containsExactly("name","quantity");
        assertThat(writer.pages).allSatisfy(page->assertThat(page.rows()).hasSizeLessThanOrEqualTo(200));
        var result=writer.pages.stream().flatMap(page->page.rows().stream()).toList();
        assertThat(result).hasSize(1001);
        assertThat(result).extracting(row->row.get("id")).containsExactlyElementsOf(IntStream.range(0,1001).mapToObj(Integer::toString).toList());
        assertThat(result).allSatisfy(row->assertThat(row.get("quantity")).isEqualTo(new BigDecimal("12345678901234567890.123456789")));
    }

    @Test void selectedRowsBeyondTheFirstBatchUseAuthoritativeValuesAndMissingRowsRejectTheFile() {
        var selection=List.of(Map.of("id","500"),Map.of("id","700"));
        var projection=new TableColumnProjection("master.goods","master_goods",List.of(
                new TableColumnProjection.Column("name","名称",180d,ExportColumn.TEXT,null)),selection);
        var writer=new CapturedWriter();var pages=adapter.open(writer,projection,"master_goods","货品资料");
        pages.accept(new ExportPayload(COLUMNS,rows(0,500),501));
        pages.accept(new ExportPayload(COLUMNS,rows(500,501),501));
        assertThat(writer.pages).flatExtracting(DocumentPageSink.Page::rows).extracting(row->row.get("name")).containsExactly("货品-500");
        assertThatThrownBy(pages::complete).isInstanceOf(ApiException.class).hasMessageContaining("选中记录已变化");
    }

    @Test void realPdfContainsRowsAfterTheFormerFiveHundredBoundaryAndCleansItsSpool() throws Exception {
        try(var writer=new TabularPdfExportService().openDocumentStream(directory);var output=new ByteArrayOutputStream()) {
            var projection=new TableColumnProjection("master.goods","master_goods",List.of(new TableColumnProjection.Column("name","名称",180d,ExportColumn.TEXT,null)));
            var pages=adapter.open(writer,projection,"master_goods","货品资料");
            pages.accept(new ExportPayload(COLUMNS,rows(0,500),501));pages.accept(new ExportPayload(COLUMNS,rows(500,501),501));pages.complete();
            assertThat(writer.primaryRowCount()).isEqualTo(501);
            writer.finish(output);
            try(var document=Loader.loadPDF(output.toByteArray())) {
                String text=new PDFTextStripper().getText(document);
                for(int i=0;i<501;i++)assertThat(text).contains("货品-"+i);
            }
        }
        try(var files=Files.list(directory)){assertThat(files).isEmpty();}
    }

    @Test void realPdfBeyondSixtyThousandCellsKeepsAllSourceIdentitiesAndReleasesTemporaryFiles() throws Exception {
        var columns=IntStream.range(0,10).mapToObj(i->new ExportColumn("c"+i,"来源列"+i,ExportColumn.TEXT)).toList();
        int count=6001;
        try(var writer=new TabularPdfExportService().openDocumentStream(directory);var output=new ByteArrayOutputStream()) {
            var pages=adapter.open(writer,null,"view_sales","完整来源记录");
            for(int start=0;start<count;start+=500) {
                var values=IntStream.range(start,Math.min(start+500,count)).mapToObj(index->{
                    Map<String,Object> row=new java.util.LinkedHashMap<>();
                    row.put("c0",String.format(java.util.Locale.ROOT,"ROW-%05d",index));
                    for(int column=1;column<10;column++)row.put("c"+column,"原文"+column);
                    return row;
                }).toList();
                pages.accept(new ExportPayload(columns,values,count));
            }
            pages.complete();assertThat(writer.primaryRowCount()).isEqualTo(count);
            assertThat(writer.rowCount()).isEqualTo(count);
            writer.finish(output);
            try(var document=Loader.loadPDF(output.toByteArray())) {
                String text=new PDFTextStripper().getText(document);
                var identities=java.util.regex.Pattern.compile("ROW-([0-9]{5})").matcher(text).results()
                        .map(match->Integer.parseInt(match.group(1))).toList();
                assertThat(identities).containsExactlyElementsOf(IntStream.range(0,count).boxed().toList());
                for(int column=1;column<10;column++)assertThat(text).contains("原文"+column);
            }
        }
        try(var files=Files.list(directory)){assertThat(files).isEmpty();}
    }

    @Test void emptyResultsKeepTheirAuthorizedHeadersAndRejectChangedSourceMetadata() {
        var writer=new CapturedWriter();var pages=adapter.open(writer,null,"view_sales","销售报表");
        pages.accept(new ExportPayload(COLUMNS,List.of(),0));pages.complete();
        assertThat(writer.header.sections().getFirst().columns()).isEqualTo(COLUMNS);
        assertThat(writer.pages).isEmpty();
        assertThatThrownBy(()->pages.accept(new ExportPayload(COLUMNS,rows(0,1),1))).isInstanceOf(IllegalStateException.class);
        var another=adapter.open(new CapturedWriter(),null,"view_sales","销售报表");
        another.accept(new ExportPayload(COLUMNS,rows(0,1),2).withDocumentMetadata(Map.of("版本","original")));
        assertThatThrownBy(()->another.accept(new ExportPayload(COLUMNS,rows(1,2),2).withDocumentMetadata(Map.of("版本","changed"))))
                .isInstanceOf(IllegalStateException.class).hasMessageContaining("metadata changed");
    }

    private static final class CapturedWriter implements StreamingDocumentWriter {
        DocumentPageSink.Header header;
        final List<DocumentPageSink.Page> pages=new ArrayList<>();
        @Override public void begin(DocumentPageSink.Header value){assertThat(header).isNull();header=value;}
        @Override public void accept(DocumentPageSink.Page value){pages.add(value);}
        @Override public long primaryRowCount(){return pages.stream().mapToLong(page->page.rows().size()).sum();}
        @Override public long rowCount(){return primaryRowCount();}
        @Override public void finish(OutputStream output)throws IOException { }
        @Override public void close() { }
    }
}
