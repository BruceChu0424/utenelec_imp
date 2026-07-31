package com.uten.imp.features.production.fulfillment;

import org.junit.jupiter.api.Test;

import java.util.List;

import static org.assertj.core.api.Assertions.assertThat;

class PlanningPackageFingerprintTest {

    @Test
    void isDeterministicOrderIndependentAndSensitiveToSnapshotContent() {
        String first = PlanningPackageFingerprint.sha256(List.of(
                "PLAN|p1",
                "WAREHOUSE|w1",
                "MATERIAL|a|10"));
        String replay = PlanningPackageFingerprint.sha256(List.of(
                "PLAN|p1",
                "WAREHOUSE|w1",
                "MATERIAL|a|10"));
        String changed = PlanningPackageFingerprint.sha256(List.of(
                "WAREHOUSE|w1",
                "PLAN|p1",
                "MATERIAL|a|10"));
        String changedContent = PlanningPackageFingerprint.sha256(List.of(
                "WAREHOUSE|w1",
                "PLAN|p1",
                "MATERIAL|a|11"));

        assertThat(first)
                .hasSize(64)
                .matches("[0-9a-f]{64}")
                .isEqualTo(replay)
                .isEqualTo(changed)
                .isNotEqualTo(changedContent);
    }
}
