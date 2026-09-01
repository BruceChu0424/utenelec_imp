package com.uten.imp.features.production.analysis;

import com.uten.imp.application.port.SubcontractPreparationPort;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import org.junit.jupiter.api.Test;

import java.util.List;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;

import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class SubcontractPreparationAllowedActionsTest {

    @Test
    void startAndOpenAnalysisAreProjectedFromIndependentAuthorities() {
        SubcontractPreparationPort port = mock(SubcontractPreparationPort.class);
        SecurityContextCurrentUser currentUser = mock(SecurityContextCurrentUser.class);
        when(port.tasks(any(), org.mockito.ArgumentMatchers.anyBoolean(),
                org.mockito.ArgumentMatchers.anyBoolean()))
                .thenReturn(new SubcontractPreparationPort.Page(
                        List.of(), 1, 20, 0, 0));

        AuthUser starterWithoutAnalysis = user(Set.of(
                "subcontract_preparation:view",
                "subcontract_preparation:start"));
        when(currentUser.get()).thenReturn(Optional.of(starterWithoutAnalysis));
        SubcontractPreparationCoordinator coordinator =
                new SubcontractPreparationCoordinator(
                        port, mock(MaterialAnalysisService.class),
                        mock(SubcontractPreparationEntitlementHandoffService.class),
                        currentUser);
        UUID sourceAnalysisId = UUID.randomUUID();
        UUID sourceMaterialLineId = UUID.randomUUID();
        coordinator.tasks(1, 20, null, null, null,
                sourceAnalysisId, sourceMaterialLineId);
        verify(port).tasks(org.mockito.ArgumentMatchers.eq(
                        new SubcontractPreparationPort.TaskQuery(
                                1, 20, null, null, null,
                                sourceAnalysisId, sourceMaterialLineId)),
                org.mockito.ArgumentMatchers.eq(true),
                org.mockito.ArgumentMatchers.eq(false));

        AuthUser oldGenericProductionOnly = user(Set.of(
                "production_material_analysis:view",
                "production_material_analysis:create"));
        when(currentUser.get()).thenReturn(Optional.of(oldGenericProductionOnly));
        coordinator.tasks(1, 20, null, null, null, null, null);
        verify(port).tasks(any(), org.mockito.ArgumentMatchers.eq(false),
                org.mockito.ArgumentMatchers.eq(true));
    }

    private static AuthUser user(Set<String> permissions) {
        return new AuthUser(
                UUID.randomUUID(), UUID.randomUUID(), "permission-test",
                Set.of("employee"), permissions,
                false, true, false);
    }
}
