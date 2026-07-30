package com.uten.imp.features.admin.systemsetting;

import lombok.RequiredArgsConstructor;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

/**
 * 公共运行时设置（仅需登录，非超管）：返回前端需要的、非敏感的全局运行时配置。
 *
 * <p>与 {@link SystemSettingController}（超管 authorization:manage 读写全部）区别：本端点对**所有登录用户**
 * 开放只读，只暴露前端运行所需的少量项（如会话空闲超时阈值），不暴露管理类设置。
 *
 * <p>路径 {@code /api/settings/public} 不在 {@code /api/admin/} 下，故不要求 authorization:manage；
 * Spring Security 默认要求已认证（任何登录用户可读）。
 */
@RestController
@RequestMapping("/api/settings")
@RequiredArgsConstructor
public class PublicSettingsController {

    private final SystemSettingsService settings;

    @GetMapping("/public")
    public PublicSettings publicSettings() {
        return new PublicSettings(
                settings.readInt("session_idle_timeout_minutes", 30));
    }

    /** 前端运行时需要的公共设置（非敏感）。后续可按需扩展（如密码最小长度，供前端校验提示）。 */
    public record PublicSettings(int idleTimeoutMinutes) {}
}
