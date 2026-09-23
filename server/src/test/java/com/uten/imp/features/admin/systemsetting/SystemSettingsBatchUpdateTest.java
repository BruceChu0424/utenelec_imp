package com.uten.imp.features.admin.systemsetting;

import com.uten.imp.audit.AuditService;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.security.TxSessionVars;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import java.util.List;
import java.util.Optional;
import java.util.UUID;
import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

class SystemSettingsBatchUpdateTest {
    private final SystemSettingRepository repository = mock(SystemSettingRepository.class);
    private final AuditService audit = mock(AuditService.class);
    private final UUID actorId = UUID.randomUUID();
    private final SystemSettingsService service = new SystemSettingsService(
            repository, audit, mock(TxSessionVars.class));
    private final SystemSetting hot = setting("audit_hot_retention_months", "6");
    private final SystemSetting archive = setting("audit_archive_retention_months", "30");

    @BeforeEach
    void setup() {
        when(repository.findAllForUpdate(anyCollection())).thenReturn(List.of(hot, archive));
    }

    @Test
    void savesAllChangesInOneLockedPassAndOneFlush() {
        var result = service.writeBatch(request("12", "60", "6"), actorId, "admin");
        assertEquals(2, result.size());
        assertEquals("12", hot.getValue());
        assertEquals("60", archive.getValue());
        verify(repository, times(1)).findAllForUpdate(anyCollection());
        verify(repository, times(1)).flush();
        verify(audit, times(2)).logCommitted(eq(actorId), eq("admin"),
                eq("update_system_setting"), eq("system_settings"), anyString(), eq("success"));
        // 列表项的元数据来自登记枚举: 界面直接拿到取值范围, 不再在前端另写一份。
        SystemSettingDto hotDto = result.stream()
                .filter(dto -> dto.key().equals("audit_hot_retention_months")).findFirst().orElseThrow();
        assertEquals(1L, hotDto.minValue());
        assertEquals(120L, hotDto.maxValue());
        assertEquals("在线审计保留期", hotDto.label());
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
    void unregisteredKeyIsRejectedBeforeLocking() {
        ApiException error = assertThrows(ApiException.class, () -> service.writeBatch(
                new SystemSettingDto.BatchUpdate(List.of(
                        new SystemSettingDto.Change("made_up_setting", "1", "0"))), actorId, "admin"));
        assertEquals(ErrorCode.NOT_FOUND, error.getCode());
        verify(repository, never()).findAllForUpdate(anyCollection());
    }

    @Test
    void duplicateSettingsAreRejectedBeforeLocking() {
        var change = new SystemSettingDto.Change(hot.getKey(), "12", "6");
        assertThrows(ApiException.class, () -> service.writeBatch(
                new SystemSettingDto.BatchUpdate(List.of(change, change)), actorId, "admin"));
        verify(repository, never()).findAllForUpdate(anyCollection());
    }

    @Test
    void unknownCelebrationTypesCannotBeSavedAsAnEffectiveSchedule() {
        SystemSetting types = setting("celebration.auto_types", "birthday");
        when(repository.findAllForUpdate(anyCollection())).thenReturn(List.of(types));
        assertThrows(ApiException.class, () -> service.writeBatch(
                new SystemSettingDto.BatchUpdate(List.of(
                        new SystemSettingDto.Change(types.getKey(), "wedding", "birthday"))), actorId, "admin"));
        verify(repository, never()).save(any());
    }

    @Test
    void delegatedWriteUsesTheSameValidationLockAndAudit() {
        SystemSetting auto = setting("celebration.auto_enabled", "false");
        when(repository.findAllForUpdate(List.of("celebration.auto_enabled"))).thenReturn(List.of(auto));

        service.writeDelegated(SystemSettingKey.CELEBRATION_AUTO_ENABLED, "true",
                actorId, "hr", "notice_celebration_auto_toggle");

        assertEquals("true", auto.getValue());
        assertEquals(actorId, auto.getUpdatedBy());
        verify(audit).logCommitted(eq(actorId), eq("hr"), eq("notice_celebration_auto_toggle"),
                eq("system_settings"), eq("celebration.auto_enabled: false → true"), eq("success"));
        assertThrows(ApiException.class, () -> service.writeDelegated(
                SystemSettingKey.CELEBRATION_AUTO_ENABLED, "maybe", actorId, "hr", "x"));
    }

    @Test
    void readsFallBackToTheRegisteredDefaultWhenTheStoredValueIsMissingOrOutOfRange() {
        when(repository.findById("lockout_threshold")).thenReturn(Optional.of(setting("lockout_threshold", "0")));
        when(repository.findById("lockout_minutes")).thenReturn(Optional.empty());
        when(repository.findById("jwt_access_ttl_minutes")).thenReturn(
                Optional.of(setting("jwt_access_ttl_minutes", "60")));

        assertEquals(5, service.readInt(SystemSettingKey.LOCKOUT_THRESHOLD));
        assertEquals(15, service.readInt(SystemSettingKey.LOCKOUT_MINUTES));
        assertEquals(60L, service.readLong(SystemSettingKey.JWT_ACCESS_TTL_MINUTES));
        assertThrows(IllegalArgumentException.class,
                () -> service.readInt(SystemSettingKey.JWT_ACCESS_TTL_MINUTES));
    }

    private SystemSettingDto.BatchUpdate request(String newHot, String newArchive, String expectedHot) {
        return new SystemSettingDto.BatchUpdate(List.of(
                new SystemSettingDto.Change(hot.getKey(), newHot, expectedHot),
                new SystemSettingDto.Change(archive.getKey(), newArchive, "30")));
    }

    private static SystemSetting setting(String key, String value) {
        SystemSetting result = new SystemSetting();
        result.setKey(key);
        result.setValue(value);
        return result;
    }
}
