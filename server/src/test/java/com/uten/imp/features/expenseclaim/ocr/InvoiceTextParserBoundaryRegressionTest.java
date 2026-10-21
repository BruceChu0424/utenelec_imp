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
}
