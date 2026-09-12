package com.uten.imp.features.admin.systemsetting;

import com.uten.imp.audit.AuditService;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.auth.model.UserAccount;
import com.uten.imp.features.auth.model.UserAccountRepository;
import com.uten.imp.security.TxSessionVars;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.security.crypto.password.PasswordEncoder;
import java.util.List;
import java.util.Optional;
import java.util.UUID;
import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

class SystemSettingsBatchUpdateTest {
    private final SystemSettingRepository repository = mock(SystemSettingRepository.class);
    private final AuditService audit = mock(AuditService.class);
    private final PasswordEncoder encoder = mock(PasswordEncoder.class);
    private final UserAccountRepository users = mock(UserAccountRepository.class);
    private final UUID actorId = UUID.randomUUID();
    private final SystemSettingsService service = new SystemSettingsService(
            repository, audit, encoder, users, mock(TxSessionVars.class));
    private final SystemSetting hot = setting("audit_hot_retention_months", "6", "int");
    private final SystemSetting archive = setting("audit_archive_retention_months", "30", "int");

    @BeforeEach
    void setup() {
        UserAccount user = new UserAccount();
        user.setSuperAdmin(true);
        user.setPasswordHash("hash");
        when(users.findById(actorId)).thenReturn(Optional.of(user));
        when(encoder.matches("password", "hash")).thenReturn(true);
        when(repository.findAllForUpdate(anyCollection())).thenReturn(List.of(hot, archive));
    }

    @Test
    void savesAllChangesWithOnePasswordVerificationAndOneFlush() {
        var result = service.writeBatch(request("12", "60", "6"), actorId, "admin");
        assertEquals(2, result.size());
        assertEquals("12", hot.getValue());
        assertEquals("60", archive.getValue());
        verify(encoder, times(1)).matches("password", "hash");
        verify(repository, times(1)).findAllForUpdate(anyCollection());
        verify(repository, times(1)).flush();
        verify(audit, times(2)).logCommitted(eq(actorId), eq("admin"),
                eq("update_system_setting"), eq("system_settings"), anyString(), eq("success"));
    }

    @Test
    void invalidLaterValueDoesNotMutateEarlierSetting() {
        assertThrows(ApiException.class, () -> service.writeBatch(request("12", "241", "6"), actorId, "admin"));
        assertEquals("6", hot.getValue());
        assertEquals("30", archive.getValue());
        verify(repository, never()).save(any());
        verifyNoInteractions(audit);
    }

    @Test
    void staleAdminPageFailsBeforeAnyMutation() {
        ApiException error = assertThrows(ApiException.class,
                () -> service.writeBatch(request("12", "60", "5"), actorId, "admin"));
        assertEquals(ErrorCode.CONFLICT, error.getCode());
        assertEquals("6", hot.getValue());
        verify(repository, never()).save(any());
        verifyNoInteractions(audit);
    }

    @Test
    void badPasswordCannotLockOrWriteSettings() {
        when(encoder.matches("password", "hash")).thenReturn(false);
        assertThrows(ApiException.class, () -> service.writeBatch(request("12", "60", "6"), actorId, "admin"));
        verify(repository, never()).findAllForUpdate(anyCollection());
        verifyNoInteractions(audit);
    }

    @Test
    void duplicateSettingsAreRejectedBeforeLocking() {
        var change = new SystemSettingDto.Change(hot.getKey(), "12", "6");
        assertThrows(ApiException.class, () -> service.writeBatch(
                new SystemSettingDto.BatchUpdate("password", List.of(change, change)), actorId, "admin"));
        verify(repository, never()).findAllForUpdate(anyCollection());
    }

    @Test
    void unknownCelebrationTypesCannotBeSavedAsAnEffectiveSchedule() {
        SystemSetting types = setting("celebration.auto_types", "birthday", "string");
        when(repository.findAllForUpdate(anyCollection())).thenReturn(List.of(types));
        assertThrows(ApiException.class, () -> service.writeBatch(
                new SystemSettingDto.BatchUpdate("password", List.of(
                        new SystemSettingDto.Change(types.getKey(), "wedding", "birthday"))), actorId, "admin"));
        verify(repository, never()).save(any());
    }

    private SystemSettingDto.BatchUpdate request(String newHot, String newArchive, String expectedHot) {
        return new SystemSettingDto.BatchUpdate("password", List.of(
                new SystemSettingDto.Change(hot.getKey(), newHot, expectedHot),
                new SystemSettingDto.Change(archive.getKey(), newArchive, "30")));
    }

    private static SystemSetting setting(String key, String value, String type) {
        SystemSetting result = new SystemSetting();
        result.setKey(key);
        result.setValue(value);
        result.setValueType(type);
        result.setLabel(key);
        return result;
    }
}
