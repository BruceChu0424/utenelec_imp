package com.uten.imp.common.util;

import com.uten.imp.common.web.ApiException;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.util.LinkedHashMap;
import java.util.Map;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;

class NumericColumnFilterTest {
    @Test void comparisonsBindExactDecimalsAndNeverEmbedInputInSql() {
        for (String operator : new String[]{"", "=", "!=", ">", ">=", "<", "<="}) {
            var parsed = NumericColumnFilter.parse(operator + " -9007199254740993.0001");
            assertEquals("difference_qty " + (operator.isEmpty() ? "=" : operator) + " :difference",
                    parsed.sql("difference_qty", "difference"));
            Map<String, BigDecimal> bound = new LinkedHashMap<>();
            parsed.bind("difference", bound::put);
            assertEquals(Map.of("difference", new BigDecimal("-9007199254740993.0001")), bound);
        }
    }

    @Test void closedRangesKeepBothBoundsAndNegativeFractionPrecision() {
        var parsed = NumericColumnFilter.parse(" -0.0001 .. +2.5000 ");
        assertEquals("difference_qty BETWEEN :difference_lower AND :difference_upper",
                parsed.sql("difference_qty", "difference"));
        Map<String, BigDecimal> bound = new LinkedHashMap<>();
        parsed.bind("difference", bound::put);
        assertEquals(new BigDecimal("-0.0001"), bound.get("difference_lower"));
        assertEquals(new BigDecimal("+2.5000"), bound.get("difference_upper"));
        assertEquals("=", NumericColumnFilter.parse("-0.0000").operator());
        assertEquals(0, NumericColumnFilter.parse("1.0..1.000").lower().compareTo(new BigDecimal("1")));
    }

    @Test void invalidOrAmbiguousInputFailsInsteadOfBecomingAnEmptyOrTextQuery() {
        for (String input : new String[]{"", " ", "abc", "1,000", "1e3", "NaN", "Infinity",
                "1..-1", "1..", "..2", "1...2", ".2", "1.", "1;DROP TABLE goods", "<>2", ">=", "1".repeat(129)})
            assertThrows(ApiException.class, () -> NumericColumnFilter.parse(input), input);
        assertThrows(ApiException.class, () -> NumericColumnFilter.parse(null));
    }

    @Test void directConstructionAndParameterNamesCannotBypassTheSqlGrammar() {
        for(String operator:new String[]{"= 1 OR TRUE --", "BETWEEN", "<>", ""}) {
            assertThrows(ApiException.class,()->new NumericColumnFilter(operator,BigDecimal.ONE,null));
        }
        assertThrows(ApiException.class,()->new NumericColumnFilter("=",BigDecimal.ONE,BigDecimal.TEN));
        assertThrows(ApiException.class,()->new NumericColumnFilter("BETWEEN",BigDecimal.TEN,BigDecimal.ONE));
        var filter=NumericColumnFilter.parse(">=1");
        for(String name:new String[]{"amount) OR TRUE --", "value:other", ""}) {
            assertThrows(IllegalArgumentException.class,()->filter.sql("amount",name));
            assertThrows(IllegalArgumentException.class,()->filter.bind(name,(key,value)->{}));
        }
    }
}
