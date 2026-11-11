package com.uten.imp.features.master.goods.costing;

import com.uten.imp.common.importing.ImportColumnGuard;
import com.uten.imp.common.web.ApiException;
import java.io.ByteArrayOutputStream;
import java.util.List;
import java.util.UUID;
import org.apache.poi.ss.usermodel.FormulaError;
import org.apache.poi.ss.usermodel.Sheet;
import org.apache.poi.xssf.usermodel.XSSFWorkbook;
import org.junit.jupiter.api.Test;
import static org.assertj.core.api.Assertions.*;

class CostStructureRowRemediationTest {
    @Test void preservedIndependentWorkbooksKeepEveryMaterialOrRejectTheLocatedUnknownCell() throws Exception {
        for(String name:List.of("ordinary-control","reserved-name-control","subtotal-name-control","mixed-header-tail")) {
            byte[] bytes;
            try(var input=getClass().getResourceAsStream("/import-cost-structure-v3/"+name+".xlsx")) {
                bytes=java.util.Objects.requireNonNull(input).readAllBytes();
            }
            if(name.equals("mixed-header-tail")) {
                assertThatThrownBy(()->parse(bytes)).isInstanceOf(ApiException.class).hasMessageContaining("第3行","第4列");
            } else {
                var preview=parse(bytes);
                assertThat(preview.columnContractVersion()).isEqualTo(ImportColumnGuard.VERSION);
                assertThat(preview.blocks().getFirst().rows()).hasSize(2);
                assertThat(preview.blocks().getFirst().rows().get(1).name()).isEqualTo(switch(name) {
                    case "ordinary-control" -> "铜片";case "reserved-name-control" -> "材料名称";default -> "小计数器件";
                });
                assertThat(preview.blocks().getFirst().rows()).allSatisfy(row->{
                    assertThat(new java.math.BigDecimal(row.quantity())).isEqualByComparingTo("1");
                    assertThat(new java.math.BigDecimal(row.unitPrice())).isEqualByComparingTo("4");
                });
            }
        }
    }
    @Test void headerKeywordsCannotDiscardMixedPhysicalValuesOrEmptyFormulaCaches() throws Exception {
        for(String name:List.of("材料名称","名称","货品名称","物料名称","零件名称","品名"))
            for(String extra:List.of("literal-header","empty-cache","cached-header")) {
                byte[] bytes=workbook(sheet->{
                    header(sheet,0);material(sheet,1,"铜钉");material(sheet,2,name);
                    var cell=sheet.getRow(2).createCell(3);
                    if(extra.equals("literal-header"))cell.setCellValue("数量");
                    else cell.setCellFormula(extra.equals("empty-cache")?"IF(1=1,\"\",\"\")":"\"数量\"");
                });
                assertThatThrownBy(()->parse(bytes)).isInstanceOf(ApiException.class).hasMessageContaining("第3行","第4列");
            }
        byte[] withinDeclared=workbook(sheet->{header(sheet,0);material(sheet,1,"铜钉");material(sheet,2,"材料名称");sheet.getRow(2).getCell(2).setCellValue("单价");});
        assertThatThrownBy(()->parse(withinDeclared)).isInstanceOf(ApiException.class).hasMessageContaining("第3行","混有表头");
    }
    @Test void firstHeaderRequiresLiteralCellsAndCannotSwallowBusinessValues() throws Exception {
        for(String kind:List.of("number","numeric-text","boolean","error","empty-cache","cached-header")) {
            byte[] bytes=workbook(sheet->{
                header(sheet,0);var cell=sheet.getRow(0).createCell(3);
                switch(kind) {
                    case "number" -> cell.setCellValue(12);
                    case "numeric-text" -> cell.setCellValue("12");
                    case "boolean" -> cell.setCellValue(true);
                    case "error" -> cell.setCellErrorValue(FormulaError.VALUE.getCode());
                    default -> cell.setCellFormula(kind.equals("empty-cache")?"IF(1=1,\"\",\"\")":"\"数量\"");
                }
                material(sheet,1,"铜钉");
            });
            assertThatThrownBy(()->parse(bytes)).isInstanceOf(ApiException.class).hasMessageContaining("第1行");
        }
    }
    @Test void onlyExactIsolatedLiteralTotalsAreStructureAndAmbiguousTotalsAreLocated() throws Exception {
        for(String marker:List.of("合计","小计","总计")) {
            var valid=parse(workbook(sheet->{header(sheet,0);material(sheet,1,"铜钉");sheet.createRow(2).createCell(0).setCellValue(marker);}));
            assertThat(valid.blocks().getFirst().rows()).hasSize(1);
            for(String kind:List.of("business-values","empty-formula","marker-formula","unknown-column")) {
                byte[] bytes=workbook(sheet->{
                    header(sheet,0);material(sheet,1,"铜钉");var row=sheet.createRow(2);row.createCell(0).setCellValue(marker);
                    switch(kind) {
                        case "business-values" -> {row.createCell(1).setCellValue(1);row.createCell(2).setCellValue(4);}
                        case "empty-formula" -> row.createCell(1).setCellFormula("IF(1=1,\"\",\"\")");
                        case "marker-formula" -> row.getCell(0).setCellFormula("\""+marker+"\"");
                        default -> row.createCell(3).setCellValue("不能忽略");
                    }
                });
                assertThatThrownBy(()->parse(bytes)).isInstanceOf(ApiException.class).hasMessageContaining("第3行");
            }
        }
    }
    @Test void materialsContainingTotalWordsAndRepeatedLiteralHeadersRemainComplete() throws Exception {
        for(String name:List.of("小计数器件","合计器","总计量器","合 计材料","材料名称")) {
            var preview=parse(workbook(sheet->{header(sheet,0);material(sheet,1,"铜钉");material(sheet,2,name);header(sheet,3);material(sheet,4,"铜片");}));
            assertThat(preview.blocks()).hasSize(2);
            assertThat(preview.blocks().getFirst().rows()).extracting(GoodsCostImportContracts.ImportRow::name).containsExactly("铜钉",name);
            assertThat(preview.blocks().get(1).rows()).extracting(GoodsCostImportContracts.ImportRow::name).containsExactly("铜片");
        }
    }
    private static GoodsCostImportContracts.Preview parse(byte[] bytes) {
        return GoodsCostWorkbookParser.parse(UUID.randomUUID(),"structure.xlsx","source",bytes);
    }
    private static byte[] workbook(java.util.function.Consumer<Sheet> write) throws Exception {
        try(var book=new XSSFWorkbook();var out=new ByteArrayOutputStream()) {
            var sheet=book.createSheet("成本");write.accept(sheet);
            book.getCreationHelper().createFormulaEvaluator().evaluateAll();book.write(out);return out.toByteArray();
        }
    }
    private static void header(Sheet sheet,int index) {
        var row=sheet.createRow(index);String[] labels={"材料名称","用量","单价"};
        for(int column=0;column<labels.length;column++)row.createCell(column).setCellValue(labels[column]);
    }
    private static void material(Sheet sheet,int index,String name) {
        var row=sheet.createRow(index);row.createCell(0).setCellValue(name);row.createCell(1).setCellValue(1);row.createCell(2).setCellValue(4);
    }
}
