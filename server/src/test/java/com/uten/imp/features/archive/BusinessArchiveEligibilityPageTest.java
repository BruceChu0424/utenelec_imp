package com.uten.imp.features.archive;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;

import com.fasterxml.jackson.databind.ObjectMapper;
import java.util.stream.Stream;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.Arguments;
import org.junit.jupiter.params.provider.MethodSource;
import org.mockito.ArgumentCaptor;
import org.springframework.jdbc.core.JdbcTemplate;

class BusinessArchiveEligibilityPageTest {
    @ParameterizedTest
    @MethodSource("pagingCases")
    void boundedPagesBindTheCorrectOffsetWithoutIntegerWraparound(
            int page, int size, int expectedSize, long expectedOffset) {
        var jdbc = mock(JdbcTemplate.class);
        var service = new BusinessArchiveEligibilityService(jdbc, new ObjectMapper(), 24);

        service.eligibilityPage("PURCHASE_ORDER", null, page, size);

        var parameters = ArgumentCaptor.forClass(Object[].class);
        verify(jdbc).queryForList(anyString(), parameters.capture());
        var bound = parameters.getValue();
        assertEquals(expectedSize, ((Number) bound[bound.length - 2]).intValue());
        assertEquals(expectedOffset, ((Number) bound[bound.length - 1]).longValue());
    }

    static Stream<Arguments> pagingCases() {
        return Stream.of(
                Arguments.of(Integer.MIN_VALUE, 1, 1, 0L),
                Arguments.of(-1, 100, 100, 0L),
                Arguments.of(0, 100, 100, 0L),
                Arguments.of(1, 100, 100, 0L),
                Arguments.of(2, 100, 100, 100L),
                Arguments.of(Integer.MAX_VALUE, 100, 100, 214748364600L),
                Arguments.of(2, Integer.MIN_VALUE, 1, 1L),
                Arguments.of(2, Integer.MAX_VALUE, 100, 100L));
    }
}
