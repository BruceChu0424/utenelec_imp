package com.uten.imp.features.finance.cost;

import com.uten.imp.common.export.*;
import com.uten.imp.features.finance.report.*;
import java.io.ByteArrayInputStream;
import java.math.BigDecimal;
import java.util.*;
import org.apache.poi.xssf.usermodel.XSSFWorkbook;
import org.apache.poi.ss.usermodel.DataFormatter;
import org.apache.pdfbox.Loader;
import org.apache.pdfbox.text.PDFTextStripper;
import org.junit.jupiter.api.Test;
import static org.assertj.core.api.Assertions.*;

class FinanceCostTemplatePresentationTest {
    @Test void copperOriginalSixColumnsKeepActualCurrenciesAndUnitsInSerializedSourceNotes()throws Exception {
        String exact="12345678901234.123456789012345678901234";
        var source=new ReportTableResponse(List.of(),List.of(
                Map.of("__headerOrdinal",1,"goodsName","匿名甲","unit","只","qty",new BigDecimal("3"),"price",new BigDecimal(exact),"amount",new BigDecimal(exact),"currencyCode","USD"),
                Map.of("__headerOrdinal",2,"goodsName","匿名乙","unit","KG","qty",new BigDecimal("4"),"price",BigDecimal.ONE,"amount",new BigDecimal("4"),"currencyCode","人民币")),Map.of(),1,2,2,1);
        var paper=FinanceCostTemplatePresentation.apply("copperFee",source);
        assertThat(paper.columns()).extracting(ReportColumn::label).containsExactly("序号","产品名称","单位","数量","单价","金额");
        assertThat(paper.rows().getFirst().get("__basis")).asString().contains("数量单位：只","单价及金额币别：USD");
        assertThat(paper.rows().getLast().get("__basis")).asString().contains("数量单位：KG","单价及金额币别：人民币");
        var columns=paper.columns().stream().map(c->new ExportColumn(c.key(),c.label(),c.type(),null,c.unitLabel(),c.unitKey())).toList();
        var layout=new ExportTableLayout("匿名铜柱原表",2,2,List.of(new ExportTableLayout.Heading(0,0,"匿名铜柱原表",18,true,"CENTER")),List.of(),Collections.nCopies(6,18d),"宋体",(short)11,22,List.of(),List.of(),List.of(),false);
        byte[] bytes=new XlsxExportService().build(new ExportPayload(columns,paper.rows(),2).withLayout(layout),null,null);
        try(var book=new XSSFWorkbook(new ByteArrayInputStream(bytes))){
            var sheet=book.getSheetAt(0);assertThat(sheet.getRow(2).getLastCellNum()).isEqualTo((short)6);
            assertThat(sheet.getRow(3).getCell(0).getStringCellValue()).isEqualTo("1");
            assertThat(sheet.getRow(3).getCell(2).getStringCellValue()).isEqualTo("只");
            assertThat(sheet.getRow(3).getCell(4).getStringCellValue()).isEqualTo(exact);
            assertThat(sheet.getRow(3).getCell(4).getCellStyle().getDataFormatString()).contains("USD");
            assertThat(sheet.getRow(4).getCell(4).getNumericCellValue()).isEqualTo(1);
            assertThat(sheet.getRow(4).getCell(4).getCellStyle().getDataFormatString()).contains("元").doesNotContain("USD");
            var notes=book.getSheet("取数与核对");assertThat(notes.getRow(1).getCell(2).getStringCellValue()).contains("只","USD").doesNotContain("人民币");
            assertThat(notes.getRow(2).getCell(2).getStringCellValue()).contains("KG","人民币").doesNotContain("USD");
        }
    }
    @Test void absentCopperCurrencyRemainsExplicitlyPending(){
        var source=new ReportTableResponse(List.of(),List.of(Map.of("unit","只","qty",BigDecimal.ONE,"price",BigDecimal.ONE,"amount",BigDecimal.ONE)),Map.of(),1,1,1,1);
        var row=FinanceCostTemplatePresentation.apply("copperFee",source).rows().getFirst();
        assertThat(row).containsEntry("__pending",true);assertThat(row.get("__basis")).asString().contains("单价及金额币别：待核对");
    }
    @Test void equalAmountsInDifferentCurrenciesRemainIdentifiableInXlsxAndActualServerPdf()throws Exception {
        var rows=new ArrayList<Map<String,Object>>();
        for(String currency:List.of("USD","人民币"))rows.add(Map.of("__headerOrdinal",rows.size()+1,"goodsName","匿名材料","unit","只","qty",BigDecimal.ONE,"price",new BigDecimal("100"),"amount",new BigDecimal("100"),"currencyCode",currency));
        var paper=FinanceCostTemplatePresentation.apply("copperFee",new ReportTableResponse(List.of(),rows,Map.of(),1,2,2,1));
        var columns=paper.columns().stream().map(c->new ExportColumn(c.key(),c.label(),c.type(),null,c.unitLabel(),c.unitKey())).toList();
        var layout=new ExportTableLayout("匿名铜柱原表",2,2,List.of(),List.of(),Collections.nCopies(6,18d),"宋体",(short)11,22,List.of(),List.of(),List.of(),false);
        byte[] xlsx=new XlsxExportService().build(new ExportPayload(columns,paper.rows(),2).withLayout(layout),null,null);
        try(var book=new XSSFWorkbook(new ByteArrayInputStream(xlsx))){
            var formatter=new DataFormatter(Locale.ROOT);var sheet=book.getSheetAt(0);
            assertThat(sheet.getRow(3).getCell(5).getNumericCellValue()).isEqualTo(100);assertThat(sheet.getRow(4).getCell(5).getNumericCellValue()).isEqualTo(100);
            assertThat(formatter.formatCellValue(sheet.getRow(3).getCell(5))).contains("100","USD").doesNotContain("元");
            assertThat(formatter.formatCellValue(sheet.getRow(4).getCell(5))).contains("100","元").doesNotContain("USD");
        }
        var document=new ExportDocument("匿名铜柱原表",List.of(),List.of(new ExportDocument.Section("原六列",columns,paper.rows())));
        try(var pdf=Loader.loadPDF(new TabularPdfExportService().build(document,null))){
            assertThat(new PDFTextStripper().getText(pdf).replaceAll("\\s+","")).contains("100USD","100元");
        }
    }
}
