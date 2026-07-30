package com.uten.imp.common.util;

/** 字符串小工具（合并各 Service 里的私有重复实现）。 */
public final class Strings {

    private Strings() {}

    public static boolean isBlank(String s) {
        return s == null || s.isBlank();
    }

    /** 手机号脱敏：138****5678；null 或过短原样返回。 */
    public static String maskPhone(String phone) {
        if (phone == null || phone.length() < 7) return phone;
        return phone.substring(0, 3) + "****" + phone.substring(phone.length() - 4);
    }

    /** 取后 4 位；null 或不足 4 位返回 null。 */
    public static String last4(String s) {
        return (s == null || s.length() < 4) ? null : s.substring(s.length() - 4);
    }
}
