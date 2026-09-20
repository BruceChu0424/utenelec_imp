package com.uten.imp.features.expenseclaim.ocr;

import com.uten.imp.features.expenseclaim.dto.RecognizedInvoiceDto;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.util.List;

import static org.assertj.core.api.Assertions.assertThat;

/** 规则抽取器：OCR 文本行 → 票面要素（数电票/专票/坏版式三类样本）。 */
class InvoiceTextParserTest {

    @Test
    void extractsActualLocalMobileOcrLabelsAsUnverifiedSuggestions() {
        var invoice = InvoiceTextParser.parse(List.of(
                "电子发票(普通发票)", "发票号码：26999900000012345678", "开票日期：2026年09月19日",
                "购买方：乌腾测试制造有限公司", "纳税人识别号：TESTBUYER123456789",
                "销售方：示例办公用品有限公司", "纳税人识别号：TESTSELLER12345678",
                "项目名称：测试办公用品", "金额：100.00", "税额：13.00", "价税合计(小写)：￥113.00"));
        assertThat(invoice.invoiceNo()).isEqualTo("26999900000012345678");
        assertThat(invoice.issueDate()).isEqualTo("2026-09-19");
        assertThat(invoice.buyerName()).isEqualTo("乌腾测试制造有限公司");
        assertThat(invoice.sellerName()).isEqualTo("示例办公用品有限公司");
        assertThat(invoice.amountExclTax()).isEqualByComparingTo("100.00");
        assertThat(invoice.taxAmount()).isEqualByComparingTo("13.00");
        assertThat(invoice.totalAmount()).isEqualByComparingTo("113.00");
        // These fictional identifiers only satisfy the extraction shape; no tax verification occurs.
        assertThat(invoice.buyerTaxNo()).isEqualTo("TESTBUYER123456789");
        assertThat(invoice.sellerTaxNo()).isEqualTo("TESTSELLER12345678");
    }

    @Test
    void parsesDigitalInvoiceLayout() {
        List<String> lines = List.of(
                "电子发票（普通发票）",
                "发票号码：24312000000012345678",
                "开票日期：2026年09月18日",
                "购买方名称：上海优腾实业有限公司",
                "购买方纳税人识别号：91310000MA1FL8XX00",
                "销售方名称：上海某某酒店管理有限公司",
                "销售方纳税人识别号：91310000MA1FL8YY11",
                "项目名称 住宿费",
                "合 计 ¥80.00 ¥4.80",
                "价税合计（小写）¥84.80",
                "价税合计（大写）捌拾肆元捌角");

        RecognizedInvoiceDto invoice = InvoiceTextParser.parse(lines);

        assertThat(invoice).isNotNull();
        assertThat(invoice.invoiceType()).isEqualTo("DIGITAL");
        assertThat(invoice.invoiceNo()).isEqualTo("24312000000012345678");
        assertThat(invoice.invoiceCode()).isNull();
        assertThat(invoice.issueDate()).isEqualTo("2026-09-18");
        assertThat(invoice.buyerName()).contains("优腾");
        assertThat(invoice.sellerName()).contains("酒店");
        assertThat(invoice.sellerTaxNo()).isEqualTo("91310000MA1FL8YY11");
        assertThat(invoice.buyerTaxNo()).isEqualTo("91310000MA1FL8XX00");
        assertThat(invoice.totalAmount()).isEqualByComparingTo(new BigDecimal("84.80"));
        assertThat(invoice.amountExclTax()).isEqualByComparingTo(new BigDecimal("80.00"));
        assertThat(invoice.taxAmount()).isEqualByComparingTo(new BigDecimal("4.80"));
    }

    @Test
    void parsesLegacySpecialInvoiceWithCode() {
        List<String> lines = List.of(
                "上海增值税专用发票",
                "发票代码：044031900111",
                "发票号码：12345678",
                "开票日期：2026年01月31日",
                "销售方名称：苏州精密机械有限公司",
                "合 计 ¥900.00 ¥54.00",
                "价税合计（小写）¥954.00");

        RecognizedInvoiceDto invoice = InvoiceTextParser.parse(lines);

        assertThat(invoice).isNotNull();
        assertThat(invoice.invoiceType()).isEqualTo("SPECIAL");
        assertThat(invoice.invoiceCode()).isEqualTo("044031900111");
        assertThat(invoice.invoiceNo()).isEqualTo("12345678");
        assertThat(invoice.totalAmount()).isEqualByComparingTo(new BigDecimal("954.00"));
        assertThat(invoice.amountExclTax()).isEqualByComparingTo(new BigDecimal("900.00"));
        assertThat(invoice.taxAmount()).isEqualByComparingTo(new BigDecimal("54.00"));
    }

    @Test
    void dirtyLayoutKeepsTotalButDropsUnreconciledBreakdown() {
        List<String> lines = List.of(
                "发票号码：24312000000012345678",
                "开票日期 2026-03-02",
                "合 计 ¥120.00 ¥7.20",
                "价 税 合 计 （ 小 写 ） ¥ 130.00");

        RecognizedInvoiceDto invoice = InvoiceTextParser.parse(lines);

        assertThat(invoice).isNotNull();
        // 120 + 7.2 = 127.2 ≠ 130：明细不猜，价税合计保留给人工核对。
        assertThat(invoice.totalAmount()).isEqualByComparingTo(new BigDecimal("130.00"));
        assertThat(invoice.amountExclTax()).isNull();
        assertThat(invoice.taxAmount()).isNull();
        assertThat(invoice.issueDate()).isEqualTo("2026-03-02");
    }

    @Test
    void blankOrAmountlessTextYieldsNull() {
        assertThat(InvoiceTextParser.parse(null)).isNull();
        assertThat(InvoiceTextParser.parse(List.of())).isNull();
        assertThat(InvoiceTextParser.parse(List.of("某商户小票", "合计金额面议"))).isNull();
    }

    @Test
    void invalidCalendarDateDoesNotDiscardOtherSuggestions() {
        var invoice = InvoiceTextParser.parse(List.of("开票日期2026-02-30", "价税合计(小写)￥10.00"));
        assertThat(invoice.issueDate()).isNull();
        assertThat(invoice.totalAmount()).isEqualByComparingTo("10.00");
    }

    @Test
    void doesNotGuessBankAccountAsInvoiceOrLastLineAsTotal() {
        var invoice = InvoiceTextParser.parse(List.of("账号12345678901234567890", "价税合计(小写)￥10.00"));
        assertThat(invoice.invoiceNo()).isNull();
        assertThat(InvoiceTextParser.parse(List.of("某商品￥10.00", "余额￥20.00"))).isNull();
    }

    @Test
    void oneCentMismatchCannotBePresentedAsReconciled() {
        var invoice = InvoiceTextParser.parse(List.of("合计￥10.00￥0.60", "价税合计(小写)￥10.61"));
        assertThat(invoice.amountExclTax()).isNull();
        assertThat(invoice.taxAmount()).isNull();
    }

    @Test
    void legacyElectronicInvoiceWithEightDigitNumberIsNotDigitalTwentyDigitType() {
        var invoice = InvoiceTextParser.parse(List.of("增值税电子普通发票", "发票号码12345678",
                "发票代码044031900111", "价税合计(小写)￥10.00"));
        assertThat(invoice.invoiceType()).isNotEqualTo("DIGITAL");
        assertThat(invoice.invoiceCode()).isEqualTo("044031900111");
    }
}
