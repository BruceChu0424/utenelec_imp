package com.uten.imp.features.admin.systemsetting;

import com.uten.imp.audit.AuditService;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.auth.model.UserAccount;
import com.uten.imp.features.auth.model.UserAccountRepository;
import com.uten.imp.security.TxSessionVars;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.CsvSource;
import org.springframework.security.crypto.password.PasswordEncoder;

import java.util.Optional;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;
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
            "export_max_rows,100001,1 至 100000"
    })
    void dangerousRetentionAndExportValuesAreRejected(
            String key,
            String value,
            String expectedMessage) {
        SystemSettingRepository repository = mock(SystemSettingRepository.class);
        AuditService audit = mock(AuditService.class);
        PasswordEncoder passwordEncoder = mock(PasswordEncoder.class);
        UserAccountRepository userRepository = mock(UserAccountRepository.class);
        SystemSettingsService service = new SystemSettingsService(
                repository, audit, passwordEncoder, userRepository,
                mock(TxSessionVars.class));
        UUID actorId = UUID.randomUUID();
        UserAccount actor = new UserAccount();
        actor.setSuperAdmin(true);
        actor.setPasswordHash("hash");
        SystemSetting setting = new SystemSetting();
        setting.setKey(key);
        setting.setValue("6");
        setting.setValueType("int");
        setting.setCategory("audit");
        setting.setLabel("测试设置");
        when(userRepository.findById(actorId)).thenReturn(Optional.of(actor));
        when(passwordEncoder.matches("password", "hash")).thenReturn(true);
        when(repository.findById(key)).thenReturn(Optional.of(setting));

        ApiException error = assertThrows(
                ApiException.class,
                () -> service.write(
                        key, value, "password", actorId, "admin"));

        assertTrue(error.getMessage().contains(expectedMessage));
        verify(repository, never()).save(setting);
        verify(audit, never()).logExplicit(
                actorId,
                "admin",
                "update_system_setting",
                "system_settings",
                key,
                "success");
    }
}
