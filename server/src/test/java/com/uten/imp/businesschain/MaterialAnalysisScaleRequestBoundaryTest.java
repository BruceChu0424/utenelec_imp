package com.uten.imp.businesschain;

import static com.uten.imp.features.production.analysis.MaterialAnalysisContracts.*;
import static org.junit.jupiter.api.Assertions.*;

import jakarta.validation.Validation;
import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.List;
import java.util.UUID;
import org.junit.jupiter.api.Test;

/** Public request limits are part of the stress scenario, not a reason to bypass controller validation. */
class MaterialAnalysisScaleRequestBoundaryTest {
    @Test
    void fiveHundredSourcesRoutesAndPlanLinesAreAllowedButFiveHundredAndOneAreRejected() {
        try (var factory = Validation.buildDefaultValidatorFactory()) {
            var validator = factory.getValidator();
            UUID warehouse = UUID.randomUUID();
            for (int size : List.of(500, 501)) {
                List<PreviewItem> sources = java.util.stream.IntStream.range(0, size)
                        .mapToObj(n -> new PreviewItem("SALES_ORDER_ITEM", UUID.randomUUID(), null, null, null,
                                null, null, LocalDate.of(2026, 9, 30), BigDecimal.TEN)).toList();
                PreviewRequest preview = new PreviewRequest(null, null, null, warehouse, "boundary-preview", sources);
                RouteRequest routes = new RouteRequest(1L, "a".repeat(64), "boundary-routes",
                        java.util.stream.IntStream.range(0, size)
                                .mapToObj(n -> new RouteDecision(UUID.randomUUID(), null, "MAKE", null)).toList());
                IssueWorkshopPlansRequest issue = new IssueWorkshopPlansRequest(1L, "a".repeat(64), "boundary-issue",
                        warehouse, LocalDate.of(2026, 9, 1), LocalDate.of(2026, 9, 30), true,
                        java.util.stream.IntStream.range(0, size)
                                .mapToObj(n -> new IssueWorkshopPlansRequest.IssuePlanLine(UUID.randomUUID(), BigDecimal.TEN)).toList());
                for (Object request : List.of(preview, routes, issue)) {
                    var violations = validator.validate(request);
                    if (size == 500) assertTrue(violations.isEmpty(), request.getClass().getSimpleName());
                    else assertEquals(1, violations.stream().filter(v -> v.getConstraintDescriptor()
                            .getAnnotation() instanceof jakarta.validation.constraints.Size).count());
                }
            }
        }
    }
}
