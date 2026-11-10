package com.uten.imp.features.finance.gl;

import org.apache.poi.xssf.usermodel.XSSFWorkbook;
import org.junit.jupiter.api.Test;
import java.util.*;
import static org.assertj.core.api.Assertions.*;

class FinanceOperatingNoteParserTest {
    @Test void unknownPopulatedNoteColumnsAreProblemsRatherThanDiscardedSourceText() throws Exception {
        var result=FinanceOperatingNoteParser.parse(UUID.randomUUID(),"2026-09","source.xlsx","a".repeat(64),book(s->{data(s,3,4,"备注","");s.getRow(1).createCell(30).setCellValue("自定义列");s.getRow(3).createCell(30).setCellValue("不能丢");}),Map.of());
        assertThat(result.issues()).anySatisfy(issue->assertThat(issue.message()).contains("自定义列","不支持"));
    }
    @Test void matchesReorderedOriginalIdentityAndPreservesTextVersionsWhileIgnoringWorkbookAmounts()throws Exception {
        byte[] bytes=book((s)->{data(s,3,5,"第二项备注","");data(s,8,4,"","第一项差异");s.getRow(3).createCell(3).setCellValue(999999);});
        var result=FinanceOperatingNoteParser.parse(UUID.randomUUID(),"2026-09","原表.xlsx","a".repeat(64),bytes,Map.of("OP_MATERIAL_5",8L));
        assertThat(result.issues()).isEmpty();assertThat(result.rows()).hasSize(2);assertThat(result.rows().getFirst().lineKey()).isEqualTo("OP_MATERIAL_5");assertThat(result.rows().getFirst().expectedVersion()).isEqualTo(8);assertThat(result.rows().getLast().varianceReason()).isEqualTo("第一项差异");
    }
    @Test void changedCaptionOrDuplicateIdentityIsLocatedAndNeverGuessed()throws Exception {
        var result=FinanceOperatingNoteParser.parse(UUID.randomUUID(),"2026-09","原表.xlsx","a".repeat(64),book((s)->{data(s,3,4,"一","");data(s,4,4,"二","");data(s,5,5,"三","");s.getRow(5).getCell(2).setCellValue("不同项目");}),Map.of());
        assertThat(result.issues()).hasSize(2);assertThat(result.issues()).extracting(i->i.sourceRow()).containsExactly(5,6);
    }
    @Test void hiddenRowsAndFormulaNotesCannotSilentlyBecomeLiteralImportedText()throws Exception {
        assertThatThrownBy(()->FinanceOperatingNoteParser.parse(UUID.randomUUID(),"2026-09","原表.xlsx","a".repeat(64),book((s)->{data(s,3,4,"备注","");s.getRow(3).setZeroHeight(true);}),Map.of())).hasMessageContaining("隐藏");
        assertThatThrownBy(()->FinanceOperatingNoteParser.parse(UUID.randomUUID(),"2026-09","原表.xlsx","a".repeat(64),book((s)->{data(s,3,4,"备注","");s.getRow(3).getCell(28).setCellFormula("1+1");}),Map.of())).hasMessageContaining("公式");
    }
    @Test void swappedRemarkAndVarianceColumnsCannotImportToWrongFields()throws Exception {
        assertThatThrownBy(()->FinanceOperatingNoteParser.parse(UUID.randomUUID(),"2026-09","原表.xlsx","a".repeat(64),book((s)->{data(s,3,4,"备注","");s.getRow(1).getCell(28).setCellValue("差异原因");}),Map.of())).hasMessageContaining("29列");
    }
    interface Fill {void fill(org.apache.poi.ss.usermodel.Sheet s);}
    static byte[] book(Fill fill)throws Exception {try(var b=new XSSFWorkbook();var out=new java.io.ByteArrayOutputStream()){var s=b.createSheet("公司经营损益表");var header=s.createRow(1);for(int i=0;i<30;i++){header.createCell(i).setCellValue(FinanceExpenseReports.operatingColumns(9).get(i).label());}fill.fill(s);b.write(out);return out.toByteArray();}}
    static void data(org.apache.poi.ss.usermodel.Sheet sheet,int targetRow,int sourceRow,String remark,String variance){var d=FinanceExpenseTemplateCatalog.operatingRows().stream().filter(r->r.sourceRow()==sourceRow).findFirst().orElseThrow();var row=sheet.createRow(targetRow);row.createCell(0).setCellValue(d.category());row.createCell(1).setCellValue(d.sub());row.createCell(2).setCellValue(d.item());row.createCell(28).setCellValue(remark);row.createCell(29).setCellValue(variance);}
}
