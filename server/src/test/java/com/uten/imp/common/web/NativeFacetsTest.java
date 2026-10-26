package com.uten.imp.common.web;

import jakarta.persistence.Query;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;

import java.util.Arrays;
import java.util.List;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.Mockito.*;

class NativeFacetsTest {
    @ParameterizedTest @ValueSource(ints = {0, 1, 50, 499, 500, 501, 10_000, Integer.MAX_VALUE})
    void boundsSqlBeforeExecutionWithoutExpandingExistingLimitsOrChangingBucketFacts(int existingLimit) {
        Query query = mock(Query.class);
        when(query.getMaxResults()).thenReturn(existingLimit);
        List<Object[]> rows = existingLimit == 0 ? List.of() : Arrays.asList(
                new Object[]{null, 7L}, new Object[]{"0001. 原文", 123456789012L});
        when(query.getResultList()).thenReturn(rows);

        var result = NativeFacets.rowsOf(query);

        var ordered = inOrder(query);
        ordered.verify(query).getMaxResults();
        ordered.verify(query).setMaxResults(Math.min(existingLimit, TableFacets.DEFAULT_LIMIT));
        ordered.verify(query).getResultList();
        if (existingLimit == 0) assertThat(result).isEmpty();
        else {
            assertThat(result).extracting(row -> row.get("value")).containsExactly("", "0001. 原文");
            assertThat(result).extracting(row -> row.get("label")).containsExactly("", "0001. 原文");
            assertThat(result).extracting(row -> row.get("count")).containsExactly(7L, 123456789012L);
        }
    }
}
