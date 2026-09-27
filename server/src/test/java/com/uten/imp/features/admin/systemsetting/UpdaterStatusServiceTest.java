package com.uten.imp.features.admin.systemsetting;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.security.RequiresStepUp;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;
import org.springframework.security.access.prepost.PreAuthorize;

import java.nio.file.Files;
import java.nio.file.Path;
import java.time.Clock;
import java.time.Instant;
import java.time.OffsetDateTime;
import java.time.ZoneOffset;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.Optional;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

class UpdaterStatusServiceTest {
    @TempDir Path directory;
    private final ObjectMapper mapper = new ObjectMapper();
    private final SystemSettingRepository repository = mock(SystemSettingRepository.class);
    private final SystemSetting setting = new SystemSetting();
    private final Map<String, Object> document = new LinkedHashMap<>();
    private UpdaterStatusService service;
    private Path statusFile;

    @BeforeEach
    void setUp() {
        statusFile = directory.resolve("status.json");
        service = new UpdaterStatusService(repository, mapper, statusFile,
                Clock.fixed(Instant.parse("2026-09-27T02:00:00Z"), ZoneOffset.UTC));
        setting.setKey(SystemSettingKey.UPDATER_CHECK_INTERVAL_DAYS.key());
        setting.setValue("7");
        setting.setUpdatedAt(OffsetDateTime.parse("2026-09-26T01:00:00Z"));
        when(repository.findById(setting.getKey())).thenReturn(Optional.of(setting));
        document.put("schemaVersion", 1);
        document.put("appliedIntervalDays", 7);
        document.put("configUpdatedAt", "2026-09-26T09:00:00+08:00");
        document.put("checkedAt", "2026-09-27T09:59:30+08:00");
        document.put("nextCheckAt", "2026-10-04T05:00:00+08:00");
        document.put("lastAttemptAt", "2026-09-27T05:00:00+08:00");
        document.put("lastResult", "SUCCESS");
        document.put("error", null);
    }

    @Test
    void freshAppliedStatusUsesDatabaseValueAndComparesTimestampInstants() throws Exception {
        write();
        var status = service.read();
        assertThat(status.available()).isTrue();
        assertThat(status.stale()).isFalse();
        assertThat(status.requestedIntervalDays()).isEqualTo(7);
        assertThat(status.appliedIntervalDays()).isEqualTo(7);
        assertThat(status.nextCheckAt()).isEqualTo(OffsetDateTime.parse("2026-10-04T05:00:00+08:00"));
        assertThat(status.lastResult()).isEqualTo("SUCCESS");
    }

    @Test
    void changingASettingDoesNotClaimTheOldScheduleIsApplied() throws Exception {
        write();
        setting.setValue("3");
        var status = service.read();
        assertThat(status.available()).isTrue();
        assertThat(status.stale()).isTrue();
        assertThat(status.requestedIntervalDays()).isEqualTo(3);
        assertThat(status.appliedIntervalDays()).isEqualTo(7);
    }

    @Test
    void changingAwayAndBackStillRequiresTheSchedulerToObserveTheNewAnchor() throws Exception {
        write();
        setting.setUpdatedAt(setting.getUpdatedAt().plusDays(1));
        assertThat(service.read().stale()).isTrue();
    }

    @Test
    void manualModeHasNoNextRunAndRetainsTheLastAttempt() throws Exception {
        setting.setValue("0");
        document.put("appliedIntervalDays", 0);
        document.put("nextCheckAt", null);
        write();
        var status = service.read();
        assertThat(status.available()).isTrue();
        assertThat(status.stale()).isFalse();
        assertThat(status.nextCheckAt()).isNull();
        assertThat(status.lastAttemptAt()).isNotNull();
        assertThat(status.lastResult()).isEqualTo("SUCCESS");
    }

    @Test
    void aScheduleWithNoAttemptsIsValid() throws Exception {
        document.put("lastResult", "NEVER");
        document.put("lastAttemptAt", null);
        write();
        assertThat(service.read().stale()).isFalse();
    }

    @Test
    void absentFileIsUnavailableWithoutLeakingTheLocalPath() {
        var status = service.read();
        assertThat(status.available()).isFalse();
        assertThat(status.stale()).isTrue();
        assertThat(status.error()).isEqualTo("服务器尚未提供更新调度状态");
        assertThat(status.appliedIntervalDays()).isNull();
    }

    @Test
    void schedulerErrorsPreserveTheAttemptButNeverClaimAnAppliedSchedule() throws Exception {
        document.put("appliedIntervalDays", null);
        document.put("configUpdatedAt", null);
        document.put("nextCheckAt", null);
        document.put("error", "无法读取服务器更新设置");
        write();
        var status = service.read();
        assertThat(status.available()).isFalse();
        assertThat(status.stale()).isTrue();
        assertThat(status.error()).isEqualTo("无法读取服务器更新设置");
        assertThat(status.lastResult()).isEqualTo("SUCCESS");
    }

    @Test
    void oldOrFutureClockEvidenceIsStale() throws Exception {
        document.put("checkedAt", "2026-09-27T01:54:59Z");
        write();
        assertThat(service.read().stale()).isTrue();
        document.put("checkedAt", "2026-09-27T02:01:01Z");
        write();
        assertThat(service.read().stale()).isTrue();
    }

    @Test
    void malformedAndOversizeFilesCannotBreakSettingsOrExposeTheirContents() throws Exception {
        Files.writeString(statusFile, "sensitive diagnostic content - not JSON");
        var malformed = service.read();
        assertThat(malformed.available()).isFalse();
        assertThat(malformed.error()).doesNotContain("sensitive", directory.toString());
        Files.writeString(statusFile, " ".repeat(16 * 1024 + 1));
        assertThat(service.read().available()).isFalse();
    }

    @Test
    void unsupportedAndIncompleteDocumentsAreUnavailable() throws Exception {
        document.put("schemaVersion", 2);
        write();
        assertThat(service.read().available()).isFalse();
        document.put("schemaVersion", 1);
        document.remove("checkedAt");
        write();
        assertThat(service.read().available()).isFalse();
    }

    @Test
    void malformedIntervalsAndTimestampsAreNotCoerced() throws Exception {
        document.put("appliedIntervalDays", "7");
        write();
        assertThat(service.read().available()).isFalse();
        document.put("appliedIntervalDays", 7);
        document.put("checkedAt", "2026-09-27T02:00:00");
        write();
        assertThat(service.read().available()).isFalse();
    }

    @Test
    void missingDatabaseSeedCannotBeReportedAsApplied() throws Exception {
        when(repository.findById(setting.getKey())).thenReturn(Optional.empty());
        write();
        assertThat(service.read().stale()).isTrue();
    }

    @Test
    void statusReadAndSettingWriteRetainSuperAdminAndStepUpBoundaries() throws Exception {
        assertThat(SystemSettingController.class.getAnnotation(PreAuthorize.class).value())
                .isEqualTo("hasAuthority('authorization:manage') and principal.superAdmin");
        assertThat(UpdaterStatusService.class.getMethod("read").getAnnotation(PreAuthorize.class).value())
                .isEqualTo("hasAuthority('authorization:manage') and principal.superAdmin");
        assertThat(SystemSettingController.class.getMethod("updateBatch", SystemSettingDto.BatchUpdate.class)
                .getAnnotation(RequiresStepUp.class)).isNotNull();
    }

    private void write() throws Exception {
        mapper.writeValue(statusFile.toFile(), document);
    }
}
