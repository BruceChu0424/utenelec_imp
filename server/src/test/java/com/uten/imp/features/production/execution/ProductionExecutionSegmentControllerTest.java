package com.uten.imp.features.production.execution;

import jakarta.validation.Validation;
import org.junit.jupiter.api.Test;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.PostMapping;

import java.lang.reflect.Method;
import java.util.Collections;
import java.util.List;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class ProductionExecutionSegmentControllerTest {

    @Test
    void batchStartUsesTheStartAuthorityAndDelegatesTheExactRequest()
            throws Exception {
        ProductionExecutionSegmentService service =
                mock(ProductionExecutionSegmentService.class);
        ProductionExecutionSegmentController controller =
                new ProductionExecutionSegmentController(service);
        UUID planId = UUID.randomUUID();
        BatchStartRequest request = new BatchStartRequest(List.of(
                new BatchStartRequest.Item(
                        UUID.randomUUID(), 3L, "batch-start-key-0001")));
        when(service.batchStart(planId, request)).thenReturn(List.of());

        assertThat(controller.batchStart(planId, request)).isEmpty();
        verify(service).batchStart(planId, request);

        Method method = ProductionExecutionSegmentController.class
                .getDeclaredMethod(
                        "batchStart", UUID.class, BatchStartRequest.class);
        assertThat(method.getAnnotation(PostMapping.class).value())
                .containsExactly("/batch-start");
        assertThat(method.getAnnotation(PreAuthorize.class).value())
                .isEqualTo("hasAuthority('production_execution:start')");
    }

    @Test
    void batchStartRequestEnforcesNestedFieldsAndOneHundredItemLimit() {
        try (var factory = Validation.buildDefaultValidatorFactory()) {
            var validator = factory.getValidator();
            BatchStartRequest.Item valid = new BatchStartRequest.Item(
                    UUID.randomUUID(), 1L, "batch-start-key-0002");

            assertThat(validator.validate(
                    new BatchStartRequest(List.of(valid)))).isEmpty();
            assertThat(validator.validate(new BatchStartRequest(
                    Collections.nCopies(100, valid)))).isEmpty();
            assertThat(validator.validate(
                    new BatchStartRequest(List.of()))).isNotEmpty();
            assertThat(validator.validate(new BatchStartRequest(
                    Collections.nCopies(101, valid)))).isNotEmpty();

            var nested = validator.validate(new BatchStartRequest(List.of(
                    new BatchStartRequest.Item(null, null, "short"))));
            assertThat(nested)
                    .extracting(violation -> violation.getPropertyPath().toString())
                    .anyMatch(path -> path.endsWith("segmentId"))
                    .anyMatch(path -> path.endsWith("expectedVersion"))
                    .anyMatch(path -> path.endsWith("idempotencyKey"));
        }
    }
}
