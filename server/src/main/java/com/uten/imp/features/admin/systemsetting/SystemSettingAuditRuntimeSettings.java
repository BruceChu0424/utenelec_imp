package com.uten.imp.features.admin.systemsetting;

import com.uten.imp.audit.AuditRuntimeSettings;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;

/**
 * Bridges database-backed system settings into the audit foundation.
 *
 * <p>Values are deliberately read on every call. Changing a setting therefore
 * affects the next export or retention cycle without restarting the server.
 */
@Component
@RequiredArgsConstructor
public class SystemSettingAuditRuntimeSettings implements AuditRuntimeSettings {

    private final SystemSettingsService settings;

    @Override
    public int exportMaxRows() {
        return settings.readInt("export_max_rows", 100_000);
    }

    @Override
    public int hotRetentionMonths() {
        return settings.readInt("audit_hot_retention_months", 6);
    }

    @Override
    public int archiveRetentionMonths() {
        return settings.readInt("audit_archive_retention_months", 30);
    }
}
