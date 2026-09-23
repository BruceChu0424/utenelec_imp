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
 * affects the next export or retention cycle without restarting the server.
 */
@Component
@RequiredArgsConstructor
public class SystemSettingAuditRuntimeSettings implements AuditRuntimeSettings, ExportLimitPort {

    private final SystemSettingsService settings;

    @Override
    public int exportMaxRows() {
        return settings.readInt(SystemSettingKey.EXPORT_MAX_ROWS);
    }

    @Override
    public int hotRetentionMonths() {
        return settings.readInt(SystemSettingKey.AUDIT_HOT_RETENTION_MONTHS);
    }

    @Override
    public int archiveRetentionMonths() {
        return settings.readInt(SystemSettingKey.AUDIT_ARCHIVE_RETENTION_MONTHS);
    }
}
