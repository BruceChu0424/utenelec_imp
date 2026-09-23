package com.uten.imp.features.admin.systemsetting;

import com.uten.imp.audit.AuditService;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.security.TxSessionVars;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.CsvSource;

import java.util.List;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyCollection;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class SystemSettingsServiceRetentionValidationTest {

    @ParameterizedTest
    @CsvSource({
            "audit_hot_retention_months,0,1 至 120",
            "audit_hot_retention_months,121,1 至 120",
            "audit_archive_retention_months,241,0 至 240",
            "export_max_rows,100001,1 至 100000",
            "password_history_size,101,0 至 100",
            "sms_code_ttl_minutes,2147483647,1 至 1440",
            "sms_send_interval_seconds,86401,1 至 86400",
            "sms_daily_limit,10001,1 至 10000",
            "login_rate_limit_per_minute,100001,1 至 100000",
            "login_ip_rate_limit_per_minute,1000001,1 至 1000000",
            "lockout_threshold,1001,1 至 1000",
            "lockout_minutes,525601,1 至 525600",
            "export_rate_limit_per_minute,10001,1 至 10000",
            "session_idle_timeout_minutes,525601,1 至 525600",
            "password_min_length,7,8 至 64",
            "temp_password_ttl_hours,169,1 至 168",
            "impersonation_window_minutes,121,1 至 120",
            "jwt_refresh_ttl_days,31,1 至 30",
            "badge_poll_seconds,14,15 至 600",
            "delivery_due_warning_days,31,1 至 30"
    })
    void dangerousRetentionAndExportValuesAreRejected(
            String key,
            String value,
            String expectedMessage) {
        SystemSettingRepository repository = mock(SystemSettingRepository.class);
        AuditService audit = mock(AuditService.class);
        SystemSettingsService service = new SystemSettingsService(
                repository, audit, mock(TxSessionVars.class));
        UUID actorId = UUID.randomUUID();
        SystemSetting setting = new SystemSetting();
        setting.setKey(key);
        setting.setValue("6");
        when(repository.findAllForUpdate(anyCollection())).thenReturn(List.of(setting));

        ApiException error = assertThrows(
                ApiException.class,
                () -> service.writeBatch(new SystemSettingDto.BatchUpdate(List.of(
                        new SystemSettingDto.Change(key, value, "6"))), actorId, "admin"));

        assertTrue(error.getMessage().contains(expectedMessage), error.getMessage());
        verify(repository, never()).save(setting);
        verify(audit, never()).logCommitted(any(), any(), any(), any(), any(), any());
    }
}
