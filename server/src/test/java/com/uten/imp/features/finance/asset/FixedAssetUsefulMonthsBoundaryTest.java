package com.uten.imp.features.finance.asset;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import org.junit.jupiter.api.Test;
import org.springframework.test.util.ReflectionTestUtils;
import java.math.BigDecimal;
import java.util.Map;
import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class FixedAssetUsefulMonthsBoundaryTest {
    @Test
    void usefulMonthsCannotSilentlyTruncateFractionalOrOverflowingInputs() {
        for (Object value : new Object[]{new BigDecimal("12.5"), 2147483648L, "NaN", "1e9999999999"}) {
            assertThatThrownBy(() -> ReflectionTestUtils.invokeMethod(FixedAssetService.class,
                    "num", Map.of("usefulMonths", value), "usefulMonths"))
                    .isInstanceOfSatisfying(ApiException.class,
                            error -> assertThat(error.getCode()).isEqualTo(ErrorCode.VALIDATION_FAILED));
        }
        assertThat(ReflectionTestUtils.<Integer>invokeMethod(FixedAssetService.class,
                "num", Map.of("usefulMonths", new BigDecimal("12.000")), "usefulMonths"))
                .isEqualTo(12);
    }
}
