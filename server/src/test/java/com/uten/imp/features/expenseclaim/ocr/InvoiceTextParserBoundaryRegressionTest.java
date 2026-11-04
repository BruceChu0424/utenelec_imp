package com.uten.imp.features.expenseclaim.ocr;

import org.junit.jupiter.api.Test;
import java.util.List;
import static org.assertj.core.api.Assertions.assertThat;

class InvoiceTextParserBoundaryRegressionTest {
    @Test
    void impossibleOcrDatesRemainUnknownAndLeapDayStillParses() {
        for (String text : List.of("开票日期：2026年02月30日", "开票日期：2026-13-01")) {
            var invoice=InvoiceTextParser.parse(List.of("发票号码：24312000000012345678",text,"价税合计（小写）￥100.00"));
            assertThat(invoice).isNotNull();
            assertThat(invoice.issueDate()).isNull();
        }
        var leap=InvoiceTextParser.parse(List.of("发票号码：24312000000012345678","开票日期：2024年02月29日","价税合计（小写）￥100.00"));
        assertThat(leap).isNotNull();
        assertThat(leap.issueDate()).isEqualTo("2024-02-29");
    }
    @Test void originalFiniteDigitsAreNotReplacedByATwoPlaceOcrPrefix() {
        var exact=InvoiceTextParser.parse(List.of("发票号码：24312000000012345678","价税合计（小写）￥100.123456789012345678901234"));
        assertThat(exact.totalAmount()).isEqualByComparingTo("100.123456789012345678901234");
        var unsupported=InvoiceTextParser.parse(List.of("发票号码：24312000000012345678","价税合计（小写）￥100.1234567890123456789012345"));
        assertThat(unsupported==null?null:unsupported.totalAmount()).isNull();
    }
}
