package com.uten.imp.common.columns;

import com.uten.imp.common.web.ApiException;
import org.junit.jupiter.api.Test;
import java.math.BigDecimal;
import java.util.List;
import java.util.UUID;
import static org.assertj.core.api.Assertions.*;

class ExtraColumnCalculatorTest {
    @Test void preservesInputOrderAndEveryDecimalDigit() {
        assertThat(ExtraColumnCalculator.apply(new BigDecimal("10.12345678901"), List.of(
                column("ADD", "0.00000000009"), column("MULTIPLY", "2"),
                column("SUBTRACT", "1"), column("DIVIDE", "8"))))
                .isEqualByComparingTo("2.405864197275");
    }
    @Test void rejectsZeroNonTerminatingDivisionNegativeResultAndOverflow() {
        for (var invalid : List.of(column("DIVIDE", "0"), column("DIVIDE", "3"),
                column("SUBTRACT", "2"), column("MULTIPLY", "10000000000000000000000000000000000000000"))) {
            assertThatThrownBy(() -> ExtraColumnCalculator.apply(BigDecimal.ONE, List.of(invalid)))
                    .isInstanceOf(ApiException.class);
        }
    }
    @Test void informationalAndEmptyColumnsDoNotInventCharges() {
        var text = new ExtraColumnSnapshot(UUID.randomUUID(), "包装要求", "TEXT", "NONE", "双层");
        assertThat(ExtraColumnCalculator.apply(new BigDecimal("7.12345"),
                List.of(text, column("ADD", null)))).isEqualByComparingTo("7.12345");
        assertThat(ExtraColumnCalculator.apply(null, List.of(column("ADD", "3")))).isNull();
    }
    @Test void forbidsExpressionSyntaxAndTextArithmetic() {
        for (String value : List.of("1e2", "1+2", "NaN", " 2", "1,000"))
            assertThatThrownBy(() -> ExtraColumnCalculator.decimal(value, "费用")).isInstanceOf(ApiException.class);
        assertThatThrownBy(() -> ExtraColumnCalculator.apply(BigDecimal.ONE,
                List.of(new ExtraColumnSnapshot(UUID.randomUUID(), "文本", "TEXT", "ADD", "2"))))
                .isInstanceOf(ApiException.class);
    }
    private static ExtraColumnSnapshot column(String operation, String value) {
        return new ExtraColumnSnapshot(UUID.randomUUID(), "费用", "AMOUNT", operation, value);
    }
}
