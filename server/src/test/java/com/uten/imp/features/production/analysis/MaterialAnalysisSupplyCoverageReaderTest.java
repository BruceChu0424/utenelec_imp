package com.uten.imp.features.production.analysis;

import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.util.ArrayList;
import java.util.List;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.*;

class MaterialAnalysisSupplyCoverageReaderTest {
    @Test
    void fiveHundredPurchaseGroupsUseThreeReadsIncludingRejectionCoverage() {
        EntityManager em = mock(EntityManager.class);
        Query empty = query(List.of());
        when(em.createNativeQuery(anyString())).thenReturn(empty);
        List<MaterialAnalysisSupplyCoverageReader.Group> groups = new ArrayList<>();
        for (int i = 0; i < 500; i++) groups.add(new MaterialAnalysisSupplyCoverageReader.Group(
                "node-" + i, "BUY", List.of(UUID.randomUUID())));

        var coverage = new MaterialAnalysisSupplyCoverageReader(em).read(UUID.randomUUID(), groups);

        verify(em, times(3)).createNativeQuery(anyString());
        assertThat(coverage.active()).hasSize(500);
        assertThat(coverage.active().values()).allSatisfy(qty -> assertThat(qty).isZero());
    }

    @Test
    void historicalGroupAliasesAreDeduplicatedWithinTheSelectedRoute() {
        EntityManager em = mock(EntityManager.class);
        UUID material = UUID.randomUUID();
        Query aliases = query(List.of(new Object[]{material, "legacy", "BUY"},
                new Object[]{material, "legacy", "BUY"}, new Object[]{material, "unrelated", "SUBCONTRACT"}));
        Query active = query(List.of(new Object[]{"current", new BigDecimal("2")},
                new Object[]{"legacy", new BigDecimal("3")}));
        Query replacement = query(List.of(new Object[]{"current", new BigDecimal("4")},
                new Object[]{"legacy", new BigDecimal("7")}));
        when(em.createNativeQuery(anyString())).thenReturn(aliases, active, replacement);

        var coverage = new MaterialAnalysisSupplyCoverageReader(em).read(UUID.randomUUID(), List.of(
                new MaterialAnalysisSupplyCoverageReader.Group("current", "BUY", List.of(material))));

        assertThat(coverage.active("current", "BUY")).isEqualByComparingTo("5");
        assertThat(coverage.replacement("current", "BUY")).isEqualByComparingTo("4");
        assertThat(coverage.active("current", "SUBCONTRACT")).isZero();
        verify(active).setParameter("groupKeys", java.util.Set.of("current", "legacy"));
    }

    @Test
    void subcontractApplicationAndPreparationCoverageAreAddedWithoutMixingRoutes() {
        EntityManager em = mock(EntityManager.class);
        Query aliases = query(List.of());
        Query external = query(java.util.Collections.singletonList(new Object[]{"sc", new BigDecimal("2")}));
        Query preparation = query(java.util.Collections.singletonList(new Object[]{"sc", new BigDecimal("5")}));
        Query replacement = query(java.util.Collections.singletonList(new Object[]{"sc", new BigDecimal("3")}));
        when(em.createNativeQuery(anyString())).thenReturn(aliases, external, preparation, replacement);

        var coverage = new MaterialAnalysisSupplyCoverageReader(em).read(UUID.randomUUID(), List.of(
                new MaterialAnalysisSupplyCoverageReader.Group("sc", "SUBCONTRACT", List.of(UUID.randomUUID()))));

        assertThat(coverage.active("sc", "SUBCONTRACT")).isEqualByComparingTo("7");
        assertThat(coverage.replacement("sc", "SUBCONTRACT")).isEqualByComparingTo("3");
        assertThat(coverage.active("sc", "BUY")).isZero();
        verify(em, times(4)).createNativeQuery(anyString());
    }

    private static Query query(List<Object[]> rows) {
        Query query = mock(Query.class);
        when(query.setParameter(anyString(), any())).thenReturn(query);
        when(query.getResultList()).thenReturn(rows);
        return query;
    }
}
