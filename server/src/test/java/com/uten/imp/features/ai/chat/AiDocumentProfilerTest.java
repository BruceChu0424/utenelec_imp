package com.uten.imp.features.ai.chat;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.files.document.DocumentGrid;
import com.uten.imp.common.files.document.DocumentKind;
import com.uten.imp.common.files.document.SpreadsheetGridReader;
import com.uten.imp.features.ai.chat.AiDocumentProfiler.Semantic;
import com.uten.imp.features.ai.chat.AiDocumentProfiler.Shape;
import org.apache.poi.hssf.usermodel.HSSFWorkbook;
import org.apache.poi.ss.util.CellRangeAddress;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;

import java.io.ByteArrayOutputStream;
import java.math.BigDecimal;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;

class AiDocumentProfilerTest {
    @ParameterizedTest @ValueSource(booleans = {true, false})
    void rosterHeaderIsFoundBelowTheTitleWithMergedDepartmentsAndTotalLineSkipped(boolean xls) throws Exception {
        var grid = SpreadsheetGridReader.read(AiDocumentFixtures.roster(xls, 86, true), xls ? DocumentKind.XLS : DocumentKind.XLSX);
        var sheet = AiDocumentProfiler.profile(grid).sheets().getFirst();
        assertThat(sheet.name()).isEqualTo("花名册");
        assertThat(sheet.headerRow()).isEqualTo(2);
        assertThat(sheet.dataRows()).as("86 people, the total line is not a person").isEqualTo(86);
        assertThat(sheet.columns()).extracting(AiDocumentProfiler.Column::label).containsExactlyElementsOf(AiDocumentFixtures.ROSTER_HEADER);
        assertThat(sheet.columns()).extracting(AiDocumentProfiler.Column::semantic).containsExactly(Semantic.SEQ, Semantic.PERSON_NAME,
                Semantic.GENDER, Semantic.DEPARTMENT, Semantic.POSITION, Semantic.HIRE_DATE, Semantic.ID_NUMBER, Semantic.PHONE);
        assertThat(sheet.columns()).extracting(AiDocumentProfiler.Column::shape).containsExactly(Shape.INTEGER, Shape.SHORT_TEXT,
                Shape.SHORT_TEXT, Shape.SHORT_TEXT, Shape.SHORT_TEXT, Shape.DATE, Shape.ID18, Shape.PHONE11);
        assertThat(sheet.semantics()).doesNotContain(Semantic.SEQ).contains(Semantic.PERSON_NAME, Semantic.ID_NUMBER);
    }

    @Test void profileNeverCarriesACellValue() throws Exception {
        var grid = SpreadsheetGridReader.read(AiDocumentFixtures.roster(true, 86, true), DocumentKind.XLS);
        String json = new ObjectMapper().writeValueAsString(AiDocumentProfiler.profile(grid).toJson());
        for (String value : AiDocumentFixtures.rosterValues(86)) assertThat(json).doesNotContain(value);
        assertThat(json).contains("\"dataRows\":86", "身份证号码");
    }

    @Test void labelsAndSheetNamesAreMaskedAndTrimmed() {
        assertThat(AiDocumentProfiler.mask("2026年10月工资", 24)).isEqualTo("#年10月工资");
        assertThat(AiDocumentProfiler.mask("联系 138-0013-8000 或 a.b@example.test", 24)).isEqualTo("联系 # 或 #");
        assertThat(AiDocumentProfiler.mask("这是一个非常非常长的列名称超过二十四个字符的限制要截断", 24)).hasSize(24);
        var row = new DocumentGrid.Row(0, List.of(DocumentGrid.Cell.text(0, "姓名"), DocumentGrid.Cell.text(1, "部门"),
                DocumentGrid.Cell.text(2, "2026年度第123批次考核结果说明文字很长很长很长")));
        var sheet = new DocumentGrid.Sheet("工号12345名单", 0, List.of(row), List.of(), 0, 2, false);
        var profile = AiDocumentProfiler.profile(new DocumentGrid(List.of(sheet))).sheets().getFirst();
        assertThat(profile.name()).isEqualTo("工号#名单");
        assertThat(profile.columns().get(2).label()).doesNotContain("2026", "123").hasSizeLessThanOrEqualTo(24);
    }

    @Test void twoRowHeaderTakesLowerLabelsAndFillsMergedParentsDown() throws Exception {
        try (var book = new HSSFWorkbook(); var out = new ByteArrayOutputStream()) {
            var sheet = book.createSheet("名单");
            var top = sheet.createRow(0);
            top.createCell(0).setCellValue("姓名"); top.createCell(1).setCellValue("部门"); top.createCell(2).setCellValue("联系方式");
            var second = sheet.createRow(1);
            second.createCell(2).setCellValue("手机"); second.createCell(3).setCellValue("邮箱");
            sheet.addMergedRegion(new CellRangeAddress(0, 1, 0, 0));
            sheet.addMergedRegion(new CellRangeAddress(0, 1, 1, 1));
            sheet.addMergedRegion(new CellRangeAddress(0, 0, 2, 3));
            var data = sheet.createRow(2);
            data.createCell(0).setCellValue("钱试一"); data.createCell(1).setCellValue("注塑一部");
            data.createCell(2).setCellValue("13800000001"); data.createCell(3).setCellValue("x@example.test");
            book.write(out);
            var profile = AiDocumentProfiler.profile(SpreadsheetGridReader.read(out.toByteArray(), DocumentKind.XLS)).sheets().getFirst();
            assertThat(profile.headerRow()).isZero();
            assertThat(profile.columns()).extracting(AiDocumentProfiler.Column::label).containsExactly("姓名", "部门", "手机", "邮箱");
            assertThat(profile.columns()).extracting(AiDocumentProfiler.Column::semantic)
                    .containsExactly(Semantic.PERSON_NAME, Semantic.DEPARTMENT, Semantic.PHONE, null);
            assertThat(profile.dataRows()).isEqualTo(1);
        }
    }

    @Test void firstDataRowOfWordsUnderAPlainHeaderIsNeverASecondHeaderRow() throws Exception {
        byte[] names = AiDocumentFixtures.table(false, "名单", List.of(
                List.of("姓名", "部门", "岗位", "备注"),
                List.of("钱试一", "销售部门", "业务员", "试用"),
                List.of("孙试二", "行政部门", "文员", "")));
        var profile = AiDocumentProfiler.profile(SpreadsheetGridReader.read(names, DocumentKind.XLSX)).sheets().getFirst();
        assertThat(profile.headerRow()).isZero();
        assertThat(profile.columns()).extracting(AiDocumentProfiler.Column::label).containsExactly("姓名", "部门", "岗位", "备注");
        assertThat(profile.dataRows()).isEqualTo(2);
        assertThat(profile.toJson().toString()).doesNotContain("钱试一", "销售部门", "业务员");
    }

    @Test void keyValueFormIsNotATableHeaderSoItsValuesNeverBecomeLabels() throws Exception {
        byte[] form = AiDocumentFixtures.table(true, "入职登记", List.of(
                List.of("姓名", "钱试一", "性别", "男"),
                List.of("身份证号", AiDocumentFixtures.idNumber("11010119900101001"), "电话", "13800000001"),
                List.of("部门", "注塑一部", "岗位", "操作工")));
        var profile = AiDocumentProfiler.profile(SpreadsheetGridReader.read(form, DocumentKind.XLS)).sheets().getFirst();
        assertThat(profile.headerRow()).isEqualTo(-1);
        assertThat(profile.columns()).isEmpty();
        assertThat(profile.toJson().toString()).doesNotContain("钱试一", "注塑一部");
        byte[] echo = AiDocumentFixtures.table(true, "入职登记", List.of(
                List.of("姓名", "钱试一", "部门", "销售部门"),
                List.of("身份证号", AiDocumentFixtures.idNumber("11010119900101001"), "电话", "13800000001")));
        var echoed = AiDocumentProfiler.profile(SpreadsheetGridReader.read(echo, DocumentKind.XLS)).sheets().getFirst();
        assertThat(echoed.headerRow()).as("a value that reads like its key (部门 | 销售部门) is still a value").isEqualTo(-1);
        assertThat(echoed.toJson().toString()).doesNotContain("钱试一", "销售部门");
        byte[] payroll = AiDocumentFixtures.table(true, "工资", List.of(
                List.of("姓名", "部门", "基本工资", "岗位工资", "迟到", "早退"),
                List.of("钱试一", "销售部门", 3000, 500, 1, 0)));
        var columns = AiDocumentProfiler.profile(SpreadsheetGridReader.read(payroll, DocumentKind.XLS)).sheets().getFirst();
        assertThat(columns.headerRow()).as("two pairs of neighbouring header words are still a table header").isZero();
        assertThat(columns.semantics()).contains(Semantic.PERSON_NAME, Semantic.PAY, Semantic.ATTENDANCE);
    }

    @Test void genericCodeAndNameTakeTheirMeaningFromTheRestOfTheHeader() throws Exception {
        var people = AiDocumentProfiler.profile(SpreadsheetGridReader.read(AiDocumentFixtures.table(false, "S", List.of(
                List.of("编号", "姓名", "部门"), List.of("A01", "钱试一", "注塑一部"))), DocumentKind.XLSX)).sheets().getFirst();
        assertThat(people.semantics()).contains(Semantic.EMPLOYEE_CODE).doesNotContain(Semantic.GOODS_CODE);
        var goods = AiDocumentProfiler.profile(SpreadsheetGridReader.read(AiDocumentFixtures.table(false, "S", List.of(
                List.of("编号", "名称", "规格", "单位"), List.of("A01", "螺丝", "M3", "个"))), DocumentKind.XLSX)).sheets().getFirst();
        assertThat(goods.semantics()).contains(Semantic.GOODS_CODE, Semantic.GOODS_NAME, Semantic.SPEC_MODEL, Semantic.UNIT);
    }

    @Test void labelVariantsMapToOneMeaningAndUnrelatedWordsStayUnknown() {
        assertThat(AiDocumentProfiler.semantic("员工身份证号码")).isEqualTo(Semantic.ID_NUMBER);
        assertThat(AiDocumentProfiler.semantic("身份证号码(18位)")).isEqualTo(Semantic.ID_NUMBER);
        assertThat(AiDocumentProfiler.semantic("身份证地址")).isEqualTo(Semantic.ADDRESS);
        assertThat(AiDocumentProfiler.semantic("联系人电话")).isEqualTo(Semantic.PHONE);
        assertThat(AiDocumentProfiler.semantic("所在部门名称")).isEqualTo(Semantic.DEPARTMENT);
        assertThat(AiDocumentProfiler.semantic("*入职时间：")).isEqualTo(Semantic.HIRE_DATE);
        assertThat(AiDocumentProfiler.semantic("规格/型号")).isEqualTo(Semantic.SPEC_MODEL);
        assertThat(AiDocumentProfiler.semantic("Unit Price")).isEqualTo(Semantic.PRICE);
        assertThat(AiDocumentProfiler.semantic("钱试一")).isNull();
        assertThat(AiDocumentProfiler.semantic("注塑一部")).isNull();
    }

    @Test void valueShapesAreTagsNotValues() {
        assertThat(AiDocumentProfiler.shape(DocumentGrid.Cell.text(0, AiDocumentFixtures.idNumber("11010119900101001")))).isEqualTo(Shape.ID18);
        assertThat(AiDocumentProfiler.shape(new DocumentGrid.Cell(0, "110101199001010000", DocumentGrid.CellKind.NUMBER,
                new BigDecimal("110101199001010000")))).as("an ID typed as a number").isEqualTo(Shape.ID18);
        assertThat(AiDocumentProfiler.shape(new DocumentGrid.Cell(0, "13800000001", DocumentGrid.CellKind.NUMBER,
                new BigDecimal("13800000001")))).isEqualTo(Shape.PHONE11);
        assertThat(AiDocumentProfiler.shape(DocumentGrid.Cell.text(0, "2020.1.5"))).isEqualTo(Shape.DATE);
        assertThat(AiDocumentProfiler.shape(DocumentGrid.Cell.text(0, "1,234.50"))).isEqualTo(Shape.AMOUNT);
        assertThat(AiDocumentProfiler.shape(DocumentGrid.Cell.text(0, "MAT-001"))).isEqualTo(Shape.CODE);
        assertThat(AiDocumentProfiler.shape(DocumentGrid.Cell.text(0, "操作工"))).isEqualTo(Shape.SHORT_TEXT);
        assertThat(AiDocumentProfiler.shape(null)).isEqualTo(Shape.EMPTY);
    }

    @Test void atMostFortyColumnsPerSheet() {
        List<DocumentGrid.Cell> cells = new ArrayList<>();
        cells.add(DocumentGrid.Cell.text(0, "姓名"));
        cells.add(DocumentGrid.Cell.text(1, "部门"));
        for (int c = 2; c < 60; c++) cells.add(DocumentGrid.Cell.text(c, "备注"));
        var sheet = new DocumentGrid.Sheet("S", 0, List.of(new DocumentGrid.Row(0, cells)), List.of(), 0, 59, false);
        assertThat(AiDocumentProfiler.profile(new DocumentGrid(List.of(sheet))).sheets().getFirst().columns())
                .hasSize(AiDocumentProfiler.MAX_COLUMNS);
    }

    @Test void textHeaderLineIsFoundInPdfOrWordLinesButNotInAKeyValueLine() {
        assertThat(AiDocumentProfiler.lineSemantics(List.of("员工名单", "序号 姓名 部门 岗位 手机号码", "1 钱试一 注塑一部 操作工 13800000001")))
                .containsExactlyInAnyOrder(Semantic.PERSON_NAME, Semantic.DEPARTMENT, Semantic.POSITION, Semantic.PHONE);
        assertThat(AiDocumentProfiler.lineSemantics(List.of("姓名: 钱试一 部门: 注塑一部"))).isEmpty();
        assertThat(AiDocumentProfiler.lineSemantics(List.of("钱试一 注塑一部 13800000001"))).isEmpty();
        assertThat(AiDocumentProfiler.profile(null)).isEqualTo(AiDocumentProfiler.Profile.empty());
        assertThat(AiDocumentProfiler.Profile.empty().toJson()).isEqualTo(Map.of("sheets", List.of()));
    }
}
