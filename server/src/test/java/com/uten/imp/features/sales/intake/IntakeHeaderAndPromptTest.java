package com.uten.imp.features.sales.intake;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.AiCompletionPort.AiCompletionRequest;
import com.uten.imp.application.port.AiCompletionPort.AiText;
import com.uten.imp.common.files.document.DocumentGrid.Cell;
import com.uten.imp.common.files.document.DocumentGrid.CellKind;
import com.uten.imp.common.files.document.DocumentGrid.Row;
import com.uten.imp.common.files.document.DocumentGrid.Sheet;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import java.util.regex.Pattern;

import static org.assertj.core.api.Assertions.assertThat;

class IntakeHeaderAndPromptTest {

    /** 发给 AI 的内容里不得出现的东西: 银行、SWIFT、账号、收款人、邮箱、电话号码、税号。 */
    private static final Pattern LEAK = Pattern.compile(
            "(?i)bank|swift|account|beneficiary|@|EXAMPLEXX|\\+962|\\+971|0000000|0000 0000|91440000X");

    @Test
    void sunasShapedHeaderRules() {
        Sheet sheet = IntakeLayoutAndExtractionTest.fixtureSheet("SUNAS");
        IntakeHeader h = IntakeHeaderRules.extract(sheet, 7);
        assertThat(h.buyerName).isEqualTo("ALPHA ELECTRICAL RESOURCE LTD");
        assertThat(h.contactName).isEqualTo("MR. CONTACT ALPHA");
        assertThat(h.emails).containsExactly("buyer@alpha-example.test");
        assertThat(h.incoterm).isEqualTo("EXW");
        assertThat(h.paymentTerms).isEqualTo("T/T 30% prepay, 70% before shippment");
        assertThat(h.remarkSuggestion()).isEqualTo("EXW; T/T 30% prepay, 70% before shippment");
        assertThat(h.buyerAddress).isNull();
    }

    @Test
    void uj23ShapedHeaderRulesSkipTheSellerLetterhead() {
        Sheet sheet = IntakeLayoutAndExtractionTest.fixtureSheet("UJ23");
        IntakeHeader h = IntakeHeaderRules.extract(sheet, 9);
        assertThat(h.buyerName).endsWith("FOR ELECTRICAL INDUSTRIES CO. LTD");
        assertThat(h.buyerName).doesNotContain("UTEN");
        assertThat(h.buyerAddress).contains("Irbid, Jordan");
        assertThat(h.country).isEqualTo("约旦");
        assertThat(h.phones).containsExactly("+962-2-0000000");
        assertThat(h.emails).isEmpty();
        assertThat(h.taxId).isEqualTo("000000000");
        assertThat(h.docNo).isEqualTo("UJ23");
        assertThat(h.docDate).isEqualTo("2026-07-06");
        assertThat(h.paymentTerms).isEqualTo("T/T 30% deposit, 70% pay before shipment");
        assertThat(h.port).isEqualTo("Xiaolan port, China");
        Map<String, Object> result = h.toResult();
        assertThat(result).containsKeys("buyerName", "emails", "phones", "docNo", "remarkSuggestion");
    }

    @Test
    void minimizedHeaderNeverContainsBankOrContactDetails() {
        for (String key : List.of("SUNAS", "UJ23")) {
            Sheet sheet = IntakeLayoutAndExtractionTest.fixtureSheet(key);
            int headerRow = IntakeLayoutDetector.detect(sheet).headerRow0();
            IntakeHeaderRules.MinimizedHeader minimized = IntakeHeaderRules.minimize(sheet, headerRow, 4000);
            assertThat(LEAK.matcher(minimized.text()).find()).as(key + ": " + minimized.text()).isFalse();
            assertThat(minimized.text()).doesNotContain("UTEN").doesNotContain("Zhongshan");
            AiCompletionRequest request = IntakePrompts.header(minimized.text(), UUID.randomUUID());
            String all = FakeJobContext.allText(request);
            assertThat(LEAK.matcher(all.replace(IntakePrompts.SELLER, "")).find()).isFalse();
            assertThat(request.userParts()).allSatisfy(p -> assertThat(((AiText) p).untrusted()).isTrue());
        }
    }

    @Test
    void placeholdersAreMappedBackServerSide() {
        Map<String, String> placeholders = new LinkedHashMap<>();
        String masked = IntakeHeaderRules.maskPii("Tel:+86 760 1234 5678 mail: a@b.com TAX NO: 91440000X", placeholders);
        assertThat(masked).doesNotContain("1234").doesNotContain("a@b.com").doesNotContain("91440000X");
        assertThat(masked).contains("⟨PHONE_1⟩").contains("⟨EMAIL_1⟩").contains("⟨TAXID_1⟩");
        assertThat(IntakeHeaderRules.unmask("⟨EMAIL_1⟩", placeholders)).isEqualTo("a@b.com");
        assertThat(IntakeHeaderRules.maskPii("Date: 2026-07-06", new LinkedHashMap<>())).contains("2026-07-06");
    }

    @Test
    void aiHeaderOnlyFillsBlanksAndMustQuoteTheSource() throws Exception {
        IntakeHeader h = new IntakeHeader();
        h.docNo = "PI-1";
        String source = "R3 | A:Messrs ACME TRADING FZE | B:Invoice PI-9";
        var node = new ObjectMapper().readTree("""
                {"buyerName":"ACME TRADING FZE","docNo":"PI-9","contactName":"Invented Person","docDate":"6 July 2026",
                 "incoterm":"fob","country":"United Arab Emirates","port":null}""");
        SalesIntakePipeline.mergeAiHeader(h, node, source, Map.of(), "RULES+AI");
        assertThat(h.buyerName).isEqualTo("ACME TRADING FZE");
        assertThat(h.docNo).isEqualTo("PI-1");
        assertThat(h.contactName).isNull();
        assertThat(h.docDate).isEqualTo("2026-07-06");
        assertThat(h.incoterm).isEqualTo("FOB");
        assertThat(h.country).isEqualTo("阿联酋");
        assertThat(h.source).isEqualTo("RULES+AI");
    }

    @Test
    void sellerLabelBlockAndBuyerLabelBelow() {
        Sheet sheet = new Sheet("S", 0, List.of(
                new Row(0, List.of(Cell.text(0, "Buyer"), Cell.text(4, "Seller"))),
                new Row(1, List.of(Cell.text(0, "OMEGA IMPORTS LLC"), Cell.text(4, "SOME SUPPLIER NAME"))),
                new Row(2, List.of(Cell.text(0, "Contact: Mr. K"), Cell.text(4, "Tel: +86 760 0000 1111"))),
                new Row(3, List.of(Cell.text(0, "Quotation No.: Q-7788"), Cell.text(4, "Date: 06/07/2026")))),
                List.of(), 0, 4, false);
        IntakeHeader h = IntakeHeaderRules.extract(sheet, 5);
        assertThat(h.buyerName).isEqualTo("OMEGA IMPORTS LLC");
        assertThat(h.contactName).isEqualTo("Mr. K");
        assertThat(h.phones).isEmpty();
        assertThat(h.docNo).isEqualTo("Q-7788");
        assertThat(h.docDate).isEqualTo("2026-07-06");
    }

    @Test
    void datesInManyShapes() {
        assertThat(IntakeHeaderRules.parseDate("2026-7-6")).isEqualTo("2026-07-06");
        assertThat(IntakeHeaderRules.parseDate("2026年7月6日")).isEqualTo("2026-07-06");
        assertThat(IntakeHeaderRules.parseDate("6-Jul-2026")).isEqualTo("2026-07-06");
        assertThat(IntakeHeaderRules.parseDate("July 6th, 2026")).isEqualTo("2026-07-06");
        assertThat(IntakeHeaderRules.parseDate("06/07/2026")).isEqualTo("2026-07-06");
        assertThat(IntakeHeaderRules.parseDate("not a date")).isNull();
    }

    @Test
    void matchPromptSeparatesCustomerTextFromCatalogAndUsesShortRefs() {
        List<IntakePrompts.MatchLine> lines = List.of(new IntakePrompts.MatchLine("S1R13", "part KMLD-01-2 ; barcket ; 门铃按钮支架",
                List.of("g1", "g2")));
        Map<String, String> catalog = Map.of("g1", "Q1200148 | Q120大板按钮支撑块 | | Q120 | 深灰色", "g2", "W500028 | W50门铃按钮 | | W50 | 白色");
        AiCompletionRequest req = IntakePrompts.match(lines, catalog, List.of("g1"), UUID.randomUUID());
        assertThat(((AiText) req.userParts().get(0)).untrusted()).isTrue();
        assertThat(((AiText) req.userParts().get(0)).text()).contains("KMLD-01-2").doesNotContain("Q1200148");
        assertThat(((AiText) req.userParts().get(1)).untrusted()).isFalse();
        assertThat(((AiText) req.userParts().get(1)).text()).contains("g1 | Q1200148").contains("S1R13: g1, g2");
        assertThat(req.jsonSchema()).containsKey("properties");
        assertThat(req.systemPrompt()).contains(IntakePrompts.SELLER).contains("Never invent");
    }

    @Test
    void documentPromptForPdfTextIsMinimized() {
        Map<String, String> placeholders = new LinkedHashMap<>();
        String text = IntakeHeaderRules.minimizeText(List.of(
                "ZHONGSHAN SHI UTEN ELECTRIC CO.,LTD", "Buyer: ACME FZE, Tel +971 4 000 0000, buyer@acme.test",
                "KCL-01 curtain switch 5000 0.537 2685", "Bank: EXAMPLE BANK", "SWIFT: EXAMPLEXX", "Account No. 0000 0000"),
                placeholders);
        assertThat(LEAK.matcher(text).find()).as(text).isFalse();
        assertThat(text).contains("KCL-01 curtain switch").doesNotContain("UTEN");
        AiCompletionRequest req = IntakePrompts.documentText(text, 3, UUID.randomUUID());
        assertThat(req.maxOutputTokens()).isBetween(1000, IntakePrompts.MAX_OUTPUT_CAP);
    }

    @Test
    void pdfBankBlocksAreDroppedEvenWhenLinesCarryNoBankKeyword() {
        Map<String, String> placeholders = new LinkedHashMap<>();
        String text = IntakeHeaderRules.minimizeText(List.of(
                "PROFORMA INVOICE No. PI-778",
                "1  KCL-01  curtain switch  5000  0.537  2685",
                "BANK INFORMATION",
                "HSBC HONG KONG MAIN BRANCH",
                "1 QUEEN'S ROAD CENTRAL, HONG KONG",
                "ACC NO: 8123 4567 8901",
                "Acc. No. 812345678901",
                "BIC: HSBCHKHHHKH",
                "Sort code 12-34-56",
                "收款行: 中国银行中山分行",
                "8123 4567 8901",
                "Remark: delivery within 45 days",
                "2  Z13N-03  Shutter  20000  0.011  220"), placeholders);
        assertThat(LEAK.matcher(text).find()).as(text).isFalse();
        assertThat(text).doesNotContain("HSBC").doesNotContain("8123").doesNotContain("812345678901")
                .doesNotContain("QUEEN").doesNotContain("Sort code").doesNotContain("中国银行");
        assertThat(text).contains("PI-778").contains("KCL-01  curtain switch").contains("Remark: delivery")
                .contains("Z13N-03");
        AiCompletionRequest req = IntakePrompts.documentText(text, 2, UUID.randomUUID());
        assertThat(FakeJobContext.allText(req)).doesNotContain("HSBC").doesNotContain("8123");

        // 银行块最多连着吞 6 行, 之后的正常行照发; 像货品的行立刻结束银行块。
        String capped = IntakeHeaderRules.minimizeText(List.of("Bank details:", "a", "b", "c", "d", "e", "f",
                "seventh line"), new LinkedHashMap<>());
        assertThat(capped).isEqualTo("seventh line");
        String goodsAfterBank = IntakeHeaderRules.minimizeText(List.of("Beneficiary: EXAMPLE CO",
                "3  GK12  switch  700  9.45  6615"), new LinkedHashMap<>());
        assertThat(goodsAfterBank).contains("GK12");
    }

    @Test
    void spreadsheetHeaderMinimizationDropsTheRowsOfABankBlock() {
        Sheet sheet = new Sheet("S", 0, List.of(
                new Row(0, List.of(Cell.text(0, "Bank information:"))),
                new Row(1, List.of(Cell.text(0, "HSBC HONG KONG MAIN BRANCH"))),
                new Row(2, List.of(Cell.text(0, "8123 4567 8901"))),
                new Row(3, List.of(Cell.text(0, "Messrs: OMEGA IMPORTS LLC"))),
                new Row(5, List.of(Cell.text(0, "Part No"), Cell.text(1, "Qty")))),
                List.of(), 0, 1, false);
        String text = IntakeHeaderRules.minimize(sheet, 5, 4000).text();
        assertThat(text).doesNotContain("HSBC").doesNotContain("8123").contains("OMEGA IMPORTS LLC");
    }

    @Test
    void sellerNameInsideGoodsLinesIsMaskedInsteadOfDropped() {
        Map<String, String> placeholders = new LinkedHashMap<>();
        String text = IntakeHeaderRules.minimizeText(List.of(
                "ZHONGSHAN SHI UTEN ELECTRIC CO.,LTD",
                "Item  Description  Qty  Price  Amount",
                "1  GZ23/D  socket with UTEN logo  1800  21  37800",
                "2  GK12  switch (UTEN brand)  700  9.45  6615",
                "For and on behalf of ZHONGSHAN UTEN ELECTRIC"), placeholders);
        assertThat(text).doesNotContain("SHI UTEN ELECTRIC CO.,LTD").doesNotContain("UTEN ")
                .contains("socket with ⟨SELLER_1⟩ logo").contains("switch (⟨SELLER_1⟩ brand)");
        assertThat(IntakeHeaderRules.unmask("socket with ⟨SELLER_1⟩ logo", placeholders)).isEqualTo("socket with UTEN logo");

        // 每页顶部的抬头(我司名称)仍整行去掉; 从页中间接着的一段不当抬头。
        String twoPages = IntakeHeaderRules.minimizeText(List.of("1  GZ23/D  socket  1800  21  37800",
                "UTEN ELECTRIC letterhead", "3  GK22  switch  10  9.5  95"), Set.of(0, 1), new LinkedHashMap<>());
        assertThat(twoPages).doesNotContain("letterhead").contains("GK22");
        String midPage = IntakeHeaderRules.minimizeText(List.of("with UTEN logo", "4  GK45A  switch  10  9.5  95"),
                Set.of(), new LinkedHashMap<>());
        assertThat(midPage).contains("with ⟨SELLER_1⟩ logo");

        Sheet sheet = new Sheet("S", 0, List.of(
                new Row(0, List.of(Cell.text(0, "ZHONGSHAN SHI UTEN ELECTRIC CO.,LTD"))),
                new Row(2, List.of(Cell.text(0, "Part No"), Cell.text(1, "Description"), Cell.text(2, "Qty"),
                        Cell.text(3, "Price"))),
                new Row(3, List.of(Cell.text(0, "GZ23/D"), Cell.text(1, "socket with UTEN logo"),
                        new Cell(2, "1800", CellKind.NUMBER, new BigDecimal("1800")),
                        new Cell(3, "21", CellKind.NUMBER, new BigDecimal("21")))),
                new Row(5, List.of(Cell.text(0, "Bank: EXAMPLE BANK"))),
                new Row(6, List.of(Cell.text(0, "HSBC HONG KONG MAIN BRANCH")))),
                List.of(), 0, 3, false);
        Sheet sanitized = IntakeHeaderRules.sanitizeForColumnPrompt(sheet, 0, 14);
        assertThat(sanitized.rows()).extracting(Row::index0).containsExactly(2, 3);
        assertThat(sanitized.text(3, 1)).isEqualTo("socket with ⟨SELLER_1⟩ logo");
    }
}
