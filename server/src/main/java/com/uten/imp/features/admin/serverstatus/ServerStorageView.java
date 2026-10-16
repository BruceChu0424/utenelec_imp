package com.uten.imp.features.admin.serverstatus;

import jakarta.validation.constraints.NotEmpty;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Size;
import java.time.Instant;
import java.util.List;
import java.util.UUID;

/** Typed public projection: no helper paths, credentials or raw filesystem metadata. */
public final class ServerStorageView {
    private ServerStorageView() {}
    public enum Kind { SYSTEM, RELEASES, RELEASE_STAGING, PREACTIVATION_BACKUPS, PAIRED_BACKUPS, DATABASE, UPLOADS, LEGACY_UPLOADS, LOGS, CACHE }
    public record Capabilities(boolean available, boolean canCleanup, String unavailableReason) {}
    public record Volume(String id, String label, Long totalBytes, Long usedBytes, Long freeBytes) {}
    public record Category(Kind kind, String label, String status, Long logicalBytes, Long allocatedBytes,
                           Long reclaimableBytes, Long count, String detail, boolean canList, String volumeId) {}
    public record ProcessMemory(Long rssBytes, long heapUsedBytes, long heapMaxBytes, String detail) {}
    public record Database(Long sizeBytes, String status) {}
    public record Uploads(Long count, Long logicalBytes, Long storedBytes, String status, String detail) {}
    public record Summary(Instant sampledAt, String status, String revision, Capabilities capabilities,
                          List<Volume> volumes, List<Category> categories, ProcessMemory process,
                          Database database, Uploads uploads) {}
    public record Resource(String id, String label, Kind kind, Long logicalBytes, Long allocatedBytes,
                           Long reclaimableBytes, Instant modifiedAt, boolean canDelete,
                           List<String> protectionReasons, String detail, String verificationLevel) {}
    public record Resources(Instant sampledAt, String revision, Kind kind, List<Resource> items, String nextCursor, long total) {}
    public record Preview(String previewId, Instant expiresAt, String revision, List<Resource> resources,
                          Long totalReclaimableBytes, String confirmationText, List<String> warnings) {}
    public record Result(UUID requestId, String status, int deletedCount, Long reclaimedBytes, String detail) {}
    public record PreviewRequest(@NotEmpty @Size(max = 50) List<@NotNull @Size(min = 64, max = 64) String> resourceIds) {}
    public record DeleteRequest(@NotNull UUID previewId, @NotNull UUID requestId) {}
}
