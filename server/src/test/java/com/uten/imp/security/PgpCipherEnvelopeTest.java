package com.uten.imp.security;

import com.uten.imp.config.props.CryptoProperties;
import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.*;

class PgpCipherEnvelopeTest {
    @Test void historicalUnversionedCipherDoesNotFollowTheCurrentWriteVersion() {
        var properties = new CryptoProperties(); properties.setPgpKeyVersion("2");
        var parsed = PgpCipherEnvelope.parse("test-base64-body",properties.getPgpUnversionedKeyVersion());
        assertEquals("1",parsed.version()); assertFalse(parsed.versioned());
        assertEquals("test-base64-body",parsed.body());
        assertEquals("2",PgpCipherEnvelope.parse("2:body","1").version());
    }

    @Test void malformedPrefixCannotAppearInAnException() {
        String sensitive = "not a real ID but confidential";
        var error = assertThrows(IllegalArgumentException.class, () -> PgpCipherEnvelope.parse(sensitive+":bad","1"));
        assertFalse(error.getMessage().contains(sensitive));
    }
}
