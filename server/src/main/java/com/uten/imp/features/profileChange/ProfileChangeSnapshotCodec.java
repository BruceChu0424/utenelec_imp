package com.uten.imp.features.profilechange;

import com.uten.imp.security.TxSessionVars;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;

import java.util.Base64;
import java.util.UUID;
import java.util.regex.Pattern;

/**
 * Canonical protection boundary for values persisted in
 * {@code profile_change_requests.old_value_enc/new_value_enc}.
 *
 * <p>The encrypted payload carries its own inner format marker.  The outer
 * {@link TxSessionVars} version prefix selects the PGP key; the inner marker
 * prevents a valid ciphertext from another domain from being accepted as a
 * profile-change snapshot.</p>
 */
@Component
@RequiredArgsConstructor
public class ProfileChangeSnapshotCodec {

    public static final String ENCODING_PLAIN = "PLAIN";
    public static final String ENCODING_PGCRYPTO_V1 = "PGCRYPTO_V1";
    public static final String ENCODING_LEGACY_UNKNOWN = "LEGACY_UNKNOWN";

    static final String PAYLOAD_PREFIX = "uten-profile-change-snapshot:v1:";
    private static final Pattern CIPHER_VERSION =
            Pattern.compile("[A-Za-z0-9._-]{1,64}");
    private static final Pattern BASE64_BODY =
            Pattern.compile("[A-Za-z0-9+/]+={0,2}");

    private final TxSessionVars tx;

    /** Bind the V284 transaction-local write capability before persistence. */
    public void bindWriteCapability() {
        tx.bindProfileChangeSnapshotCodecV1();
    }

    public String encodingFor(String fieldCode) {
        return ProfileFieldPolicy.requiresEncryptedSnapshot(fieldCode)
                ? ENCODING_PGCRYPTO_V1
                : ENCODING_PLAIN;
    }

    /** Encode a nullable snapshot using the field's authoritative policy. */
    public String encode(String fieldCode, String plain) {
        if (plain == null) {
            return null;
        }
        if (!ProfileFieldPolicy.requiresEncryptedSnapshot(fieldCode)) {
            return plain;
        }
        return encryptPayload(plain);
    }

    /**
     * Decode only when the persisted state matches the field policy.
     * LEGACY_UNKNOWN and cross-domain/corrupt ciphertext fail closed.
     */
    public String decode(String fieldCode, String encoding, String stored) {
        boolean encrypted = ProfileFieldPolicy.requiresEncryptedSnapshot(fieldCode);
        if (encrypted) {
            requireEncoding(fieldCode, encoding, ENCODING_PGCRYPTO_V1);
            return stored == null ? null : decryptCanonicalPayload(fieldCode, stored);
        }
        requireEncoding(fieldCode, encoding, ENCODING_PLAIN);
        return stored;
    }

    /**
     * Convert one historical sensitive value to the canonical payload.
     *
     * <p>A value without either a plausible version prefix or an unversioned
     * OpenPGP packet header is safely identifiable as the legacy plaintext
     * written by the old service.  A plausible cipher is first decrypted:
     * success preserves/re-wraps the value, while any unknown key, corruption
     * or ambiguity aborts startup.  This also covers the unversioned pgcrypto
     * format still supported by {@link TxSessionVars#decrypt(String)}.</p>
     */
    public String canonicalizeLegacySensitive(
            UUID rowId,
            String fieldCode,
            String slot,
            String stored) {
        if (!ProfileFieldPolicy.requiresEncryptedSnapshot(fieldCode)) {
            throw new IllegalStateException(
                    "legacy snapshot classification disagrees with field policy for row "
                            + rowId + " field " + fieldCode);
        }
        if (stored == null) {
            return null;
        }
        if (!looksLikeVersionedCipher(stored)
                && !looksLikeUnversionedPgcryptoCipher(stored)) {
            return encryptPayload(stored);
        }

        final String decrypted;
        try {
            decrypted = tx.decrypt(stored);
        } catch (RuntimeException exception) {
            throw new IllegalStateException(
                    "ambiguous or unreadable legacy profile-change " + slot
                            + " snapshot for row " + rowId + " field " + fieldCode,
                    exception);
        }
        if (decrypted == null) {
            throw new IllegalStateException(
                    "legacy profile-change " + slot + " snapshot decrypted to null for row "
                            + rowId + " field " + fieldCode);
        }
        if (decrypted.startsWith(PAYLOAD_PREFIX)) {
            return stored;
        }
        return encryptPayload(decrypted);
    }

    static boolean looksLikeVersionedCipher(String value) {
        if (value == null) {
            return false;
        }
        int separator = value.indexOf(':');
        return separator > 0
                && separator < value.length() - 1
                && CIPHER_VERSION.matcher(value.substring(0, separator)).matches();
    }

    /**
     * Detect the legacy raw-base64 pgcrypto shape without decrypting it.
     * pgp_sym_encrypt starts with an OpenPGP symmetric-key encrypted session-key
     * packet (tag 3), in either old or new packet-header format.
     */
    static boolean looksLikeUnversionedPgcryptoCipher(String value) {
        if (value == null) {
            return false;
        }
        String body = value.replaceAll("\\s", "");
        if (body.length() < 8 || body.length() % 4 != 0
                || !BASE64_BODY.matcher(body).matches()) {
            return false;
        }
        final byte[] decoded;
        try {
            decoded = Base64.getDecoder().decode(body);
        } catch (IllegalArgumentException exception) {
            return false;
        }
        if (decoded.length == 0) {
            return false;
        }
        int first = Byte.toUnsignedInt(decoded[0]);
        if ((first & 0x80) == 0) {
            return false;
        }
        boolean newPacketFormat = (first & 0x40) != 0;
        int packetTag = newPacketFormat ? first & 0x3f : (first >>> 2) & 0x0f;
        return packetTag == 3;
    }

    private String encryptPayload(String plain) {
        String cipher = tx.encrypt(PAYLOAD_PREFIX + plain);
        if (cipher == null || cipher.isBlank()) {
            throw new IllegalStateException("profile-change snapshot encryption returned no ciphertext");
        }
        return cipher;
    }

    private String decryptCanonicalPayload(String fieldCode, String cipher) {
        final String payload;
        try {
            payload = tx.decrypt(cipher);
        } catch (RuntimeException exception) {
            throw new IllegalStateException(
                    "profile-change snapshot cannot be decrypted for field " + fieldCode,
                    exception);
        }
        if (payload == null || !payload.startsWith(PAYLOAD_PREFIX)) {
            throw new IllegalStateException(
                    "profile-change snapshot payload domain is invalid for field " + fieldCode);
        }
        return payload.substring(PAYLOAD_PREFIX.length());
    }

    private static void requireEncoding(
            String fieldCode,
            String actual,
            String expected) {
        if (!expected.equals(actual)) {
            throw new IllegalStateException(
                    "profile-change snapshot encoding " + actual
                            + " is invalid for field " + fieldCode
                            + "; expected " + expected);
        }
    }
}
