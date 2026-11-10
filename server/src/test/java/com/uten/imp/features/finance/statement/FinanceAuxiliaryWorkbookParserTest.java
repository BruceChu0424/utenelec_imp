package com.uten.imp.features.finance.statement;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.finance.gl.FinanceTemplateContract;
import org.apache.poi.xssf.usermodel.XSSFWorkbook;
import org.junit.jupiter.api.Test;
import java.io.ByteArrayOutputStream;
import java.util.function.Consumer;
import static org.assertj.core.api.Assertions.*;

class FinanceAuxiliaryWorkbookParserTest {
    @Test void populatedUnknownColumnsAreLocatedButAnEmptyTailIsAllowed() throws Exception {
        var invalid=FinanceAuxiliaryWorkbookParser.parse(true,"source.xlsx",file(true,w->{w.getSheetAt(0).getRow(2).createCell(14).setCellValue("用户自定义");w.getSheetAt(0).getRow(3).createCell(14).setCellValue("不能丢");}));
        assertThat(invalid.issues()).anySatisfy(issue->assertThat(issue.message()).contains("自定义","不支持"));
        var valid=FinanceAuxiliaryWorkbookParser.parse(true,"source.xlsx",file(true,w->w.getSheetAt(0).getRow(2).createCell(14).setCellValue("空尾列")));
        assertThat(valid.issues()).isEmpty();
    }
    @Test void preservesLiteralSourceCodesAndOriginalFourteenHeaderOrder()throws Exception {
        for(boolean receivable:new boolean[]{true,false}) {
            var parsed=FinanceAuxiliaryWorkbookParser.parse(receivable,"anonymous.xlsx",file(receivable,w->{}));
            assertThat(parsed.issues()).isEmpty();assertThat(parsed.rows()).hasSize(1);
            var row=parsed.rows().getFirst();assertThat(row.partyCode()).isEqualTo("00017");
            assertThat(row.openingDebit()).isEqualByComparingTo("100.1234");assertThat(row.closingBalance()).isEqualByComparingTo("113.1235");
        }
    }
    @Test void rejectsHeaderRenamingAndComputedOrHiddenIdentities()throws Exception {
        assertThatThrownBy(()->FinanceAuxiliaryWorkbookParser.parse(false,"anonymous.xlsx",file(false,w->w.getSheetAt(0).getRow(2).getCell(5).setCellValue("期初贷方余额"))))
                .isInstanceOf(ApiException.class).hasMessageContaining("期初贷款余额");
        assertThatThrownBy(()->FinanceAuxiliaryWorkbookParser.parse(true,"anonymous.xlsx",file(true,w->w.getSheetAt(0).getRow(3).getCell(2).setCellFormula("\"00017\""))))
                .isInstanceOf(ApiException.class).hasMessageContaining("公式");
        assertThatThrownBy(()->FinanceAuxiliaryWorkbookParser.parse(true,"anonymous.xlsx",file(true,w->w.getSheetAt(0).getRow(3).setZeroHeight(true))))
                .isInstanceOf(ApiException.class);
    }
    @Test void missingAndWrongAmountsAreIssuesAndNeverSilentlyReplacedByZero()throws Exception {
        var absent=FinanceAuxiliaryWorkbookParser.parse(true,"anonymous.xlsx",file(true,w->w.getSheetAt(0).getRow(3).getCell(8).setBlank()));
        assertThat(absent.rows().getFirst().debit()).isNull();assertThat(absent.issues()).anySatisfy(i->assertThat(i.message()).contains("不能按零"));
        var wrong=FinanceAuxiliaryWorkbookParser.parse(true,"anonymous.xlsx",file(true,w->w.getSheetAt(0).getRow(3).getCell(13).setCellValue(999)));
        assertThat(wrong.issues()).anySatisfy(i->assertThat(i.message()).contains("期末借方减贷方"));
        var lostCode=FinanceAuxiliaryWorkbookParser.parse(true,"anonymous.xlsx",file(true,w->w.getSheetAt(0).getRow(3).getCell(2).setCellValue(17)));
        assertThat(lostCode.issues()).anySatisfy(i->assertThat(i.message()).contains("前导0"));
    }
    private static byte[] file(boolean receivable,Consumer<XSSFWorkbook> change)throws Exception {
        try(var workbook=new XSSFWorkbook();var bytes=new ByteArrayOutputStream()) {
            var sheet=workbook.createSheet("匿名明细");var header=sheet.createRow(2);
            String key=receivable?"receivableAuxiliaryDetail":"payableAuxiliaryDetail";
            for(int col=0;col<14;col++)header.createCell(col).setCellValue(FinanceTemplateContract.header(key,col));
            var row=sheet.createRow(3);row.createCell(0).setCellValue(receivable?"112201":"2202");row.createCell(1).setCellValue("原科目名称");row.createCell(2).setCellValue("00017");row.createCell(3).setCellValue("匿名对象");
            row.createCell(receivable?4:6).setCellValue("借");row.createCell(receivable?5:4).setCellValue(100.1234);row.createCell(receivable?6:5).setCellValue(0);
            row.createCell(7).setCellValue(100.1234);row.createCell(8).setCellValue(20.0001);row.createCell(9).setCellValue(7);
            row.createCell(10).setCellValue(113.1235);row.createCell(11).setCellValue(0);row.createCell(12).setCellValue("借");row.createCell(13).setCellValue(113.1235);
            change.accept(workbook);workbook.write(bytes);return bytes.toByteArray();
        }
    }
}
