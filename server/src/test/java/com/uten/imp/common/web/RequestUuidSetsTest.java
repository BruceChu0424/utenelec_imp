package com.uten.imp.common.web;

import org.junit.jupiter.api.Test;

import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class RequestUuidSetsTest {

    @Test
    void parsesDeduplicatedCommaSeparatedUuids() {
        UUID first = UUID.randomUUID();
        UUID second = UUID.randomUUID();

        assertThat(RequestUuidSets.commaSeparated(
                first + ", " + second + "," + first, "货品 ID"))
                .containsExactlyInAnyOrder(first, second);
    }

    @Test
    void rejectsMalformedUuidAsStructuredValidationError() {
        assertThatThrownBy(() -> RequestUuidSets.commaSeparated("probe", "货品 ID"))
                .isInstanceOfSatisfying(ApiException.class, error -> {
                    assertThat(error.getCode()).isEqualTo(ErrorCode.VALIDATION_FAILED);
                    assertThat(error.getMessage()).contains("非法 UUID");
                });
    }
}
