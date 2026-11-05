package com.uten.imp.features.production.analysis;

import com.uten.imp.features.production.ProductionDocumentAccessPolicy;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.List;
import java.util.Map;
import java.util.UUID;

import static com.uten.imp.features.production.analysis.AggregateMaterialOrderContracts.*;
import static com.uten.imp.features.production.analysis.MaterialAnalysisContracts.AnalysisView;
import static com.uten.imp.features.production.analysis.MaterialAnalysisContracts.MaterialView;
import static com.uten.imp.features.production.analysis.MaterialAnalysisContracts.ProductView;
import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.*;

/** Stock already assigned to demand never becomes a second private order allocation. */
class MaterialAnalysisCoveredStockOrderTest {
    @Test void coveredSourceOrdersExplicitPublicStockWithoutChangingItsExistingInventoryBinding() {
        var fixture = fixture(true);
        var result = fixture.service().resolve(fixture.analysisId(), fixture.request(), fixture.view()).groups().getFirst();
        assertThat(result.blockedReason()).isNull();
        assertThat(result.publicExtraQty()).isEqualByComparingTo("5");
        assertThat(result.sources()).allSatisfy(source -> assertThat(source.allocatedQty()).isZero());
        assertThat(fixture.material().allocatedAvailableQty()).isEqualByComparingTo("1000");
        assertThat(fixture.material().actionable()).isFalse();
    }

    @Test void coveredPurchaseStillRequiresIndependentPublicStockPermission() {
        var fixture = fixture(false);
        var result = fixture.service().resolve(fixture.analysisId(), fixture.request(), fixture.view()).groups().getFirst();
        assertThat(result.blockedReason()).contains("超量下达权限");
        assertThat(result.publicExtraQty()).isEqualByComparingTo("5");
    }

    private record Fixture(UUID analysisId, MaterialView material, AnalysisView view,
                           PreviewRequest request, AggregateMaterialOrderPreviewService service) { }

    private static Fixture fixture(boolean canOverSupply) {
        UUID analysisId = UUID.randomUUID(), warehouse = UUID.randomUUID(), sourceId = UUID.randomUUID();
        MaterialView material = mock(MaterialView.class);
        when(material.materialLineId()).thenReturn(UUID.randomUUID());
        when(material.analysisLineId()).thenReturn(sourceId);
        when(material.goodsId()).thenReturn(UUID.randomUUID());
        when(material.unitId()).thenReturn(UUID.randomUUID());
        when(material.nodeKey()).thenReturn("stock-covered");
        when(material.path()).thenReturn(List.of("产品", "已齐套采购件"));
        when(material.goodsName()).thenReturn("已齐套采购件");
        when(material.sourceConfirmed()).thenReturn("BUY");
        when(material.routeConfirmed()).thenReturn(true);
        when(material.controlStage()).thenReturn("START");
        when(material.level()).thenReturn(1);
        when(material.requiredQty()).thenReturn(new BigDecimal("1000"));
        when(material.sourceRequiredQty()).thenReturn(new BigDecimal("1000"));
        when(material.allocatedAvailableQty()).thenReturn(new BigDecimal("1000"));
        when(material.planningUncoveredQty()).thenReturn(BigDecimal.ZERO);
        when(material.shortageQty()).thenReturn(BigDecimal.ZERO);
        when(material.safetyStockQty()).thenReturn(BigDecimal.ZERO);
        when(material.mainWarehousePublicAvailableQty()).thenReturn(BigDecimal.ZERO);
        when(material.mainWarehouseOpenSafetySupplyQty()).thenReturn(BigDecimal.ZERO);
        when(material.mainWarehouseSafetyReplenishmentGapQty()).thenReturn(BigDecimal.ZERO);
        when(material.downstreamReferences()).thenReturn(List.of());
        ProductView product = mock(ProductView.class);
        when(product.analysisLineId()).thenReturn(sourceId);
        when(product.sourceType()).thenReturn("SALES");
        when(product.unitRate()).thenReturn(BigDecimal.ONE);
        String fingerprint = "a".repeat(64);
        var view = new AnalysisView(analysisId, "PARTIALLY_PLANNED", 13, fingerprint, fingerprint, warehouse,
                List.of(warehouse), null, List.of(product), List.of(material), List.of(), List.of(), List.of(),
                false, null, Map.of(), 0, 0, 0, Map.of(), null);
        var group = new GroupInput("covered-stock", List.of(material.materialLineId()), "BUY", new BigDecimal("5"),
                true, null, null, null, null, null, null, null, null);
        var request = new PreviewRequest(13L, fingerprint, "covered-stock-preview", warehouse,
                LocalDate.of(2026, 11, 4), LocalDate.of(2026, 11, 4), false, List.of(group));
        var access = mock(ProductionDocumentAccessPolicy.class);
        when(access.hasAuthority(anyString())).thenAnswer(call ->
                !"production_material_analysis:over_supply".equals(call.getArgument(0)) || canOverSupply);
        return new Fixture(analysisId, material, view, request,
                new AggregateMaterialOrderPreviewService(null, access, mock(AggregateMaterialBatchLookup.class)));
    }
}
