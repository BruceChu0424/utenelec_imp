package com.uten.imp.features.master.goods.importing;

import org.apache.poi.xssf.usermodel.XSSFWorkbook;
import org.junit.jupiter.api.Test;
import java.io.ByteArrayOutputStream;
import java.lang.reflect.Field;
import java.util.List;
import static org.assertj.core.api.Assertions.*;

class GoodsImportColumnContractTest {
    private final GoodsImportService service = new GoodsImportService(null,null,null,null,null,null,null,null,null,null,null);

    @Test void duplicateBusinessAliasesCannotChooseByPosition() throws Exception {
        for (String[] names : List.of(new String[]{"货品名称","名称"},new String[]{"名称","货品名称"})) {
            var errors=errors(workbook(new String[]{names[0],"类别",names[1]},new String[]{"伪装自定义值","成品","真实名称"},false));
            assertThat(errors).anyMatch(error->error.message().contains("重复"));
        }
    }
    @Test void unknownPopulatedColumnsAndBlankCachedFormulasAreNotSilentlyLost() throws Exception {
        assertThat(errors(workbook(new String[]{"名称","类别","用户自定义"},new String[]{"货品","成品","原始自定义值"},false)))
                .anyMatch(error->error.column().equals("用户自定义")&&error.message().contains("不支持"));
        byte[] formula=workbook(new String[]{"名称","类别","用户自定义"},new String[]{"货品","成品",""},true);
        assertThatThrownBy(()->errors(formula)).isInstanceOf(java.lang.reflect.InvocationTargetException.class)
                .hasCauseInstanceOf(com.uten.imp.common.web.ApiException.class);
    }
    @Test void entirelyEmptyUnknownColumnsRemainCompatible() throws Exception {
        assertThat(errors(workbook(new String[]{"名称","类别","用户自定义",""},new String[]{"货品","成品","",""},false))).isEmpty();
    }
    @Test void knownReadOnlyExportColumnsAreRecognizedWithoutBecomingWrites() throws Exception {
        assertThat(errors(workbook(new String[]{"名称","类别","库存量","折扣"},new String[]{"货品","成品","999","50%"},false))).isEmpty();
    }
    @Test void previewAndDirectCommitBothRejectColumnLossBeforeAnyBusinessWrite() throws Exception {
        byte[] bytes=workbook(new String[]{"名称","类别","用户自定义"},new String[]{"货品","成品","不能丢"},false);
        assertThat(service.detect(bytes).errors()).anyMatch(error->error.message().contains("不支持"));
        assertThatThrownBy(()->service.commit(null,bytes,"source.xlsx"))
                .isInstanceOf(com.uten.imp.common.web.ApiException.class).hasMessageContaining("自定义列仍有未处理问题");
    }
    @Test void markedSingleCustomPriceIsNeverMappedByItsBusinessLookingLabel() {
        String key="platform:"+java.util.UUID.randomUUID();
        byte[] bytes=new com.uten.imp.common.export.XlsxExportService().build(
                List.of(new com.uten.imp.common.export.ExportColumn(key,"价格","qty")),List.of(java.util.Map.of(key,"123.4567")));
        assertThat(service.detect(bytes).errors()).anyMatch(error->error.column().equals("自定义列")&&error.message().contains("不能按显示名称"));
        assertThatThrownBy(()->service.commit(null,bytes,"source.xlsx"))
                .isInstanceOf(com.uten.imp.common.web.ApiException.class).hasMessageContaining("自定义列");
    }
    @SuppressWarnings("unchecked")
    private List<GoodsImportError> errors(byte[] bytes) throws Exception {
        var method=GoodsImportService.class.getDeclaredMethod("parse",byte[].class);method.setAccessible(true);
        Object parsed=method.invoke(service,(Object)bytes);Field field=parsed.getClass().getDeclaredField("headerErrors");field.setAccessible(true);
        return (List<GoodsImportError>)field.get(parsed);
    }
    static byte[] workbook(String[] headers,String[] values,boolean formula) throws Exception {
        try(var book=new XSSFWorkbook();var output=new ByteArrayOutputStream()) {
            var sheet=book.createSheet("货品");var head=sheet.createRow(0);var row=sheet.createRow(1);
            for(int i=0;i<headers.length;i++){head.createCell(i).setCellValue(headers[i]);row.createCell(i).setCellValue(values[i]);}
            if(formula)row.getCell(2).setCellFormula("IF(1=1,\"\",\"原值\")");
            book.write(output);return output.toByteArray();
        }
    }
}
