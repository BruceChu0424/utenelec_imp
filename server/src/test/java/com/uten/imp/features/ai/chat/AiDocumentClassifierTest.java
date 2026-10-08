package com.uten.imp.features.ai.chat;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.files.document.DocumentGrid;
import com.uten.imp.common.files.document.DocumentKind;
import com.uten.imp.common.files.document.SpreadsheetGridReader;
import org.apache.poi.ss.util.CellRangeAddress;
import org.apache.poi.xssf.usermodel.XSSFWorkbook;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;

import java.io.ByteArrayOutputStream;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.Set;

import static org.assertj.core.api.Assertions.assertThat;

class AiDocumentClassifierTest {
    private static final String GOODS_HEADER = "品名 数量 单价";

    @Test void repositorySunasFixtureIsCommercialInvoiceDespiteItsQuotationTerms() throws Exception {
        // This is the repository's synthetic regression fixture, not the user's screenshot file.
        try (var input = getClass().getResourceAsStream("/sales-intake/matching-fixture.json");
             var workbook = new XSSFWorkbook(); var output = new ByteArrayOutputStream()) {
            var root = new ObjectMapper().readTree(input);
            var document = java.util.stream.StreamSupport.stream(root.path("documents").spliterator(), false)
                    .filter(value -> value.path("key").asText().equals("SUNAS")).findFirst().orElseThrow();
            var sheet = workbook.createSheet(document.path("sheetName").asText());
            for (var item : document.path("rows")) {
                var row = sheet.createRow(item.path("row").asInt() - 1);
                for (var cell : item.path("cells").properties())
                    row.createCell(DocumentGrid.columnIndex(cell.getKey())).setCellValue(cell.getValue().asText());
            }
            for (var merge : document.path("merges")) sheet.addMergedRegion(CellRangeAddress.valueOf(merge.asText()));
            workbook.write(output);
            var grid = SpreadsheetGridReader.read(output.toByteArray(), DocumentKind.XLSX);
            List<List<String>> sections = new ArrayList<>();
            for (var read : grid.sheets()) {
                List<String> lines = new ArrayList<>(List.of(read.name()));
                read.rows().forEach(row -> lines.add(row.joinedText())); sections.add(lines);
            }
            assertThat(sections.getFirst()).anyMatch(line -> line.contains("Commercial Invoice"))
                    .anyMatch(line -> line.contains("Quotation base on EX-WORK"));
            assertThat(AiDocumentClassifier.classifySections(sections).type()).isEqualTo("COMMERCIAL_INVOICE");
            assertThat(AiDocumentClassifier.classifySections(sections).multipleInvoices()).isFalse();
            assertThat(AiDocumentClassifier.hasGoodsTable(sections.getFirst())).isTrue();
        }
    }

    @ParameterizedTest @ValueSource(strings = {"采购订货单", "采购订单", "采购订单 Purchase Order"})
    void specificProcurementTitleIsNotASecondSalesFamily(String title) {
        assertThat(AiDocumentClassifier.classify(List.of(title, GOODS_HEADER)).type()).isEqualTo("PURCHASE_DOCUMENT");
    }

    @Test void quotationMayReferenceInvoiceAndOrderNumbersWithoutBecomingMixed() {
        var lines = List.of("报价单", "Invoice No: INV2026", "Order No: PO2026", GOODS_HEADER,
                "备注：按销售订单安排出库单，电子发票另行开具。", "1. Quotation base on EX-WORK price, not including tax and delivery.");
        assertThat(AiDocumentClassifier.classify(lines)).isEqualTo(new AiDocumentClassifier.Classification("SALES_QUOTATION", false, "TITLE"));
    }

    @Test void contractNumberReferencesAreMetadataButAnIndependentContractHeadingRemainsMixed() {
        var quote = List.of("报价单", GOODS_HEADER, "Contract No: SC2026", "销售合同编号:2026001");
        assertThat(AiDocumentClassifier.classify(quote).type()).isEqualTo("SALES_QUOTATION");
        assertThat(AiDocumentClassifier.classifySections(List.of(quote, List.of("Contract", "Contract No: SC2026"))).type())
                .isEqualTo("MIXED_DOCUMENT");
    }

    @ParameterizedTest @ValueSource(strings = {"工资表印刷服务 1 20", "PAYROLL SOFTWARE 2 30", "备注：本报价不含工资表维护服务", "备注：后续提供销售合同与电子发票"})
    void productDescriptionsAndNotesDoNotBecomeIndependentDocuments(String line) {
        assertThat(AiDocumentClassifier.classify(List.of("报价单", GOODS_HEADER, line)).type()).isEqualTo("SALES_QUOTATION");
    }

    @ParameterizedTest @ValueSource(strings = {"工资表", "2026年10月工资表", "Payroll Report 2026-10", "销售合同", "电子发票"})
    void actualOtherDocumentTitlesOnTheSameSheetStillBlock(String second) {
        assertThat(AiDocumentClassifier.classify(List.of("报价单", GOODS_HEADER, second)).type()).isEqualTo("MIXED_DOCUMENT");
    }

    @Test void actualSalaryColumnsCannotBorrowQuotationColumnsEvenWithoutPayrollTitle() {
        assertThat(AiDocumentClassifier.classify(List.of("报价单", GOODS_HEADER, "员工姓名 应发工资 实发工资", "张三 5000 4500")).type())
                .isEqualTo("MIXED_DOCUMENT");
    }

    @Test void twoRealTitlesInOneJoinedSpreadsheetRowRemainMixedWithoutSplittingProductDescriptions() {
        for(String row:List.of("报价单 工资表","报价单 / 电子发票","销售合同 | 报价单"))
            assertThat(AiDocumentClassifier.classify(List.of(row,GOODS_HEADER)).type()).as(row).isEqualTo("MIXED_DOCUMENT");
        assertThat(AiDocumentClassifier.classify(List.of("采购订货单 Purchase Order",GOODS_HEADER)).type()).isEqualTo("PURCHASE_DOCUMENT");
        assertThat(AiDocumentClassifier.classify(List.of("报价单",GOODS_HEADER,"工资表印刷 1 20")).type()).isEqualTo("SALES_QUOTATION");
    }

    @ParameterizedTest @ValueSource(strings = {"工资表", "销售合同", "电子发票", "库存盘点表", "生产日报", "采购订单"})
    void separateBusinessSheetsRemainMixed(String second) {
        assertThat(AiDocumentClassifier.classifySections(List.of(List.of("报价单", GOODS_HEADER), List.of(second))).type())
                .isEqualTo("MIXED_DOCUMENT");
    }

    @Test void compatibleTradeSheetsDoNotLetAnInvoiceReferencePolluteTheWorkbook() {
        var sections = List.of(List.of("报价单", GOODS_HEADER), List.of("Invoice No: REFERENCE-1"),
                List.of("Commercial Invoice", "Description QTY Unit Price"));
        assertThat(AiDocumentClassifier.classifySections(sections).type()).isEqualTo("SALES_QUOTATION");
        assertThat(AiDocumentClassifier.classifySections(sections).multipleInvoices()).isFalse();
        assertThat(AiDocumentClassifier.classifySections(List.of(List.of("报价单"), List.of("订货单"))).type()).isEqualTo("SALES_ORDER");
    }

    @Test void proformaIsTradeButAnActualTaxInvoiceRemainsSeparate() {
        assertThat(AiDocumentClassifier.classify(List.of("PROFORMA INVOICE", "Invoice No: PI2026", GOODS_HEADER)).type()).isEqualTo("SALES_ORDER");
        assertThat(AiDocumentClassifier.classifySections(List.of(List.of("报价单", GOODS_HEADER), List.of("PROFORMA INVOICE"))).type()).isEqualTo("SALES_ORDER");
        assertThat(AiDocumentClassifier.classifySections(List.of(List.of("Commercial Invoice", GOODS_HEADER), List.of("税票", "发票号码:12345678", "价税合计:100"))).type())
                .isEqualTo("MIXED_DOCUMENT");
    }

    @Test void twoRealInvoicesRemainMultipleAndCannotBecomeOneAmount() {
        var first = List.of("电子发票", "发票号码:12345678", "价税合计:100");
        var second = List.of("电子发票", "发票号码:87654321", "价税合计:200");
        assertThat(AiDocumentClassifier.classifySections(List.of(first, second))).isEqualTo(new AiDocumentClassifier.Classification("INVOICE", true, "TITLE"));
        assertThat(AiDocumentClassifier.classify(List.of("电子发票", "发票号码:12345678", "价税合计:100", "价税合计（大写）:壹佰元")).multipleInvoices()).isFalse();
    }

    @Test void untitledEnglishInvoiceReferencesDoNotEstablishCommercialOrDomesticTaxType() {
        assertThat(AiDocumentClassifier.classify(List.of("Invoice No: REF-2026", "Grand Total:100")).type()).isEqualTo("UNKNOWN");
        assertThat(AiDocumentClassifier.classify(List.of("Invoice No: REF-2026", "Grand Total:100", GOODS_HEADER)).type()).isEqualTo("SALES_TABLE");
        assertThat(AiDocumentClassifier.classifySections(List.of(List.of("报价单", GOODS_HEADER),
                List.of("Invoice No: REF-2026", "Grand Total:100"))).type()).isEqualTo("SALES_QUOTATION");
    }

    @Test void genericInvoiceTemplateDoesNotProveCommercialInvoiceOrOverrideQuotationEvidence() {
        assertThat(AiDocumentClassifier.classify(List.of("Invoice", GOODS_HEADER)))
                .isEqualTo(new AiDocumentClassifier.Classification("SALES_TABLE", false, "COLUMNS"));
        assertThat(AiDocumentClassifier.classify(List.of("Invoice", "报价单", GOODS_HEADER)).type()).isEqualTo("SALES_QUOTATION");
        assertThat(AiDocumentClassifier.classify(List.of("Invoice", "unknown content")).type()).isEqualTo("UNKNOWN");
        assertThat(AiDocumentClassifier.classify(List.of("Invoice No: REF-2026", "Grand Total:100")).evidence()).isEqualTo("FIELDS");
        assertThat(AiDocumentClassifier.classifySections(List.of(
                List.of("Invoice No: ONE-2026", "Grand Total:100"), List.of("Invoice No: TWO-2026", "Grand Total:200"))).multipleInvoices()).isTrue();
    }

    @Test void untitledDomesticInvoiceNumberAndTaxTotalRemainDistinctFromTradeSheets() {
        var invoice = List.of("发票号码:12345678", "价税合计:100");
        assertThat(AiDocumentClassifier.classify(invoice).type()).isEqualTo("INVOICE");
        assertThat(AiDocumentClassifier.classifySections(List.of(List.of("报价单", GOODS_HEADER),invoice)).type()).isEqualTo("MIXED_DOCUMENT");
    }

    @Test void goodsTableNeedsNeighboringColumnHeadingsNotIncidentalWordsAcrossTheDocument() {
        assertThat(AiDocumentClassifier.hasGoodsTable(List.of("ITEM NO. Description EXW-WORK PRICE (RMB) QTY TOTAL AMOUNT"))).isTrue();
        assertThat(AiDocumentClassifier.hasGoodsTable(List.of("产品名称", "数量", "单价"))).isTrue();
        assertThat(AiDocumentClassifier.hasGoodsTable(List.of("备注：请提供产品名称、数量、单价"))).isFalse();
        assertThat(AiDocumentClassifier.hasGoodsTable(List.of("产品名称", "客户资料", "其他说明", "数量", "单价"))).isFalse();
        assertThat(AiDocumentClassifier.classify(List.of("Invoice No: REF-2026")).type()).isEqualTo("UNKNOWN");
        assertThat(AiDocumentClassifier.classify(List.of(GOODS_HEADER)).type()).isEqualTo("SALES_TABLE");
    }

    @ParameterizedTest @ValueSource(booleans = {true, false})
    void rosterIsRecognizedFromItsTitleOrFromItsColumnsAlone(boolean xls) throws Exception {
        DocumentKind kind = xls ? DocumentKind.XLS : DocumentKind.XLSX;
        var titled = workbook(AiDocumentFixtures.roster(xls, 86, true), kind);
        assertThat(titled.type()).isEqualTo("EMPLOYEE_ROSTER");
        assertThat(titled.evidence()).isEqualTo("TITLE");
        var untitled = workbook(AiDocumentFixtures.table(xls, "Sheet1", List.of(
                List.of("工号", "姓名", "性别", "所属部门", "职位", "入职时间", "联系电话"),
                List.of("A001", "钱试一", "男", "注塑一部", "操作工", java.time.LocalDate.of(2020, 1, 2), 13800000001L))), kind);
        assertThat(untitled).isEqualTo(new AiDocumentClassifier.Classification("EMPLOYEE_ROSTER", false, "COLUMNS"));
    }

    @Test void rosterPayrollAndSalesTablesStayDistinct() throws Exception {
        assertThat(workbook(AiDocumentFixtures.table(true, "Sheet1", List.of(List.of("姓名", "部门", "基本工资", "实发工资"),
                List.of("钱试一", "注塑一部", 3000, 2800))), DocumentKind.XLS).type()).isEqualTo("PAYROLL");
        assertThat(workbook(AiDocumentFixtures.table(false, "Sheet1", List.of(List.of("品名", "规格", "数量", "单价", "金额"),
                List.of("螺丝", "M3", 10, 0.5, 5))), DocumentKind.XLSX).type()).isEqualTo("SALES_TABLE");
        assertThat(workbook(AiDocumentFixtures.table(false, "Sheet1", List.of(List.of("报价单"), List.of("品名", "规格", "数量", "单价", "金额"),
                List.of("螺丝", "M3", 10, 0.5, 5))), DocumentKind.XLSX).type()).isEqualTo("SALES_QUOTATION");
        assertThat(workbook(AiDocumentFixtures.table(true, "Sheet1", List.of(List.of("姓名", "部门", "岗位", "身份证号", "应发工资"),
                List.of("钱试一", "注塑一部", "操作工", AiDocumentFixtures.idNumber("11010119900101001"), 3000))), DocumentKind.XLS).type())
                .as("a roster with a pay column is payroll").isEqualTo("PAYROLL");
        assertThat(workbook(AiDocumentFixtures.table(true, "Sheet1", List.of(List.of("姓名", "部门", "出勤天数", "迟到"),
                List.of("钱试一", "注塑一部", 22, 1))), DocumentKind.XLS).type()).isEqualTo("ATTENDANCE");
        assertThat(AiDocumentClassifier.classify(List.of("员工花名册", "姓名 部门 岗位 入职日期 身份证号码 手机号码")).type()).isEqualTo("EMPLOYEE_ROSTER");
        assertThat(AiDocumentClassifier.classify(List.of("姓名 部门 岗位 入职日期 身份证号码 手机号码")))
                .isEqualTo(new AiDocumentClassifier.Classification("EMPLOYEE_ROSTER", false, "COLUMNS"));
        assertThat(AiDocumentClassifier.classify(List.of("2026年10月考勤表")).type()).isEqualTo("ATTENDANCE");
        assertThat(AiDocumentClassifier.classify(List.of("员工档案", "姓名 性别 部门 岗位 身份证号码")).type())
                .as("a specific roster header refines the generic personnel title").isEqualTo("EMPLOYEE_ROSTER");
    }

    @Test void hrSheetsShareOneFamilyButARosterBesideAQuotationIsMixed() {
        var roster = List.of("花名册", "姓名 部门 岗位 身份证号码 手机号码");
        assertThat(AiDocumentClassifier.classifySections(List.of(roster, List.of("工资表", "姓名 应发工资 实发工资"))).type())
                .isEqualTo("EMPLOYEE_ROSTER");
        assertThat(AiDocumentClassifier.classifySections(List.of(roster, List.of("报价单", GOODS_HEADER))).type()).isEqualTo("MIXED_DOCUMENT");
        assertThat(AiDocumentClassifier.classify(List.of("某某有限公司2026年10月员工花名册(在职)", "姓名 部门")).type()).isEqualTo("EMPLOYEE_ROSTER");
        assertThat(AiDocumentClassifier.classify(List.of("员工花名册打印服务 1 20")).type()).isEqualTo("UNKNOWN");
    }

    @Test void masterStockAndBankListsComeFromTheirColumns() throws Exception {
        Map<String, List<Object>> headers = new java.util.LinkedHashMap<>();
        headers.put("GOODS_LIST", List.of("货品编码", "品名", "规格", "单位", "颜色"));
        headers.put("STOCK_LIST", List.of("货品编码", "品名", "仓库", "库存数量"));
        headers.put("BOM_LIST", List.of("父件编码", "子件编码", "子件名称", "用量"));
        headers.put("CUSTOMER_LIST", List.of("客户名称", "联系人", "电话", "地址"));
        headers.put("SUPPLIER_LIST", List.of("供应商名称", "联系人", "手机"));
        headers.put("BANK_STATEMENT", List.of("交易日期", "收入", "支出", "余额", "对方户名"));
        for (var entry : headers.entrySet()) {
            var bytes = AiDocumentFixtures.table(false, "Sheet1", List.of(entry.getValue(), List.of("A1", "B2", "C3", "D4")));
            assertThat(workbook(bytes, DocumentKind.XLSX).type()).as(entry.getKey()).isEqualTo(entry.getKey());
        }
        assertThat(AiDocumentClassifier.classify(List.of("银行流水", "交易日期 摘要 收入 支出 余额")).type()).isEqualTo("BANK_STATEMENT");
    }

    @Test void listHeadingsInsideAQuotationDoNotMakeItMixed() {
        assertThat(AiDocumentClassifier.classify(List.of("报价单", "客户资料", "客户名称 某某公司", GOODS_HEADER)).type()).isEqualTo("SALES_QUOTATION");
        assertThat(AiDocumentClassifier.classify(List.of("报价单", GOODS_HEADER, "备注", "交易明细")).type()).isEqualTo("SALES_QUOTATION");
        assertThat(AiDocumentClassifier.classifySections(List.of(List.of("客户名单", "客户名称 联系人 电话"), List.of("报价单", GOODS_HEADER))).type())
                .as("separate sheets of different businesses").isEqualTo("MIXED_DOCUMENT");
    }

    private static AiDocumentClassifier.Classification workbook(byte[] bytes, DocumentKind kind) {
        var grid = SpreadsheetGridReader.read(bytes, kind);
        var profile = AiDocumentProfiler.profile(grid);
        List<List<String>> sections = new ArrayList<>();
        List<Set<AiDocumentProfiler.Semantic>> columns = new ArrayList<>();
        for (int i = 0; i < grid.sheets().size(); i++) {
            List<String> lines = new ArrayList<>(List.of(grid.sheets().get(i).name()));
            grid.sheets().get(i).rows().forEach(row -> lines.add(row.joinedText()));
            sections.add(lines);
            columns.add(profile.sheets().get(i).semantics());
        }
        return AiDocumentClassifier.classifySections(sections, columns);
    }
}
