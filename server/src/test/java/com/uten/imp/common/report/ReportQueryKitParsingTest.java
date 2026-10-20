package com.uten.imp.common.report;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import org.junit.jupiter.api.Test;

import java.util.List;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class ReportQueryKitParsingTest {
    @Test
    void emptyOptionalFiltersAndExactShortBoundariesRetainTheirMeaning() {
        assertThat(ReportQueryKit.parseShort(null)).isNull();
        assertThat(ReportQueryKit.parseShort(" ")).isNull();
        assertThat(ReportQueryKit.parseShort("-32768")).isEqualTo(Short.MIN_VALUE);
        assertThat(ReportQueryKit.parseShort("32767")).isEqualTo(Short.MAX_VALUE);
    }

    @Test
    void malformedOrOutOfRangeRequestFiltersHaveAnExplicitValidationFailure() {
        for (String value : List.of("32768", "-32769", "not-an-integer", "1.5", " 1 ")) {
            assertThatThrownBy(() -> ReportQueryKit.parseShort(value))
                    .isInstanceOfSatisfying(ApiException.class,
                            failure -> assertThat(failure.getCode()).isEqualTo(ErrorCode.VALIDATION_FAILED));
        }
    }

    @Test
    void requiredFacetIntegersKeepExactBoundsAndRejectMissingOrMalformedValues() {
        assertThat(ReportQueryKit.parseRequiredInt("-2147483648")).isEqualTo(Integer.MIN_VALUE);
        assertThat(ReportQueryKit.parseRequiredInt("2147483647")).isEqualTo(Integer.MAX_VALUE);
        assertThatThrownBy(() -> ReportQueryKit.parseRequiredInt(null))
                .isInstanceOf(ApiException.class);
        for (String value : List.of("", " ", "2147483648", "-2147483649", "1.5", "0 OR 1=1")) {
            assertThatThrownBy(() -> ReportQueryKit.parseRequiredInt(value))
                    .isInstanceOfSatisfying(ApiException.class,
                            failure -> assertThat(failure.getCode()).isEqualTo(ErrorCode.VALIDATION_FAILED));
        }
    }
}
