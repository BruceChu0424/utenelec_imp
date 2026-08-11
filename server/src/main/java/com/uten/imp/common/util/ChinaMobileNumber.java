package com.uten.imp.common.util;

import java.text.Normalizer;
import java.util.Optional;
import java.util.regex.Pattern;

/**
 * 中国大陆手机号的统一输入规范。
 *
 * <p>接受本地 11 位号码，以及常见的 {@code +86}/{@code 0086}/{@code 86} 前缀和空格、
 * 连字符、括号；输出始终为 11 位 ASCII 数字。不会像“删除所有非数字”那样把夹带字母
 * 的输入悄悄修正为另一个有效号码。
 */
public final class ChinaMobileNumber {

    private static final Pattern ALLOWED_INPUT =
            Pattern.compile("[0-9+()\\-\\s]+");
    private static final Pattern MAINLAND_MOBILE =
            Pattern.compile("1[3-9][0-9]{9}");

    private ChinaMobileNumber() {}

    public static Optional<String> normalize(String raw) {
        if (raw == null) {
            return Optional.empty();
        }
        String value = Normalizer.normalize(raw, Normalizer.Form.NFKC).strip();
        if (value.isEmpty() || !ALLOWED_INPUT.matcher(value).matches()) {
            return Optional.empty();
        }

        value = value.replaceAll("[()\\-\\s]", "");
        if (value.startsWith("+86")) {
            value = value.substring(3);
        } else if (value.startsWith("0086")) {
            value = value.substring(4);
        } else if (value.startsWith("86") && value.length() == 13) {
            value = value.substring(2);
        }

        return MAINLAND_MOBILE.matcher(value).matches()
                ? Optional.of(value)
                : Optional.empty();
    }

    /** 只暴露尾四位，供短信网关运行日志定位；不记录完整手机号。 */
    public static String maskedSuffix(String canonicalPhone) {
        if (canonicalPhone == null || canonicalPhone.length() < 4) {
            return "****";
        }
        return "****" + canonicalPhone.substring(canonicalPhone.length() - 4);
    }
}
