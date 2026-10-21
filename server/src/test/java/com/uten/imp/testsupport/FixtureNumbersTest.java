package com.uten.imp.testsupport;

import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertInstanceOf;
import static org.junit.jupiter.api.Assertions.assertThrows;

class FixtureNumbersTest {
    @Test
    void signedIntegralBoundariesRemainExact() {
        assertEquals(Integer.MIN_VALUE, FixtureNumbers.integer("-2147483648"));
        assertEquals(Integer.MAX_VALUE, FixtureNumbers.integer("2147483647"));
        assertEquals(Long.MIN_VALUE, FixtureNumbers.longInteger("-9223372036854775808"));
        assertEquals(Long.MAX_VALUE, FixtureNumbers.longInteger("9223372036854775807"));
    }

    @Test
    void malformedAndOverflowingIntegralFactsFailWithTheirOriginalCause() {
        for (String value : new String[]{"", "1.5", "2147483648", "-2147483649"}) {
            assertInstanceOf(NumberFormatException.class,
                    assertThrows(AssertionError.class, () -> FixtureNumbers.integer(value)).getCause());
        }
        assertInstanceOf(NumberFormatException.class,
                assertThrows(AssertionError.class, () -> FixtureNumbers.longInteger("9223372036854775808")).getCause());
    }

    @Test
    void spreadsheetNumbersPreserveFiniteValuesAndRejectNonFiniteOverflow() {
        assertEquals(0.125, FixtureNumbers.finiteDouble("0.125"));
        for (String value : new String[]{"NaN", "Infinity", "-Infinity", "1e999", "not-a-number"}) {
            assertThrows(AssertionError.class, () -> FixtureNumbers.finiteDouble(value));
        }
    }
}
