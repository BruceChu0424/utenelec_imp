package com.uten.imp.features.master.client;

import org.junit.jupiter.api.Test;

import java.util.List;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;

class ClientPreviousOwnerVisibilityTest {

    @Test
    void firstOwnerChangeRetainsEligiblePreviousOwnerForExistingDrafts() {
        UUID previous = UUID.randomUUID();
        UUID next = UUID.randomUUID();
        UUID explicitViewer = UUID.randomUUID();

        List<UUID> effective = ClientAccessService.effectiveViewerIds(
                previous, next, List.of(explicitViewer), true);

        assertThat(effective).containsExactlyInAnyOrder(previous, explicitViewer);
    }

    @Test
    void subsequentSameOwnerSaveCanExplicitlyRemoveThePreviousOwner() {
        UUID currentOwner = UUID.randomUUID();
        UUID oldViewer = UUID.randomUUID();

        List<UUID> effective = ClientAccessService.effectiveViewerIds(
                currentOwner, currentOwner, List.of(), true);

        assertThat(effective).doesNotContain(oldViewer).isEmpty();
    }

    @Test
    void resignedOrDisabledPreviousOwnerIsNotRetained() {
        UUID previous = UUID.randomUUID();
        UUID next = UUID.randomUUID();

        List<UUID> effective = ClientAccessService.effectiveViewerIds(
                previous, next, List.of(), false);

        assertThat(effective).isEmpty();
    }

    @Test
    void sameOwnerDoesNotCreateASelfViewer() {
        UUID owner = UUID.randomUUID();

        List<UUID> effective = ClientAccessService.effectiveViewerIds(
                owner, owner, List.of(), true);

        assertThat(effective).isEmpty();
    }
}
