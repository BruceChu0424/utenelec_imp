package com.uten.imp.features.companyfiles;

import com.uten.imp.common.util.NumericColumnFilter;
import com.uten.imp.common.web.ApiException;
import org.junit.jupiter.api.Test;
import java.math.BigDecimal;
import java.time.Instant;
import java.util.Map;
import static org.assertj.core.api.Assertions.*;

class CompanyFileHeaderQueryTest {
    @Test void decimalCursorPredicatesKeepExactValuesAndUnknowns() {
        assertThat(NumericColumnFilter.parse("9007199254740993").matches(new BigDecimal("9007199254740993.00"))).isTrue();
        assertThat(NumericColumnFilter.parse("9007199254740993").matches(new BigDecimal("9007199254740992"))).isFalse();
        assertThat(NumericColumnFilter.parse("!=0").matches(null)).isFalse();
        for (String query : new String[]{">=12", ">11.9", "<=12", "<12.1", "!=0", "11..12"})
            assertThat(NumericColumnFilter.parse(query).matches(new BigDecimal("12"))).as(query).isTrue();
    }

    @Test void filtersMatchActualFieldsAndChineseCalendarBoundaries() {
        var query = new CompanyFileHeaderQuery(Map.of("name", "采购 模板", "kind", "file", "type", "pdf",
                "size", ">=12", "updatedBy", "陈晓 10001", "updated", "2026-10-28"));
        Instant time = Instant.parse("2026-10-27T16:00:00Z");
        assertThat(query.matches("FILE", "采购内部模板.PDF", 12L, "陈晓(10001)", time)).isTrue();
        assertThat(query.matches("FILE", "采购内部模板.PDF", null, "陈晓(10001)", time)).isFalse();
        assertThat(query.matches("FILE", "采购内部模板.PDF", 12L, "陈晓(10001)", time.minusSeconds(1))).isFalse();
        assertThat(query.matches("FILE", "采购内部模板.PDF", 12L, "陈晓(10001)", time.plusSeconds(86400))).isFalse();
        assertThat(new CompanyFileHeaderQuery(Map.of("type", "pdf")).matches("FOLDER", "采购.PDF", null, "", time)).isFalse();
        assertThat(new CompanyFileHeaderQuery(Map.of("type", "文件夹")).matches("FOLDER", "采购.PDF", null, "", time)).isTrue();
    }

    @Test void invalidOrUndeclaredConditionsAreRejected() {
        for (Map<String, String> terms : java.util.List.of(Map.of("attachmentId", "secret"), Map.of("kind", "all"),
                Map.of("size", "1 KB"), Map.of("updated", "2026-02-30")))
            assertThatThrownBy(() -> new CompanyFileHeaderQuery(terms)).isInstanceOf(ApiException.class);
    }
}
