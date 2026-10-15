package com.uten.imp.features.admin.systemsetting;

import com.uten.imp.audit.AuditRetentionModeReader;
import com.uten.imp.audit.AuditService;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.config.props.StorageProperties;
import com.uten.imp.security.TxSessionVars;
import java.util.List;
import java.util.UUID;
import org.junit.jupiter.api.Test;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.*;
import static org.mockito.ArgumentMatchers.*;

class SystemSettingsEffectiveContractTest {
    private final SystemSettingRepository repo = mock(SystemSettingRepository.class);
    private final AuditService audit = mock(AuditService.class);
    private final SystemSettingsService service = new SystemSettingsService(repo, audit, mock(TxSessionVars.class));
    @Test void ipLimitBelowSubjectIsRejectedRatherThanSavedButSilentlyClamped() {
        var subject = row("login_rate_limit_per_minute", "5");
        var ip = row("login_ip_rate_limit_per_minute", "300");
        when(repo.findAllForUpdate(anyCollection())).thenAnswer(call -> {
            var keys = (java.util.Collection<?>) call.getArgument(0);
            return List.of(subject, ip).stream().filter(r -> keys.contains(r.getKey())).toList();
        });
        assertThatThrownBy(() -> service.writeBatch(new SystemSettingDto.BatchUpdate(List.of(
                new SystemSettingDto.Change(ip.getKey(), "2", "300"))), UUID.randomUUID(), "admin"))
                .isInstanceOf(ApiException.class);
        assertThat(ip.getValue()).isEqualTo("300");
        verify(repo, never()).save(any());
    }
    @Test void retiredUpdaterSettingCannotBeWrittenByOldOrDelegatedClients() {
        var interval = row("updater_check_interval_days", "7");
        when(repo.findAllForUpdate(anyCollection())).thenReturn(List.of(interval));
        assertThatThrownBy(() -> service.writeBatch(new SystemSettingDto.BatchUpdate(List.of(
                new SystemSettingDto.Change(interval.getKey(), "0", "7"))), UUID.randomUUID(), "admin"))
                .isInstanceOf(ApiException.class);
        assertThatThrownBy(() -> service.writeDelegated(SystemSettingKey.UPDATER_CHECK_INTERVAL_DAYS,
                "0", UUID.randomUUID(), "admin", "legacy")) .isInstanceOf(ApiException.class);
        assertThat(interval.getValue()).isEqualTo("7");
    }
    @Test void publicAuditReceiptWindowMatchesDatabaseSixMonthSafetyFloor() {
        var settings = mock(SystemSettingsService.class);
        when(settings.readInt(SystemSettingKey.AUDIT_HOT_RETENTION_MONTHS)).thenReturn(1);
        when(settings.readInt(SystemSettingKey.AUDIT_ARCHIVE_RETENTION_MONTHS)).thenReturn(0);
        var view = new PublicSettingsController(settings, mock(StorageProperties.class),
                mock(AuditRetentionModeReader.class)).publicSettings();
        assertThat(view.auditReceiptRetentionMonths()).isEqualTo(6);
    }
    @Test void aJointRateLimitChangeUsesBothProspectiveValuesUnderOneDeterministicLock() {
        var subject=row("login_rate_limit_per_minute","5");var ip=row("login_ip_rate_limit_per_minute","300");
        when(repo.findAllForUpdate(anyCollection())).thenReturn(List.of(ip,subject));
        var saved=service.writeBatch(new SystemSettingDto.BatchUpdate(List.of(
                new SystemSettingDto.Change(subject.getKey(),"500","5"),
                new SystemSettingDto.Change(ip.getKey(),"600","300"))),UUID.randomUUID(),"admin");
        assertThat(saved).hasSize(2);assertThat(subject.getValue()).isEqualTo("500");
        assertThat(ip.getValue()).isEqualTo("600");
        verify(repo).findAllForUpdate(eq(new java.util.TreeSet<>(List.of(subject.getKey(),ip.getKey()))));
        verify(repo,times(1)).flush();
    }
    @Test void effectiveMetadataMatchesDefaultsFloorAndIssuanceTimingWithoutOverwritingStoredValues() {
        var archive=row("audit_archive_retention_months","0");var hot=row("audit_hot_retention_months","1");
        var token=row("jwt_access_ttl_minutes","broken");var legacy=row("updater_check_interval_days","11");
        var bool=row("celebration.auto_enabled"," true ");
        when(repo.findAll()).thenReturn(List.of(archive,hot,token,legacy,bool));
        var byKey=service.list().stream().collect(java.util.stream.Collectors.toMap(SystemSettingDto::key,e->e));
        assertThat(byKey.get(archive.getKey()).effectiveValue()).isEqualTo("5");
        assertThat(byKey.get(archive.getKey()).value()).isEqualTo("0");
        assertThat(byKey.get(token.getKey()).effectiveValue()).isEqualTo("15");
        assertThat(byKey.get(token.getKey()).applyMode()).isEqualTo("NEXT_ISSUANCE");
        assertThat(byKey.get(legacy.getKey()).effectiveValue()).isNull();
        assertThat(byKey.get(legacy.getKey()).editable()).isFalse();
        assertThat(byKey.get(bool.getKey()).effectiveValue()).isEqualTo("true");
        when(repo.findById(bool.getKey())).thenReturn(java.util.Optional.of(bool));
        assertThat(service.readBool(SystemSettingKey.CELEBRATION_AUTO_ENABLED)).isTrue();
        verify(repo,never()).save(any());
    }
    private static SystemSetting row(String key, String value) {
        var row = new SystemSetting(); row.setKey(key); row.setValue(value); return row;
    }
}
