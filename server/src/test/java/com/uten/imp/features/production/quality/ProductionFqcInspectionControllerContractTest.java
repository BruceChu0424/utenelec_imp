package com.uten.imp.features.production.quality;

import com.uten.imp.features.production.quality.ProductionFqcContracts.DecisionRequest;
import com.uten.imp.features.production.quality.ProductionFqcContracts.PassAllBatchRequest;
import org.junit.jupiter.api.Test;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestMapping;

import java.lang.reflect.Method;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;

class ProductionFqcInspectionControllerContractTest {

    @Test
    void controllerUsesDedicatedViewAndApproveAuthorities() throws Exception {
        RequestMapping mapping = ProductionFqcInspectionController.class
                .getAnnotation(RequestMapping.class);
        assertThat(mapping.value())
                .containsExactly("/api/production/quality-inspections");

        Method list = ProductionFqcInspectionController.class
                .getDeclaredMethod(
                        "list", String.class, String.class,
                        int.class, int.class);
        Method capability = ProductionFqcInspectionController.class
                .getDeclaredMethod("capability");
        Method detail = ProductionFqcInspectionController.class
                .getDeclaredMethod("detail", UUID.class);
        Method decide = ProductionFqcInspectionController.class
                .getDeclaredMethod("decide", UUID.class, DecisionRequest.class);
        Method passAll = ProductionFqcInspectionController.class
                .getDeclaredMethod("passAll", PassAllBatchRequest.class);

        assertThat(list.getAnnotation(GetMapping.class)).isNotNull();
        assertThat(detail.getAnnotation(GetMapping.class)).isNotNull();
        assertThat(capability.getAnnotation(GetMapping.class).value())
                .containsExactly("/capability");
        assertThat(list.getAnnotation(PreAuthorize.class).value())
                .isEqualTo("hasAuthority('production_quality_inspection:view')");
        assertThat(detail.getAnnotation(PreAuthorize.class).value())
                .isEqualTo("hasAuthority('production_quality_inspection:view')");
        assertThat(capability.getAnnotation(PreAuthorize.class).value())
                .isEqualTo("hasAuthority('production_quality_inspection:view')");
        assertThat(decide.getAnnotation(PostMapping.class).value())
                .containsExactly("/{id}/decisions");
        assertThat(decide.getAnnotation(PreAuthorize.class).value())
                .contains("production_quality_inspection:view")
                .contains("production_quality_inspection:approve");
        assertThat(passAll.getAnnotation(PostMapping.class).value())
                .containsExactly("/decisions/pass-all");
        assertThat(passAll.getAnnotation(PreAuthorize.class).value())
                .contains("production_quality_inspection:view")
                .contains("production_quality_inspection:approve");
    }
}
