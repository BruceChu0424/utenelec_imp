package com.uten.imp.features.production.analysis;

import com.uten.imp.common.web.ApiException;
import org.junit.jupiter.api.Test;

import java.util.ArrayList;
import java.util.List;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.mockito.Mockito.*;

class MaterialAnalysisRouteGroupIndexTest {
    @Test
    void fiveHundredDecisionsDoNotRehashTheWholeMaterialSet() {
        List<MaterialAnalysisService.MaterialRow> rows = new ArrayList<>();
        for (int i = 0; i < 100; i++) rows.add(row("group-" + i, true));
        var index = MaterialAnalysisService.MaterialGroupIndex.of(rows);

        for (int i = 0; i < 500; i++) {
            var resolved = index.resolve(new MaterialAnalysisContracts.RouteDecision(
                    null, "group-" + i % rows.size(), "BUY", null));
            assertThat(resolved.materials()).containsExactly(rows.get(i % rows.size()));
        }

        rows.forEach(row -> verify(row, times(1)).actionGroupKey());
    }

    @Test
    void representativeResolutionAndInactiveUnknownGuardsKeepTheExistingContract() {
        var active = row("current", true);
        var inactive = row("inactive", false);
        var index = MaterialAnalysisService.MaterialGroupIndex.of(List.of(active, inactive));
        assertThat(index.resolve(new MaterialAnalysisContracts.RouteDecision(active.id(), null, "MAKE", null)).key())
                .isEqualTo("current");
        assertThrows(ApiException.class, () -> index.resolve(
                new MaterialAnalysisContracts.RouteDecision(inactive.id(), null, "MAKE", null)));
        assertThrows(ApiException.class, () -> index.resolve(
                new MaterialAnalysisContracts.RouteDecision(UUID.randomUUID(), null, "MAKE", null)));
        assertThrows(ApiException.class, () -> index.resolve(
                new MaterialAnalysisContracts.RouteDecision(null, "unknown", "MAKE", null)));
        assertThrows(ApiException.class, () -> index.resolve(null));
        verify(inactive, never()).actionGroupKey();
    }

    private static MaterialAnalysisService.MaterialRow row(String key, boolean actionable) {
        var row = mock(MaterialAnalysisService.MaterialRow.class);
        when(row.id()).thenReturn(UUID.randomUUID());
        when(row.actionable()).thenReturn(actionable);
        if (actionable) when(row.actionGroupKey()).thenReturn(key);
        return row;
    }
}
