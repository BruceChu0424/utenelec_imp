package com.uten.imp.features.finance.gl;

import com.uten.imp.common.web.ApiException;
import org.apache.poi.xssf.usermodel.XSSFWorkbook;
import org.junit.jupiter.api.Test;
import java.io.ByteArrayOutputStream;
import java.util.UUID;
import static org.assertj.core.api.Assertions.*;

class FinanceChartWorkbookParserTest {
    @Test void suppliedXlsKeepsAll177CodesTheirOrderAndCurrencyWithoutCreatingZeroBalances()throws Exception {
        byte[] bytes=getClass().getResourceAsStream("/finance/finance-chart-codes.xls").readAllBytes();
        var result=FinanceChartWorkbookParser.parse(UUID.randomUUID(),"2026年9月份科目余额表代码.xls","source",bytes);
        assertThat(result.issues()).isEmpty();assertThat(result.rows()).hasSize(177);
        assertThat(result.rows().getFirst().code()).isEqualTo("1001");
        assertThat(result.rows().getLast().code()).isEqualTo("571106");
        assertThat(result.rows()).filteredOn(r->r.code().equals("112202")).singleElement()
                .satisfies(r->assertThat(r.currencyName()).isEqualTo("美元"));
        assertThat(result.rows()).extracting(FinanceChartContracts.SourceRow::code).doesNotHaveDuplicates();
    }
    @Test void duplicateCodesAndBalanceValuesProduceLocatedIssuesInsteadOfPartialImports()throws Exception {
        var result=parse(workbook((book,sheet)->{
            sheet.createRow(1).createCell(0).setCellValue("000001");sheet.getRow(1).createCell(1).setCellValue("现金");
            sheet.createRow(2).createCell(0).setCellValue("000001");sheet.getRow(2).createCell(1).setCellValue("同名");
            sheet.getRow(2).createCell(3).setCellValue(123);
        }));
        assertThat(result.rows().getFirst().code()).isEqualTo("000001");
        assertThat(result.issues()).hasSize(2).allSatisfy(i->assertThat(i.sourceRow()).isEqualTo(3));
    }
    @Test void hiddenRecordsAndFormulaIdentitiesAreRejected()throws Exception {
        assertThatThrownBy(()->parse(workbook((book,sheet)->{
            var row=sheet.createRow(1);row.createCell(0).setCellValue("1001");row.createCell(1).setCellValue("现金");row.setZeroHeight(true);
        }))).isInstanceOf(ApiException.class);
        assertThatThrownBy(()->parse(workbook((book,sheet)->{
            var row=sheet.createRow(1);row.createCell(0).setCellFormula("1000+1");row.createCell(1).setCellValue("现金");
        }))).isInstanceOf(ApiException.class);
    }
    @Test void numericIdentityNeverSilentlyLosesLeadingZeroes()throws Exception {
        var result=parse(workbook((book,sheet)->{
            var row=sheet.createRow(1);row.createCell(0).setCellValue(1);row.createCell(1).setCellValue("现金");
        }));
        assertThat(result.issues()).anySatisfy(i->{assertThat(i.field()).isEqualTo("科目编码");assertThat(i.message()).contains("文本");});
    }
    private static FinanceChartContracts.Preview parse(byte[] bytes){return FinanceChartWorkbookParser.parse(UUID.randomUUID(),"chart.xlsx","source",bytes);}
    private static byte[] workbook(java.util.function.BiConsumer<XSSFWorkbook,org.apache.poi.ss.usermodel.Sheet> fill)throws Exception {
        try(var book=new XSSFWorkbook();var out=new ByteArrayOutputStream()) {
            var sheet=book.createSheet("科目");var row=sheet.createRow(0);
            row.createCell(0).setCellValue("科目编码");row.createCell(1).setCellValue("科目名称");row.createCell(2).setCellValue("外币名称");
            fill.accept(book,sheet);book.write(out);return out.toByteArray();
        }
    }
}
