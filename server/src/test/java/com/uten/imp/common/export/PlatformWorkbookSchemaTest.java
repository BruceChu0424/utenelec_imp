package com.uten.imp.common.export;

import com.uten.imp.common.importing.PlatformWorkbookSchema;
import org.apache.poi.xssf.usermodel.XSSFWorkbook;
import org.junit.jupiter.api.Test;
import java.io.*;
import java.util.*;
import static org.assertj.core.api.Assertions.*;

class PlatformWorkbookSchemaTest {
    @Test void scopeContinuationAndPasswordProtectionPreserveTheSameColumnIdentity() throws Exception {
        String id=UUID.randomUUID().toString(),key="platform:"+id;
        var columns=List.of(new ExportColumn(key,"名称",ExportColumn.TEXT));
        byte[] bytes;
        try(var output=new ByteArrayOutputStream();var writer=new XlsxExportService().openStream(null,"master_goods")) {
            writer.accept(new ExportPayload(columns,List.of(Map.of(key,"甲")),1));
            // Exercise the physical continuation boundary without allocating a million fixture rows.
            var states=writer.getClass().getDeclaredField("sheets");states.setAccessible(true);
            Object state=((Map<?,?>)states.get(writer)).get("data");var rowIndex=state.getClass().getDeclaredField("rowIndex");rowIndex.setAccessible(true);
            rowIndex.setInt(state,org.apache.poi.ss.SpreadsheetVersion.EXCEL2007.getMaxRows());
            writer.accept(new ExportPayload(columns,List.of(Map.of(key,"乙")),1));writer.finish(output);bytes=output.toByteArray();
        }
        byte[] protectedBytes=new WorkbookDownloadService().protect(bytes,"synthetic-test-only");
        try(var book=org.apache.poi.ss.usermodel.WorkbookFactory.create(new ByteArrayInputStream(protectedBytes),"synthetic-test-only")) {
            assertThat(book.getNumberOfSheets()).isEqualTo(2);
            var source=(XSSFWorkbook)book;String marker=source.getProperties().getCustomProperties().getProperty(PlatformWorkbookSchema.PROPERTY).getLpwstr();
            var json=new com.fasterxml.jackson.databind.ObjectMapper().readTree(marker);
            assertThat(json.path("scope").asText()).isEqualTo("master_goods");assertThat(json.path("sheets").size()).isEqualTo(2);
            for(var sheet:json.path("sheets"))assertThat(sheet.path("columns").get(0).path("definitionId").asText()).isEqualTo(id);
        }
    }
    @Test void evenOneCustomColumnNamedLikeABusinessFieldCarriesStableProvenance() throws Exception {
        String id=UUID.randomUUID().toString();
        byte[] bytes=new XlsxExportService().build(List.of(new ExportColumn("platform:"+id,"价格",ExportColumn.QTY)),List.of(Map.of("platform:"+id,"12.3456")));
        try(var book=new XSSFWorkbook(new ByteArrayInputStream(bytes))) {
            var property=book.getProperties().getCustomProperties().getProperty(PlatformWorkbookSchema.PROPERTY);
            assertThat(property).isNotNull();
            assertThat(property.getLpwstr()).contains(id,"\"schemaVersion\":1","\"index\":0","价格");
            assertThat(PlatformWorkbookSchema.importRejection(book)).contains("自定义列","不能按显示名称");
        }
    }
    @Test void systemOnlyWorkbooksRemainOrdinaryFiles() throws Exception {
        byte[] bytes=new XlsxExportService().build(List.of(new ExportColumn("price","价格",ExportColumn.NUMBER)),List.of(Map.of("price",12)));
        try(var book=new XSSFWorkbook(new ByteArrayInputStream(bytes))) { assertThat(PlatformWorkbookSchema.importRejection(book)).isNull(); }
    }
    @Test void malformedAndFutureMarkersFailClosed() throws Exception {
        for(String marker:List.of("{}","{\"schemaVersion\":2}","not-json","x".repeat(65_537))) {
            try(var book=new XSSFWorkbook()) {
                book.getProperties().getCustomProperties().addProperty(PlatformWorkbookSchema.PROPERTY,marker);
                assertThat(PlatformWorkbookSchema.importRejection(book)).contains("缺损、过大或版本不支持");
            }
        }
    }
}
