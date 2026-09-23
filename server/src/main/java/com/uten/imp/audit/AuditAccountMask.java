package com.uten.imp.audit;

import java.util.Set;
import java.util.regex.Pattern;

/**
 * 审计里的操作人账号只存脱敏展示值(ADR-105, security-10)。
 *
 * <p>登录账号就是手机号, 审计沿用账号当可读操作人会把完整手机号铺满审计表。人员由
 * {@code actor_id} 关联、界面按 id 解析姓名, 账号列只需要「保留后 4 位」的核对线索。
 * 与数据库函数 {@code fn_audit_mask_account} 同一口径。
 *
 * <p>未通过认证的输入(登录失败时用户敲进账号框的原文, 常见误把密码敲进去)不是可信账号:
 * 只有看起来像号码时才保留脱敏值, 其余一律不落库; 系统任务标识原样保留。
 */
public final class AuditAccountMask {

    private static final Pattern NUMBER_LIKE = Pattern.compile("^\\+?[0-9*][0-9* -]{5,}[0-9]$");
    private static final Set<String> SYSTEM_ACCOUNTS = Set.of("system", "ops");

    private AuditAccountMask() {
    }

    /** 已通过认证的账号: 号码类只保留后 4 位, 其余原样(系统任务名、非号码账号)。 */
    public static String mask(String account) {
        if (account == null || account.isBlank()) {
            return null;
        }
        String trimmed = account.trim();
        if (!looksLikeNumber(trimmed)) {
            return account;
        }
        return "*".repeat(Math.max(trimmed.length() - 4, 3)) + trimmed.substring(trimmed.length() - 4);
    }

    /**
     * 写入审计前的最终口径: 有已验证操作人时按账号脱敏; 没有时(登录失败等)账号只是
     * 用户输入, 号码类脱敏保留, 非号码的原文丢弃, 系统任务标识保留。
     */
    static String forStorage(boolean verifiedActor, String account) {
        if (account == null || account.isBlank()) {
            return null;
        }
        String trimmed = account.trim();
        if (verifiedActor || looksLikeNumber(trimmed) || isSystemAccount(trimmed)) {
            return mask(account);
        }
        return null;
    }

    static boolean isSystemAccount(String account) {
        String value = account.trim().toLowerCase(java.util.Locale.ROOT);
        return SYSTEM_ACCOUNTS.contains(value) || value.startsWith("ops:") || value.startsWith("系统");
    }

    private static boolean looksLikeNumber(String value) {
        if (!NUMBER_LIKE.matcher(value).matches()) {
            return false;
        }
        int digits = 0;
        for (int index = 0; index < value.length(); index++) {
            if (Character.isDigit(value.charAt(index))) {
                digits++;
            }
        }
        return digits >= 4;
    }
}
