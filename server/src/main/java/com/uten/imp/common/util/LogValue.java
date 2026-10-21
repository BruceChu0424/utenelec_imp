package com.uten.imp.common.util;

/** Bounded single-line fields for operational logs; authoritative audit values stay in their own journal. */
public final class LogValue {
    private static final int MAX_LENGTH = 512;

    private LogValue() {}

    public static String singleLine(String value) {
        if (value == null) return "-";
        String normalized = value.replaceAll("\\R", "_").replaceAll("[\\p{Cntrl}]", "_");
        return normalized.length() <= MAX_LENGTH ? normalized : normalized.substring(0, MAX_LENGTH);
    }
}
