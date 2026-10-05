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
        return check(id) == null;
    }

    /**
     * 唯一的身份证号判定规则：合格返回 null，否则返回第一处具体问题。
     *
     * <p>按固定顺序逐项检查 (空 → 长度 → 第1-17位数字 → 第18位 → 出生日期 → 地区码
     * → 顺序码 → 校验码)，只报第一处，说明里只写位置和长度，不带号码本身。
     * Flutter 端 {@code IdCardUtils.problemOf} 按同一顺序给出同样的文字。
     */
    public static IdCardProblem check(String raw) {
        String normalized = normalize(raw);
        if (normalized == null) {
            return IdCardProblem.empty();
        }
        int[] chars = normalized.codePoints().toArray();
        if (chars.length != 18) {
            return IdCardProblem.length(chars.length);
        }
        for (int i = 0; i < 17; i++) {
            if (!isAsciiDigit(chars[i])) {
                return IdCardProblem.character(i + 1);
            }
        }
        if (!isAsciiDigit(chars[17]) && chars[17] != 'X') {
            return IdCardProblem.character(18);
        }
        // 到这里 18 位全是 ASCII，按 char 下标取子串是安全的。
        LocalDate birthDate;
        try {
            birthDate = parseBirthDate(normalized);
        } catch (DateTimeException ignored) {
            return IdCardProblem.birthDate();
        }
        if (birthDate.getYear() < 1800) {
            return IdCardProblem.birthTooEarly();
        }
        if (birthDate.isAfter(BusinessTime.today())) {
            return IdCardProblem.birthFuture();
        }
        if ("000000".contentEquals(normalized.subSequence(0, 6))) {
            return IdCardProblem.regionCode();
        }
        if ("000".contentEquals(normalized.subSequence(14, 17))) {
            return IdCardProblem.sequenceCode();
        }
        int sum = 0;
        for (int i = 0; i < 17; i++) {
            sum += (normalized.charAt(i) - '0') * W[i];
        }
        if (CHECK[sum % 11] != normalized.charAt(17)) {
            return IdCardProblem.checkDigit();
        }
        return null;
    }

    public static LocalDate birthDate(String id) {
        String normalized = normalize(id);
        requireValid(normalized);
        return parseBirthDate(normalized);
    }

    /** 第 17 位奇数=男，偶数=女。 */
    public static String gender(String id) {
        String normalized = normalize(id);
        requireValid(normalized);
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

    private static void requireValid(String normalized) {
        IdCardProblem problem = check(normalized);
        if (problem != null) {
            throw new IllegalArgumentException(problem.message());
        }
    }

    private static boolean isAsciiDigit(int codePoint) {
        return codePoint >= '0' && codePoint <= '9';
    }

    private static LocalDate parseBirthDate(String normalized) {
        return LocalDate.parse(normalized.substring(6, 14), DateTimeFormatter.BASIC_ISO_DATE);
    }
}
