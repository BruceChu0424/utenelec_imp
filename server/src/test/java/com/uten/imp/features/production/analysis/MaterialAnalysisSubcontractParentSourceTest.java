package com.uten.imp.features.production.analysis;

import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.util.List;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

class MaterialAnalysisSubcontractParentSourceTest {
    @Test void rootEdgeUsesItsSourceGoodsInsteadOfTheStoredParentHint() {
        UUID root = UUID.randomUUID();
        UUID storedParent = UUID.randomUUID();
        assertThat(MaterialAnalysisService.materialParentGoodsId(row(1, null), source(root))).isEqualTo(root);
        assertThat(MaterialAnalysisService.materialParentGoodsId(row(1, storedParent), source(root))).isEqualTo(root);
        assertThat(MaterialAnalysisService.materialParentGoodsId(row(2, storedParent), source(root))).isEqualTo(storedParent);
    }

    @Test void approvedSupplyIsBoundToTheSourceAndDirectChildPath() {
        UUID first = UUID.randomUUID();
        UUID second = UUID.randomUUID();
        UUID goods = UUID.randomUUID();
        var rules = MaterialAnalysisService.subcontractSupplyRules(List.of(
                supply(first, "child", goods, "1100"),
                supply(second, "child", goods, "1200"),
                supply(first, "parent/child", goods, "1250")));

        assertThat(rules.keySet()).containsExactlyInAnyOrder(
                first + "|child", second + "|child", first + "|parent/child");
        assertThat(required(rules.get(first + "|child"))).isEqualByComparingTo("1100");
        assertThat(required(rules.get(second + "|child"))).isEqualByComparingTo("1200");
        assertThat(required(rules.get(first + "|parent/child"))).isEqualByComparingTo("1250");
        assertThat(required(rules.getOrDefault(second + "|parent/child", SubcontractMaterialSupplyRequirement.NONE)))
                .isEqualByComparingTo("1000");
    }

    private static SubcontractComponentCustodyProjection.ChildCoverage supply(
            UUID source, String path, UUID goods, String approvedMaterial) {
        return new SubcontractComponentCustodyProjection.ChildCoverage(source, path, UUID.randomUUID(), goods,
                null, BigDecimal.ZERO, new BigDecimal("1000"), new BigDecimal(approvedMaterial), new BigDecimal("1000"));
    }

    private static BigDecimal required(SubcontractMaterialSupplyRequirement rule) {
        return rule.required(new BigDecimal("1000"), BigDecimal.ONE,
                MaterialConsumptionMath.PER_UNIT, BigDecimal.ONE, true);
    }

    private static MaterialAnalysisService.MaterialRow row(int depth, UUID parent) {
        var row = mock(MaterialAnalysisService.MaterialRow.class);
        when(row.depth()).thenReturn(depth);
        when(row.parentGoodsId()).thenReturn(parent);
        return row;
    }

    private static MaterialAnalysisService.SourceLine source(UUID goods) {
        var source = mock(MaterialAnalysisService.SourceLine.class);
        when(source.goodsId()).thenReturn(goods);
        return source;
    }
}
