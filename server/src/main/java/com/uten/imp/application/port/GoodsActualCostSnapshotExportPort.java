package com.uten.imp.application.port;

/** Publishes the inspected cost snapshot through the owning master-data authority. */
public interface GoodsActualCostSnapshotExportPort {
    void streamExport(GoodsActualCostQueryPort.Query query, String expectedDigest, int perSectionLimit);
}
