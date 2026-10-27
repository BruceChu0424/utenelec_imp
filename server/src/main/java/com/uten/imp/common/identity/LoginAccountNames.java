package com.uten.imp.common.identity;

import java.util.Optional;

/** Canonicalizes new identifiers only; it never rewrites a retained account or login request. */
public final class LoginAccountNames {
    public static final int MAX_LENGTH = 128;

    public static Optional<String> normalizeNew(String raw) {
        if (raw == null || raw.codePoints().anyMatch(c -> Character.isISOControl(c) && !trimSpace(c))) {
            return Optional.empty();
        }
        int start = 0, end = raw.length();
        while (start < end && trimSpace(raw.codePointAt(start))) start += Character.charCount(raw.codePointAt(start));
        while (start < end && trimSpace(raw.codePointBefore(end))) end -= Character.charCount(raw.codePointBefore(end));
        String value = raw.substring(start, end);
        if (value.isEmpty() || value.length() > MAX_LENGTH || value.codePoints().anyMatch(c -> trimSpace(c)
                || Character.isISOControl(c) || Character.getType(c) == Character.FORMAT)) {
            return Optional.empty();
        }
        return Optional.of(value);
    }

    private static boolean trimSpace(int codePoint) {
        // Dart String.trim's Unicode whitespace/BOM boundary, including no-break spaces.
        return codePoint >= 0x09 && codePoint <= 0x0d || codePoint == 0x20 || codePoint == 0x85
                || codePoint == 0xa0 || codePoint == 0x1680 || codePoint >= 0x2000 && codePoint <= 0x200a
                || codePoint == 0x2028 || codePoint == 0x2029 || codePoint == 0x202f || codePoint == 0x205f
                || codePoint == 0x3000 || codePoint == 0xfeff;
    }

    private LoginAccountNames() {}
}
