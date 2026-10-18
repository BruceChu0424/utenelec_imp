package com.uten.imp.features.auth;

import javax.crypto.Mac;
import javax.crypto.spec.SecretKeySpec;
import java.nio.ByteBuffer;
import java.nio.charset.StandardCharsets;
import java.security.GeneralSecurityException;
import java.security.MessageDigest;
import java.security.SecureRandom;
import java.time.Instant;
import java.util.Arrays;
import java.util.Locale;

/** RFC 6238: SHA-1, six digits, 30-second steps; RFC vectors also exercise eight digits. */
final class Totp {
    private static final char[] BASE32 = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567".toCharArray();
    private static final SecureRandom RANDOM = new SecureRandom();
    private Totp() {}

    static String newSecret() {
        byte[] bytes = new byte[20];
        RANDOM.nextBytes(bytes);
        try { return encode(bytes); } finally { Arrays.fill(bytes, (byte) 0); }
    }

    static long matchingStep(String secret, String code, Instant now, Long lastAccepted) {
        if (code == null || !code.matches("[0-9]{6}")) return -1;
        long current = Math.floorDiv(now.getEpochSecond(), 30);
        long match = -1;
        // Evaluate the entire window without early exit. A consumed step never succeeds again.
        for (long step = current - 1; step <= current + 1; step++) {
            if (step < 0) continue;
            boolean same = MessageDigest.isEqual(code.getBytes(StandardCharsets.US_ASCII),
                    code(secret, step, 6).getBytes(StandardCharsets.US_ASCII));
            if (same && (lastAccepted == null || step > lastAccepted)) match = step;
        }
        return match;
    }

    static String code(String secret, long step, int digits) {
        if (step < 0 || (digits != 6 && digits != 8)) throw new IllegalArgumentException("Invalid TOTP parameters");
        byte[] key = decode(secret);
        try {
            Mac mac = Mac.getInstance("HmacSHA1");
            mac.init(new SecretKeySpec(key, "HmacSHA1"));
            byte[] digest = mac.doFinal(ByteBuffer.allocate(Long.BYTES).putLong(step).array());
            int offset = digest[digest.length - 1] & 15;
            int binary = ((digest[offset] & 127) << 24) | ((digest[offset + 1] & 255) << 16)
                    | ((digest[offset + 2] & 255) << 8) | (digest[offset + 3] & 255);
            return String.format(Locale.ROOT, "%0" + digits + "d", binary % (digits == 6 ? 1_000_000 : 100_000_000));
        } catch (GeneralSecurityException impossible) {
            throw new IllegalStateException("TOTP cryptography unavailable", impossible);
        } finally { Arrays.fill(key, (byte) 0); }
    }

    static String encode(byte[] bytes) {
        StringBuilder encoded = new StringBuilder();
        int bits = 0, buffer = 0;
        for (byte value : bytes) {
            buffer = (buffer << 8) | (value & 255);
            bits += 8;
            while (bits >= 5) { bits -= 5; encoded.append(BASE32[(buffer >>> bits) & 31]); }
        }
        if (bits != 0) encoded.append(BASE32[(buffer << (5 - bits)) & 31]);
        return encoded.toString();
    }

    private static byte[] decode(String value) {
        if (value == null || !value.matches("[A-Z2-7]{32}")) throw new IllegalArgumentException("Invalid TOTP secret");
        byte[] bytes = new byte[value.length() * 5 / 8];
        int bits = 0, buffer = 0, index = 0;
        for (char c : value.toCharArray()) {
            int digit = c >= 'A' && c <= 'Z' ? c - 'A' : c - '2' + 26;
            buffer = (buffer << 5) | digit;
            bits += 5;
            if (bits >= 8) { bits -= 8; bytes[index++] = (byte) (buffer >>> bits); }
        }
        return bytes;
    }
}
