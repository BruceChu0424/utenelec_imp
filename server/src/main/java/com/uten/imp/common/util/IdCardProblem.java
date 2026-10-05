package com.uten.imp.common.util;

/**
 * 身份证号具体哪里不对：{@code code} 是稳定的机器码 (可以存库、可以对比)，
 * {@code message} 是给人看的说明。说明只写位置和长度，绝不带号码本身。
 *
 * <p>同一个 code 永远对应同一句说明：{@link #fromCode(String)} 能从存下来的 code
 * 原样还原说明，所以库里只存 code，界面上的文字仍和录入时当场看到的一致。
 */
public record IdCardProblem(String code, String message) {

    public static final String EMPTY = "empty";
    public static final String LENGTH_PREFIX = "length:";
    public static final String CHARACTER_PREFIX = "character:";
    public static final String BIRTH_DATE = "birth_date";
    public static final String BIRTH_TOO_EARLY = "birth_too_early";
    public static final String BIRTH_FUTURE = "birth_future";
    public static final String REGION_CODE = "region_code";
    public static final String SEQUENCE_CODE = "sequence_code";
    public static final String CHECK_DIGIT = "check_digit";

    static IdCardProblem empty() {
        return new IdCardProblem(EMPTY, "身份证号不能为空");
    }

    static IdCardProblem length(int actual) {
        return new IdCardProblem(LENGTH_PREFIX + actual, "身份证号应为18位，当前为" + actual + "位");
    }

    static IdCardProblem character(int position) {
        return new IdCardProblem(CHARACTER_PREFIX + position, position == 18
                ? "身份证号第18位只能是数字或X"
                : "身份证号第" + position + "位不是数字(只有第18位可以是X)");
    }

    static IdCardProblem birthDate() {
        return new IdCardProblem(BIRTH_DATE, "身份证号第7-14位不是有效的出生日期");
    }

    static IdCardProblem birthTooEarly() {
        return new IdCardProblem(BIRTH_TOO_EARLY, "身份证号第7-14位的出生日期早于1800年");
    }

    static IdCardProblem birthFuture() {
        return new IdCardProblem(BIRTH_FUTURE, "身份证号第7-14位的出生日期晚于今天");
    }

    static IdCardProblem regionCode() {
        return new IdCardProblem(REGION_CODE, "身份证号前6位地区码不能全为0");
    }

    static IdCardProblem sequenceCode() {
        return new IdCardProblem(SEQUENCE_CODE, "身份证号第15-17位顺序码不能全为0");
    }

    static IdCardProblem checkDigit() {
        return new IdCardProblem(CHECK_DIGIT,
                "身份证号第18位校验码与前17位不符，通常是某一位数字录错或相邻两位颠倒，请对照证件逐位核对");
    }

    /**
     * 按存下来的 code 还原同一句说明；不认识的 code 返回 null (调用方自己决定兜底文案)。
     */
    public static IdCardProblem fromCode(String code) {
        if (code == null) {
            return null;
        }
        switch (code) {
            case EMPTY:
                return empty();
            case BIRTH_DATE:
                return birthDate();
            case BIRTH_TOO_EARLY:
                return birthTooEarly();
            case BIRTH_FUTURE:
                return birthFuture();
            case REGION_CODE:
                return regionCode();
            case SEQUENCE_CODE:
                return sequenceCode();
            case CHECK_DIGIT:
                return checkDigit();
            default:
                break;
        }
        if (code.startsWith(LENGTH_PREFIX)) {
            Integer actual = smallNumber(code.substring(LENGTH_PREFIX.length()), 3);
            return actual == null || actual == 18 ? null : length(actual);
        }
        if (code.startsWith(CHARACTER_PREFIX)) {
            Integer position = smallNumber(code.substring(CHARACTER_PREFIX.length()), 2);
            return position == null || position < 1 || position > 18 ? null : character(position);
        }
        return null;
    }

    /** 只接受 1 到 maxDigits 位的纯 ASCII 数字，其它一律视为不认识。 */
    private static Integer smallNumber(String text, int maxDigits) {
        if (text.isEmpty() || text.length() > maxDigits) {
            return null;
        }
        for (int i = 0; i < text.length(); i++) {
            char c = text.charAt(i);
            if (c < '0' || c > '9') {
                return null;
            }
        }
        return Integer.parseInt(text);
    }
}
