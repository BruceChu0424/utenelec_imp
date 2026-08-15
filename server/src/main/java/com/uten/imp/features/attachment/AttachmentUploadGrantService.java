package com.uten.imp.features.attachment;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.config.props.CryptoProperties;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.stereotype.Service;

import javax.crypto.Mac;
import javax.crypto.spec.SecretKeySpec;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.time.Clock;
import java.time.Instant;
import java.time.temporal.ChronoUnit;
import java.util.Base64;
import java.util.UUID;

/** 短期、单用途语义的附件上传授权（无服务端会话，HMAC 防篡改）。 */
@Service
public class AttachmentUploadGrantService {

    private static final String HMAC = "HmacSHA256";
    private static final String DOMAIN = "uten-attachment-upload-v1\n";

    private final ObjectMapper objectMapper;
    private final byte[] secret;
    private final Clock clock;

    @Autowired
    public AttachmentUploadGrantService(ObjectMapper objectMapper, CryptoProperties crypto) {
        this(objectMapper, crypto, Clock.systemUTC());
    }

    AttachmentUploadGrantService(ObjectMapper objectMapper, CryptoProperties crypto, Clock clock) {
        this.objectMapper = objectMapper;
        this.clock = clock;
        if (crypto.getHmacKey() == null || crypto.getHmacKey().isBlank()) {
            throw new IllegalStateException("缺少 UTEN_HMAC_KEY，无法签发附件上传授权");
        }
        this.secret = crypto.getHmacKey().getBytes(StandardCharsets.UTF_8);
    }

    public String issue(Grant grant) {
        try {
            byte[] payload = objectMapper.writeValueAsBytes(grant);
            return encode(payload) + "." + encode(sign(payload));
        } catch (JsonProcessingException e) {
            throw new IllegalStateException("无法生成附件上传授权", e);
        }
    }

    public Grant verify(String token) {
        Grant grant = verifySigned(token);
        requireUnexpired(grant);
        return grant;
    }

    /** Validates authenticity but lets confirm inspect an already-persisted binding after expiry. */
    public Grant verifySigned(String token) {
        try {
            if (token == null || token.isBlank()) {
                throw invalid();
            }
            String[] parts = token.split("\\.", -1);
            if (parts.length != 2) {
                throw invalid();
            }
            byte[] payload = Base64.getUrlDecoder().decode(parts[0]);
            byte[] supplied = Base64.getUrlDecoder().decode(parts[1]);
            // The JDK decoder accepts non-zero unused bits in an unpadded
            // Base64URL tail. Reject alternate textual encodings of the same
            // signed bytes so an upload grant has one canonical identity.
            if (!encode(payload).equals(parts[0]) || !encode(supplied).equals(parts[1])) {
                throw invalid();
            }
            if (!MessageDigest.isEqual(sign(payload), supplied)) {
                throw invalid();
            }
            return objectMapper.readValue(payload, Grant.class);
        } catch (ApiException e) {
            throw e;
        } catch (Exception e) {
            throw invalid();
        }
    }

    public void requireUnexpired(Grant grant) {
        if (grant.expiresAt() == null || !grant.expiresAt().isAfter(clock.instant())) {
            throw new ApiException(ErrorCode.CONFLICT, "附件上传授权已过期，请重新上传");
        }
    }

    /**
     * PostgreSQL {@code TIMESTAMPTZ} persists microseconds and rounds finer input.
     * Canonicalize before both signing and persistence so the token, response and
     * durable reservation carry one byte-for-byte expiry value.
     */
    static Instant canonicalExpiry(Instant expiresAt) {
        if (expiresAt == null) {
            throw new IllegalArgumentException("Attachment upload expiry is required");
        }
        return expiresAt.truncatedTo(ChronoUnit.MICROS);
    }

    private byte[] sign(byte[] payload) {
        try {
            Mac mac = Mac.getInstance(HMAC);
            mac.init(new SecretKeySpec(secret, HMAC));
            mac.update(DOMAIN.getBytes(StandardCharsets.UTF_8));
            return mac.doFinal(payload);
        } catch (Exception e) {
            throw new IllegalStateException("无法校验附件上传授权", e);
        }
    }

    private static String encode(byte[] value) {
        return Base64.getUrlEncoder().withoutPadding().encodeToString(value);
    }

    private static ApiException invalid() {
        return new ApiException(ErrorCode.FORBIDDEN, "附件上传授权无效，请重新上传");
    }

    public record Grant(
            String storageKey,
            String ownerType,
            UUID ownerId,
            UUID userId,
            String originalName,
            String contentType,
            long sizeBytes,
            Instant expiresAt) {
    }
}
