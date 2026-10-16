package com.uten.imp.features.admin.systemsetting;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.security.RequiresStepUp;
import java.nio.file.Files;
import java.nio.file.Path;
import java.time.Clock;
import java.time.OffsetDateTime;
import java.util.Map;
import java.util.Optional;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;
import org.springframework.security.access.prepost.PreAuthorize;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.*;

class UpdaterStatusServiceTest {
    @TempDir Path directory;
    private final SystemSettingRepository repository=mock(SystemSettingRepository.class);
    private final ObjectMapper mapper=new ObjectMapper();
    private final SystemSetting setting=new SystemSetting();
    private Path statusFile;
    private UpdaterStatusService service;
    @BeforeEach void setUp(){
        statusFile=directory.resolve("status.json");service=new UpdaterStatusService(repository,mapper,statusFile,Clock.systemUTC());
        setting.setKey(SystemSettingKey.UPDATER_CHECK_INTERVAL_DAYS.key());setting.setValue("7");
        setting.setUpdatedAt(OffsetDateTime.parse("2026-09-26T01:00:00Z"));
        when(repository.findById(setting.getKey())).thenReturn(Optional.of(setting));
    }
    @Test void evenAFreshFormerlyValidSuccessReceiptCannotClaimAnAutomaticScheduleIsApplied() throws Exception {
        mapper.writeValue(statusFile.toFile(),Map.of("schemaVersion",1,"appliedIntervalDays",7,
                "configUpdatedAt",setting.getUpdatedAt().toString(),"checkedAt",OffsetDateTime.now().toString(),
                "nextCheckAt",OffsetDateTime.now().plusDays(7).toString(),"lastAttemptAt",OffsetDateTime.now().toString(),"lastResult","SUCCESS"));
        assertRetired(service.read());assertThat(service.read().requestedIntervalDays()).isEqualTo(7);
        assertThat(service.read().requestedUpdatedAt()).isEqualTo(setting.getUpdatedAt());
    }
    @ParameterizedTest @ValueSource(strings={"0","3","7","11","365"})
    void historicalRequestedChoiceRemainsReadableButNeverControlsRuntime(int value){
        setting.setValue(Integer.toString(value));var status=service.read();
        assertThat(status.requestedIntervalDays()).isEqualTo(value);assertRetired(status);
    }
    @Test void changingAwayAndBackOrMovingTheOldTimestampDoesNotReenableScheduling(){
        setting.setValue("3");assertRetired(service.read());setting.setValue("7");
        setting.setUpdatedAt(setting.getUpdatedAt().plusDays(1));assertRetired(service.read());
    }
    @ParameterizedTest @ValueSource(strings={"private diagnostic content","{}","{\"schemaVersion\":2}","{\"checkedAt\":\"bad-time\"}"})
    void malformedOrUnsupportedOldFilesAreNeverParsedOrLeaked(String bytes) throws Exception {
        Files.writeString(statusFile,bytes);var status=service.read();assertRetired(status);
        assertThat(status.error()).doesNotContain("private",directory.toString(),"bad-time");
    }
    @Test void absentOversizedOrDirectoryFilesCannotAffectTheCompatibilityRead() throws Exception {
        assertRetired(service.read());Files.writeString(statusFile," ".repeat(65537));assertRetired(service.read());
        Files.delete(statusFile);Files.createDirectory(statusFile);assertRetired(service.read());
    }
    @Test void missingSeedDoesNotInventAppliedStatus(){
        when(repository.findById(setting.getKey())).thenReturn(Optional.empty());var status=service.read();
        assertThat(status.requestedUpdatedAt()).isNull();assertRetired(status);
    }
    @Test void statusReadAndSettingWriteRetainSuperAdminAndStepUpBoundaries() throws Exception {
        assertThat(SystemSettingController.class.getAnnotation(PreAuthorize.class).value())
                .isEqualTo("hasAuthority('authorization:manage') and principal.superAdmin");
        assertThat(UpdaterStatusService.class.getMethod("read").getAnnotation(PreAuthorize.class).value())
                .isEqualTo("hasAuthority('authorization:manage') and principal.superAdmin");
        assertThat(SystemSettingController.class.getMethod("updateBatch",SystemSettingDto.BatchUpdate.class).getAnnotation(RequiresStepUp.class)).isNotNull();
    }
    private static void assertRetired(UpdaterStatusService.Status status){
        assertThat(status.available()).isFalse();assertThat(status.stale()).isTrue();
        assertThat(status.appliedIntervalDays()).isNull();assertThat(status.configUpdatedAt()).isNull();
        assertThat(status.checkedAt()).isNull();assertThat(status.nextCheckAt()).isNull();
        assertThat(status.lastAttemptAt()).isNull();assertThat(status.lastResult()).isNull();
        assertThat(status.error()).contains("已退役","服务器运维");
    }
}
