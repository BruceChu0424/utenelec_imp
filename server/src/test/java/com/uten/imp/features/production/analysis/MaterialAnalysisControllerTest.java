package com.uten.imp.features.production.analysis;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.production.mrp.GoodsWorkshopPreferenceView;
import com.uten.imp.features.production.mrp.ProductionGoodsWorkshopPreferenceService;
import org.junit.jupiter.api.Test;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.GetMapping;

import java.lang.reflect.Method;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Set;
import java.util.UUID;
import java.util.stream.Collectors;
import java.util.stream.IntStream;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.when;

class MaterialAnalysisControllerTest {

    @Test
    void defaultWorkshopLookupUsesProductionPermissionAndPreferenceService()
            throws Exception {
        ProductionGoodsWorkshopPreferenceService preferences =
                mock(ProductionGoodsWorkshopPreferenceService.class);
        MaterialAnalysisController controller = new MaterialAnalysisController(
                mock(MaterialAnalysisService.class),
                mock(MaterialAnalysisCommandService.class),
                mock(MaterialStockReallocationService.class),
                preferences,
                mock(MaterialAnalysisSupplyProgressService.class),
                mock(com.uten.imp.audit.AuditDetailViewRecorder.class));
        UUID goodsId = UUID.randomUUID();
        UUID workshopId = UUID.randomUUID();
        Set<UUID> goodsIds = Set.of(goodsId);
        List<GoodsWorkshopPreferenceView> expected = List.of(
                new GoodsWorkshopPreferenceView(
                        goodsId, workshopId, "注塑车间"));
        when(preferences.findValidByGoodsIds(goodsIds)).thenReturn(expected);

        assertThat(controller.defaultWorkshops(goodsIds)).isEqualTo(expected);
        verify(preferences).findValidByGoodsIds(goodsIds);

        Method method = MaterialAnalysisController.class.getDeclaredMethod(
                "defaultWorkshops", Set.class);
        assertThat(method.getAnnotation(GetMapping.class).value())
                .containsExactly("/default-workshops");
        assertThat(method.getAnnotation(PreAuthorize.class).value())
                .isEqualTo(
                        "hasAuthority('production_material_analysis:view')");
    }

    @Test
    void defaultWorkshopLookupRejectsEmptyAndMoreThanTwoHundredIds() {
        ProductionGoodsWorkshopPreferenceService preferences =
                mock(ProductionGoodsWorkshopPreferenceService.class);
        MaterialAnalysisController controller = new MaterialAnalysisController(
                mock(MaterialAnalysisService.class),
                mock(MaterialAnalysisCommandService.class),
                mock(MaterialStockReallocationService.class),
                preferences,
                mock(MaterialAnalysisSupplyProgressService.class),
                mock(com.uten.imp.audit.AuditDetailViewRecorder.class));
        Set<UUID> oversized = IntStream.range(0, 201)
                .mapToObj(ignored -> UUID.randomUUID())
                .collect(Collectors.toCollection(LinkedHashSet::new));

        assertThatThrownBy(() -> controller.defaultWorkshops(Set.of()))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("1-200");
        assertThatThrownBy(() -> controller.defaultWorkshops(oversized))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("1-200");
        verifyNoInteractions(preferences);
    }

    @Test
    void previewAndCancelUseSplitActionAuthorities() throws Exception {
        Method preview = MaterialAnalysisController.class.getDeclaredMethod(
                "preview",
                MaterialAnalysisContracts.PreviewRequest.class);
        String previewGuard = preview.getAnnotation(PreAuthorize.class).value();
        assertThat(previewGuard)
                .contains("#request.analysisId == null")
                .contains("production_material_analysis:create")
                .contains("#request.analysisId != null")
                .contains("production_material_analysis:refresh")
                .doesNotContain("production_material_analysis:manage");

        Method cancel = MaterialAnalysisController.class.getDeclaredMethod(
                "cancelAnalysis",
                UUID.class,
                MaterialAnalysisContracts.CancelRequest.class);
        assertThat(cancel.getAnnotation(PreAuthorize.class).value())
                .isEqualTo(
                        "hasAuthority('production_material_analysis:cancel')");
    }
}
