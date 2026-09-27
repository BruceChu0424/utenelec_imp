package com.uten.imp.security;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import org.springframework.stereotype.Component;

/**
 * 员工密码只要求非空，不限制长度或字符组合；保留原始内容用于哈希和匹配。
 */
@Component
public class PasswordPolicy {

    public void validate(String newPassword) {
        if (newPassword == null || newPassword.isBlank()) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "密码不能为空");
        }
    }
}
