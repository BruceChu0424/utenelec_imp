package com.uten.imp.features.visitor.dto;

import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.Pattern;
import jakarta.validation.constraints.Size;

import java.util.UUID;

/** 访客鉴权相关 DTO（发送验证码 / 登录 / 刷新）。 */
public final class VisitorAuthDto {
    private VisitorAuthDto() {}

    public record SendCodeRequest(
            @NotBlank(message = "手机号不能为空")
            @Size(max = 32, message = "手机号过长")
            @Pattern(
                    regexp = "^[+＋0-9０-９()()\\-－\\s]+$",
                    message = "手机号格式不正确")
            String phone) {}

    public record VisitorLoginRequest(
            @NotBlank(message = "手机号不能为空")
            @Size(max = 32, message = "手机号过长")
            @Pattern(
                    regexp = "^[+＋0-9０-９()()\\-－\\s]+$",
                    message = "手机号格式不正确")
            String phone,
            @NotBlank(message = "验证码不能为空")
            @Pattern(regexp = "^\\d{6}$", message = "验证码必须为6位数字")
            String code) {}

    public record VisitorRefreshRequest(
            @NotBlank(message = "刷新令牌不能为空")
            @Size(max = 512, message = "刷新令牌过长")
            String refreshToken) {}

    /** send-code 响应；devCode 仅开发期（log 网关）返回，便于联调。 */
    public record SendCodeResponse(String scene, int expiresInSeconds, String devCode) {}

    public record VisitorTokenResponse(
            String accessToken, String refreshToken,
            UUID visitorId, String visitorNo, String name, String avatarSeed) {}
}
