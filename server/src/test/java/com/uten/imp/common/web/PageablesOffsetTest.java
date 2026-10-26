package com.uten.imp.common.web;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.CsvSource;
import org.junit.jupiter.params.provider.MethodSource;
import org.springframework.data.domain.Sort;

import java.util.stream.Stream;

import static org.assertj.core.api.Assertions.*;

class PageablesOffsetTest {
    @ParameterizedTest
    @CsvSource({
            "1,100,0", "2,100,100", "2,200,200", "2,500,500", "100000,100,9999900",
            "2,2147483647,2147483647", "2147483648,1,2147483647",
            "-2147483648,2147483647,0", "2,-2147483648,1", "0,0,0"
    })
    void retainsTheActualPageAndTheCallersDifferentSizePolicies(long page, long size, int expected) {
        assertThat(Pageables.checkedOffset(page, size)).isEqualTo(expected);
    }

    static Stream<long[]> unrepresentablePages() {
        return Stream.of(new long[]{2, 2147483648L}, new long[]{2147483649L, 1},
                new long[]{Integer.MAX_VALUE, Integer.MAX_VALUE}, new long[]{Long.MAX_VALUE, 2},
                new long[]{Long.MAX_VALUE, Long.MAX_VALUE});
    }

    @ParameterizedTest
    @MethodSource("unrepresentablePages")
    void refusesIntOrLongOverflowWith422InsteadOfWrappingOrClamping(long[] pageAndSize) {
        assertThatThrownBy(() -> Pageables.checkedOffset(pageAndSize[0], pageAndSize[1]))
                .isInstanceOfSatisfying(ApiException.class, error -> {
                    assertThat(error.getCode()).isEqualTo(ErrorCode.VALIDATION_FAILED);
                    assertThat(error.getCode().getHttpStatus()).isEqualTo(422);
                });
    }

    @Test void regularPageConstructionKeepsItsOriginalNormalizationAndSqlLongOffsetContract() {
        var first = Pageables.of(Integer.MIN_VALUE, Integer.MAX_VALUE);
        assertThat(first.getPageNumber()).isZero();
        assertThat(first.getPageSize()).isEqualTo(100);
        var deepSqlPage = Pageables.of(Integer.MAX_VALUE, 100, Sort.by("id"));
        assertThat(deepSqlPage.getOffset()).isEqualTo(214748364600L);
        assertThat(deepSqlPage.getSort()).isEqualTo(Sort.by("id"));
    }
}
