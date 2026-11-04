package com.uten.imp.common.files.document;

import java.io.*;
import java.util.zip.*;
import org.apache.poi.xssf.usermodel.XSSFWorkbook;
import org.junit.jupiter.api.Test;
import static org.assertj.core.api.Assertions.*;

class FinancialSpreadsheetProfileTest {
    @Test void ordinaryIntakeStillHasEightSheetsWhileFinancialWorkbookUsesItsExplicitBound()throws Exception {
        byte[] bytes;
        try(var wb=new XSSFWorkbook();var out=new ByteArrayOutputStream()){
            for(int i=0;i<9;i++)wb.createSheet("原表"+i).createRow(0).createCell(0).setCellValue("原表字段");
            wb.write(out);bytes=out.toByteArray();
        }
        assertThatThrownBy(()->SpreadsheetGridReader.read(bytes,DocumentKind.XLSX)).hasMessageContaining("8 个可见工作表");
        assertThat(SpreadsheetGridReader.read(bytes,DocumentKind.XLSX,DocumentIntakeProfile.FINANCIAL_TEMPLATE).sheets()).hasSize(9);
        assertThat(DocumentIntakeProfile.DEFAULT.maxBytes()).isEqualTo(15L*1024*1024);
        assertThat(DocumentIntakeProfile.FINANCIAL_TEMPLATE.maxBytes()).isEqualTo(15L*1024*1024);
        try(var wb=new XSSFWorkbook();var out=new ByteArrayOutputStream()){
            for(int i=0;i<33;i++)wb.createSheet("原表"+i).createRow(0).createCell(0).setCellValue("原表字段");
            wb.write(out);byte[] excessive=out.toByteArray();
            assertThatThrownBy(()->SpreadsheetGridReader.read(excessive,DocumentKind.XLSX,DocumentIntakeProfile.FINANCIAL_TEMPLATE)).hasMessageContaining("32 个工作表");
        }
    }
    @Test void financialProfilePreservesHiddenRowsColumnsAndSheetsWithoutChangingDefault()throws Exception {
        byte[] bytes;
        try(var wb=new XSSFWorkbook();var out=new ByteArrayOutputStream()) {
            var sheet=wb.createSheet("原表");sheet.createRow(0).createCell(0).setCellValue("表头");
            sheet.getRow(0).createCell(1).setCellValue("隐藏月");sheet.setColumnHidden(1,true);
            var row=sheet.createRow(1);row.createCell(0).setCellValue("隐藏资产");row.setZeroHeight(true);
            wb.createSheet("历史完成").createRow(0).createCell(0).setCellValue("历史事实");wb.setSheetHidden(1,true);
            wb.write(out);bytes=out.toByteArray();
        }
        var normal=SpreadsheetGridReader.read(bytes,DocumentKind.XLSX);
        assertThat(normal.hiddenIncluded()).isFalse();assertThat(normal.sheets()).hasSize(1);
        assertThat(normal.sheets().getFirst().text(0,1)).isEmpty();assertThat(normal.sheets().getFirst().skippedHiddenRows()).isEqualTo(1);
        var finance=SpreadsheetGridReader.read(bytes,DocumentKind.XLSX,DocumentIntakeProfile.FINANCIAL_TEMPLATE);
        assertThat(finance.hiddenIncluded()).isTrue();assertThat(finance.sheets()).hasSize(2);
        assertThat(finance.sheets().getFirst().text(0,1)).isEqualTo("隐藏月");
        assertThat(finance.sheets().getFirst().text(1,0)).isEqualTo("隐藏资产");
        assertThat(finance.sheets().getFirst().skippedHiddenRows()).isZero();assertThat(finance.sheets().getFirst().truncated()).isFalse();
    }
    @Test void onlyAssetProfileAdmitsImageHeavySourceAndAllProfilesStillRejectActiveContent()throws Exception {
        var out=new ByteArrayOutputStream();
        try(var zip=new ZipOutputStream(out)) {
            for(String part:new String[]{"[Content_Types].xml","xl/workbook.xml"}){zip.putNextEntry(new ZipEntry(part));zip.write("<x/>".getBytes());zip.closeEntry();}
            zip.putNextEntry(new ZipEntry("xl/media/image1.png"));
            byte[] chunk=new byte[1024*1024];var random=new java.util.SplittableRandom(994);
            for(int i=0;i<chunk.length;i+=8){long bits=random.nextLong();for(int j=0;j<8;j++)chunk[i+j]=(byte)(bits>>>(j*8));}
            for(int n=0;n<17;n++){zip.write(chunk);}zip.closeEntry();
        }
        byte[] bytes=out.toByteArray();assertThat(bytes.length).isGreaterThan(15*1024*1024);
        assertThatThrownBy(()->ZipSafety.inspectSpreadsheet(bytes)).hasMessageContaining("15 MB");
        assertThat(ZipSafety.inspectSpreadsheet(bytes,DocumentIntakeProfile.FINANCIAL_ASSET)).contains("xl/media/image1.png");
        out.reset();try(var zip=new ZipOutputStream(out)){zip.putNextEntry(new ZipEntry("xl/vbaProject.bin"));zip.write(1);zip.closeEntry();}
        assertThatThrownBy(()->ZipSafety.inspectSpreadsheet(out.toByteArray(),DocumentIntakeProfile.FINANCIAL_ASSET)).hasMessageContaining("宏");
    }
}
