package com.uten.imp.features.admin.systemsetting;

import com.uten.imp.config.props.StorageProperties;
import lombok.RequiredArgsConstructor;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

/**
 * 公共运行时设置 (仅需登录, 非超管): 下发前端运行需要的非敏感值。
 *
 * <p>只下发 {@link SystemSettingKey#isPublic()} 为 true 的登记项, 外加部署配置里的附件大小上限
 * (它属于部署配置, 不入库)。前端的校验提示与轮询间隔一律以这里的值为准, 不再各自写死。
 */
@RestController
@RequestMapping("/api/settings")
@RequiredArgsConstructor
public class PublicSettingsController {

    private final SystemSettingsService settings;
    private final StorageProperties storage;

    @GetMapping("/public")
    public PublicSettings publicSettings() {
        return new PublicSettings(
                settings.readInt(SystemSettingKey.SESSION_IDLE_TIMEOUT_MINUTES),
                settings.readInt(SystemSettingKey.AUDIT_HOT_RETENTION_MONTHS)
                        + settings.readInt(SystemSettingKey.AUDIT_ARCHIVE_RETENTION_MONTHS),
                settings.readInt(SystemSettingKey.PASSWORD_MIN_LENGTH),
                storage.getMaxBytes(),
                settings.readInt(SystemSettingKey.BADGE_POLL_SECONDS));
    }

    /** 前端运行时需要的公共设置 (非敏感)。 */
    public record PublicSettings(
            int idleTimeoutMinutes,
            int auditReceiptRetentionMonths,
            int passwordMinLength,
            long attachmentMaxBytes,
            int badgePollSeconds) {}
}
