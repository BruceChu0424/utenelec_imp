package com.uten.imp.common.util;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.Base64;

/** 哈希工具。 */
public final class HashUtil {

    private HashUtil() {}

    /**
     * SHA-256 → Base64。
     * 注意：存量 refresh_tokens / visitor_sms_codes 里的哈希即此格式，
     * 不得改编码（如改 hex），否则存量令牌与未消费验证码全部失效。
     */
    public static String sha256(String raw) {
        try {
            MessageDigest md = MessageDigest.getInstance("SHA-256");
            byte[] h = md.digest(raw.getBytes(StandardCharsets.UTF_8));
            return Base64.getEncoder().encodeToString(h);
        } catch (Exception e) {
            throw new IllegalStateException(e);
        }
    }
}
