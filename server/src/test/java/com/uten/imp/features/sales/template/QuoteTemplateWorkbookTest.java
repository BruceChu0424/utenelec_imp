package com.uten.imp.features.sales.template;

import org.apache.poi.common.usermodel.HyperlinkType;
import org.apache.poi.ss.usermodel.*;
import org.apache.poi.ss.util.CellRangeAddress;
import org.apache.poi.xssf.usermodel.XSSFWorkbook;
import org.junit.jupiter.api.Test;

import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.util.*;

import static org.assertj.core.api.Assertions.*;

class QuoteTemplateWorkbookTest {
    private static final Map<String, String> ROLES = Map.of("A", "PART_NO", "B", "DESCRIPTION", "D", "QTY", "E", "UNIT_PRICE", "F", "AMOUNT");

    @Test
    void keepsChosenSheetPresentationButNoHistoricalOrExecutableData() throws Exception {
        var candidate = capture(sample("OLD CUSTOMER", 2));
        try (XSSFWorkbook wb = open(candidate.xlsx())) {
            assertThat(wb.getNumberOfSheets()).isEqualTo(1);
            assertThat(wb.getAllNames()).hasSize(1); // only the sanitized repeating print rows
            assertThat(wb.getAllPictures()).isEmpty();
            assertThat(wb.getPackage().getParts())
                    .noneMatch(part -> part.getPartName().getName().startsWith("/xl/externalLinks/"));
            assertThat(wb.getPackagePart().getRelationships())
                    .noneMatch(relation -> relation.getRelationshipType().endsWith("/externalLink"));
            Sheet sheet = wb.getSheetAt(0);
            assertThat(sheet.getColumnWidth(1)).isEqualTo(30 * 256);
            assertThat(sheet.getPrintSetup().getLandscape()).isTrue();
            assertThat(sheet.getMargin(PageMargin.LEFT)).isEqualTo(.25);
            assertThat(sheet.getRow(4).getHeightInPoints()).isEqualTo(28);
            assertThat(sheet.getRepeatingRows().getFirstRow()).isEqualTo(3);
            List<String> strings = new ArrayList<>();
            for (Row row : sheet) for (Cell c : row) {
                assertThat(c.getCellType()).isNotEqualTo(CellType.FORMULA);
                assertThat(c.getCellComment()).isNull();
                assertThat(c.getHyperlink()).isNull();
                if (c.getCellType() == CellType.STRING) strings.add(c.getStringCellValue());
            }
            assertThat(strings).noneMatch(s -> s.contains("OLD") || s.contains("SECRET") || s.contains("991234"));
        }
    }

    @Test
    void fillsMergedHeaderAndRepeatsDetailMergesAndMovesFooterWithoutOldRows() throws Exception {
        var candidate = capture(sample("OLD CUSTOMER", 2));
        List<QuoteTemplateWorkbook.ExportLine> lines = List.of(line("NEW-1", "2", "8"), line("NEW-2", "3", "12"), line("NEW-3", "4", "16"));
        byte[] exported = QuoteTemplateWorkbook.render(candidate.xlsx(), candidate.mapping(), lines,
                Map.of("buyerName", "CURRENT CUSTOMER", "docNo", "BJ-2026", "docDate", "2026-09-29"), "36");
        try (XSSFWorkbook wb = open(exported)) {
            Sheet s = wb.getSheetAt(0);
            assertThat(s.getRow(1).getCell(2).getStringCellValue()).isEqualTo("CURRENT CUSTOMER");
            assertThat(s.getRow(4).getCell(0).getStringCellValue()).isEqualTo("NEW-1");
            assertThat(s.getRow(6).getCell(0).getStringCellValue()).isEqualTo("NEW-3");
            assertThat(s.getMergedRegions()).extracting(CellRangeAddress::formatAsString)
                    .contains("B5:C5", "B6:C6", "B7:C7", "A8:E8");
            assertThat(s.getRow(7).getCell(5).getNumericCellValue()).isEqualTo(36);
            assertThat(s.getRow(7).getCell(0).getStringCellValue()).isEqualTo("TOTAL");
            assertThat(s.getRow(8).getCell(0).getCellType()).isEqualTo(CellType.BLANK);
            assertThat(s.getRow(6).getHeightInPoints()).isEqualTo(28);
            assertThat(s.getRow(6).getCell(5).getCellStyle().getBorderBottom()).isEqualTo(BorderStyle.THIN);
            assertThat(wb.getPrintArea(0)).contains("$A$1:$G$9");
        }
    }

    @Test
    void differentRowCountsAndCustomerValuesHaveSameFingerprint() throws Exception {
        var one = capture(sample("CLIENT A", 2));
        var two = QuoteTemplateWorkbook.capture(sample("CLIENT B", 4), 1, 3, 1, ROLES,
                Map.of("G", "Packaging fee"), List.of(4, 5, 6, 7));
        assertThat(two.fingerprint()).isEqualTo(one.fingerprint());
        assertThat(SalesQuoteTemplateStore.compatible(one.features(), two.features())).isTrue();
    }

    @Test
    void exactNumbersAndFormulaLikeUserTextStaySafe() throws Exception {
        var candidate = capture(sample("OLD", 2));
        var value = new HashMap<String, String>();
        value.put("PART_NO", "=HYPERLINK(\"https://example.com\")");
        value.put("QTY", "1234567890123456.12345");
        value.put("extra:packagingfee", "=1+1");
        byte[] exported = QuoteTemplateWorkbook.render(candidate.xlsx(), candidate.mapping(),
                List.of(new QuoteTemplateWorkbook.ExportLine(value)), Map.of(), "1234567890123456.12345");
        try (XSSFWorkbook wb = open(exported)) {
            Row row = wb.getSheetAt(0).getRow(4);
            assertThat(row.getCell(0).getCellType()).isEqualTo(CellType.STRING);
            assertThat(row.getCell(3).getStringCellValue()).isEqualTo("1234567890123456.12345");
            assertThat(row.getCell(6).getStringCellValue()).isEqualTo("=1+1");
        }
    }

    @Test
    void defaultTemplateUsesRequestedColumnsAndCurrentHeader() throws Exception {
        var candidate = QuoteTemplateWorkbook.defaultTemplate();
        byte[] exported = QuoteTemplateWorkbook.render(candidate.xlsx(), candidate.mapping(), List.of(line("P1", "2", "8")),
                Map.of("buyerName", "NEW CLIENT", "docNo", "Q1"), "8");
        try (XSSFWorkbook wb = open(exported)) {
            assertThat(wb.getSheetAt(0).getRow(1).getCell(1).getStringCellValue()).isEqualTo("NEW CLIENT");
            assertThat(wb.getSheetAt(0).getRow(4).getPhysicalNumberOfCells()).isEqualTo(10);
        }
    }

    @Test
    void invalidColumnAndOversizedLayoutFailInsteadOfSilentlyDroppingContent() throws Exception {
        byte[] bytes = sample("OLD", 2);
        assertThatThrownBy(() -> QuoteTemplateWorkbook.capture(bytes, 1, 3, 1, Map.of("ZZ", "AMOUNT"), Map.of()))
                .isInstanceOf(IllegalArgumentException.class);
        try (XSSFWorkbook wb = open(bytes)) {
            wb.getSheetAt(1).createRow(2000).createCell(0).setCellValue("SECRET");
            byte[] huge = bytes(wb);
            assertThatThrownBy(() -> capture(huge)).isInstanceOf(IllegalArgumentException.class);
        }
    }

    @Test
    void netUnitPriceIsUsedOnlyWhenTemplateHasNoDiscountAndNewFeesAreNeverDropped() throws Exception {
        var candidate = capture(sample("OLD", 2));
        Map<String, String> values = new LinkedHashMap<>();
        values.put("UNIT_PRICE", "10"); values.put("UNIT_PRICE_NET", "8.5"); values.put("DISCOUNT", "0.85");
        values.put("extra-label:insurance", "Insurance"); values.put("extra:insurance", "2.25");
        var lines = List.of(new QuoteTemplateWorkbook.ExportLine(values));
        try (XSSFWorkbook custom = open(QuoteTemplateWorkbook.render(candidate.xlsx(), candidate.mapping(), lines, Map.of(), "10.75"))) {
            assertThat(custom.getSheetAt(0).getRow(4).getCell(4).getNumericCellValue()).isEqualTo(8.5);
            assertThat(custom.getSheetAt(0).getRow(3).getCell(7).getStringCellValue()).isEqualTo("Insurance");
            assertThat(custom.getSheetAt(0).getRow(4).getCell(7).getStringCellValue()).isEqualTo("2.25");
        }
        var base = QuoteTemplateWorkbook.defaultTemplate();
        try (XSSFWorkbook standard = open(QuoteTemplateWorkbook.render(base.xlsx(), base.mapping(), lines, Map.of(), "10.75"))) {
            assertThat(standard.getSheetAt(0).getRow(5).getCell(6).getNumericCellValue()).isEqualTo(10);
            assertThat(standard.getSheetAt(0).getRow(5).getCell(7).getNumericCellValue()).isEqualTo(.85);
            assertThat(standard.getSheetAt(0).getRow(4).getCell(10).getStringCellValue()).isEqualTo("Insurance");
        }
    }

    @Test
    void verticalDetailMergeRepeatsAsABlockAndCustomNumberFormatDoesNotLeakHistoricalText() throws Exception {
        try (XSSFWorkbook source = new XSSFWorkbook()) {
            Sheet sheet = source.createSheet("Example");
            sheet.createRow(0).createCell(0).setCellValue("Description");
            sheet.getRow(0).createCell(1).setCellValue("Amount");
            CellStyle style = source.createCellStyle();
            style.setDataFormat(source.createDataFormat().getFormat("0.00 \"SECRET CUSTOMER\""));
            for (int row = 1; row <= 4; row++) {
                sheet.createRow(row).createCell(0).setCellValue("OLD ITEM");
                sheet.getRow(row).createCell(1).setCellStyle(style);
            }
            sheet.addMergedRegion(new CellRangeAddress(1, 2, 0, 0));
            sheet.addMergedRegion(new CellRangeAddress(3, 4, 0, 0));
            sheet.createRow(5).createCell(0).setCellValue("Total");
            var candidate = QuoteTemplateWorkbook.capture(bytes(source), 0, 0, 1, Map.of("A", "DESCRIPTION", "B", "AMOUNT"), Map.of(), List.of(1, 3));
            var lines = List.of(line("N1", "1", "4"), line("N2", "1", "4"), line("N3", "1", "4"));
            try (XSSFWorkbook rendered = open(QuoteTemplateWorkbook.render(candidate.xlsx(), candidate.mapping(), lines, Map.of(), "12"))) {
                assertThat(rendered.getSheetAt(0).getMergedRegions()).extracting(CellRangeAddress::formatAsString)
                        .containsExactly("A2:A3", "A4:A5", "A6:A7");
                assertThat(rendered.getSheetAt(0).getRow(7).getCell(1).getNumericCellValue()).isEqualTo(12);
                assertThat(rendered.getStylesSource().getNumberFormats().values()).noneMatch(f -> f.contains("SECRET"));
            }
        }
    }

    @Test
    void actualDiscountHeadingOverridesIntakeReferenceMappingWithCurrentQuotationDiscount() throws Exception {
        try (XSSFWorkbook source = new XSSFWorkbook()) {
            Sheet sheet = source.createSheet("Discounted");
            sheet.createRow(0).createCell(0).setCellValue("Unit price");
            sheet.getRow(0).createCell(1).setCellValue("Discount %");
            sheet.getRow(0).createCell(2).setCellValue("Amount");
            sheet.createRow(1).createCell(0).setCellValue(999);
            sheet.getRow(1).createCell(1).setCellValue(.1);
            var candidate = QuoteTemplateWorkbook.capture(bytes(source), 0, 0, 1,
                    Map.of("A", "UNIT_PRICE", "B", "IGNORED", "C", "AMOUNT"), Map.of("B", "Discount %"), List.of(1));
            Map<String, String> values = Map.of("UNIT_PRICE", "10", "UNIT_PRICE_NET", "8.5", "DISCOUNT", ".85",
                    "extra:discount", ".1", "extra-label:discount", "Discount %");
            try (XSSFWorkbook rendered = open(QuoteTemplateWorkbook.render(candidate.xlsx(), candidate.mapping(),
                    List.of(new QuoteTemplateWorkbook.ExportLine(values)), Map.of(), "8.5"))) {
                assertThat(rendered.getSheetAt(0).getRow(1).getCell(0).getNumericCellValue()).isEqualTo(10);
                assertThat(rendered.getSheetAt(0).getRow(1).getCell(1).getNumericCellValue()).isEqualTo(.85);
                assertThat(rendered.getSheetAt(0).getRow(0).getPhysicalNumberOfCells()).isEqualTo(3);
            }
        }
    }

    @Test
    void oldUsdLabelsAndMoneyFormatsCannotMislabelCurrentCnyPrices() throws Exception {
        try (XSSFWorkbook source = new XSSFWorkbook()) {
            Sheet sheet = source.createSheet("USD quotation");
            sheet.createRow(0).createCell(0).setCellValue("Part no");
            sheet.getRow(0).createCell(1).setCellValue("UNIT PRICE USD");
            sheet.getRow(0).createCell(2).setCellValue("AMOUNT ($)");
            CellStyle dollar = source.createCellStyle(); dollar.setDataFormat(source.createDataFormat().getFormat("\"$\"#,##0.00"));
            sheet.createRow(1).createCell(1).setCellStyle(dollar);
            sheet.getRow(1).createCell(2).setCellStyle(dollar);
            var candidate = QuoteTemplateWorkbook.capture(bytes(source), 0, 0, 1,
                    Map.of("A", "PART_NO", "B", "UNIT_PRICE", "C", "AMOUNT"), Map.of(), List.of(1));
            var values = Map.of("PART_NO", "USD-MODEL", "UNIT_PRICE", "10", "UNIT_PRICE_NET", "8.5", "AMOUNT", "17");
            try (XSSFWorkbook rendered = open(QuoteTemplateWorkbook.render(candidate.xlsx(), candidate.mapping(),
                    List.of(new QuoteTemplateWorkbook.ExportLine(values)), Map.of("currencyCode", "CNY"), "17"))) {
                assertThat(rendered.getSheetAt(0).getRow(0).getCell(1).getStringCellValue()).isEqualTo("UNIT PRICE (CNY)");
                assertThat(rendered.getSheetAt(0).getRow(0).getCell(2).getStringCellValue()).isEqualTo("AMOUNT (CNY)");
                assertThat(rendered.getSheetAt(0).getRow(1).getCell(0).getStringCellValue()).isEqualTo("USD-MODEL");
                assertThat(rendered.getSheetAt(0).getRow(1).getCell(1).getNumericCellValue()).isEqualTo(8.5);
                assertThat(rendered.getSheetAt(0).getRow(1).getCell(1).getCellStyle().getDataFormatString()).doesNotContain("$");
            }
        }
    }

    @Test
    void liveProjectionReordersRemovesAndAddsColumnsWhileKeepingCustomerHeaderVisible() throws Exception {
        var template = capture(sample("OLD CUSTOMER", 2));
        var projection = List.of(
                new QuoteTemplateWorkbook.DisplayColumn("qty", "数量", 180, "QTY", "QTY", null),
                new QuoteTemplateWorkbook.DisplayColumn("goods", "货品名称", 280, "GOODS_NAME", "DESCRIPTION", null),
                new QuoteTemplateWorkbook.DisplayColumn("platform:test", "计算展示", 140, "PLATFORM_ID:test", null, null));
        var projected = QuoteTemplateWorkbook.project(template.xlsx(), template.mapping(), projection);
        var row = Map.of("QTY", "3", "GOODS_NAME", "CURRENT GOODS", "PLATFORM_ID:test", "7", "UNIT_PRICE", "999",
                "extra-label:unselected", "不要显示", "extra:unselected", "SECRET FEE");
        try (XSSFWorkbook wb = open(QuoteTemplateWorkbook.render(projected.xlsx(), projected.mapping(),
                List.of(new QuoteTemplateWorkbook.ExportLine(row)), Map.of("buyerName", "CURRENT CLIENT"), "999"))) {
            var sheet = wb.getSheetAt(0);
            assertThat(java.util.stream.StreamSupport.stream(sheet.getRow(3).spliterator(), false).map(Cell::getStringCellValue).toList()).containsExactly("数量", "货品名称", "计算展示");
            assertThat(sheet.getRow(4).getCell(0).getNumericCellValue()).isEqualTo(3);
            assertThat(sheet.getRow(4).getCell(1).getStringCellValue()).isEqualTo("CURRENT GOODS");
            assertThat(sheet.getRow(4).getCell(2).getStringCellValue()).isEqualTo("7");
            assertThat(sheet.getRow(4).getLastCellNum()).isEqualTo((short)3);
            assertThat(sheet.getColumnWidth(1)).isGreaterThan(sheet.getColumnWidth(0));
            assertThat(sheet.getRow(1).getCell(2).getStringCellValue()).contains("CURRENT CLIENT");
        }
        var narrow = QuoteTemplateWorkbook.project(template.xlsx(), template.mapping(), projection.subList(0,1));
        try (XSSFWorkbook wb = open(QuoteTemplateWorkbook.render(narrow.xlsx(), narrow.mapping(),
                List.of(new QuoteTemplateWorkbook.ExportLine(row)), Map.of("buyerName", "CURRENT CLIENT"), "999"))) {
            assertThat(wb.getSheetAt(0).getRow(1).getCell(0).getStringCellValue()).contains("Buyer: CURRENT CLIENT");
        }
    }

    private static QuoteTemplateWorkbook.Candidate capture(byte[] bytes) {
        return QuoteTemplateWorkbook.capture(bytes, 1, 3, 1, ROLES, Map.of("G", "Packaging fee"), List.of(4, 5));
    }
    private static QuoteTemplateWorkbook.ExportLine line(String model, String qty, String amount) {
        return new QuoteTemplateWorkbook.ExportLine(Map.of("PART_NO", model, "DESCRIPTION", "NEW PRODUCT", "QTY", qty,
                "UNIT_PRICE", "4", "AMOUNT", amount));
    }
    private static byte[] sample(String buyer, int count) throws Exception {
        try (XSSFWorkbook wb = new XSSFWorkbook()) {
            wb.createSheet("HIDDEN SECRET").createRow(0).createCell(0).setCellValue("SECRET OTHER CUSTOMER");
            wb.setSheetHidden(0, true);
            Sheet s = wb.createSheet("Customer quotation");
            s.createRow(0).createCell(0).setCellValue("Quotation");
            s.createRow(1).createCell(0).setCellValue("Buyer:");
            s.getRow(1).createCell(2).setCellValue(buyer);
            s.addMergedRegion(new CellRangeAddress(1, 1, 0, 1));
            s.addMergedRegion(new CellRangeAddress(1, 1, 2, 6));
            s.createRow(2).createCell(0).setCellValue("SECRET BANK ACCOUNT 991234");
            String[] labels = {"Part no", "Description", "", "Qty", "Unit price", "Amount", "Packaging fee"};
            Row heading = s.createRow(3);
            for (int i = 0; i < labels.length; i++) heading.createCell(i).setCellValue(labels[i]);
            CellStyle style = wb.createCellStyle(); style.setBorderBottom(BorderStyle.THIN); style.setWrapText(true);
            for (int index = 4; index < count + 4; index++) {
                Row row = s.createRow(index); row.setHeightInPoints(28);
                for (int col = 0; col < 7; col++) row.createCell(col).setCellStyle(style);
                row.getCell(0).setCellValue("OLD-" + index);
                row.getCell(1).setCellValue("OLD ITEM DESCRIPTION");
                row.getCell(3).setCellValue(100);
                row.getCell(4).setCellValue(99);
                row.getCell(5).setCellFormula("D" + (index + 1) + "*E" + (index + 1));
                s.addMergedRegion(new CellRangeAddress(index, index, 1, 2));
            }
            var link = wb.getCreationHelper().createHyperlink(HyperlinkType.URL); link.setAddress("https://example.com/SECRET");
            s.getRow(4).getCell(1).setHyperlink(link);
            s.createRow(count + 4).createCell(0).setCellValue("TOTAL");
            s.getRow(count + 4).createCell(5).setCellValue(9999);
            s.addMergedRegion(new CellRangeAddress(count + 4, count + 4, 0, 4));
            s.createRow(count + 5).createCell(0).setCellValue("SECRET TERMS");
            s.setColumnWidth(1, 30 * 256);
            s.getPrintSetup().setLandscape(true); s.setMargin(PageMargin.LEFT, .25);
            s.setRepeatingRows(new CellRangeAddress(3, 3, -1, -1));
            s.getHeader().setLeft("SECRET HEADER");
            wb.getProperties().getCoreProperties().setCreator("SECRET CREATOR");
            return bytes(wb);
        }
    }
    private static XSSFWorkbook open(byte[] bytes) throws Exception { return new XSSFWorkbook(new ByteArrayInputStream(bytes)); }
    private static byte[] bytes(Workbook wb) throws Exception { ByteArrayOutputStream out = new ByteArrayOutputStream(); wb.write(out); return out.toByteArray(); }
}
