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
        assertThat(AiDocumentClassifier.classify(lines)).isEqualTo(new AiDocumentClassifier.Classification("SALES_QUOTATION", false));
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
        assertThat(AiDocumentClassifier.classifySections(List.of(first, second))).isEqualTo(new AiDocumentClassifier.Classification("INVOICE", true));
        assertThat(AiDocumentClassifier.classify(List.of("电子发票", "发票号码:12345678", "价税合计:100", "价税合计（大写）:壹佰元")).multipleInvoices()).isFalse();
    }

    @Test void untitledEnglishInvoiceReferencesAreCommercialRatherThanDomesticTaxEvidence() {
        assertThat(AiDocumentClassifier.classify(List.of("Invoice No: REF-2026", "Grand Total:100")).type()).isEqualTo("COMMERCIAL_INVOICE");
        assertThat(AiDocumentClassifier.classifySections(List.of(List.of("报价单", GOODS_HEADER),
                List.of("Invoice No: REF-2026", "Grand Total:100"))).type()).isEqualTo("SALES_QUOTATION");
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
}
