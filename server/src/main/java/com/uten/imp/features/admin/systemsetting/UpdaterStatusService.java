package com.uten.imp.features.admin.systemsetting;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.NoSuchFileException;
import java.nio.file.Path;
import java.time.Clock;
import java.time.Duration;
import java.time.OffsetDateTime;
import java.time.format.DateTimeParseException;
import java.util.Set;

/** Read-only bridge to the root-owned updater; a saved setting is not proof of application. */
@Service
public class UpdaterStatusService {
    private static final int MAX_STATUS_BYTES = 16 * 1024;
    private static final Duration FRESHNESS = Duration.ofMinutes(5);
    private static final Set<String> RESULTS = Set.of("NEVER", "RUNNING", "SUCCESS", "FAILED");

    private final SystemSettingRepository repository;
    private final ObjectMapper mapper;
    private final Path statusFile;
    private final Clock clock;

    @Autowired
    public UpdaterStatusService(SystemSettingRepository repository, ObjectMapper mapper,
            @Value("${uten.updater.status-file:/var/lib/uten-imp/updater-schedule/status.json}") String statusFile) {
        this(repository, mapper, Path.of(statusFile), Clock.systemUTC());
    }

    UpdaterStatusService(SystemSettingRepository repository, ObjectMapper mapper, Path statusFile, Clock clock) {
        this.repository = repository;
        this.mapper = mapper;
        this.statusFile = statusFile;
        this.clock = clock;
    }

    @Transactional(readOnly = true)
    @PreAuthorize("hasAuthority('authorization:manage') and principal.superAdmin")
    public Status read() {
        SystemSetting row = repository.findById(SystemSettingKey.UPDATER_CHECK_INTERVAL_DAYS.key()).orElse(null);
        int requested = (int) SystemSettingsService.effectiveNumber(
                SystemSettingKey.UPDATER_CHECK_INTERVAL_DAYS, row == null ? null : row.getValue());
        OffsetDateTime requestedUpdatedAt = row == null ? null : row.getUpdatedAt();
        try {
            byte[] bytes;
            try (var input = Files.newInputStream(statusFile)) {
                bytes = input.readNBytes(MAX_STATUS_BYTES + 1);
            }
            if (bytes.length > MAX_STATUS_BYTES) {
                return unavailable(requested, requestedUpdatedAt, "服务器更新调度状态格式异常");
            }
            JsonNode document = mapper.readTree(bytes);
            if (document == null || !document.isObject() || !document.path("schemaVersion").isInt()
                    || document.path("schemaVersion").intValue() != 1) {
                return unavailable(requested, requestedUpdatedAt, "服务器更新调度状态版本不受支持");
            }
            OffsetDateTime checkedAt = time(document, "checkedAt");
            OffsetDateTime configUpdatedAt = time(document, "configUpdatedAt");
            OffsetDateTime nextCheckAt = time(document, "nextCheckAt");
            OffsetDateTime lastAttemptAt = time(document, "lastAttemptAt");
            Integer applied = interval(document.get("appliedIntervalDays"));
            String result = string(document, "lastResult");
            String error = string(document, "error");
            if (checkedAt == null || !RESULTS.contains(result == null ? "" : result)
                    || ("NEVER".equals(result) != (lastAttemptAt == null))
                    || (error == null && (applied == null || configUpdatedAt == null
                        || (applied == 0) != (nextCheckAt == null)))) {
                return unavailable(requested, requestedUpdatedAt, "服务器更新调度状态不完整");
            }
            boolean available = error == null;
            boolean stale = !available || requestedUpdatedAt == null || applied == null || applied != requested
                    || !requestedUpdatedAt.toInstant().equals(configUpdatedAt.toInstant())
                    || checkedAt.toInstant().isBefore(clock.instant().minus(FRESHNESS))
                    || checkedAt.toInstant().isAfter(clock.instant().plusSeconds(60));
            return new Status(requested, requestedUpdatedAt, applied, configUpdatedAt, checkedAt,
                    nextCheckAt, lastAttemptAt, result, error, available, stale);
        } catch (NoSuchFileException e) {
            return unavailable(requested, requestedUpdatedAt, "服务器尚未提供更新调度状态");
        } catch (IOException | IllegalArgumentException | DateTimeParseException e) {
            return unavailable(requested, requestedUpdatedAt, "服务器更新调度状态暂不可读取");
        }
    }

    private static OffsetDateTime time(JsonNode document, String field) {
        String value = string(document, field);
        return value == null ? null : OffsetDateTime.parse(value);
    }

    private static String string(JsonNode document, String field) {
        JsonNode value = document.get(field);
        if (value == null || value.isNull()) return null;
        if (!value.isTextual() || value.textValue().length() > 400) {
            throw new IllegalArgumentException("Invalid updater status field");
        }
        return value.textValue();
    }

    private static Integer interval(JsonNode value) {
        if (value == null || value.isNull()) return null;
        if (!value.isInt() || value.intValue() < 0 || value.intValue() > 365) {
            throw new IllegalArgumentException("Invalid updater interval");
        }
        return value.intValue();
    }

    private static Status unavailable(int requested, OffsetDateTime updatedAt, String error) {
        return new Status(requested, updatedAt, null, null, null, null, null, null, error, false, true);
    }

    public record Status(int requestedIntervalDays, OffsetDateTime requestedUpdatedAt,
            Integer appliedIntervalDays, OffsetDateTime configUpdatedAt, OffsetDateTime checkedAt,
            OffsetDateTime nextCheckAt, OffsetDateTime lastAttemptAt, String lastResult,
            String error, boolean available, boolean stale) {}
}
