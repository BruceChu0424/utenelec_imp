package com.uten.imp.features.master.goods.costing;

import com.uten.imp.common.files.document.SpreadsheetEvidenceReader;
import com.uten.imp.common.files.document.ZipSafety;
import org.apache.poi.xssf.usermodel.XSSFWorkbook;
import org.junit.jupiter.api.Test;
import java.io.ByteArrayOutputStream;
import java.util.UUID;
import static org.assertj.core.api.Assertions.*;

class GoodsCostWorkbookParserTest {
    @Test void hiddenCostInputsCannotDisappearBeforeColumnValidation() throws Exception {
        for(String hidden:java.util.List.of("column","row","sheet","empty-cache-formula")) {
            try(var wb=new XSSFWorkbook();var out=new ByteArrayOutputStream()) {
                var sheet=wb.createSheet("成本");var header=sheet.createRow(0);var row=sheet.createRow(1);
                String[] labels={"材料名称","用量","单价","运输费用"};String[] values={"铜料","1","2","99"};
                for(int index=0;index<labels.length;index++){header.createCell(index).setCellValue(labels[index]);row.createCell(index).setCellValue(values[index]);}
                if(hidden.equals("row"))row.setZeroHeight(true);
                else if(hidden.equals("sheet")){wb.createSheet("可见");wb.setSheetHidden(0,true);}
                else {sheet.setColumnHidden(3,true);if(hidden.equals("empty-cache-formula"))row.getCell(3).setCellFormula("IF(1=1,\"\",\"\")");}
                wb.write(out);
                assertThatThrownBy(()->GoodsCostWorkbookParser.parse(UUID.randomUUID(),"source.xlsx","a".repeat(64),out.toByteArray()))
                        .isInstanceOf(com.uten.imp.common.web.ApiException.class).hasMessageContaining("隐藏");
            }
        }
    }
    @Test void hiddenStyledEmptyTailIsNotAdoptedOrMistakenForData() throws Exception {
        try(var wb=new XSSFWorkbook();var out=new ByteArrayOutputStream()) {
            var sheet=wb.createSheet("成本");headers(sheet,0);var row=sheet.createRow(1);
            row.createCell(0).setCellValue("原料");row.createCell(1).setCellValue(1);
            row.createCell(6).setCellStyle(wb.createCellStyle());sheet.setColumnHidden(6,true);wb.write(out);
            assertThat(GoodsCostWorkbookParser.parse(UUID.randomUUID(),"source.xlsx","a".repeat(64),out.toByteArray()).blocks()).hasSize(1);
        }
    }
    @Test void duplicateAndPopulatedCustomColumnsRequireExplicitHandling() throws Exception {
        for(String extra:java.util.List.of("单价","自定义备注")) {
            try(var wb=new XSSFWorkbook();var out=new ByteArrayOutputStream()) {
                var sheet=wb.createSheet("材料");headers(sheet,0);sheet.getRow(0).createCell(5).setCellValue(extra);
                var row=sheet.createRow(1);row.createCell(0).setCellValue("原料");row.createCell(1).setCellValue(1);row.createCell(5).setCellValue("不可丢弃");
                wb.write(out);
                assertThatThrownBy(()->GoodsCostWorkbookParser.parse(UUID.randomUUID(),"source.xlsx","a".repeat(64),out.toByteArray()))
                        .isInstanceOf(com.uten.imp.common.web.ApiException.class).hasMessageContaining(extra.equals("单价")?"重复":"不支持");
            }
        }
    }
    @Test void entirelyEmptyExtraCostColumnDoesNotBlockOrdinaryRows() throws Exception {
        try(var wb=new XSSFWorkbook();var out=new ByteArrayOutputStream()) {
            var sheet=wb.createSheet("材料");headers(sheet,0);sheet.getRow(0).createCell(5).setCellValue("空尾列");
            var row=sheet.createRow(1);row.createCell(0).setCellValue("原料");row.createCell(1).setCellValue(1);wb.write(out);
            assertThat(GoodsCostWorkbookParser.parse(UUID.randomUUID(),"source.xlsx","a".repeat(64),out.toByteArray()).blocks()).hasSize(1);
        }
    }
    @Test void discoversProductBlocksKeepsCachedFormulaEvidenceAndNeverFillsMissingPricesWithZero() throws Exception {
        byte[] bytes;
        try (var wb = new XSSFWorkbook(); var out = new ByteArrayOutputStream()) {
            var sheet = wb.createSheet("材料明细");
            sheet.createRow(0).createCell(1).setCellValue("产品名称: 产品甲");
            headers(sheet, 1);
            var first = sheet.createRow(2);
            first.createCell(0).setCellValue("小量原料"); first.createCell(1).setCellValue(.00007);
            first.createCell(2).setCellValue("kg"); first.createCell(3).setCellValue(35);
            first.createCell(4).setCellFormula("B3*D3"); first.getCell(4).setCellValue(.00245);
            var missing = sheet.createRow(3); missing.createCell(0).setCellValue("待核价物料"); missing.createCell(1).setCellValue(2);
            sheet.createRow(4).createCell(0).setCellValue("合计");
            sheet.createRow(5).createCell(1).setCellValue("产品名称: 产品乙"); headers(sheet, 6);
            var second = sheet.createRow(7); second.createCell(0).setCellValue("包装"); second.createCell(1).setCellValue(.1);
            second.createCell(2).setCellValue("个"); second.createCell(3).setCellValue(1.33);
            wb.write(out); bytes = out.toByteArray();
        }
        var result = GoodsCostWorkbookParser.parse(UUID.randomUUID(), "source.xlsx", "a".repeat(64), bytes);
        assertThat(result.blocks()).hasSize(2);
        assertThat(result.blocks().getFirst().label()).isEqualTo("产品甲");
        assertThat(new java.math.BigDecimal(result.blocks().getFirst().rows().getFirst().quantity())).isEqualByComparingTo("0.00007");
        assertThat(result.blocks().getFirst().rows().getFirst().formula()).contains("E3=B3*D3");
        assertThat(result.blocks().getFirst().rows().get(1).unitPrice()).isNull();
        assertThat(result.blocks().get(1).rows().getFirst().unitPrice()).isEqualTo("1.33");
    }
    private static void headers(org.apache.poi.ss.usermodel.Sheet sheet, int index) {
        var row = sheet.createRow(index);
        String[] titles = {"名称", "单位用量", "材料单位", "材料单价(元)", "成本金额"};
        for (int c = 0; c < titles.length; c++) row.createCell(c).setCellValue(titles[c]);
    }
}
