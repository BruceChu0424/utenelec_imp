package com.uten.imp.features.admin.systemsetting;

import java.time.OffsetDateTime;

/**
 * 系统设置列表项（管理端读写视图）。
 *
 * @param key         设置键（如 lockout_minutes）
 * @param value       当前值（字符串，前端按 valueType 校验/转换）
 * @param valueType   值类型：int / long / string / bool
 * @param category    分组：security / token / sms / business
 * @param label       中文显示名
 * @param description 说明（UI 提示）
 * @param unit        单位（次/分、分钟、天、秒、行…）
 * @param sortOrder   分组内排序
 * @param updatedAt   最后修改时间（DB 触发器维护）
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
        OffsetDateTime updatedAt) {

    public static SystemSettingDto of(SystemSetting s) {
        return new SystemSettingDto(
                s.getKey(), s.getValue(), s.getValueType(), s.getCategory(),
                s.getLabel(), s.getDescription(), s.getUnit(), s.getSortOrder(), s.getUpdatedAt());
    }

    /** 写入请求：value + 当前账号密码（二次确认，见 Service）。 */
    public record Update(String value, String password) {}
}
