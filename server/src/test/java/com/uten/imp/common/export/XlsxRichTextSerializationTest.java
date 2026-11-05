package com.uten.imp.common.export;

import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.math.BigDecimal;
import java.nio.file.Path;
import java.util.List;
import java.util.Map;
import java.util.stream.IntStream;
import java.util.stream.Stream;
import org.apache.poi.ss.usermodel.CellType;
import org.apache.poi.ss.usermodel.WorkbookFactory;
import org.apache.poi.xssf.usermodel.XSSFRichTextString;
import org.junit.jupiter.api.io.TempDir;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.Arguments;
import org.junit.jupiter.params.provider.MethodSource;
import org.junit.jupiter.params.provider.ValueSource;
import static org.assertj.core.api.Assertions.assertThat;

class XlsxRichTextSerializationTest {
    @TempDir Path temporary;

    static Stream<Arguments> cases() {
        return Stream.of(Arguments.of(false,1),Arguments.of(true,1),
                Arguments.of(false,205),Arguments.of(true,205));
    }

    @ParameterizedTest @ValueSource(strings={"95","-95","1140","0.000000000000000000000001"})
    void percentageKeepsItsNumericValueAndFontWhileColumnFitsTheDisplayedToken(String value) throws Exception {
        double sourceWidth=6.7734375;
        var layout=new ExportTableLayout("比例",0,0,List.of(),List.of(),List.of(sourceWidth),"宋体",(short)12,16,
                List.of(),List.of(),List.of(),false);
        var column=new ExportColumn("ratio","月均利润率","number",null,"%",null);
        var payload=new ExportPayload(List.of(column),List.of(Map.of("ratio",new BigDecimal(value))),1,layout);
        try(var workbook=WorkbookFactory.create(new ByteArrayInputStream(new XlsxExportService().build(payload,null,null)))) {
            var sheet=workbook.getSheetAt(0);var cell=sheet.getRow(1).getCell(0);
            assertThat(cell.getCellType()).isEqualTo(CellType.NUMERIC);
            assertThat(cell.getNumericCellValue()).isEqualTo(new BigDecimal(value).movePointLeft(2).doubleValue());
            assertThat(workbook.getFontAt(cell.getCellStyle().getFontIndex()).getFontHeightInPoints()).isEqualTo((short)12);
            assertThat(cell.getCellStyle().getShrinkToFit()).isFalse();
            assertThat(new org.apache.poi.ss.usermodel.DataFormatter(java.util.Locale.ROOT).formatCellValue(cell)).endsWith("%");
            assertThat(sheet.getColumnWidth(0)).isGreaterThan((int)Math.round(sourceWidth*256));
        }
    }

    @ParameterizedTest @MethodSource("cases")
    void originalPartialColorsSurviveActualZipAndStreamingFlush(boolean bounded,int count) throws Exception {
        String caption="加：营业外收入（退税收入+收客户税点） & 原文";
        int start=caption.indexOf('（'),end=caption.indexOf('）')+1,second=caption.indexOf("原文");
        var layout=new ExportTableLayout("原表",0,0,List.of(),List.of(),List.of(60d,20d,12d,20d),"宋体",(short)11,16,
                List.of(new ExportTableLayout.Band(0,0,0,null,true)),List.of(new ExportTableLayout.TextSpan(0,0,start,end,"FF0000"),
                new ExportTableLayout.TextSpan(0,0,second,caption.length(),"0000FF")),List.of(),false,
                List.of(new ExportTableLayout.SupplementalCell(1,3,"text","保留原表空档",false)));
        var columns=List.of(new ExportColumn("caption","项目","text"),new ExportColumn("amount","金额","money"));
        var rows=IntStream.range(0,count).mapToObj(i->Map.<String,Object>of(
                "caption",i==0?caption:" =SUM(1,2) <&> \"中文\"",
                "amount",new BigDecimal("595.00"))).toList();
        byte[] bytes;
        var service=new XlsxExportService();
        try(var output=new ByteArrayOutputStream();var writer=bounded
                ?service.openStream(null,null,temporary):service.openStream(null,null)) {
            writer.accept(new ExportPayload(columns,rows,rows.size(),layout));
            writer.finish(output);
            bytes=output.toByteArray();
        }
        try(var workbook=WorkbookFactory.create(new ByteArrayInputStream(bytes))) {
            var sheet=workbook.getSheet("原表");
            assertThat(sheet.getLastRowNum()).isEqualTo(count);
            var cell=sheet.getRow(1).getCell(0);
            assertThat(cell.getCellType()).isEqualTo(CellType.STRING);
            assertThat(cell.getStringCellValue()).isEqualTo(caption);
            var rich=(XSSFRichTextString)cell.getRichStringCellValue();
            assertThat(rich.hasFormatting()).isTrue();
            assertThat(rich.getFontAtIndex(start)).isNotNull();
            assertThat(rich.getFontAtIndex(start).getXSSFColor().getARGBHex()).endsWith("FF0000");
            assertThat(rich.getFontAtIndex(start).getBold()).isTrue();
            assertThat(rich.getFontAtIndex(start).getFontName()).isEqualTo("宋体");
            assertThat(rich.getFontAtIndex(second)).isNotNull();
            assertThat(rich.getFontAtIndex(second).getXSSFColor().getARGBHex()).endsWith("0000FF");
            assertThat(sheet.getRow(1).getCell(1).getCellType()).isEqualTo(CellType.NUMERIC);
            assertThat(sheet.getRow(1).getCell(1).getNumericCellValue()).isEqualTo(595d);
            assertThat(sheet.getRow(1).getCell(3).getStringCellValue()).isEqualTo("保留原表空档");
            if(count>1) {
                assertThat(sheet.getRow(2).getCell(0).getCellType()).isEqualTo(CellType.STRING);
                assertThat(sheet.getRow(2).getCell(0).getStringCellValue()).isEqualTo(" =SUM(1,2) <&> \"中文\"");
            }
        }
    }
}
