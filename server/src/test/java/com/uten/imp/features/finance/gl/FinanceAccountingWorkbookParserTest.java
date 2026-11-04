package com.uten.imp.features.finance.gl;

import org.apache.poi.hssf.usermodel.HSSFWorkbook;
import org.junit.jupiter.api.*;
import java.io.*;
import java.nio.*;
import java.nio.charset.Charset;
import java.nio.file.*;
import java.math.BigDecimal;
import java.util.*;
import static org.assertj.core.api.Assertions.*;

class FinanceAccountingWorkbookParserTest {
    @Test void rawBiff3GbkBalancesAndLiteral83ColumnJournalsReconcileWithoutExecutingFileFlags() throws Exception {
        var balance=FinanceAccountingWorkbookParser.parse("BALANCE","balances.xls",balance());
        var journals=FinanceAccountingWorkbookParser.parse("VOUCHERS","journals.xls",journals(false,false));
        assertThat(balance.issues()).isEmpty();assertThat(journals.issues()).isEmpty();
        assertThat(balance.balances()).extracting(row->row.accountCode()).containsExactly("1001","5001");
        assertThat(journals.vouchers()).hasSize(1);
        assertThat(journals.vouchers().getFirst().entries().getFirst().source()).containsEntry("F39","true");
        assertThat(journals.vouchers().getFirst().entries().getFirst().number()).isEqualTo("0001");
        assertThat(FinanceAccountingWorkbookParser.reconcile(journals,balance)).isEmpty();
    }
    @Test void duplicateEntryIdentityAndUnbalancedVoucherAreLocatedRatherThanSilentlyDropped() throws Exception {
        var parsed=FinanceAccountingWorkbookParser.parse("VOUCHERS","journals.xls",journals(true,false));
        assertThat(parsed.issues()).anySatisfy(issue->assertThat(issue.message()).contains("分录自动编号重复"));
        assertThat(parsed.issues()).anySatisfy(issue->assertThat(issue.message()).contains("借贷不平"));
    }
    @Test void numericVoucherNumbersAreRejectedBeforeLeadingZerosCanBeGuessed() throws Exception {
        var parsed=FinanceAccountingWorkbookParser.parse("VOUCHERS","journals.xls",journals(false,true));
        assertThat(parsed.issues()).anySatisfy(issue->assertThat(issue.message()).contains("凭证号须保留原始文本"));
    }
    @Test void sourcePeriodAndOccurrenceMismatchCannotCertifyCompleteness() throws Exception {
        var balance=FinanceAccountingWorkbookParser.parse("BALANCE","balances.xls",balance());
        var parsed=FinanceAccountingWorkbookParser.parse("VOUCHERS","journals.xls",journals(false,false));
        try(var book=new HSSFWorkbook(new ByteArrayInputStream(journals(false,false)));var out=new ByteArrayOutputStream()) {
            book.getSheetAt(0).getRow(1).getCell(6).setCellValue(99);
            book.write(out);
            assertThat(FinanceAccountingWorkbookParser.reconcile(FinanceAccountingWorkbookParser.parse("VOUCHERS","journals.xls",out.toByteArray()),balance))
                    .anySatisfy(issue->assertThat(issue.message()).contains("当期借贷发生额"));
        }
        assertThat(parsed.vouchers().getFirst().closingCandidate()).isFalse();
    }
    @Test void privateSuppliedFilesAreReadOnlyOptionalEvidence() throws Exception {
        String root=System.getenv("UTEN_FINANCE_SOURCE_DIR");Assumptions.assumeTrue(root!=null&&!root.isBlank());
        var folder=Path.of(root);Path voucher=folder.resolve("2026年9月份会计分录凭证.xls");
        Path balance;
        try(var files=Files.walk(folder)){balance=files.filter(file->file.getFileName().toString().matches(".*9月份科目余额表.xls")).findFirst().orElseThrow();}
        var journals=FinanceAccountingWorkbookParser.parse("VOUCHERS",voucher.getFileName().toString(),Files.readAllBytes(voucher));
        var balances=FinanceAccountingWorkbookParser.parse("BALANCE",balance.getFileName().toString(),Files.readAllBytes(balance));
        assertThat(journals.issues()).isEmpty();assertThat(balances.issues()).isEmpty();
        assertThat(journals.vouchers()).hasSize(8);
        assertThat(journals.vouchers().stream().mapToInt(value->value.entries().size()).sum()).isEqualTo(813);
        assertThat(journals.vouchers().stream().filter(value->value.closingCandidate()).count()).isEqualTo(1);
        assertThat(FinanceAccountingWorkbookParser.reconcile(journals,balances)).hasSize(2)
                .allSatisfy(issue->assertThat(issue.message()).contains("原凭证科目560301在余额文件中缺失"));
    }
    private static byte[] journals(boolean duplicate,boolean numericVoucher) throws Exception {
        try(var book=new HSSFWorkbook();var out=new ByteArrayOutputStream()) {
            var sheet=book.createSheet("原始凭证");var header=sheet.createRow(0);
            for(int col=0;col<82;col++)header.createCell(col).setCellValue("F"+(col+1)+"原表头");
            header.createCell(82).setCellValue("凭证输出：V800：T01：匿名账套：2026");
            for(int index=0;index<2;index++) {
                var row=sheet.createRow(index+1);
                Map<Integer,String> strings=Map.ofEntries(Map.entry(0,"2026-09-30"),Map.entry(1,"记"),Map.entry(2,"0001"),Map.entry(4,"匿名销售业务"),
                        Map.entry(5,index==0?"1001":"5001"),Map.entry(38,"true"),Map.entry(48,"T01"),Map.entry(49,"匿名账套"),Map.entry(61,index==0?"库存现金":"主营业务收入"));
                strings.forEach((col,text)->row.createCell(col).setCellValue(text));
                row.createCell(index==0?6:7).setCellValue(100);
                row.createCell(50).setCellValue(2026);row.createCell(51).setCellValue(9);row.createCell(58).setCellValue(index+1);
                row.createCell(80).setCellValue(duplicate?1:index+1);row.createCell(81).setCellValue(901);
                if(numericVoucher&&index==0)row.getCell(2).setCellValue(1);
            }
            book.write(out);return out.toByteArray();
        }
    }
    private static byte[] balance() throws Exception {
        try(var out=new ByteArrayOutputStream()) {
            record(out,0x0209,new byte[]{0,3,0x10,0,0,0});
            var labels=List.of("会计年度","会计期间","科目编码","科目名称","外币名称","期初借方","期初贷方","本期发生借方","本期发生贷方","期末借方","期末贷方");
            for(int col=0;col<labels.size();col++)label(out,0,col,labels.get(col));
            for(int row=1;row<=2;row++) {
                number(out,row,0,2026);number(out,row,1,9);label(out,row,2,row==1?"1001":"5001");
                label(out,row,3,row==1?"库存现金":"主营业务收入");label(out,row,4,"");
                for(int col=5;col<=10;col++)number(out,row,col,(row==1&&(col==7||col==9))||(row==2&&(col==8||col==10))?100:0);
            }
            record(out,0x000a,new byte[0]);return out.toByteArray();
        }
    }
    private static void label(ByteArrayOutputStream out,int row,int col,String value)throws Exception {
        byte[] text=value.getBytes(Charset.forName("GBK"));var data=ByteBuffer.allocate(text.length+8).order(ByteOrder.LITTLE_ENDIAN);
        data.putShort((short)row).putShort((short)col).putShort((short)0).putShort((short)text.length).put(text);record(out,0x0204,data.array());
    }
    private static void number(ByteArrayOutputStream out,int row,int col,double value)throws Exception {
        var data=ByteBuffer.allocate(14).order(ByteOrder.LITTLE_ENDIAN);data.putShort((short)row).putShort((short)col).putShort((short)0).putDouble(value);record(out,0x0203,data.array());
    }
    private static void record(ByteArrayOutputStream out,int sid,byte[] data)throws Exception {
        out.write(ByteBuffer.allocate(4).order(ByteOrder.LITTLE_ENDIAN).putShort((short)sid).putShort((short)data.length).array());out.write(data);
    }
}
