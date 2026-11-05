package com.uten.imp.common.export;

import com.uten.imp.common.platformcolumns.PlatformColumnService;
import com.uten.imp.common.web.ApiException;
import org.apache.pdfbox.Loader;
import org.apache.pdfbox.text.PDFTextStripper;
import org.apache.poi.xssf.usermodel.XSSFWorkbook;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.io.TempDir;
import java.io.*;
import java.math.BigDecimal;
import java.nio.file.*;
import java.util.*;
import java.util.concurrent.CancellationException;
import java.util.stream.IntStream;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.*;

class SelectedDocumentProjectionTest {
    @TempDir Path directory;
    private final List<ExportColumn> columns=List.of(new ExportColumn("code","编号",ExportColumn.TEXT),
            new ExportColumn("name","名称",ExportColumn.TEXT),new ExportColumn("qty","原始数量",ExportColumn.QTY));
    private final ExportDocumentProjectionService projections=new ExportDocumentProjectionService(
            new ExportTableProjectionService(mock(PlatformColumnService.class)));
    @AfterEach void clearInterrupt(){Thread.interrupted();}
    private Map<String,Object> row(int i){return Map.of("code",String.format("%03d",i),"name","选中行-"+String.format("%03d",i),
            "qty",new BigDecimal("1.00000000000000001"));}
    private ExportDocument document(){
        return new ExportDocument("冻结成本快照",List.of("冻结版本原文"),List.of(
                new ExportDocument.Section("冻结汇总",columns,List.of(Map.of("code","summary","name","汇总不得输出"))),
                new ExportDocument.Section("物料明细",columns,IntStream.range(0,401).mapToObj(this::row).toList()),
                new ExportDocument.Section("产出证据",columns,List.of(Map.of("code","other","name","其他分表不得输出")))));
    }
    private TableColumnProjection projection(String... codes){
        return new TableColumnProjection("master.goods.cost.actual.1","view_goods_cost",columns.stream().map(column->
                new TableColumnProjection.Column(column.key(),null,null,null,null)).toList(),
                Arrays.stream(codes).map(code->Map.of("code",code)).toList());
    }
    @Test void synchronousProjectionContainsOnlySelectedTargetSectionWithExplicitScope() throws Exception {
        var selected=projections.project(document(),projection("001","400"),"物料明细","view_goods_cost");
        assertThat(selected.title()).contains("已选 2 项");assertThat(selected.metadata()).contains("输出范围：仅选中 2 项");
        assertThat(selected.sections()).singleElement().satisfies(section->{
            assertThat(section.name()).isEqualTo("物料明细");assertThat(section.rows()).containsExactly(row(1),row(400));
        });
        byte[] xlsx=new XlsxExportService().buildDocument(selected);
        assertWorkbook(xlsx);
        assertPdf(new TabularPdfExportService().build(selected,null));
    }
    @Test void realStreamingXlsxAndPdfKeepOnlyTheSecondarySelectedSectionIncludingFinalPage() throws Exception {
        for(boolean asPdf:new boolean[]{false,true}){
            byte[] bytes;
            try(var out=new ByteArrayOutputStream();var writer=asPdf?new TabularPdfExportService().openDocumentStream(directory):new XlsxExportService().openDocumentStream(directory)){
                var filter=projections.stream(writer,projection("001","400"),"物料明细","view_goods_cost");
                try(var sink=DocumentPageSink.open(filter)){DocumentPageSink.emitDocument(document(),filter);}
                assertThat(writer.primaryRowCount()).isEqualTo(2);assertThat(writer.rowCount()).isEqualTo(2);
                writer.finish(out);bytes=out.toByteArray();
            }
            if(asPdf)assertPdf(bytes);else assertWorkbook(bytes);
            try(var files=Files.list(directory)){assertThat(files).isEmpty();}
        }
    }
    private void assertWorkbook(byte[] bytes)throws Exception{
        try(var book=new XSSFWorkbook(new ByteArrayInputStream(bytes))){
            assertThat(IntStream.range(0,book.getNumberOfSheets()).mapToObj(book::getSheetName).toList())
                    .containsExactly("说明","物料明细");
            var sheet=book.getSheet("物料明细");assertThat(sheet.getLastRowNum()).isEqualTo(2);
            assertThat(sheet.getRow(1).getCell(0).getStringCellValue()).isEqualTo("001");
            assertThat(sheet.getRow(2).getCell(0).getStringCellValue()).isEqualTo("400");
            assertThat(sheet.getRow(2).getCell(2).getStringCellValue()).isEqualTo("1.00000000000000001");
        }
    }
    private void assertPdf(byte[] bytes)throws Exception{
        try(var pdf=Loader.loadPDF(bytes)){
            String text=new PDFTextStripper().getText(pdf);
            assertThat(text).contains("已选 2 项","选中行-001","选中行-400","1.00000000000000001")
                    .doesNotContain("选中行-000","选中行-399","汇总不得输出","其他分表不得输出");
        }
    }
    @Test void missingOrDuplicateSelectionPublishesNothingAndRestoresPreviousSink()throws Exception{
        var previous=mock(DocumentPageSink.Consumer.class);
        try(var outer=DocumentPageSink.open(previous)){
            for(boolean duplicate:new boolean[]{false,true}){
                var out=new ByteArrayOutputStream();
                assertThatThrownBy(()->{
                    try(var writer=new XlsxExportService().openDocumentStream(directory)){
                        var filter=projections.stream(writer,projection("001","400"),"物料明细","view_goods_cost");
                        try(var sink=DocumentPageSink.open(filter)){
                            filter.begin(new DocumentPageSink.Header("冻结快照",List.of(),List.of(new DocumentPageSink.Section("detail","物料明细",columns,true,false)),2));
                            filter.accept(new DocumentPageSink.Page("detail",List.of(row(1))));
                            if(duplicate)filter.accept(new DocumentPageSink.Page("detail",List.of(row(1))));
                        }
                        writer.finish(out);
                    }
                }).isInstanceOf(ApiException.class);
                assertThat(out.size()).isZero();assertThat(DocumentPageSink.current()).isSameAs(previous);
                try(var files=Files.list(directory)){assertThat(files).isEmpty();}
            }
        }
        assertThat(DocumentPageSink.current()).isNull();
    }
    @Test void interruptionAndUnknownOrAmbiguousTargetCannotExpandIntoAllSections()throws Exception{
        assertThatThrownBy(()->projections.project(document(),projection("001"),"不存在分表","view_goods_cost"))
                .isInstanceOf(ApiException.class);
        var section=document().sections().get(1);
        var ambiguous=new ExportDocument("冻结",List.of(),List.of(section,section));
        assertThatThrownBy(()->projections.project(ambiguous,projection("001"),"物料明细","view_goods_cost"))
                .isInstanceOf(ApiException.class);
        var previous=mock(DocumentPageSink.Consumer.class);
        try(var outer=DocumentPageSink.open(previous)){
            var filter=projections.stream(mock(DocumentPageSink.Consumer.class),projection("001"),"物料明细","view_goods_cost");
            assertThatThrownBy(()->{
                try(var ignored=DocumentPageSink.open(filter)){
                    filter.begin(new DocumentPageSink.Header("冻结",List.of(),List.of(new DocumentPageSink.Section("detail","物料明细",columns,true,false)),1));
                    Thread.currentThread().interrupt();filter.accept(new DocumentPageSink.Page("detail",List.of(row(1))));
                }finally{Thread.interrupted();}
            }).isInstanceOf(CancellationException.class);
            assertThat(DocumentPageSink.current()).isSameAs(previous);
        }
        assertThat(DocumentPageSink.current()).isNull();
    }
}
