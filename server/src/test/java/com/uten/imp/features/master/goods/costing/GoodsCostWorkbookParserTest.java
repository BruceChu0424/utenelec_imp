package com.uten.imp.features.master.goods.costing;

import com.uten.imp.common.files.document.SpreadsheetEvidenceReader;
import com.uten.imp.common.files.document.ZipSafety;
import org.apache.poi.xssf.usermodel.XSSFWorkbook;
import org.junit.jupiter.api.Test;
import java.io.ByteArrayOutputStream;
import java.util.UUID;
import static org.assertj.core.api.Assertions.*;

class GoodsCostWorkbookParserTest {
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
