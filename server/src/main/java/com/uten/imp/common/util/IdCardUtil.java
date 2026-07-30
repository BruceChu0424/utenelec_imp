package com.uten.imp.common.util;

import java.time.LocalDate;
import java.time.format.DateTimeFormatter;

/** 中国居民身份证（18 位，GB11643-1999）：校验、反推生日/性别、取后六位、脱敏。 */
public final class IdCardUtil {

    private static final int[] W = {7, 9, 10, 5, 8, 4, 2, 1, 6, 3, 7, 9, 10, 5, 8, 4, 2};
    private static final char[] CHECK = {'1', '0', 'X', '9', '8', '7', '6', '5', '4', '3', '2'};

    private IdCardUtil() {}

    public static boolean isValid(String id) {
        if (id == null || id.length() != 18) {
            return false;
        }
        int sum = 0;
        for (int i = 0; i < 17; i++) {
            char c = id.charAt(i);
            if (!Character.isDigit(c)) {
                return false;
            }
            sum += (c - '0') * W[i];
        }
        char expected = CHECK[sum % 11];
        char actual = Character.toUpperCase(id.charAt(17));
        return expected == actual;
    }

    public static LocalDate birthDate(String id) {
        return LocalDate.parse(id.substring(6, 14), DateTimeFormatter.BASIC_ISO_DATE);
    }

    /** 第 17 位奇数=男，偶数=女。 */
    public static String gender(String id) {
        int seq = id.charAt(16) - '0';
        return (seq % 2 == 1) ? "male" : "female";
    }

    /** 身份证后六位（用于派生初始密码，仅在内存中处理，绝不落库）。 */
    public static String last6(String id) {
        return id.substring(12);
    }

    public static String last4(String id) {
        return Strings.last4(id);
    }

    public static String mask(String id) {
        return id == null || id.length() < 4 ? null : "****" + id.substring(id.length() - 4);
    }
}
