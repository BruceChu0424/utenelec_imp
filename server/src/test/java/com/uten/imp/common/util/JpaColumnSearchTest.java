package com.uten.imp.common.util;

import com.uten.imp.common.web.ApiException;
import java.math.BigDecimal;
import java.time.OffsetDateTime;
import java.util.Map;
import org.junit.jupiter.api.Test;
import static org.assertj.core.api.Assertions.*;

class JpaColumnSearchTest {
    @Test void calendarPrefixesAndRangesUseWholeChineseBusinessDays() {
        var day = JpaColumnSearch.businessDateBounds("2026-10-28");
        assertThat(day.from().toInstant()).isEqualTo(OffsetDateTime.parse("2026-10-27T16:00:00Z").toInstant());
        assertThat(day.toExclusive().toInstant()).isEqualTo(OffsetDateTime.parse("2026-10-28T16:00:00Z").toInstant());
        var month = JpaColumnSearch.businessDateBounds("2024-02");
        assertThat(java.time.Duration.between(month.from(), month.toExclusive()).toDays()).isEqualTo(29);
        var range = JpaColumnSearch.businessDateBounds("2026-10-01..2026-10-31");
        assertThat(java.time.Duration.between(range.from(), range.toExclusive()).toDays()).isEqualTo(31);
        assertThatThrownBy(() -> JpaColumnSearch.businessDateBounds("2026-10-31..2026-10-01")).isInstanceOf(ApiException.class);
        assertThatThrownBy(() -> JpaColumnSearch.businessDateBounds("2026-02-30")).isInstanceOf(ApiException.class);
        for (String invalid : new String[]{"", "2026-13", "2026-02-29", "2026-10-01..", "2026-10-01;select 1", "+10000-01-01"})
            assertThatThrownBy(() -> JpaColumnSearch.businessDateBounds(invalid)).isInstanceOf(ApiException.class);
        assertThatThrownBy(() -> JpaColumnSearch.businessDateBounds(null)).isInstanceOf(ApiException.class);
        assertThat(JpaColumnSearch.businessDateBounds(" 2026-10-01 .. 2026-10-28 ").toExclusive().toInstant())
                .isEqualTo(java.time.Instant.parse("2026-10-28T16:00:00Z"));
    }

    @Test void nativeSearchUsesBoundEscapedTermsAndExactNumericBoundaries() {
        var criteria = SqlColumnSearch.criteria(
                Map.of("name", "50%_a\\b", "count", ">=9007199254740993.25"),
                Map.of("name", SqlColumnSearch.Field.text("row.name"), "count", SqlColumnSearch.Field.decimal("row.count")));
        assertThat(criteria.predicate()).doesNotContain("9007199254740993", "50%").contains("ESCAPE '\\'");
        assertThat(criteria.parameters().values()).contains(new BigDecimal("9007199254740993.25"), "%50\\%\\_a\\\\b%");
        assertThatThrownBy(() -> SqlColumnSearch.criteria(Map.of("secret", "probe"), Map.of()))
                .isInstanceOf(ApiException.class);
        assertThatThrownBy(() -> JpaColumnSearch.validate(Map.of("count", "NaN"),
                Map.of("count", JpaColumnSearch.Field.decimal("count"))))
                .isInstanceOf(ApiException.class);
    }

    @Test void calendarDateColumnsKeepLocalDatesWhileInstantsUseChineseDayBoundaries() {
        var criteria = SqlColumnSearch.criteria(Map.of("due", "2026-10-28", "created", "2026-10-28"),
                Map.of("due", SqlColumnSearch.Field.calendarDate("t.due_date"),
                        "created", SqlColumnSearch.Field.instant("t.created_at")));
        assertThat(criteria.parameters().values()).contains(java.time.LocalDate.of(2026, 10, 28),
                java.time.LocalDate.of(2026, 10, 29), OffsetDateTime.parse("2026-10-28T00:00:00+08:00"),
                OffsetDateTime.parse("2026-10-29T00:00:00+08:00"));
        assertThat(criteria.predicate()).contains("t.due_date >=", "t.due_date <", "t.created_at >=");
    }
}
