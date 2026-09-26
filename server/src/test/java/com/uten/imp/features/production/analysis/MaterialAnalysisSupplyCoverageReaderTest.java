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
    void fiveHundredPurchaseGroupsUseFourReadsIncludingRejectionAndCrossRouteCoverage() {
        EntityManager em = mock(EntityManager.class);
        Query empty = query(List.of());
        when(em.createNativeQuery(anyString())).thenReturn(empty);
        List<MaterialAnalysisSupplyCoverageReader.Group> groups = new ArrayList<>();
        for (int i = 0; i < 500; i++) groups.add(new MaterialAnalysisSupplyCoverageReader.Group(
                "node-" + i, "BUY", List.of(UUID.randomUUID())));

        var coverage = new MaterialAnalysisSupplyCoverageReader(em).read(UUID.randomUUID(), groups);

        // 历史别名、本路线在途、IQC 补货在途、跨路线调入——四条固定语句，
        // 与操作组数量无关（500 组仍然是 4 次读）。
        verify(em, times(4)).createNativeQuery(anyString());
        assertThat(coverage.active()).hasSize(500);
        assertThat(coverage.active().values()).allSatisfy(qty -> assertThat(qty).isZero());
    }

    @Test
    void historicalGroupAliasesAreDeduplicatedWithinTheSelectedRoute() {
        EntityManager em = mock(EntityManager.class);
        UUID material = UUID.randomUUID();
        Query aliases = query(List.of(new Object[]{material, "legacy", "BUY",null},
                new Object[]{material, "legacy", "BUY",null}, new Object[]{material, "unrelated", "SUBCONTRACT",null}));
        Query active = query(List.of(new Object[]{"current", new BigDecimal("2")},
                new Object[]{"legacy", new BigDecimal("3")}));
        Query replacement = query(List.of(new Object[]{"current", new BigDecimal("4")},
                new Object[]{"legacy", new BigDecimal("7")}));
        Query crossRoute = query(List.of());
        when(em.createNativeQuery(anyString())).thenReturn(aliases, active, replacement, crossRoute);

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
        Query crossRoute = query(java.util.Collections.emptyList());
        when(em.createNativeQuery(anyString()))
                .thenReturn(aliases, external, preparation, replacement, crossRoute);

        var coverage = new MaterialAnalysisSupplyCoverageReader(em).read(UUID.randomUUID(), List.of(
                new MaterialAnalysisSupplyCoverageReader.Group("sc", "SUBCONTRACT", List.of(UUID.randomUUID()))));

        assertThat(coverage.active("sc", "SUBCONTRACT")).isEqualByComparingTo("7");
        assertThat(coverage.replacement("sc", "SUBCONTRACT")).isEqualByComparingTo("3");
        assertThat(coverage.active("sc", "BUY")).isZero();
        verify(em, times(5)).createNativeQuery(anyString());
    }

    @Test
    void sharedActionCoverageIsReturnedPerMaterialRatherThanCopiedToEveryAlias() {
        EntityManager em=mock(EntityManager.class);
        UUID first=UUID.randomUUID(),second=UUID.randomUUID(),third=UUID.randomUUID(),batch=UUID.randomUUID();
        Query aliases=query(List.of(new Object[]{first,"shared","MAKE",batch},new Object[]{second,"shared","MAKE",batch},new Object[]{third,"shared","MAKE",batch}));
        Query legacy=query(List.of()),cross=query(List.of());
        Query exact=query(List.of(new Object[]{first,new BigDecimal("400")},new Object[]{second,new BigDecimal("1000")},new Object[]{third,new BigDecimal("1000")}));
        when(em.createNativeQuery(anyString())).thenReturn(aliases,legacy,cross,exact);
        var coverage=new MaterialAnalysisSupplyCoverageReader(em).read(UUID.randomUUID(),List.of(
                new MaterialAnalysisSupplyCoverageReader.Group("a","MAKE",List.of(first)),
                new MaterialAnalysisSupplyCoverageReader.Group("b","MAKE",List.of(second)),
                new MaterialAnalysisSupplyCoverageReader.Group("c","MAKE",List.of(third))));
        assertThat(coverage.active("a","MAKE")).isEqualByComparingTo("400");
        assertThat(coverage.active("b","MAKE")).isEqualByComparingTo("1000");
        assertThat(coverage.active("c","MAKE")).isEqualByComparingTo("1000");
        verify(em).createNativeQuery(contains("WITH inherited AS MATERIALIZED"));
        verify(em,times(4)).createNativeQuery(anyString());
    }

    @Test
    void canonicalMaterialIncludesItsExactOldPlanCoverageWithoutInventingAnotherOrder() {
        EntityManager em=mock(EntityManager.class);UUID canonical=UUID.randomUUID();
        Query aliases=query(java.util.Collections.singletonList(new Object[]{canonical,null,null,UUID.randomUUID()}));
        Query legacy=query(List.of()),cross=query(List.of());
        Query inherited=query(java.util.Collections.singletonList(new Object[]{canonical,new BigDecimal("3000")}));
        when(em.createNativeQuery(anyString())).thenReturn(aliases,legacy,cross,inherited);
        var coverage=new MaterialAnalysisSupplyCoverageReader(em).read(UUID.randomUUID(),List.of(
                new MaterialAnalysisSupplyCoverageReader.Group("canonical","MAKE",List.of(canonical))));
        assertThat(coverage.active("canonical","MAKE")).isEqualByComparingTo("3000");
        assertThat(coverage.replacement("canonical","MAKE")).isZero();
    }

    private static Query query(List<Object[]> rows) {
        Query query = mock(Query.class);
        when(query.setParameter(anyString(), any())).thenReturn(query);
        when(query.getResultList()).thenReturn(rows);
        return query;
    }
}
