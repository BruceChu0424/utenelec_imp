package com.uten.imp.features.production;

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

import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verifyNoInteractions;

class ProductionLegacyWriteControllerTest {

    @Test
    void directPlanCreateIsPermanentlyRejectedWithoutCallingTheService() {
        ProductionPlanService service = mock(ProductionPlanService.class);
        ProductionPlanController controller = new ProductionPlanController(service);

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
