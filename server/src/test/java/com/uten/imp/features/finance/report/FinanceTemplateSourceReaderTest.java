package com.uten.imp.features.finance.report;

import com.uten.imp.common.files.document.DocumentIntakeProfile;
import com.uten.imp.common.storage.ImmutableDocumentStore;
import com.uten.imp.features.finance.gl.FinanceTemplateContract;
import java.io.ByteArrayOutputStream;
import java.nio.file.*;
import java.util.UUID;
import org.apache.poi.xssf.usermodel.XSSFWorkbook;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import static org.assertj.core.api.Assertions.*;

class FinanceTemplateSourceReaderTest {
    @Test void sameWorkbookAttachmentsRequireExplicitSheetAndKeepEveryOriginalDigit()throws Exception{
        byte[] bytes;try(var book=new XSSFWorkbook();var out=new ByteArrayOutputStream()){
            for(String name:new String[]{"原附件甲","原附件乙"}){var sheet=book.createSheet(name);var header=sheet.createRow(2);for(int col=0;col<6;col++)header.createCell(col).setCellValue(FinanceTemplateContract.header("copperDetail",col));
                var row=sheet.createRow(3);row.createCell(0).setCellValue("2026-09-01");row.createCell(1).setCellValue(name);row.createCell(2).setCellValue("1.000000000000000000000001");row.createCell(3).setCellValue("KG");row.createCell(4).setCellValue("3");row.createCell(5).setCellValue("PCS");}
            book.write(out);bytes=out.toByteArray();
        }
        String hash=ImmutableDocumentStore.digest(bytes);
        assertThatThrownBy(()->FinanceTemplateSourceReader.read(UUID.randomUUID(),"copperDetail","2026-09","原附件.xlsx",hash,bytes,DocumentIntakeProfile.FINANCIAL_TEMPLATE))
            .isInstanceOfSatisfying(com.uten.imp.common.web.ApiException.class,error->assertThat(error.getFieldErrors()).extracting(com.uten.imp.common.web.ApiError.FieldError::message).containsExactly("原附件甲","原附件乙"));
        for(String sheet:new String[]{"原附件甲","原附件乙"}){
            var p=FinanceTemplateSourceReader.read(UUID.randomUUID(),"copperDetail","2026-09","原附件.xlsx",hash,bytes,DocumentIntakeProfile.FINANCIAL_TEMPLATE,sheet);
            assertThat(p.sourceSheet()).isEqualTo(sheet);assertThat(p.rows()).hasSize(1);assertThat(p.rows().getFirst().cells()).anySatisfy(cell->assertThat(cell.text()).isEqualTo("1.000000000000000000000001"));
        }
        assertThatThrownBy(()->FinanceTemplateSourceReader.read(UUID.randomUUID(),"copperDetail","2026-09","原附件.xlsx",hash,bytes,DocumentIntakeProfile.FINANCIAL_TEMPLATE,"不存在"))
            .hasMessageContaining("没有所选工作表");
    }
    @Test void originalLeafOrderAndDuplicateUnitHeadersAreRetainedAndAChangedOrderIsRejected()throws Exception {
        byte[] source=workbook(false);
        var p=FinanceTemplateSourceReader.read(UUID.randomUUID(),"copperDetail","2026-09","匿名明细.xlsx",ImmutableDocumentStore.digest(source),source,DocumentIntakeProfile.FINANCIAL_TEMPLATE);
        assertThat(p.headers()).containsExactly("时间","货品名称","重量","单位","数量","单位");
        assertThat(p.hiddenIncluded()).isTrue();assertThat(p.rows()).hasSize(1);assertThat(p.rows().getFirst().sourceRow()).isEqualTo(4);
        assertThat(p.rows().getFirst().cells()).anySatisfy(c->{assertThat(c.column()).isEqualTo(3);assertThat(c.number()).isEqualTo("1.0001");});
        byte[] swapped=workbook(true);
        assertThatThrownBy(()->FinanceTemplateSourceReader.read(UUID.randomUUID(),"copperDetail","2026-09","错序.xlsx",ImmutableDocumentStore.digest(swapped),swapped,DocumentIntakeProfile.FINANCIAL_TEMPLATE)).hasMessageContaining("列名和顺序");
    }
    @Test @EnabledIfEnvironmentVariable(named="FINANCE_REAL_ASSET_FILE",matches=".+")
    void privateSeptemberWorkbookIncludesAllThreeOriginalSheetsAndHiddenColumns()throws Exception {
        byte[] bytes=Files.readAllBytes(Path.of(System.getenv("FINANCE_REAL_ASSET_FILE")));
        String hash=ImmutableDocumentStore.digest(bytes);
        assertThat(hash).isEqualTo("7b68d284343175c7e89b9d1d1f4d085cee899a1e6f657a4687ce7a3eb7020778");
        for(String key:new String[]{"depreciation","amortization","depreciationCompleted"}){
            var p=FinanceTemplateSourceReader.read(UUID.randomUUID(),key,"2026-09","2026年9月固定资产明细表.xlsx",hash,bytes,DocumentIntakeProfile.FINANCIAL_ASSET);
            assertThat(p.headers()).hasSize(FinanceTemplateContract.template(key).required("headers").size());
            assertThat(p.rows().size()).isGreaterThan(key.equals("depreciation")?900:key.equals("amortization")?60:180);
            assertThat(p.hiddenIncluded()).isTrue();assertThat(p.issues()).isEmpty();
        }
    }
    @Test void materialOriginalTenColumnsAndHiddenSupplementalCachedFactsRetainCoordinatesWithoutExecutingFormulas()throws Exception{
        byte[] bytes;try(var workbook=new XSSFWorkbook();var out=new ByteArrayOutputStream()){
            var sheet=workbook.createSheet("匿名金本原表");var header=sheet.createRow(2);for(int col=0;col<10;col++)header.createCell(col).setCellValue(FinanceTemplateContract.header("otherReceivableStatement",col));
            var top=sheet.createRow(3);String[] names={"名称","单位","数量","单价","金额"};for(int col=0;col<5;col++)top.createCell(11+col).setCellValue(names[col]);
            var row=sheet.createRow(4);row.createCell(0).setCellValue("2026-09-01");row.createCell(1).setCellValue("匿名产品原文");row.createCell(9).setCellValue(10);row.createCell(11).setCellValue("匿名旁算原文");var amount=row.createCell(16);amount.setCellFormula("P5/0.87");amount.getCTCell().setV("12345678901234.000000000000000000000001");
            sheet.createRow(14).createCell(14).setCellErrorValue(org.apache.poi.ss.usermodel.FormulaError.DIV0.getCode());for(int col=11;col<=16;col++)sheet.setColumnHidden(col,true);workbook.write(out);bytes=out.toByteArray();
        }
        var preview=FinanceTemplateSourceReader.read(UUID.randomUUID(),"otherReceivableStatement","2026-09","anonymous.xlsx",ImmutableDocumentStore.digest(bytes),bytes,DocumentIntakeProfile.FINANCIAL_TEMPLATE);
        assertThat(preview.headers()).hasSize(10);assertThat(preview.hiddenIncluded()).isTrue();assertThat(preview.rows()).allSatisfy(row->assertThat(row.cells()).allSatisfy(cell->assertThat(cell.column()).isLessThanOrEqualTo(10)));
        assertThat(preview.supplementalCells()).anySatisfy(cell->{assertThat(cell.sourceCell()).isEqualTo("Q5");assertThat(cell.number()).isEqualTo("12345678901234.000000000000000000000001");});
        assertThat(preview.supplementalCells()).anySatisfy(cell->{assertThat(cell.sourceCell()).isEqualTo("O15");assertThat(cell.kind()).isEqualTo("ERROR");assertThat(cell.text()).isEqualTo("#DIV/0!");});
        assertThat(preview.supplementalCells()).noneSatisfy(cell->assertThat(cell.sourceCell()).isEqualTo("Q4"));
    }
    private static byte[] workbook(boolean swapped)throws Exception {
        try(var w=new XSSFWorkbook();var out=new ByteArrayOutputStream()){
            var sheet=w.createSheet("原表");var header=sheet.createRow(2);
            String[] names={"时间","货品名称","重量","单位","数量","单位"};
            if(swapped){names[2]="数量";names[4]="重量";}
            for(int i=0;i<names.length;i++)header.createCell(i).setCellValue(names[i]);
            var row=sheet.createRow(3);row.createCell(0).setCellValue("2026-09-01");row.createCell(1).setCellValue("匿名产品");row.createCell(2).setCellValue(1.0001);row.createCell(3).setCellValue("KG");row.createCell(4).setCellValue(2);row.createCell(5).setCellValue("个");
            sheet.setColumnHidden(2,true);w.write(out);return out.toByteArray();
        }
    }
}
