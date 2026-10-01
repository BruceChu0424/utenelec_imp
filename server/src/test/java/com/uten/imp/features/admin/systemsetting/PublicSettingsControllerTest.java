package com.uten.imp.features.admin.systemsetting;

import com.uten.imp.audit.AuditRetentionModeReader;
import com.uten.imp.config.props.StorageProperties;
import org.junit.jupiter.api.Test;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

class PublicSettingsControllerTest {
    @Test
    void preservationCapabilityIsSeparateFromTheLocalReceiptAndOtherRuntimeLimits() {
        var settings = mock(SystemSettingsService.class);
        var storage = mock(StorageProperties.class);
        var retention = mock(AuditRetentionModeReader.class);
        when(settings.readInt(SystemSettingKey.SESSION_IDLE_TIMEOUT_MINUTES)).thenReturn(20);
        when(settings.readInt(SystemSettingKey.AUDIT_HOT_RETENTION_MONTHS)).thenReturn(6);
        when(settings.readInt(SystemSettingKey.AUDIT_ARCHIVE_RETENTION_MONTHS)).thenReturn(30);
        when(settings.readInt(SystemSettingKey.BADGE_POLL_SECONDS)).thenReturn(90);
        when(storage.getMaxBytes()).thenReturn(10485760L);
        when(retention.currentMode()).thenReturn(AuditRetentionModeReader.PurgeMode.PRESERVE_UNCLASSIFIED,
                AuditRetentionModeReader.PurgeMode.UNKNOWN);
        var controller = new PublicSettingsController(settings, storage, retention);
        var protectedMode = controller.publicSettings();
        assertThat(protectedMode.auditArchivePurgeMode()).isEqualTo(AuditRetentionModeReader.PurgeMode.PRESERVE_UNCLASSIFIED);
        assertThat(protectedMode.auditReceiptRetentionMonths()).isEqualTo(36);
        assertThat(protectedMode.idleTimeoutMinutes()).isEqualTo(20);
        assertThat(protectedMode.badgePollSeconds()).isEqualTo(90);
        assertThat(protectedMode.attachmentMaxBytes()).isEqualTo(10485760L);
        var unavailableMode = controller.publicSettings();
        assertThat(unavailableMode.auditArchivePurgeMode()).isEqualTo(AuditRetentionModeReader.PurgeMode.UNKNOWN);
        assertThat(unavailableMode.auditReceiptRetentionMonths()).isEqualTo(36);
    }
}
