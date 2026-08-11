package com.uten.imp.common.util;

import com.uten.imp.common.time.BusinessTime;

import java.text.Normalizer;
import java.time.LocalDate;
import java.time.DateTimeException;
import java.time.format.DateTimeFormatter;
import java.util.Locale;

/** 中国居民身份证（18 位，GB11643-1999）：校验、反推生日/性别、脱敏。 */
public final class IdCardUtil {

    private static final int[] W = {7, 9, 10, 5, 8, 4, 2, 1, 6, 3, 7, 9, 10, 5, 8, 4, 2};
    private static final char[] CHECK = {'1', '0', 'X', '9', '8', '7', '6', '5', '4', '3', '2'};

    private IdCardUtil() {}

    public static boolean isValid(String id) {
        String normalized = normalize(id);
        if (normalized == null || normalized.length() != 18) {
            return false;
        }
        if ("000000".contentEquals(normalized.subSequence(0, 6))
                || "000".contentEquals(normalized.subSequence(14, 17))) {
            return false;
        }
        int sum = 0;
        for (int i = 0; i < 17; i++) {
            char c = normalized.charAt(i);
            if (c < '0' || c > '9') {
                return false;
            }
            sum += (c - '0') * W[i];
        }
        char expected = CHECK[sum % 11];
        if (expected != normalized.charAt(17)) {
            return false;
        }
        try {
            LocalDate birthDate = parseBirthDate(normalized);
            return birthDate.getYear() >= 1800
                    && !birthDate.isAfter(BusinessTime.today());
        } catch (DateTimeException ignored) {
            return false;
        }
    }

    public static LocalDate birthDate(String id) {
        String normalized = normalize(id);
        if (!isValid(normalized)) {
            throw new IllegalArgumentException("身份证号校验未通过");
        }
        return parseBirthDate(normalized);
    }

    /** 第 17 位奇数=男，偶数=女。 */
    public static String gender(String id) {
        String normalized = normalize(id);
        if (!isValid(normalized)) {
            throw new IllegalArgumentException("身份证号校验未通过");
        }
        int seq = normalized.charAt(16) - '0';
        return (seq % 2 == 1) ? "male" : "female";
    }

    /** 去除首尾空白、兼容全角数字，并将校验位统一为大写 X。 */
    public static String normalize(String id) {
        if (id == null) {
            return null;
        }
        String normalized = Normalizer.normalize(id, Normalizer.Form.NFKC)
                .strip()
                .toUpperCase(Locale.ROOT);
        return normalized.isEmpty() ? null : normalized;
    }

    public static String last4(String id) {
        return Strings.last4(id);
    }

    public static String mask(String id) {
        return id == null || id.length() < 4 ? null : "****" + id.substring(id.length() - 4);
    }

    private static LocalDate parseBirthDate(String normalized) {
        return LocalDate.parse(normalized.substring(6, 14), DateTimeFormatter.BASIC_ISO_DATE);
    }
}
