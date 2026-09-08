package com.uten.imp.features.production.analysis;

import com.uten.imp.common.web.ApiException;
import jakarta.validation.Validation;
import org.junit.jupiter.api.Test;
import static org.assertj.core.api.Assertions.assertThat;
import static org.junit.jupiter.api.Assertions.assertThrows;

class MaterialAnalysisOptionalRouteReasonTest {
    @Test
    void reasonCanBeAbsentBlankOrOneCharacter() {
        assertThat(MaterialAnalysisService.normalizeRouteReason(null)).isNull();
        assertThat(MaterialAnalysisService.normalizeRouteReason(" \t\n")).isNull();
        assertThat(MaterialAnalysisService.normalizeRouteReason("  改  ")).isEqualTo("改");
        assertThat(MaterialAnalysisService.normalizeRouteReason("1")).isEqualTo("1");
    }

    @Test
    void nonBlankReasonKeepsTheExistingMaximum() {
        assertThat(MaterialAnalysisService.normalizeRouteReason("理".repeat(1000))).hasSize(1000);
        assertThrows(ApiException.class,
                () -> MaterialAnalysisService.normalizeRouteReason("理".repeat(1001)));
    }

    @Test
    void routeDecisionContractAcceptsOptionalReasonButRejectsOversizedInput() {
        try (var factory = Validation.buildDefaultValidatorFactory()) {
            var validator = factory.getValidator();
            for (String reason : new String[]{null, " ", "1", "理".repeat(1000)}) {
                assertThat(validator.validate(new MaterialAnalysisContracts.RouteDecision(
                        null, "material-group", "MAKE", reason))).isEmpty();
            }
            assertThat(validator.validate(new MaterialAnalysisContracts.RouteDecision(
                    null, "material-group", "MAKE", "理".repeat(1001))))
                    .anyMatch(violation -> violation.getPropertyPath().toString().equals("reason"));
        }
    }
}
