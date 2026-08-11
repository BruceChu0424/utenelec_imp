package com.uten.imp.features.admin.impersonation.dto;

import com.uten.imp.features.auth.dto.TokenResponse;

/** start 成功返回：目标 token（前端以目标身份发请求）+ 模拟元数据。 */
public record ImpersonationStartResponse(
        TokenResponse token,
        ImpersonationMeta meta) {
}
