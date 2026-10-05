package com.uten.imp.features.admin.systemtest;

import java.time.Duration;

/**
 * Time limits of one "clear business data" request (ADR-155).
 *
 * @param filesBudget        the single deadline: from acceptance, the file phase (check before draining,
 *                           draining, locked check and deletion) must finish within it
 * @param precheckInspection storage check limit before draining; what is not checked yet is checked
 *                           again under the locks before anything is deleted
 * @param previewInspection  storage check limit of the dialog preview (below the 45s gateway limit)
 * @param drainTimeout       wait for in-flight requests
 * @param resetLockTimeout   lock wait inside the reset transaction
 */
public record BusinessDataResetTimings(Duration filesBudget, Duration precheckInspection, Duration previewInspection,
                                       Duration drainTimeout, Duration resetLockTimeout) {
    public static final BusinessDataResetTimings DEFAULT = new BusinessDataResetTimings(
            Duration.ofMinutes(5), Duration.ofSeconds(60), Duration.ofSeconds(20),
            Duration.ofSeconds(45), Duration.ofSeconds(15));
}
