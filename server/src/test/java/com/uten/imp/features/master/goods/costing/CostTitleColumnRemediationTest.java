package com.uten.imp.features.master.goods.costing;
import com.uten.imp.common.web.ApiException;
import org.junit.jupiter.api.Test;
import java.util.*;
import static org.assertj.core.api.Assertions.*;
class CostTitleColumnRemediationTest {
    @Test void cachedFormulaCannotBecomeAStructuralTitleOrHeader() throws Exception {
        for(boolean title:List.of(false,true))try(var book=new org.apache.poi.xssf.usermodel.XSSFWorkbook();var out=new java.io.ByteArrayOutputStream()) {
            var sheet=book.createSheet("成本");var header=sheet.createRow(title?1:0);
            header.createCell(0).setCellValue("材料名称");header.createCell(1).setCellValue("用量");header.createCell(2).setCellValue("单价");
            var cell=title?sheet.createRow(0).createCell(0):header.getCell(0);
            cell.setCellFormula(title?"\"产品名称：A\"":"\"材料名称\"");book.getCreationHelper().createFormulaEvaluator().evaluateFormulaCell(cell);
            var row=sheet.createRow(title?2:1);row.createCell(0).setCellValue("铜钉");row.createCell(1).setCellValue(1);row.createCell(2).setCellValue(4);book.write(out);
            assertThatThrownBy(()->GoodsCostWorkbookParser.parse(UUID.randomUUID(),"source.xlsx","source",out.toByteArray())).isInstanceOf(ApiException.class);
        }
    }
    @Test void titleInAnExtraDataCellCannotDeleteTheMaterialRow() throws Exception {
        for(String name:List.of("cost-title-true.xlsx","cost-title-false.xlsx")) {
            byte[] bytes;try(var in=getClass().getResourceAsStream("/import-column-remediation/"+name)){bytes=Objects.requireNonNull(in).readAllBytes();}
            assertThatThrownBy(()->GoodsCostWorkbookParser.parse(UUID.randomUUID(),name,"source",bytes))
                    .isInstanceOf(ApiException.class).hasMessageContaining(name.contains("true")?"第3行":"运输费");
        }
    }
}
