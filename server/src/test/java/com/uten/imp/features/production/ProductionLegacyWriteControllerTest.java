package com.uten.imp.features.production;

import com.uten.imp.audit.AuditDetailViewRecorder;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.production.mrp.MrpController;
import com.uten.imp.features.production.mrp.MrpService;
import com.uten.imp.features.production.mrp.ProductionPlanningDraftService;
import com.uten.imp.features.production.mrp.ProductionPlanningPackageService;
import com.uten.imp.features.production.plan.ProductionPlanController;
import com.uten.imp.features.production.plan.ProductionPlanService;
import com.uten.imp.features.production.schedule.ProductionScheduleController;
import com.uten.imp.features.production.schedule.ProductionScheduleService;
import org.junit.jupiter.api.Test;
import org.springframework.web.bind.annotation.PostMapping;

import java.util.HashSet;
import java.util.List;
import java.util.Set;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verifyNoInteractions;

class ProductionLegacyWriteControllerTest {

    @Test
    void mrpWriteSurfaceKeepsCurrentPackageRouteAndRemovesLegacySubplanRoutes() {
        Set<String> routes = new HashSet<>();
        for (var method : MrpController.class.getDeclaredMethods()) {
            PostMapping mapping = method.getAnnotation(PostMapping.class);
            if (mapping != null) {
                routes.addAll(List.of(mapping.value()));
            }
        }

        assertThat(routes)
                .contains("/{id}/mrp/generate-planning-package")
                .doesNotContain(
                        "/{id}/mrp/generate-subplan",
                        "/{id}/mrp/generate-subplans");
    }

    @Test
    void directPlanCreateIsPermanentlyRejectedWithoutCallingTheService() {
        ProductionPlanService service = mock(ProductionPlanService.class);
        ProductionPlanController controller = new ProductionPlanController(
                service, mock(AuditDetailViewRecorder.class));

        ApiException error = assertThrows(ApiException.class,
                () -> controller.create(null));

        assertThat(error.getCode()).isEqualTo(ErrorCode.CONFLICT);
        assertThat(error.getCode().getHttpStatus()).isEqualTo(409);
        verifyNoInteractions(service);
    }

    @Test
    void bottomUpFullTreeHttpWriteIsPermanentlyRejected() {
        MrpService mrp = mock(MrpService.class);
        ProductionPlanningPackageService packages =
                mock(ProductionPlanningPackageService.class);
        ProductionPlanningDraftService drafts = mock(ProductionPlanningDraftService.class);
        MrpController controller = new MrpController(mrp, packages, drafts);

        ApiException error = assertThrows(ApiException.class,
                () -> controller.generatePlanningPackageFullTree(UUID.randomUUID(), null));

        assertThat(error.getCode()).isEqualTo(ErrorCode.CONFLICT);
        assertThat(error.getCode().getHttpStatus()).isEqualTo(409);
        verifyNoInteractions(mrp, packages, drafts);
    }

    @Test
    void legacyMergePlanHttpWriteIsPermanentlyRejected() {
        ProductionScheduleService service = mock(ProductionScheduleService.class);
        ProductionScheduleController controller = new ProductionScheduleController(service);

        ApiException error = assertThrows(ApiException.class,
                () -> controller.mergePlan(null));

        assertThat(error.getCode()).isEqualTo(ErrorCode.CONFLICT);
        assertThat(error.getCode().getHttpStatus()).isEqualTo(409);
        verifyNoInteractions(service);
    }
}
