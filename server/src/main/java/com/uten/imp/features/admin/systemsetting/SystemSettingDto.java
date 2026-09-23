package com.uten.imp.features.admin.systemsetting;

import java.time.OffsetDateTime;
import java.util.List;
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
 * @param category    分组: security / token / sms / business / audit
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
        String defaultValue) {

    static SystemSettingDto of(SystemSettingKey key, SystemSetting row) {
        return new SystemSettingDto(
                key.key(), row.getValue(), key.type().wire(), key.category().wire(),
                key.label(), key.description(), key.unit(), key.sortOrder(), row.getUpdatedAt(),
                key.min(), key.max(), key.defaultValue());
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
