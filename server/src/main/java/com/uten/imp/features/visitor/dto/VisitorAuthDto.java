package com.uten.imp.features.visitor.dto;

import java.util.UUID;

/** 访客鉴权相关 DTO（发送验证码 / 登录 / 刷新）。 */
public final class VisitorAuthDto {
    private VisitorAuthDto() {}

    public record SendCodeRequest(String phone) {}

    public record VisitorLoginRequest(String phone, String code) {}

    public record VisitorRefreshRequest(String refreshToken) {}

    /** send-code 响应；devCode 仅开发期（log 网关）返回，便于联调。 */
    public record SendCodeResponse(String scene, int expiresInSeconds, String devCode) {}

    public record VisitorTokenResponse(
            String accessToken, String refreshToken,
            UUID visitorId, String visitorNo, String name, String avatarSeed) {}
}
