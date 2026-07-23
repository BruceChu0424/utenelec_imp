package com.uten.imp.security;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import org.springframework.stereotype.Component;

import java.util.regex.Pattern;

/** 密码复杂度策略：≥8 位 + 含字母 + 含数字 + 不与登录账号相同。 */
@Component
public class PasswordPolicy {

    private static final Pattern LETTER = Pattern.compile(".*[A-Za-z].*");
    private static final Pattern DIGIT = Pattern.compile(".*\\d.*");

    public void validate(String newPassword, String loginAccount) {
        if (newPassword == null || newPassword.length() < 8) {
            throw new ApiException(ErrorCode.PASSWORD_TOO_WEAK, "密码至少 8 位");
        }
        if (newPassword.length() > 128) {
            // 长度上限：防 Argon2 CPU DoS
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
