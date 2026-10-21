package com.uten.imp.features.admin.systemsetting;

import java.time.OffsetDateTime;
import java.util.List;
import java.util.Map;
import jakarta.validation.Valid;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Size;

/**
 * 系统设置列表项 (管理端读写视图)。元数据来自 {@link SystemSettingKey}, 当前值来自数据库。
 *
 * @param key         设置键 (如 lockout_minutes)
 * @param value       当前值 (字符串, 前端按 valueType 校验/转换)
 * @param valueType   值类型: int / long / string / bool
 * @param category    分组: security / token / sms / business / audit / updates
 * @param label       中文显示名
 * @param description 说明 (界面提示)
 * @param unit        单位 (次/分、分钟、天、秒、行…)
 * @param sortOrder   分组内排序
 * @param updatedAt   最后修改时间 (DB 触发器维护)
 * @param minValue    数值项允许的最小值; 非数值项为 null
 * @param maxValue    数值项允许的最大值; 非数值项为 null
 * @param defaultValue 出厂默认值
 */
public record SystemSettingDto(
        String key,
        String value,
        String valueType,
        String category,
        String label,
        String description,
        String unit,
        int sortOrder,
        OffsetDateTime updatedAt,
        Long minValue,
        Long maxValue,
        String defaultValue,
        String effectiveValue,
        String effectiveNote,
        String applyMode,
        boolean editable) {

    static SystemSettingDto of(SystemSettingKey key, SystemSetting row) {
        return of(key, row, Map.of(key.key(), row.getValue()));
    }

    static SystemSettingDto of(SystemSettingKey key, SystemSetting row, Map<String, String> values) {
        boolean editable = key != SystemSettingKey.UPDATER_CHECK_INTERVAL_DAYS;
        String mode = switch (key) {
            case UPDATER_CHECK_INTERVAL_DAYS -> "LEGACY_MANUAL_ONLY";
            case JWT_ACCESS_TTL_MINUTES, JWT_REFRESH_TTL_DAYS, TEMP_PASSWORD_TTL_HOURS,
                    IMPERSONATION_WINDOW_MINUTES, SMS_CODE_TTL_MINUTES -> "NEXT_ISSUANCE";
            case CELEBRATION_AUTO_ENABLED, CELEBRATION_AUTO_TYPES, CELEBRATION_PUBLISHER_NAME,
                    MATERIAL_FORECAST_ENABLED, MATERIAL_FORECAST_INTERVAL_MINUTES, MATERIAL_FORECAST_HISTORY_DAYS, MATERIAL_FORECAST_BACKFILL_BUDGET,
                    AUDIT_HOT_RETENTION_MONTHS, AUDIT_ARCHIVE_RETENTION_MONTHS -> "NEXT_SCHEDULED_RUN";
            default -> "NEXT_REQUEST";
        };
        String note = switch (mode) {
            case "LEGACY_MANUAL_ONLY" -> "旧自动检查间隔仅供历史核对，已停止接受修改；实际手动模式与定时器状态以服务器运维页为准。";
            case "NEXT_ISSUANCE" -> "后续新签发的令牌、会话或凭证使用此值；已经签发的到期时间保持不变。";
            case "NEXT_SCHEDULED_RUN" -> "后续任务执行时读取此值；审计保全模式仍由服务器决定，修改月份不会开启清除。";
            default -> "后续请求或业务判断读取此值；既有锁定与业务记录不会追溯改写。";
        };
        if(key.category()==SystemSettingKey.Category.MATERIAL_MARKET)note="保存配置后由后台监督器应用；以自动采集状态中的配置回执确认，保存成功不代表进程已经运行。";
        return new SystemSettingDto(
                key.key(), row.getValue(), key.type().wire(), key.category().wire(),
                key.label(), key.description(), key.unit(), key.sortOrder(), row.getUpdatedAt(),
                key.min(), key.max(), key.defaultValue(), editable ? effective(key, values) : null,
                note, mode, editable);
    }

    private static String effective(SystemSettingKey key, Map<String, String> values) {
        String raw = values.get(key.key());
        if (key.numeric()) {
            long value = SystemSettingsService.effectiveNumber(key, raw);
            if (key == SystemSettingKey.AUDIT_ARCHIVE_RETENTION_MONTHS) {
                value = Math.max(value, 6 - SystemSettingsService.effectiveNumber(
                        SystemSettingKey.AUDIT_HOT_RETENTION_MONTHS,
                        values.get(SystemSettingKey.AUDIT_HOT_RETENTION_MONTHS.key())));
            } else if (key == SystemSettingKey.LOGIN_IP_RATE_LIMIT_PER_MINUTE) {
                value = Math.max(value, SystemSettingsService.effectiveNumber(
                        SystemSettingKey.LOGIN_RATE_LIMIT_PER_MINUTE,
                        values.get(SystemSettingKey.LOGIN_RATE_LIMIT_PER_MINUTE.key())));
            }
            return Long.toString(value);
        }
        String normalized = raw == null ? null : raw.trim();
        if (normalized == null || SystemSettingsService.validationError(key, normalized) != null
                || (key.type() == SystemSettingKey.Type.STRING && normalized.isBlank())) return key.defaultValue();
        return key.type() == SystemSettingKey.Type.BOOL ? Boolean.toString(Boolean.parseBoolean(normalized)) : normalized;
    }

    /**
     * 一次保存的全部修改。再认证由 {@code @RequiresStepUp} 在控制器入口统一校验,
     * 请求体不再携带密码。
     */
    public record BatchUpdate(
            @NotNull @Size(min = 1, max = 50) List<@NotNull @Valid Change> changes) {}

    public record Change(
            @NotBlank @Size(max = 128) String key,
            @NotNull @Size(max = 1024) String value,
            @NotNull @Size(max = 1024) String expectedValue) {}
}
