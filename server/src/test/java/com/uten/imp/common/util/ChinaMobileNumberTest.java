package com.uten.imp.common.util;

import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

class ChinaMobileNumberTest {

    @Test
    void acceptsCommonMainlandRepresentationsAndReturnsOneCanonicalValue() {
        assertEquals(
                "13800138000",
                ChinaMobileNumber.normalize("13800138000").orElseThrow());
        assertEquals(
                "13800138000",
                ChinaMobileNumber.normalize("+86 138-0013-8000").orElseThrow());
        assertEquals(
                "13800138000",
                ChinaMobileNumber.normalize("0086 (138) 0013 8000").orElseThrow());
        assertEquals(
                "13800138000",
                ChinaMobileNumber.normalize("８６１３８００１３８０００").orElseThrow());
    }

    @Test
    void rejectsNonMainlandOrAmbiguousInputs() {
        assertTrue(ChinaMobileNumber.normalize("12800138000").isEmpty());
        assertTrue(ChinaMobileNumber.normalize("138abc00138000").isEmpty());
        assertTrue(ChinaMobileNumber.normalize("+1 202 555 0100").isEmpty());
        assertTrue(ChinaMobileNumber.normalize(null).isEmpty());
    }

    @Test
    void logMaskNeverReturnsTheFullPhone() {
        assertEquals("****8000", ChinaMobileNumber.maskedSuffix("13800138000"));
        assertEquals("****", ChinaMobileNumber.maskedSuffix(null));
    }
}
