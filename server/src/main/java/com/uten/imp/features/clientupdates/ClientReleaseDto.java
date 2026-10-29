package com.uten.imp.features.clientupdates;

import java.time.Instant;
import java.util.UUID;

public final class ClientReleaseDto {
    private ClientReleaseDto() {}

    public record Create(UUID requestId, String platform, String architecture, String version,
                         long buildNumber, String releaseNotes, boolean mandatory, String fileName,
                         String expectedSha256, String storeUrl, String packageKind, String runtimeFamily) {
        public Create {
            packageKind = packageKind == null ? "update" : packageKind;
            runtimeFamily = ClientRuntimeFamily.normalize(runtimeFamily);
        }

        public Create(UUID requestId, String platform, String architecture, String version,
                      long buildNumber, String releaseNotes, boolean mandatory, String fileName,
                      String expectedSha256, String storeUrl, String packageKind) {
            this(requestId, platform, architecture, version, buildNumber, releaseNotes, mandatory,
                    fileName, expectedSha256, storeUrl, packageKind, ClientRuntimeFamily.FLUTTER);
        }

        public Create(UUID requestId, String platform, String architecture, String version,
                      long buildNumber, String releaseNotes, boolean mandatory, String fileName,
                      String expectedSha256, String storeUrl) {
            this(requestId, platform, architecture, version, buildNumber, releaseNotes, mandatory,
                    fileName, expectedSha256, storeUrl, "update");
        }
    }

    public record Release(UUID id, String platform, String architecture, String version,
                          long buildNumber, String releaseNotes, boolean mandatory, String fileName,
                          String expectedSha256, String sha256, long sizeBytes, String installMode,
                          String storeUrl, String downloadUrl, String state, Instant createdAt,
                          Instant publishedAt, String packageKind, String runtimeFamily) {
        public Release {
            packageKind = packageKind == null ? "update" : packageKind;
            runtimeFamily = ClientRuntimeFamily.normalize(runtimeFamily);
        }

        public Release(UUID id, String platform, String architecture, String version,
                       long buildNumber, String releaseNotes, boolean mandatory, String fileName,
                       String expectedSha256, String sha256, long sizeBytes, String installMode,
                       String storeUrl, String downloadUrl, String state, Instant createdAt,
                       Instant publishedAt, String packageKind) {
            this(id, platform, architecture, version, buildNumber, releaseNotes, mandatory, fileName,
                    expectedSha256, sha256, sizeBytes, installMode, storeUrl, downloadUrl, state, createdAt,
                    publishedAt, packageKind, ClientRuntimeFamily.FLUTTER);
        }

        public Release(UUID id, String platform, String architecture, String version,
                       long buildNumber, String releaseNotes, boolean mandatory, String fileName,
                       String expectedSha256, String sha256, long sizeBytes, String installMode,
                       String storeUrl, String downloadUrl, String state, Instant createdAt, Instant publishedAt) {
            this(id, platform, architecture, version, buildNumber, releaseNotes, mandatory, fileName,
                    expectedSha256, sha256, sizeBytes, installMode, storeUrl, downloadUrl, state, createdAt, publishedAt, "update");
        }
    }

    public record Check(boolean updateAvailable, Release release, int checkIntervalSeconds) {}
}
