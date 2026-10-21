package com.uten.imp.features.production.analysis;

import org.junit.jupiter.api.Test;
import java.math.BigDecimal;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

class MaterialAnalysisOptionalTuningTest {
    @Test
    void residualAllocationWithoutBorrowTuningPreservesExistingKitsAndShortage() {
        UUID item = UUID.randomUUID(), goods = UUID.randomUUID(), unit = UUID.randomUUID();
        var source = mock(MaterialAnalysisService.SourceLine.class);
        when(source.analysisItemId()).thenReturn(item);
        var node = new MaterialAnalysisService.BomNode(item, UUID.randomUUID(), UUID.randomUUID(),
                goods, null, unit, 1, "material", null, BigDecimal.ONE, BigDecimal.ONE, BigDecimal.ONE,
                new BigDecimal("6"), "M-1", "material", null, null, "piece", BigDecimal.ZERO,
                "BUY", false, "START", "PER_UNIT", BigDecimal.ONE, true, true);
        var kits = Map.of(item + "|material", new MaterialAnalysisService.NodeAllocation(
                new BigDecimal("2"), new BigDecimal("4")));
        var actual = MaterialAnalysisService.allocateDirectMaterials(List.of(source), Map.of(item, List.of(node)),
                Map.of(node.dimension(), new BigDecimal("3")), kits, null);
        assertThat(actual.get(item + "|material").allocatedQty()).isEqualByComparingTo("5");
        assertThat(actual.get(item + "|material").shortageQty()).isEqualByComparingTo("1");
        assertThat(kits.get(item + "|material").allocatedQty()).isEqualByComparingTo("2");
    }
}
