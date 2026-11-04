package com.uten.imp.common.files.document;

import java.math.BigDecimal;
import java.io.*;
import java.nio.charset.StandardCharsets;
import java.util.*;
import java.util.zip.*;
import org.junit.jupiter.api.Test;
import static org.assertj.core.api.Assertions.*;

class SpreadsheetExactNumberTest {
    @Test void storedFiniteDecimalNeverBecomesAnExcelFifteenDigitApproximation(){
        for(String raw:List.of("12345678901234.0001","0.123456789012345678901234567890","1.9999999999999999","-999999999999999999999999.000000000000000000000001"))
            assertThat(SpreadsheetGridReader.excelNumber(new BigDecimal(raw))).isEqualByComparingTo(raw);
        assertThat(SpreadsheetGridReader.excelNumber(BigDecimal.valueOf(0.12345678901234568))).isEqualByComparingTo("0.12345678901234568");
        assertThatThrownBy(()->SpreadsheetGridReader.excelNumber(new BigDecimal("1E+1000000000"))).isInstanceOf(IllegalArgumentException.class);
        assertThatThrownBy(()->SpreadsheetGridReader.excelNumber(new BigDecimal("1E-1000000000"))).isInstanceOf(IllegalArgumentException.class);
    }
    @Test void actualXlsxStoredValuesRetainAllDigitsBeforeAnyBusinessPrecisionChoice()throws Exception{
        var parts=new LinkedHashMap<String,String>();
        parts.put("[Content_Types].xml","<Types xmlns='http://schemas.openxmlformats.org/package/2006/content-types'><Default Extension='rels' ContentType='application/vnd.openxmlformats-package.relationships+xml'/><Default Extension='xml' ContentType='application/xml'/><Override PartName='/xl/workbook.xml' ContentType='application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml'/><Override PartName='/xl/worksheets/sheet1.xml' ContentType='application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml'/></Types>");
        parts.put("_rels/.rels","<Relationships xmlns='http://schemas.openxmlformats.org/package/2006/relationships'><Relationship Id='rId1' Type='http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument' Target='xl/workbook.xml'/></Relationships>");
        parts.put("xl/workbook.xml","<workbook xmlns='http://schemas.openxmlformats.org/spreadsheetml/2006/main' xmlns:r='http://schemas.openxmlformats.org/officeDocument/2006/relationships'><sheets><sheet name='精确原值' sheetId='1' r:id='rId1'/></sheets></workbook>");
        parts.put("xl/_rels/workbook.xml.rels","<Relationships xmlns='http://schemas.openxmlformats.org/package/2006/relationships'><Relationship Id='rId1' Type='http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet' Target='worksheets/sheet1.xml'/></Relationships>");
        parts.put("xl/worksheets/sheet1.xml","<worksheet xmlns='http://schemas.openxmlformats.org/spreadsheetml/2006/main'><sheetData><row r='1'><c r='A1'><v>12345678901234.0001</v></c><c r='B1'><v>0.123456789012345678901234567890</v></c></row></sheetData></worksheet>");
        var out=new ByteArrayOutputStream();try(var zip=new ZipOutputStream(out)){for(var p:parts.entrySet()){zip.putNextEntry(new ZipEntry(p.getKey()));zip.write(p.getValue().getBytes(StandardCharsets.UTF_8));zip.closeEntry();}}
        var grid=SpreadsheetGridReader.read(out.toByteArray(),DocumentKind.XLSX,DocumentIntakeProfile.FINANCIAL_TEMPLATE);
        assertThat(grid.sheets().getFirst().row(0).cell(0).number()).isEqualByComparingTo("12345678901234.0001");
        assertThat(grid.sheets().getFirst().row(0).cell(1).number()).isEqualByComparingTo("0.123456789012345678901234567890");
        assertThat(grid.sheets().getFirst().truncated()).isFalse();
    }
}
