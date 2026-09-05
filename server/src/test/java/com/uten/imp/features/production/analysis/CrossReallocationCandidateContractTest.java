package com.uten.imp.features.production.analysis;

import com.uten.imp.common.web.PageResponse;
import org.junit.jupiter.api.Test;
import org.springframework.security.access.prepost.PreAuthorize;

import java.lang.reflect.Method;
import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.Arrays;
import java.util.List;
import java.util.UUID;

import static com.uten.imp.features.production.analysis.MaterialAnalysisContracts.CrossReallocationCandidate;
import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class CrossReallocationCandidateContractTest {

    @Test
    void candidateCarriesServerAuthoritativeLendableQtyThroughController()
            throws Exception {
        MaterialStockReallocationService reallocations =
                mock(MaterialStockReallocationService.class);
        MaterialAnalysisController controller = new MaterialAnalysisController(
                mock(MaterialAnalysisService.class),
                mock(MaterialAnalysisCommandService.class),
                reallocations,
                mock(com.uten.imp.features.production.mrp
                        .ProductionGoodsWorkshopPreferenceService.class),
                mock(MaterialAnalysisSupplyProgressService.class),
                mock(SubcontractMakeTaskService.class),
                mock(com.uten.imp.audit.AuditDetailViewRecorder.class));
        UUID sourceAnalysisId = UUID.randomUUID();
        UUID sourceMaterialId = UUID.randomUUID();
        CrossReallocationCandidate candidate = new CrossReallocationCandidate(
                UUID.randomUUID(), 7L, "b".repeat(64), UUID.randomUUID(),
                UUID.randomUUID(), "主仓", "计划B", "产品B",
                LocalDate.of(2026, 9, 3), new BigDecimal("6.5"),
                new BigDecimal("4"));
        PageResponse<CrossReallocationCandidate> expected = new PageResponse<>(
                List.of(candidate), 1, 20, 1, 1);
        when(reallocations.candidates(
                sourceAnalysisId, sourceMaterialId, "计划B", 1, 20))
                .thenReturn(expected);

        PageResponse<CrossReallocationCandidate> result =
                controller.crossReallocationCandidates(
                        sourceAnalysisId, sourceMaterialId, "计划B", 1, 20);

        assertThat(result).isSameAs(expected);
        assertThat(result.getItems()).singleElement()
                .extracting(CrossReallocationCandidate::sourceLendableQty)
                .isEqualTo(new BigDecimal("6.5"));
        assertThat(Arrays.stream(
                CrossReallocationCandidate.class.getRecordComponents())
                .map(component -> component.getName()))
                .containsSubsequence(
                        "deliveryDate", "sourceLendableQty", "shortageQty");
        verify(reallocations).candidates(
                sourceAnalysisId, sourceMaterialId, "计划B", 1, 20);
        Method method = MaterialAnalysisController.class.getDeclaredMethod(
                "crossReallocationCandidates", UUID.class, UUID.class,
                String.class, int.class, int.class);
        assertThat(method.getAnnotation(PreAuthorize.class).value())
                .isEqualTo(
                        "hasAuthority('production_material_analysis:view') and "
                                + "hasAuthority('production_material_analysis:cross_reallocate')");
    }
}
