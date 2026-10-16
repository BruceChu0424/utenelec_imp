package com.uten.imp.features.admin.serveroperations;

import com.fasterxml.jackson.annotation.JsonIgnoreProperties;
import com.fasterxml.jackson.annotation.JsonProperty;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Size;
import java.time.OffsetDateTime;
import java.time.LocalDate;
import java.util.UUID;

public final class ServerOperationsDto {
    private ServerOperationsDto() {}

    @JsonIgnoreProperties(ignoreUnknown = true)
    public record Job(UUID id, UUID requestId, UUID actorId, String mode, String state, String phase,
            OffsetDateTime startedAt, OffsetDateTime finishedAt, String currentVersion,
            String targetVersion, String message, String backupPath, Boolean migrationRequired, String health,
            OffsetDateTime scheduledAt, String displayLocalTime) {}

    public record LatestJob(Job job) {}

    public record Status(boolean available, Boolean manualOnly, Boolean timerActive, Boolean timerEnabled,
            String currentVersion, String sourceRevision, Boolean sourceConfigured, Job latestJob,
            String latestVersion, OffsetDateTime lastCheckedAt, Boolean updateAvailable,
            String serverTimeZone, OffsetDateTime serverTime,
            String message, boolean canUpdate, boolean canCleanup, boolean canConfigureSource) {}

    public record SourceView(String revision, String endpoint, String bucket, String objectPrefix,
            boolean accessKeyConfigured, String accessKeyIdHint, String signingPublicKey,
            String signingKeyFingerprint, String sourceUrl, boolean applied) {}

    public record SourceSave(
            @NotNull UUID requestId,
            @NotBlank @Size(max = 128) String expectedRevision,
            @NotBlank @Size(max = 128) String endpoint,
            @NotBlank @Size(max = 63) String bucket,
            @NotNull @Size(max = 256) String objectPrefix,
            @JsonProperty(access = JsonProperty.Access.WRITE_ONLY) @Size(max = 256) String accessKeyId,
            @JsonProperty(access = JsonProperty.Access.WRITE_ONLY) @Size(max = 1024) String accessKeySecret,
            boolean clearCredentials,
            @Size(max = 1024) String signingPublicKey) {
        @Override public String toString() {
            return "SourceSave[requestId=" + requestId + ", sensitiveFields=REDACTED]";
        }
    }

    public record UpdateStart(@NotNull UUID requestId, @NotBlank @Size(max = 24) String mode,
            @NotBlank @Size(max = 128) String expectedSourceRevision,
            @Size(max = 32) String expectedCurrentVersion,
            @Size(max = 32) String targetVersion, OffsetDateTime scheduledAt) {}

    public record Check(@NotNull UUID requestId,
            @NotBlank @Size(max = 128) String expectedSourceRevision,
            @Size(max = 32) String expectedCurrentVersion) {}

    public record SchedulePreview(@NotNull LocalDate localDate, @NotNull Integer hour) {}

    public record ScheduleSlot(OffsetDateTime scheduledAt, String serverTimeZone, String displayLocalTime) {}

    public record Cancel(@NotNull UUID requestId) {}
}
