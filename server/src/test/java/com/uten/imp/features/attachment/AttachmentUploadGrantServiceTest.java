package com.uten.imp.features.attachment;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.config.props.CryptoProperties;
import com.uten.imp.features.attachment.AttachmentUploadGrantService.Grant;
import org.junit.jupiter.api.Test;

import java.time.Clock;
import java.time.Instant;
import java.time.ZoneOffset;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;

class AttachmentUploadGrantServiceTest {

    private static final Instant NOW = Instant.parse("2026-08-09T02:00:00Z");

    @Test
    void signedGrantRoundTripsAndAnyTamperIsRejected() {
        AttachmentUploadGrantService service = serviceAt(NOW);
        Grant grant = grant(NOW.plusSeconds(60));

        String token = service.issue(grant);
        assertEquals(grant, service.verify(token));

        int last = token.length() - 1;
        char replacement = token.charAt(last) == 'A' ? 'B' : 'A';
        String tampered = token.substring(0, last) + replacement;
        ApiException failure = assertThrows(ApiException.class, () -> service.verify(tampered));
        assertEquals(ErrorCode.FORBIDDEN, failure.getCode());
    }

    @Test
    void expiredGrantIsRejectedEvenWhenSignatureIsValid() {
        AttachmentUploadGrantService issuer = serviceAt(NOW.minusSeconds(120));
        Grant expired = grant(NOW.minusSeconds(1));
        String token = issuer.issue(expired);

        ApiException failure = assertThrows(ApiException.class, () -> serviceAt(NOW).verify(token));
        assertEquals(ErrorCode.CONFLICT, failure.getCode());
        assertEquals(expired, serviceAt(NOW).verifySigned(token));
    }

    private static AttachmentUploadGrantService serviceAt(Instant instant) {
        CryptoProperties crypto = new CryptoProperties();
        crypto.setHmacKey("attachment-grant-test-key-with-sufficient-entropy-0123456789");
        ObjectMapper mapper = new ObjectMapper().findAndRegisterModules();
        return new AttachmentUploadGrantService(
                mapper, crypto, Clock.fixed(instant, ZoneOffset.UTC));
    }

    private static Grant grant(Instant expiry) {
        return new Grant(
                "abc123.png", "EXPENSE_CLAIM", UUID.randomUUID(), UUID.randomUUID(),
                "receipt.png", "image/png", 42, expiry);
    }
}
