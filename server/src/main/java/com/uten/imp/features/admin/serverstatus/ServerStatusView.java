package com.uten.imp.features.admin.serverstatus;

import java.time.Instant;
import java.util.List;

/** Read-only operational summary; unavailable values are null, never invented zeros. */
public record ServerStatusView(
        Instant sampledAt, int refreshAfterSeconds, String status, String environment,
        String applicationVersion, long uptimeSeconds, List<Metric> metrics,
        List<Disk> disks, Database database, Backup backup, List<Alert> alerts) {

    public record Metric(String key, String label, Double value, String unit,
                         Double warningThreshold, Double criticalThreshold,
                         String status, String detail, Long totalBytes, Long usedBytes, Long freeBytes) {}
    public record Disk(String key, String label, Long totalBytes, Long usedBytes,
                       Long freeBytes, Double usedPercent, double warningThreshold,
                       double criticalThreshold, String status, String detail) {}
    public record Database(String status, Double responseMs, Integer connections,
                           Integer maxConnections, String detail) {}
    public record Backup(String status, Instant lastSuccessAt, Double ageHours,
                         int warningAfterHours, int criticalAfterHours, String detail) {}
    public record Alert(String key, String status, String message, String suggestion) {}
}
