package com.uten.imp.common.importing;

import org.apache.poi.xssf.usermodel.XSSFWorkbook;
import org.junit.jupiter.api.Test;
import java.util.*;
import static org.assertj.core.api.Assertions.*;

class ImportColumnGuardTest {
    @Test void aBlankHeaderWithDataOrAnEmptyCachedFormulaIsStillAnUnmappedColumn() throws Exception {
        for(boolean formula:List.of(false,true))try(var book=new XSSFWorkbook()) {
            var sheet=book.createSheet("data");sheet.createRow(0).createCell(0).setCellValue("名称");
            var row=sheet.createRow(1);row.createCell(0).setCellValue("货品");
            if(formula)row.createCell(2).setCellFormula("IF(1=1,\"\",\"\")");else row.createCell(2).setCellValue("不可丢弃");
            var issues=ImportColumnGuard.inspect(sheet,0,name->name.equals("名称")?"name":null);
            assertThat(issues).hasSize(1);assertThat(issues.getFirst().column()).contains("第3列","未命名");
            assertThat(issues.getFirst().message()).doesNotContain("不可丢弃");
        }
    }
    @Test void stylingDoesNotTurnAnEmptyTailIntoBusinessData() throws Exception {
        try(var book=new XSSFWorkbook()) {
            var sheet=book.createSheet("data");sheet.createRow(0).createCell(0).setCellValue("名称");
            var row=sheet.createRow(1);row.createCell(0).setCellValue("货品");
            row.createCell(63).setCellStyle(book.createCellStyle());
            assertThat(ImportColumnGuard.inspect(sheet,0,name->name.equals("名称")?"name":null)).isEmpty();
        }
    }
    @Test void absentOrFutureValidationFactsCannotAuthorizeAPersistedPreview() throws Exception {
        var json=new com.fasterxml.jackson.databind.ObjectMapper();
        var old=json.readValue("{}",com.uten.imp.features.master.goods.costing.GoodsCostImportContracts.Preview.class);
        assertThat(old.columnContractVersion()).isZero();
        assertThatThrownBy(()->ImportColumnGuard.requireValidated(old.columnContractVersion())).hasMessageContaining("重新检测");
        assertThatThrownBy(()->ImportColumnGuard.requireValidated(1)).hasMessageContaining("重新检测");
        assertThatThrownBy(()->ImportColumnGuard.requireValidated(ImportColumnGuard.VERSION+1)).hasMessageContaining("重新检测");
        assertThatCode(()->ImportColumnGuard.requireValidated(ImportColumnGuard.VERSION)).doesNotThrowAnyException();
    }
}
