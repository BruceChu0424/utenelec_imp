package com.uten.imp.security;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.admin.systemsetting.SystemSettingKey;
import com.uten.imp.features.admin.systemsetting.SystemSettingsService;
import org.springframework.stereotype.Component;

import java.util.regex.Pattern;

/**
 * 密码复杂度策略：≥「密码最短长度」位 (系统设置 password_min_length, 下限 8) + 含字母 + 含数字
 * + 不与登录账号相同。前端提示与校验用 /api/settings/public 下发的同一个值。
 */
@Component
public class PasswordPolicy {

    /** 长度上限：防 Argon2 CPU DoS。 */
    static final int MAX_LENGTH = 128;

    private static final Pattern LETTER = Pattern.compile(".*[A-Za-z].*");
    private static final Pattern DIGIT = Pattern.compile(".*\\d.*");

    private final SystemSettingsService settings;

    public PasswordPolicy(SystemSettingsService settings) {
        this.settings = settings;
    }

    public void validate(String newPassword, String loginAccount) {
        int minLength = settings.readInt(SystemSettingKey.PASSWORD_MIN_LENGTH);
        if (newPassword == null || newPassword.length() < minLength) {
            throw new ApiException(ErrorCode.PASSWORD_TOO_WEAK, "密码至少 " + minLength + " 位");
        }
        if (newPassword.length() > MAX_LENGTH) {
            throw new ApiException(ErrorCode.PASSWORD_TOO_WEAK, "密码过长");
        }
        if (!LETTER.matcher(newPassword).matches() || !DIGIT.matcher(newPassword).matches()) {
            throw new ApiException(ErrorCode.PASSWORD_TOO_WEAK, "密码需同时包含字母和数字");
        }
        if (loginAccount != null && newPassword.equals(loginAccount)) {
            throw new ApiException(ErrorCode.PASSWORD_TOO_WEAK, "密码不能与登录账号相同");
        }
    }
}
