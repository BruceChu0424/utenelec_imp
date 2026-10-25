package com.uten.imp.ops;

import org.junit.jupiter.api.Test;

import java.util.List;

import static org.assertj.core.api.Assertions.assertThat;

/** Also catches stale executable classes retained by an incremental build. */
class BusinessDataResetRetirementContractTest {
    @Test
    void compiledApplicationContainsNoRetiredResetImplementation() {
        ClassLoader loader = getClass().getClassLoader();
        for (String type : List.of(
                "features/admin/systemtest/SystemTestController",
                "features/admin/systemtest/BusinessDataResetService",
                "features/admin/systemtest/BusinessDataResetFeatureGate",
                "features/admin/systemtest/BusinessDataResetDrainGate",
                "features/admin/systemtest/BusinessDataResetDrainFilter",
                "features/admin/systemtest/BusinessDataResetWebConfig",
                "features/admin/systemtest/BusinessDataResetTimings",
                "features/admin/systemtest/DrainAwareTaskScheduler",
                "features/attachment/BusinessTestResetFiles",
                "application/port/BusinessDataResetGatePort",
                "application/port/BusinessTestResetFilesPort",
                "common/platformcolumns/RetainedPlatformColumnAdapter",
                "features/ai/job/AiJobWorker$ResetDraining")) {
            assertThat(loader.getResource("com/uten/imp/" + type + ".class"))
                    .as("retired destructive implementation %s", type).isNull();
        }
    }
}
