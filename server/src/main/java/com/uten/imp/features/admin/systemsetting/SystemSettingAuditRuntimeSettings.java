package com.uten.imp.features.admin.systemsetting;

import com.uten.imp.application.port.ExportLimitPort;
import com.uten.imp.audit.AuditRuntimeSettings;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;

/**
 * Bridges database-backed system settings into the audit foundation and the
 * shared export limit port.
 *
 * <p>Values are deliberately read on every call. Changing a setting therefore
 * affects the next export without restarting the server. 审计保留期由数据库留存函数
 * 直接读取系统设置(ADR-105), 不经过这里。
 */
@Component
@RequiredArgsConstructor
public class SystemSettingAuditRuntimeSettings implements AuditRuntimeSettings, ExportLimitPort {

    private final SystemSettingsService settings;

    @Override
    public int exportMaxRows() {
        return settings.readInt(SystemSettingKey.EXPORT_MAX_ROWS);
    }
}
