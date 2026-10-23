package com.uten.imp.features.clientupdates;

import java.time.Instant;
import java.util.UUID;

public final class ClientReleaseDto {
    private ClientReleaseDto() {}

    public record Create(UUID requestId, String platform, String architecture, String version,
                         long buildNumber, String releaseNotes, boolean mandatory, String fileName,
                         String expectedSha256, String storeUrl) {}

    public record Release(UUID id, String platform, String architecture, String version,
                          long buildNumber, String releaseNotes, boolean mandatory, String fileName,
                          String expectedSha256, String sha256, long sizeBytes, String installMode,
                          String storeUrl, String downloadUrl, String state, Instant createdAt,
                          Instant publishedAt) {}

    public record Check(boolean updateAvailable, Release release, int checkIntervalSeconds) {}
}
