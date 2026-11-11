package com.uten.imp.features.finance.gl;

import com.uten.imp.common.importing.ImportColumnGuard;
import com.uten.imp.common.web.ApiException;
import org.junit.jupiter.api.Test;
import java.util.*;
import static org.assertj.core.api.Assertions.*;

/** Exact independently audited files; these assertions express the corrected contract. */
class WorkbookColumnRemediationTest {
    @Test void subtotalAndOrdinaryRowsBothRetainLocatedUnknownColumnProblems() throws Exception {
        for(String name:List.of("chart-true.xlsx","chart-false.xlsx")) {
            var preview=FinanceChartWorkbookParser.parse(UUID.randomUUID(),name,"source",file(name));
            assertThat(preview.rows()).extracting(FinanceChartContracts.SourceRow::code).containsExactly("1001");
            assertThat(preview.issues()).anySatisfy(issue->{assertThat(issue.field()).isEqualTo("追加约定");assertThat(issue.sourceRow()).isEqualTo(name.equals("chart-true.xlsx")?3:2);});
            assertThat(preview.columnContractVersion()).isEqualTo(ImportColumnGuard.VERSION);
        }
    }
    @Test void innerMonthColumnCannotImpersonateANoteOrDisappearAsUnknown() throws Exception {
        for(String name:List.of("note-duplicate.xlsx","note-unknown.xlsx"))
            assertThatThrownBy(()->FinanceOperatingNoteParser.parse(UUID.randomUUID(),"2026-09",name,"source",file(name),Map.of()))
                    .isInstanceOf(ApiException.class).hasMessageContaining("第4列");
    }
    @Test void physicalEmptyCacheFormulaAndReplacedSignatureCannotCertifyAVoucher() throws Exception {
        var formula=FinanceAccountingWorkbookParser.parse("VOUCHERS","voucher.xls",file("voucher-empty-formula.xls"));
        assertThat(formula.issues()).anySatisfy(issue->{assertThat(issue.sourceRow()).isEqualTo(2);assertThat(issue.field()).contains("84");});
        assertThatThrownBy(()->FinanceAccountingWorkbookParser.parse("VOUCHERS","voucher.xls",file("voucher-wrong-signature.xls")))
                .isInstanceOf(ApiException.class).hasMessageContaining("输出签名");
        assertThat(FinanceAccountingWorkbookParser.parse("VOUCHERS","voucher.xls",file("voucher-style.xls")).issues()).isEmpty();
    }
    @Test void everyEarlierServerSafetyVersionIsRetired() {
        for(int version:List.of(0,1,2,ImportColumnGuard.VERSION+1,Integer.MAX_VALUE))assertThatThrownBy(()->ImportColumnGuard.requireValidated(version))
                .isInstanceOf(ApiException.class).hasMessageContaining("重新生成文件");
        assertThatCode(()->ImportColumnGuard.requireValidated(ImportColumnGuard.VERSION)).doesNotThrowAnyException();
    }
    @Test void originalCompanyPunctuationDoesNotInvalidateAnOtherwiseMatchingSignature() throws Exception {
        try(var book=new org.apache.poi.hssf.usermodel.HSSFWorkbook(new java.io.ByteArrayInputStream(file("voucher-style.xls")));var out=new java.io.ByteArrayOutputStream()) {
            var sheet=book.getSheetAt(0);sheet.getRow(0).getCell(82).setCellValue("凭证输出：V800：T01：匿名：账套：2026");
            for(int row=1;row<=2;row++)sheet.getRow(row).getCell(49).setCellValue("匿名：账套");book.write(out);
            assertThat(FinanceAccountingWorkbookParser.parse("VOUCHERS","source.xls",out.toByteArray()).issues()).isEmpty();
        }
    }
    @Test void anExtraSheetWithOnlyAnEmptyCacheFormulaIsStillARealInput() throws Exception {
        try(var book=new org.apache.poi.hssf.usermodel.HSSFWorkbook(new java.io.ByteArrayInputStream(file("voucher-style.xls")));var out=new java.io.ByteArrayOutputStream()) {
            var cell=book.createSheet("额外表").createRow(0).createCell(83);cell.setCellFormula("IF(1=1,\"\",\"\")");book.getCreationHelper().createFormulaEvaluator().evaluateFormulaCell(cell);book.write(out);
            assertThatThrownBy(()->FinanceAccountingWorkbookParser.parse("VOUCHERS","source.xls",out.toByteArray()))
                    .isInstanceOf(ApiException.class).hasMessageContaining("额外表");
        }
    }
    private byte[] file(String name)throws Exception {try(var in=getClass().getResourceAsStream("/import-column-remediation/"+name)){return Objects.requireNonNull(in).readAllBytes();}}
}
