package com.uten.imp.common.util;

import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;

class LogValueTest {
    @Test void hostileRequestFieldsCannotCreateAnotherLogLineOrControlTheTerminal() {
        String value = LogValue.singleLine("GET\r\nforged=success\u2028another-line\t\u001b[31m");
        assertEquals("GET_forged=success_another-line__[31m", value);
        assertFalse(value.matches("(?s).*[\\r\\n\\p{Cntrl}\\u2028\\u2029].*"));
    }

    @Test void fieldsRemainBoundedAndOrdinaryPathsKeepTheirMeaning() {
        assertEquals("/api/master/goods?page=1", LogValue.singleLine("/api/master/goods?page=1"));
        assertEquals(512, LogValue.singleLine("x".repeat(10_000)).length());
        assertEquals("-", LogValue.singleLine(null));
    }
}
