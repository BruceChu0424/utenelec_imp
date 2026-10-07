package com.uten.imp.application.port;

import java.util.UUID;

/** Releases existing FQC PASS facts after the exact excess-output slice is authorized. */
public interface ProductionOverLimitReleasePort {
    /**
     * Called in the disposition approval transaction, after source mutation locks have been
     * acquired. No quality decision or stock receipt is invented; an uninspected slice has
     * nothing to release, and repeating the call never releases an existing PASS twice.
     */
    void releasePendingForReportItem(UUID sourceReportItemId);
}
