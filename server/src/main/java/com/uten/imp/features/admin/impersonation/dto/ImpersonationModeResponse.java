package com.uten.imp.features.admin.impersonation.dto;

/** enter 成功返回：modeToken（限时窗口内复用）+ 窗口秒数。 */
public record ImpersonationModeResponse(
        String modeToken,
        long expiresIn) {
}
