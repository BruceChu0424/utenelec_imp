package com.uten.imp.features.subcontract.draw;

import com.uten.imp.common.finance.ProcurementDeliveryDifference;
import com.uten.imp.features.subcontract.SubcontractDocumentAccessPolicy;
import com.uten.imp.security.DocumentAccessPolicy;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import java.math.BigDecimal;
import java.util.Collections;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;
import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.*;

class SubcontractDrawDeliveryDifferenceTest {
    @Test void colorCandidatesCoverTheAuthorizedLaneBeforePaginationAndKeepOtherFilters() {
        var fixture = fixture(true, BigDecimal.ZERO);
        var result = fixture.service.tasks(2, 50, "", "", null, List.of(), List.of(), null,
                null, null, Map.of("f.colorName", "浅灰", "search.goods", "毛坯"));
        assertThat(result.facets().get("colorName")).extracting(com.uten.imp.common.web.FacetBucket::value)
                .containsExactly("浅灰", "梦幻金");
        assertThat(result.facets().get("colorName").getFirst().count()).isEqualTo(201);
        assertThat(result.nullCounts().get("colorName")).isEqualTo(3);
        var sql = ArgumentCaptor.forClass(String.class);
        verify(fixture.em).createNativeQuery(sql.capture());
        String colors = sql.getValue().split("color_buckets AS \\(", 2)[1].split("color_facets AS", 2)[0];
        assertThat(colors).contains("FROM classified WHERE", "draw_header_goods")
                .doesNotContain("draw_exact_colorName", "pageLimit", "pageOffset");
        assertThat(sql.getValue()).contains("AND color_name = :draw_exact_colorName", "o.maker_id IN (:readOwners)")
                .doesNotContain("浅灰", "毛坯");
        verify(fixture.query).setParameter("draw_exact_colorName", "浅灰");
        verify(fixture.query).setParameter("pageOffset", 50L);
    }

    @Test void exactColorsDoNotMatchSimilarNamesAndEmptyColorIsAnExplicitNullFilter() {
        var query = mock(Query.class);
        var headers = new SubcontractDrawTableQuery(null, null, Map.of("f.colorName", "__null__"));
        assertThat(headers.sql(true)).contains("NULLIF(color_name, '') IS NULL");
        assertThat(headers.sql(true, "colorName")).isEmpty();
        headers.bind(query);
        verifyNoInteractions(query);
        assertThat(new SubcontractDrawTableQuery(null, null, Map.of("f.colorName", "浅灰")).sql(true))
                .isEqualTo(" AND color_name = :draw_exact_colorName");
    }

    @Test void taskUsesExactOrderDeliveryFactAndExistingReadableOwnerScope() {
        var fixture = fixture(true, new BigDecimal("-9007199254740993.0001"));
        var task = fixture.service.tasks(1, 20, "", "", null, List.of()).page().getItems().getFirst();
        assertThat(task.getDifferenceQtyExact()).isEqualTo("-9007199254740993.0001");
        assertThat(task.unitName()).isEqualTo("套");
        assertThat(task.shortQty()).isEqualByComparingTo("0");
        var sql = ArgumentCaptor.forClass(String.class);
        verify(fixture.em).createNativeQuery(sql.capture());
        assertThat(sql.getValue()).contains(
                ProcurementDeliveryDifference.sql("oi.qty", "oi.received_qty", "oi.returned_qty") + " AS difference_qty",
                "page.difference_qty", "o.maker_id IN (:readOwners)");
        verify(fixture.query).setParameter("readOwners", Set.of(fixture.owner));
    }

    @Test void unavailableAndUnauthorizedFactsStayUnknownInsteadOfUsingDrawShortage() {
        for (var fixture : List.of(fixture(true, null), fixture(false, new BigDecimal("-10")))) {
            var task = fixture.service.tasks(1, 20, "", "", null, List.of()).page().getItems().getFirst();
            assertThat(task.differenceQty()).isNull();
            assertThat(task.getDifferenceQtyExact()).isNull();
        }
    }

    @Test void mixedTableHeadersFilterClassifiedFactsBeforeBothCountAndPageAndSortTheWholeLane() {
        var fixture = fixture(true, new BigDecimal("-7.1250"));
        fixture.service.tasks(2, 50, "", "", null, List.of(), List.of(), null,
                "differenceQty", "desc", Map.of("search.differenceQty", "-8..0", "search.goods", "毛坯"));
        var sql = ArgumentCaptor.forClass(String.class);
        verify(fixture.em).createNativeQuery(sql.capture());
        assertThat(sql.getValue()).contains("difference_qty BETWEEN :draw_header_differenceQty_lower AND :draw_header_differenceQty_upper",
                "FROM classified WHERE", "ORDER BY search_rank, difference_qty DESC NULLS LAST",
                "ORDER BY page.search_rank, page.difference_qty DESC NULLS LAST", "o.maker_id IN (:readOwners)");
        assertThat(sql.getValue()).doesNotContain("毛坯");
        verify(fixture.query).setParameter("draw_header_differenceQty_lower", new BigDecimal("-8"));
        verify(fixture.query).setParameter("draw_header_differenceQty_upper", BigDecimal.ZERO);
        verify(fixture.query).setParameter("draw_header_goods", "毛坯");
        verify(fixture.query).setParameter("pageOffset", 50L);
    }

    @Test void unknownGuidanceCellsDoNotBecomeNumericZerosAndUnreadableDifferencesCannotBeInferred() {
        var headers = new SubcontractDrawTableQuery(null, null, Map.of("search.issuedAt", "2026", "search.spec", "规格", "search.differenceQty", "!=0"));
        assertThat(headers.sql(false)).contains("NULL::numeric != :draw_header_differenceQty", "NULL::text");
        assertThat(headers.sql(true)).contains("difference_qty != :draw_header_differenceQty");
        assertThat(new SubcontractDrawTableQuery("openQty", "asc", Map.of()).orderSql()).startsWith("0::numeric ASC");
    }

    @Test void dateHeadersUseSharedCalendarRangesAndKeepTheMissingIssueDateUnknown() {
        var headers = new SubcontractDrawTableQuery(null, null, Map.of("search.needDate", "2026-10-01..2026-10-28"));
        assertThat(headers.sql(true)).contains("deliver_date >= :draw_dates_0_from", "deliver_date < :draw_dates_0_to")
                .doesNotContain("ILIKE");
        var query = mock(Query.class);
        headers.bind(query);
        verify(query).setParameter("draw_dates_0_from", java.time.LocalDate.parse("2026-10-01"));
        verify(query).setParameter("draw_dates_0_to", java.time.LocalDate.parse("2026-10-29"));
        assertThat(new SubcontractDrawTableQuery(null, null, Map.of("search.issuedAt", "2026")).sql(true))
                .contains("NULL::timestamptz >=");
        org.assertj.core.api.Assertions.assertThatThrownBy(() -> new SubcontractDrawTableQuery(null, null,
                Map.of("search.needDate", "2026-10-28..2026-10-27"))).isInstanceOf(com.uten.imp.common.web.ApiException.class);
    }

    private static Fixture fixture(boolean canView, BigDecimal difference) {
        var em = mock(EntityManager.class);
        var query = mock(Query.class);
        var access = mock(SubcontractDocumentAccessPolicy.class);
        UUID owner = UUID.randomUUID();
        when(access.nativeReadScope("o.maker_id", "readOwners")).thenReturn(
                new DocumentAccessPolicy.NativeReadScope("o.maker_id IN (:readOwners)", "readOwners", Set.of(owner)));
        when(access.hasAuthority("subcontract_order:view")).thenReturn(canView);
        when(em.createNativeQuery(anyString())).thenReturn(query);
        Object[] row = new Object[36];
        row[34] = "[{\"value\":\"浅灰\",\"count\":201},{\"value\":\"梦幻金\",\"count\":5}]";
        row[35] = 3L;
        row[4] = 1L; row[5] = 1L;
        int offset = 6;
        row[offset] = UUID.randomUUID(); row[offset + 1] = UUID.randomUUID();
        row[offset + 2] = "WW-1"; row[offset + 3] = 1;
        row[offset + 12] = "套";
        row[offset + 13] = BigDecimal.TEN;
        row[offset + 14] = BigDecimal.TEN;
        row[offset + 15] = BigDecimal.ZERO;
        row[offset + 16] = BigDecimal.ZERO;
        row[offset + 17] = BigDecimal.ZERO;
        row[offset + 18] = 1; row[offset + 19] = 1; row[offset + 20] = 0;
        row[offset + 21] = "DRAW_SUBMITTED"; row[offset + 23] = owner;
        row[offset + 24] = BigDecimal.TEN; row[offset + 25] = "WL-1";
        row[offset + 26] = new UUID[0]; row[offset + 27] = difference;
        when(query.getResultList()).thenReturn(Collections.singletonList(row));
        return new Fixture(new SubcontractDrawQueryService(em, access), em, query, owner);
    }

    private record Fixture(SubcontractDrawQueryService service, EntityManager em, Query query, UUID owner) { }
}
