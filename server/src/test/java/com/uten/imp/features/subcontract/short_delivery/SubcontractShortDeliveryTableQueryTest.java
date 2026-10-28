package com.uten.imp.features.subcontract.short_delivery;

import com.uten.imp.common.web.ApiException;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;
import java.math.BigDecimal;
import java.util.Map;
import java.util.List;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.*;

class SubcontractShortDeliveryTableQueryTest {
    @Test void requestKeysSelectDeclaredFiltersAndPreserveLongTextExactValuesAndFacetExclusion() {
        String requested=new String("f.status".toCharArray());
        String text="x".repeat(500);
        var headers=new SubcontractShortDeliveryTableQuery(Map.of(requested,"PENDING_OWNER",
                "search.goodsName",text,"search.shortfallQty",">=0.0000000001"));
        assertThat(headers.filters().keySet().stream().filter(key->key.equals(requested)).findFirst().orElseThrow())
                .isNotSameAs(requested);
        assertThat(headers.sql(null)).contains(":short_header_status",":short_header_goodsName",":short_header_shortfallQty")
                .doesNotContain(text,"0.0000000001");
        var bound=mock(Query.class);headers.bind(bound,null);
        verify(bound).setParameter("short_header_status","PENDING_OWNER");
        verify(bound).setParameter("short_header_goodsName",text);
        verify(bound).setParameter("short_header_shortfallQty",new BigDecimal("0.0000000001"));
        assertThat(headers.sql("status")).doesNotContain(":short_header_status").contains(":short_header_goodsName");
        assertThatThrownBy(()->new SubcontractShortDeliveryTableQuery(Map.of("f.status) OR TRUE --","")))
                .isInstanceOf(ApiException.class);
    }

    @Test void numericTextAndEffectiveStatusPredicatesRemainBoundAndExclusiveCandidatesKeepOtherFilters() {
        var headers = new SubcontractShortDeliveryTableQuery(Map.of(
                "search.shortfallQty", "-9007199254740993.0001..0",
                "search.goodsName", "毛坯'_%", "f.status", "PENDING_OWNER",
                "search.orderBillNo", "WW-1"));
        String sql = headers.sql(null);
        assertThat(sql).contains("c.shortfall_qty BETWEEN :short_header_shortfallQty_lower AND :short_header_shortfallQty_upper",
                "COALESCE(c.goods_name_snapshot, goods.name)", "expected_complete_by < CURRENT_DATE");
        assertThat(sql).doesNotContain("毛坯'_%", "-9007199254740993.0001", "ILIKE '%");
        Query query = mock(Query.class);
        headers.bind(query, null);
        verify(query).setParameter("short_header_shortfallQty_lower", new BigDecimal("-9007199254740993.0001"));
        verify(query).setParameter("short_header_shortfallQty_upper", BigDecimal.ZERO);
        verify(query).setParameter("short_header_goodsName", "毛坯'_%");
        verify(query).setParameter("short_header_status", "PENDING_OWNER");
        assertThat(headers.sql("orderBillNo")).doesNotContain("short_header_orderBillNo").contains("short_header_goodsName");
    }

    @Test void datesFollowDisplayedBeijingTimeAndOwnerNamesPreserveHistoricalFallback() {
        var query = new SubcontractShortDeliveryTableQuery(Map.of("search.detectedAt", "2026-10", "search.ownerName", "张"));
        assertThat(query.sql(null)).contains("c.detected_at >= :short_dates_0_from", "c.detected_at < :short_dates_0_to",
                "COALESCE(header_owner.full_name,header_legacy_owner.full_name)");
        var bindings = mock(Query.class);
        query.bind(bindings, null);
        verify(bindings).setParameter("short_dates_0_from", java.time.OffsetDateTime.parse("2026-10-01T00:00:00+08:00"));
        verify(bindings).setParameter("short_dates_0_to", java.time.OffsetDateTime.parse("2026-11-01T00:00:00+08:00"));
        assertThat(SubcontractShortDeliveryTableQuery.orderBy("shortfallPct", "desc", "c.id"))
                .isEqualTo("c.shortfall_pct DESC NULLS LAST, c.id");
        assertThat(SubcontractShortDeliveryTableQuery.orderBy("detectedAt", "asc", "c.id"))
                .startsWith("c.detected_at ASC NULLS LAST");
    }

    @Test void unknownFieldsInvalidNumericInputAndActionControlsNeverReachSql() {
        for (var filter : List.of(Map.of("search.actions", "accept"), Map.of("f.status", "DELETED"),
                Map.of("search.shortfallQty", "NaN"), Map.of("search.shortfallQty", "2..1"),
                Map.of("search.detectedAt", "2026-10-29..2026-10-28"), Map.of("search.expectedCompleteBy", "2026-02-30"),
                Map.of("search.goodsName);DROP TABLE goods", "x")))
            assertThatThrownBy(() -> new SubcontractShortDeliveryTableQuery(filter)).isInstanceOf(ApiException.class);
        assertThatThrownBy(() -> SubcontractShortDeliveryTableQuery.orderBy("goods.name;--", "asc", "c.id"))
                .isInstanceOf(ApiException.class);
    }
}
