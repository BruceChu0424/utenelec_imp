package com.uten.imp.common.export;

import com.uten.imp.common.platformcolumns.PlatformColumnService;
import com.uten.imp.common.web.ApiException;
import org.apache.poi.xssf.usermodel.XSSFWorkbook;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.io.TempDir;
import org.springframework.beans.factory.ObjectProvider;
import org.springframework.test.util.ReflectionTestUtils;
import java.io.*;
import java.math.BigDecimal;
import java.nio.file.*;
import java.util.*;
import java.util.concurrent.CancellationException;
import java.util.stream.IntStream;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.*;

class XlsxSelectedRowsStreamingTest {
    @TempDir Path directory;
    private final List<ExportColumn> columns=List.of(new ExportColumn("code","编号",ExportColumn.TEXT),
            new ExportColumn("qty","数量",ExportColumn.QTY),new ExportColumn("name","名称",ExportColumn.TEXT));
    @AfterEach void clearInterrupt(){Thread.interrupted();}
    private static String id(int i){return new UUID(0,i+1).toString();}
    private Map<String,Object> row(int i){return Map.of("id",id(i),"code",String.format("%03d",i),"qty",new BigDecimal("1.00"),"name","服务器原值"+i);}
    private TableColumnProjection projection(int... ids){
        return new TableColumnProjection("fixture","view_sales",columns.stream().map(column->
                new TableColumnProjection.Column(column.key(),null,null,null,null)).toList(),
                IntStream.of(ids).mapToObj(i->Map.of("@id",id(i))).toList());
    }
    private XlsxExportService service(){
        var service=new XlsxExportService();
        @SuppressWarnings("unchecked") ObjectProvider<ExportTableProjectionService> provider=mock(ObjectProvider.class);
        when(provider.getObject()).thenReturn(new ExportTableProjectionService(mock(PlatformColumnService.class)));
        ReflectionTestUtils.setField(service,"projections",provider);return service;
    }
    @Test void streamedSourceBeyondFiveHundredExportsOnlyCrossPageSelectedRowsIncludingLast() throws Exception {
        byte[] bytes;
        try(var out=new ByteArrayOutputStream();var writer=service().openStream(projection(1,500,699),"view_sales",directory)){
            for(int start=0;start<700;start+=100){
                var rows=IntStream.range(start,start+100).mapToObj(this::row).toList();
                writer.accept(new ExportPayload(columns,rows,700));
            }
            assertThat(writer.rowCount()).isEqualTo(3);writer.finish(out);bytes=out.toByteArray();
        }
        try(var workbook=new XSSFWorkbook(new ByteArrayInputStream(bytes))){
            var sheet=workbook.getSheetAt(0);assertThat(sheet.getLastRowNum()).isEqualTo(3);
            assertThat(sheet.getRow(1).getCell(0).getStringCellValue()).isEqualTo("001");
            assertThat(sheet.getRow(2).getCell(0).getStringCellValue()).isEqualTo("500");
            assertThat(sheet.getRow(3).getCell(0).getStringCellValue()).isEqualTo("699");
            assertThat(sheet.getRow(1).getCell(2).getStringCellValue()).isEqualTo("服务器原值1");
        }
        try(var files=Files.list(directory)){assertThat(files).isEmpty();}
    }
    @Test void missingOrRepeatedMembersPublishNoArtifactAndCleanTemporaryFiles() throws Exception {
        var service=service();
        for(boolean duplicate:new boolean[]{false,true}){
            var out=new ByteArrayOutputStream();
            assertThatThrownBy(()->{
                try(var writer=service.openStream(projection(1,2),"view_sales",directory)){
                    writer.accept(new ExportPayload(columns,List.of(row(1)),3));
                    if(duplicate)writer.accept(new ExportPayload(columns,List.of(row(1)),3));
                    writer.finish(out);
                }
            }).isInstanceOf(ApiException.class);
            assertThat(out.size()).isZero();
            try(var files=Files.list(directory)){assertThat(files).isEmpty();}
        }
    }
    @Test void cancellationAfterAValidPagePublishesNothingCleansFilesAndAllowsAFreshOperation() throws Exception {
        var out=new ByteArrayOutputStream();
        try {
            assertThatThrownBy(()->{
                try(var writer=service().openStream(projection(1,2),"view_sales",directory)){
                    writer.accept(new ExportPayload(columns,List.of(row(1)),2));
                    Thread.currentThread().interrupt();
                    writer.accept(new ExportPayload(columns,List.of(row(2)),2));writer.finish(out);
                }
            }).isInstanceOf(CancellationException.class);
        } finally {Thread.interrupted();}
        assertThat(out.size()).isZero();
        try(var files=Files.list(directory)){assertThat(files).isEmpty();}
        byte[] next=service().build(new ExportPayload(columns,List.of(row(1)),1),projection(1),"view_sales");
        try(var workbook=new XSSFWorkbook(new ByteArrayInputStream(next))){assertThat(workbook.getSheetAt(0).getLastRowNum()).isEqualTo(1);}
    }
}
