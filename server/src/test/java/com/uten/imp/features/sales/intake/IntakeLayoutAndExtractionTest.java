package com.uten.imp.features.sales.intake;

import com.uten.imp.common.files.document.DocumentGrid.Cell;
import com.uten.imp.common.files.document.DocumentGrid.MergedRange;
import com.uten.imp.common.files.document.DocumentGrid.Row;
import com.uten.imp.common.files.document.DocumentGrid.Sheet;
import com.uten.imp.common.files.document.DocumentKind;
import com.uten.imp.common.files.document.SpreadsheetGridReader;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.util.List;
import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;

class IntakeLayoutAndExtractionTest {

    static Sheet fixtureSheet(String key) {
        IntakeFixture fixture = IntakeFixture.load();
        byte[] xlsx = IntakeFixture.toXlsx(fixture.document(key));
        return SpreadsheetGridReader.read(xlsx, DocumentKind.XLSX).sheets().getFirst();
    }

    @Test
    void sunasShapedHeaderIsFoundByRules() {
        Sheet sheet = fixtureSheet("SUNAS");
        IntakeLayout layout = IntakeLayoutDetector.detect(sheet);
        assertThat(layout).isNotNull();
        assertThat(layout.headerRow0()).isEqualTo(7);
        assertThat(layout.headerRowSpan()).isEqualTo(1);
        assertThat(layout.columnRolesByLetter()).containsEntry("A", "LINE_NO").containsEntry("B", "SERIES")
                .containsEntry("C", "COLOR").containsEntry("D", "COLOR_ALT").containsEntry("E", "PART_NO")
                .containsEntry("F", "DESCRIPTION_ALT").containsEntry("G", "DESCRIPTION").containsEntry("H", "UNIT_PRICE")
                .containsEntry("I", "QTY").containsEntry("J", "AMOUNT").containsEntry("K", "PCS_PER_CTN")
                .containsEntry("L", "CTN").doesNotContainKeys("M", "N", "Q", "T");
        assertThat(layout.fileCurrency()).isEqualTo("CNY");
        assertThat(layout.source()).isEqualTo(IntakeLayout.SOURCE_RULES);
        assertThat(layout.fingerprint()).matches("[0-9a-f]{64}");
        assertThat(IntakeLayoutDetector.detect(fixtureSheet("SUNAS")).fingerprint()).isEqualTo(layout.fingerprint());
    }

    @Test
    void sunasShapedLinesAreExtractedUntilTheTotalRow() {
        Sheet sheet = fixtureSheet("SUNAS");
        IntakeLineExtractor.Extraction extraction = IntakeLineExtractor.extract(sheet, IntakeLayoutDetector.detect(sheet));
        List<ExtractedLine> lines = extraction.lines();
        assertThat(lines).hasSize(38);
        ExtractedLine first = lines.getFirst();
        assertThat(first.key()).isEqualTo("S1R9");
        assertThat(first.sourceRow()).isEqualTo(9);
        assertThat(first.partNo()).isEqualTo("GZ23/D");
        assertThat(first.description()).isEqualTo("DOUBLE 3 PIN UNIVERSAL SOCCKET WITH SWITCH");
        assertThat(first.descriptionAlt()).isEqualTo("两开多功能三极插座");
        assertThat(first.series()).isEqualTo("Z9");
        assertThat(first.colors().mainLabel()).isEqualTo("白");
        assertThat(first.contextNorm()).isEqualTo("Z9|白");
        assertThat(first.customerUnitPrice()).isEqualByComparingTo("21");
        assertThat(first.warnings()).isEmpty();
        ExtractedLine blackGray = lines.stream().filter(l -> l.sourceRow() == 27).findFirst().orElseThrow();
        assertThat(blackGray.colors().mainLabel()).isEqualTo("黑");
        assertThat(blackGray.colors().frameLabel()).isEqualTo("灰");
        assertThat(blackGray.colors().frameConflicts("金色面框")).isTrue();
        assertThat(blackGray.colors().frameConflicts("灰色面框")).isFalse();
        ExtractedLine multiLine = lines.stream().filter(l -> l.sourceRow() == 11).findFirst().orElseThrow();
        assertThat(multiLine.description()).isEqualTo("1 GANG 2 WAY SWITCH WITH LED Current: 10A");
    }

    @Test
    void uj23ShapedHeaderSplitsEnglishAndChineseInOneCell() {
        Sheet sheet = fixtureSheet("UJ23");
        IntakeLayout layout = IntakeLayoutDetector.detect(sheet);
        assertThat(layout.headerRow0()).isEqualTo(9);
        assertThat(layout.columnRolesByLetter()).containsEntry("A", "LINE_NO").containsEntry("B", "PART_NO")
                .containsEntry("C", "DESCRIPTION").containsEntry("E", "UNIT_PRICE").containsEntry("F", "QTY")
                .containsEntry("G", "AMOUNT").doesNotContainKeys("D", "H");
        assertThat(layout.fileCurrency()).isEqualTo("USD");
        assertThat(layout.headerUnit()).isEqualTo("pcs");
        List<ExtractedLine> lines = IntakeLineExtractor.extract(sheet, layout).lines();
        assertThat(lines).hasSize(22);
        ExtractedLine k20 = lines.getFirst();
        assertThat(k20.description()).isEqualTo("20A double pole switch swith light");
        assertThat(k20.descriptionAlt()).isEqualTo("20A双极开关带灯");
        assertThat(k20.warnings()).isEmpty();
        ExtractedLine tel = lines.stream().filter(l -> l.sourceRow() == 29).findFirst().orElseThrow();
        assertThat(tel.bundle()).isTrue();
        assertThat(tel.bundleParts()).containsExactly("TEL-02", "TEL-02-W", "PC-03");
        assertThat(tel.assembled()).isTrue();
        assertThat(tel.matchDescription()).isEqualTo("电话插模块功能件");
        assertThat(tel.colors().mainLabel()).isEqualTo("杏");
        assertThat(tel.colorAlt()).isEqualTo("杏色");
        assertThat(tel.warnings()).extracting(IntakeWarning::code).contains(IntakeWarning.BUNDLE_LINE);
        ExtractedLine buzzer = lines.stream().filter(l -> l.sourceRow() == 31).findFirst().orElseThrow();
        assertThat(buzzer.matchDescription()).isEqualTo("门铃扩音器-电磁声\uFF08带接线螺丝\uFF09");
    }

    @Test
    void headerKeywordsPickTheLongestMatch() {
        assertThat(IntakeLayoutDetector.classify("ITEM NO.").role()).isEqualTo(ColumnRole.PART_NO);
        assertThat(IntakeLayoutDetector.classify("ITEM").role()).isEqualTo(ColumnRole.DESCRIPTION);
        assertThat(IntakeLayoutDetector.classify("TOTAL AMOUNT").role()).isEqualTo(ColumnRole.AMOUNT);
        assertThat(IntakeLayoutDetector.classify("PCS/CTN").role()).isEqualTo(ColumnRole.PCS_PER_CTN);
        assertThat(IntakeLayoutDetector.classify("EXW-WORK PRICE (RMB)").role()).isEqualTo(ColumnRole.UNIT_PRICE);
        assertThat(IntakeLayoutDetector.classify("Part Description\n零件(配件)名称").role()).isEqualTo(ColumnRole.DESCRIPTION);
        assertThat(IntakeLayoutDetector.classify("订货数量").role()).isEqualTo(ColumnRole.QTY);
        assertThat(IntakeLayoutDetector.classify("T.G.W.").role()).isEqualTo(ColumnRole.IGNORED);
        assertThat(IntakeLayoutDetector.classify("Reference text")).isNull();
        assertThat(IntakeLayoutDetector.currencyOf("单价(USD)")).isEqualTo("USD");
        assertThat(IntakeLayoutDetector.currencyOf("Price HK$")).isEqualTo("HKD");
        assertThat(IntakeLayoutDetector.currencyOf("单价(元)")).isEqualTo("CNY");
    }

    @Test
    void mergedSeriesCellsCarryForwardAndStopRowsEndTheTable() {
        Sheet sheet = new Sheet("S", 0, List.of(
                new Row(0, List.of(Cell.text(0, "Series"), Cell.text(1, "Model"), Cell.text(2, "Qty"), Cell.text(3, "Unit"),
                        Cell.text(4, "Unit Price"), Cell.text(5, "Amount"))),
                new Row(1, List.of(Cell.text(0, "Z9"), Cell.text(1, "GK12"), num(2, "10"), Cell.text(3, "ctn"),
                        num(4, "2"), num(5, "25"))),
                new Row(2, List.of(Cell.text(1, "GK22"), num(2, "5"), num(4, "3"), num(5, "15"))),
                new Row(3, List.of(Cell.text(0, "Total"), num(5, "40"))),
                new Row(4, List.of(Cell.text(1, "GK32"), num(2, "5")))),
                List.of(new MergedRange(1, 2, 0, 0)), 0, 5, false);
        IntakeLayout layout = IntakeLayoutDetector.detect(sheet);
        List<ExtractedLine> lines = IntakeLineExtractor.extract(sheet, layout).lines();
        assertThat(lines).hasSize(2);
        assertThat(lines.get(1).series()).isEqualTo("Z9");
        assertThat(lines.getFirst().warnings()).extracting(IntakeWarning::code)
                .contains(IntakeWarning.UNIT_NOT_PCS, IntakeWarning.AMOUNT_MISMATCH);
        assertThat(lines.get(1).warnings()).isEmpty();
    }

    @Test
    void cartonQuantityIsConvertedWithPiecesPerCarton() {
        IntakeLineExtractor.RawLine raw = new IntakeLineExtractor.RawLine("S1R2", "S", 2, "1", "GK12", "1 GANG SWITCH",
                null, null, null, null, new BigDecimal("3"), "CTN", new BigDecimal("100"), new BigDecimal("9.45"), null, false);
        ExtractedLine line = IntakeLineExtractor.build(raw);
        assertThat(line.suggestedQty()).isEqualByComparingTo("300");
        assertThat(line.warnings()).extracting(IntakeWarning::code).containsExactly(IntakeWarning.UNIT_NOT_PCS);
    }

    @Test
    void numbersInCustomerTextAreParsedExactly() {
        assertThat(IntakeNumbers.parse("1,800")).isEqualByComparingTo("1800");
        assertThat(IntakeNumbers.parse("US$1.10")).isEqualByComparingTo("1.10");
        assertThat(IntakeNumbers.parse("¥21")).isEqualByComparingTo("21");
        assertThat(IntakeNumbers.parse("1.800,50")).isEqualByComparingTo("1800.50");
        assertThat(IntakeNumbers.parse("0,5")).isEqualByComparingTo("0.5");
        // 欧式小数逗号: 整数部分是 0 的「0,537」不是千分位。
        assertThat(IntakeNumbers.parse("0,537")).isEqualByComparingTo("0.537");
        assertThat(IntakeNumbers.parse("-0,537")).isEqualByComparingTo("-0.537");
        assertThat(IntakeNumbers.parse("€ 0,537")).isEqualByComparingTo("0.537");
        assertThat(IntakeNumbers.parse("12,5")).isEqualByComparingTo("12.5");
        assertThat(IntakeNumbers.parse("1,5000")).isEqualByComparingTo("1.5");
        assertThat(IntakeNumbers.parse("1,500")).isEqualByComparingTo("1500");
        assertThat(IntakeNumbers.parse("21,000,000")).isEqualByComparingTo("21000000");
        assertThat(IntakeNumbers.parse("37 800 pcs")).isEqualByComparingTo("37800");
        assertThat(IntakeNumbers.parse("RMB 1,234,567.89")).isEqualByComparingTo("1234567.89");
        assertThat(IntakeNumbers.parse("abc")).isNull();
        assertThat(IntakeNumbers.parse("")).isNull();
    }

    @Test
    void coloursFollowTheCompoundAndPriorityRules() {
        IntakeColors.ColorSpec cnWins = IntakeColors.parse("GRAY", "黑色", null, null, true);
        assertThat(cnWins.mainLabel()).isEqualTo("黑");
        IntakeColors.ColorSpec compound = IntakeColors.parse("BLACK WITH GOLD FRAME", null, null, null, true);
        assertThat(compound.mainLabel()).isEqualTo("黑");
        assertThat(compound.frameLabel()).isEqualTo("金");
        IntakeColors.ColorSpec offWhite = IntakeColors.parse("OFF WHITE", null, null, null, true);
        assertThat(offWhite.ambiguous()).isFalse();
        assertThat(offWhite.matchesMain("杏色")).isTrue();
        assertThat(offWhite.matchesMain("白色")).isFalse();
        IntakeColors.ColorSpec twoColours = IntakeColors.parse("WHITE/BLACK", null, null, null, true);
        assertThat(twoColours.ambiguous()).isTrue();
        assertThat(twoColours.known()).isFalse();
        IntakeColors.ColorSpec fromDescription = IntakeColors.parse(null, null, "电话保护门 (杏色\uFF09", "Telephone shutter", false);
        assertThat(fromDescription.mainLabel()).isEqualTo("杏");
        assertThat(fromDescription.colorAltFound()).isEqualTo("杏色");
        assertThat(IntakeColors.parse(null, null, null, "Red indicator light", false).mainLabel()).isEqualTo("红");
        assertThat(IntakeColors.parse(null, null, null, "Red indicator light", true).known()).isFalse();
    }

    @Test
    void fingerprintProbesFindTheHeaderRowForLearnedLayouts() {
        Sheet sheet = fixtureSheet("UJ23");
        IntakeLayout rules = IntakeLayoutDetector.detect(sheet);
        List<IntakeLayoutDetector.FingerprintProbe> probes = IntakeLayoutDetector.fingerprintProbes(sheet);
        assertThat(probes).anyMatch(p -> p.fingerprint().equals(rules.fingerprint()) && p.headerRow0() == 9 && p.span() == 1);
        Map<Integer, ColumnRole> roles = IntakeLayoutDetector.rolesFromLetters(Map.of("B", "PART_NO", "F", "QTY", "ZZZZ", "QTY",
                "C", "NOT_A_ROLE"));
        assertThat(roles).containsOnlyKeys(1, 5);
    }

    private static Cell num(int col, String value) {
        return new Cell(col, value, com.uten.imp.common.files.document.DocumentGrid.CellKind.NUMBER, new BigDecimal(value));
    }
}
