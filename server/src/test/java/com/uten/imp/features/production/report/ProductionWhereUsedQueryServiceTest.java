package com.uten.imp.features.production.report;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.web.PageResponse;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.ArgumentCaptor;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.List;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.when;

@ExtendWith(MockitoExtension.class)
class ProductionWhereUsedQueryServiceTest {

    @Mock
    private EntityManager em;

    @Test
    void blankMaterialKeywordReturnsImmediatelyWithoutQueryingTheDatabase() {
        PageResponse<WhereUsedMaterialOption> result = service()
                .searchWhereUsedMaterials("   ", 1, 30);

        assertThat(result.getItems()).isEmpty();
        assertThat(result.getTotal()).isZero();
        assertThat(result.getTotalPages()).isZero();
        verifyNoInteractions(em);
    }

    @Test
    void materialSearchMapsAllFifteenColumnsIncludingBomIssue() {
        UUID materialId = UUID.randomUUID();
        Query query = chainableQuery();
        when(query.getResultList()).thenReturn(List.<Object[]>of(new Object[]{
                materialId,
                "MAT-01",
                "Copper wire",
                "M-8",
                "8 mm",
                "DISABLED",
                "MIGRATED",
                "Raw material",
                true,
                true,
                false,
                true,
                true,
                false,
                37L
        }));
        when(em.createNativeQuery(anyString())).thenReturn(query);

        PageResponse<WhereUsedMaterialOption> result = service()
                .searchWhereUsedMaterials("MAT-01", 1, 20);

        assertThat(result.getItems()).singleElement().satisfies(option -> {
            assertThat(option.id()).isEqualTo(materialId);
            assertThat(option.code()).isEqualTo("MAT-01");
            assertThat(option.name()).isEqualTo("Copper wire");
            assertThat(option.model()).isEqualTo("M-8");
            assertThat(option.spec()).isEqualTo("8 mm");
            assertThat(option.status()).isEqualTo("DISABLED");
            assertThat(option.sourceType()).isEqualTo("MIGRATED");
            assertThat(option.categoryName()).isEqualTo("Raw material");
            assertThat(option.autoCreated()).isTrue();
            assertThat(option.deleted()).isTrue();
            assertThat(option.currentBom()).isFalse();
            assertThat(option.bomIssue()).isTrue();
            assertThat(option.productionHistory()).isTrue();
            assertThat(option.subcontractHistory()).isFalse();
        });
        assertThat(result.getTotal()).isEqualTo(37L);
        assertThat(result.getTotalPages()).isEqualTo(2);

        ArgumentCaptor<String> sql = ArgumentCaptor.forClass(String.class);
        verify(em).createNativeQuery(sql.capture());
        String compactSql = compact(sql.getValue());
        int matchedStart = compactSql.indexOf("WITH matched_goods AS MATERIALIZED (");
        int matchedWhereStart = compactSql.indexOf(" WHERE LOWER(", matchedStart);
        int matchedOrderStart = compactSql.indexOf(
                " ORDER BY match_rank,", matchedWhereStart);
        int pageLimitStart = compactSql.indexOf(
                " LIMIT :__limit OFFSET :__offset", matchedOrderStart);
        int outerSelectStart = compactSql.indexOf(
                ") SELECT goods.id", pageLimitStart);
        int lateralStart = compactSql.indexOf(
                " CROSS JOIN LATERAL (", outerSelectStart);
        int outerOrderStart = compactSql.lastIndexOf(
                " ORDER BY goods.match_rank,");
        assertThat(matchedStart).isGreaterThanOrEqualTo(0);
        assertThat(matchedWhereStart).isGreaterThan(matchedStart);
        assertThat(matchedOrderStart).isGreaterThan(matchedWhereStart);
        assertThat(pageLimitStart).isGreaterThan(matchedOrderStart);
        assertThat(outerSelectStart).isGreaterThan(pageLimitStart);
        assertThat(lateralStart).isGreaterThan(outerSelectStart);
        assertThat(outerOrderStart).isGreaterThan(lateralStart);

        String matchedPageSql = compactSql.substring(matchedStart, outerSelectStart);
        assertThat(matchedPageSql)
                .contains("COUNT(*) OVER() AS total_count")
                .contains("COALESCE(goods.code, '') || ' ' || COALESCE(goods.name, '')")
                .contains(") LIKE :pattern")
                .contains("ORDER BY match_rank, goods.is_deleted ASC, "
                        + "goods.auto_created ASC, goods.code ASC NULLS LAST, "
                        + "goods.name ASC NULLS LAST, goods.id ASC "
                        + "LIMIT :__limit OFFSET :__offset")
                .doesNotContain("source.current_bom")
                .doesNotContain("goods_bom_items")
                .doesNotContain("production_plan_costs")
                .doesNotContain("production_material_demands")
                .doesNotContain("subcontract_order_cost_items")
                .doesNotContain("subcontract_material_issue_items");

        String pageEnrichmentSql = compactSql.substring(
                outerSelectStart, outerOrderStart);
        assertThat(pageEnrichmentSql)
                .contains("FROM matched_goods goods CROSS JOIN LATERAL")
                .contains("source.current_bom, source.bom_issue, source.production_history")
                .contains("goods_bom_items")
                .contains("production_plan_costs")
                .contains("legacy.node_class = 0 AND legacy.master_goods_id IS NOT NULL AND legacy.master_goods_id <> goods.id")
                .contains("production_material_demands")
                .contains("subcontract_order_cost_items")
                .contains("subcontract_material_issue_items")
                .contains("order_item.id = planned.order_item_id "
                        + "AND order_item.order_id = planned.order_id "
                        + "AND order_item.is_deleted = FALSE")
                .contains("order_item.goods_id <> goods.id")
                .contains("COALESCE(order_item.goods_id, issued.parent_goods_id) "
                        + "IS NOT NULL AND COALESCE(order_item.goods_id, "
                        + "issued.parent_goods_id) <> goods.id")
                .doesNotContain("WHERE source.")
                .doesNotContain("AND (source.");

        String outerOrderSql = compactSql.substring(outerOrderStart);
        assertThat(outerOrderSql)
                .contains("ORDER BY goods.match_rank, goods.is_deleted ASC, "
                        + "goods.auto_created ASC, goods.code ASC NULLS LAST, "
                        + "goods.name ASC NULLS LAST, goods.id ASC")
                .doesNotContain("CASE WHEN source.");

        assertThat(compactSql)
                .contains("WITH matched_goods AS MATERIALIZED")
                .contains("bom.qty > 0 AND bom.goods_id <> goods.id")
                .contains("(bom.qty <= 0 OR bom.goods_id = goods.id)")
                .contains("JOIN production_plans plan ON plan.id = demand.plan_id AND plan.is_deleted = FALSE")
                .contains("LEFT JOIN production_execution_segments segment ON segment.id = demand.execution_segment_id AND segment.is_deleted = FALSE")
                .contains("demand.execution_segment_id IS NOT NULL AND segment.id IS NOT NULL AND segment.product_goods_id <> goods.id")
                .contains("demand.execution_segment_id IS NULL AND demand.status NOT IN ('RELEASED', 'REVERSED') AND plan.status = 1 AND plan.is_stopped = FALSE AND plan.is_canceled = FALSE")
                .doesNotContain("ILIKE");
        assertThat(occurrences(pageEnrichmentSql,
                "demand.execution_segment_id IS NULL AND demand.status NOT IN "
                        + "('RELEASED', 'REVERSED') AND plan.status = 1 "
                        + "AND plan.is_stopped = FALSE AND plan.is_canceled = FALSE")).isEqualTo(2);
        assertThat(occurrences(pageEnrichmentSql,
                "legacy.master_goods_id IS NOT NULL")).isEqualTo(1);
        verify(query).setParameter("pattern", "%mat-01%");
        assertThat(occurrences(pageEnrichmentSql,
                "legacy.master_goods_id <> goods.id")).isEqualTo(1);
        assertThat(occurrences(pageEnrichmentSql,
                "segment.product_goods_id <> goods.id")).isEqualTo(2);
        verify(query).setParameter("prefix", "mat-01%");
        verify(query).setParameter("exact", "mat-01");
    }

    @Test
    void materialSearchEscapesLikeWildcardsWithoutChangingTheExactRankValue() {
        Query query = chainableQuery();
        when(query.getResultList()).thenReturn(List.of());
        when(em.createNativeQuery(anyString())).thenReturn(query);

        service().searchWhereUsedMaterials("%_\\", 1, 20);

        verify(query).setParameter("pattern", "%\\%\\_\\\\%");
        verify(query).setParameter("prefix", "\\%\\_\\\\%");
        verify(query).setParameter("exact", "%_\\");
        ArgumentCaptor<String> sql = ArgumentCaptor.forClass(String.class);
        verify(em).createNativeQuery(sql.capture());
        assertThat(occurrences(compact(sql.getValue()), " ESCAPE ")).isEqualTo(3);
    }

    @Test
    void materialSearchCountsAllMatchesWhenALaterPageIsEmpty() {
        Query pageQuery = chainableQuery();
        when(pageQuery.getResultList()).thenReturn(List.of());
        Query countQuery = chainableQuery();
        when(countQuery.getSingleResult()).thenReturn(61L);
        when(em.createNativeQuery(anyString())).thenReturn(pageQuery, countQuery);

        PageResponse<WhereUsedMaterialOption> result = service()
                .searchWhereUsedMaterials("MAT", 2, 30);

        assertThat(result.getItems()).isEmpty();
        assertThat(result.getPage()).isEqualTo(2);
        assertThat(result.getTotal()).isEqualTo(61L);
        assertThat(result.getTotalPages()).isEqualTo(3);
        verify(pageQuery).setParameter("pattern", "%mat%");
        verify(countQuery).setParameter("pattern", "%mat%");

        ArgumentCaptor<String> sql = ArgumentCaptor.forClass(String.class);
        verify(em, org.mockito.Mockito.times(2)).createNativeQuery(sql.capture());
        assertThat(compact(sql.getAllValues().get(0)))
                .contains("WITH matched_goods AS MATERIALIZED");
        assertThat(compact(sql.getAllValues().get(1)))
                .contains("SELECT COUNT(*) FROM goods")
                .contains("LIKE :pattern ESCAPE")
                .doesNotContain("CROSS JOIN LATERAL");
    }

    @Test
    void rejectsUnsupportedSourceAndReverseDateRangeBeforeQuerying() {
        UUID materialId = UUID.randomUUID();

        ApiException unsupported = assertThrows(ApiException.class, () -> service().whereUsed(
                materialId, "unknown", null, null, 1, 50, null, null));
        ApiException reverseRange = assertThrows(ApiException.class, () -> service().whereUsed(
                materialId,
                "all",
                LocalDate.of(2026, 8, 2),
                LocalDate.of(2026, 8, 1),
                1,
                50,
                null,
                null));

        assertThat(unsupported.getCode()).isEqualTo(ErrorCode.VALIDATION_FAILED);
        assertThat(reverseRange.getCode()).isEqualTo(ErrorCode.VALIDATION_FAILED);
        verifyNoInteractions(em);
    }

    @Test
    void currentSourceSkipsTheHistoricalUnattributedDemandMetadataQuery() {
        Query dataQuery = chainableQuery();
        when(dataQuery.getResultList()).thenReturn(List.of());
        when(em.createNativeQuery(anyString())).thenReturn(dataQuery);

        ReportTableResponse result = service().whereUsed(
                UUID.randomUUID(), "current", null, null, 1, 50, null, null);

        assertThat(result.meta())
                .containsEntry("source", "current")
                .containsEntry("unattributedDemandCount", 0L)
                .containsEntry("unattributedDemandQty", BigDecimal.ZERO);
        ArgumentCaptor<String> sql = ArgumentCaptor.forClass(String.class);
        verify(em).createNativeQuery(sql.capture());
        assertThat(compact(sql.getValue()))
                .contains("WHERE row.current_bom")
                .doesNotContain("demand.execution_segment_id IS NULL");
        verify(dataQuery, never()).getSingleResult();
    }

    @Test
    void subcontractSourceIncludesUnapprovedOrReversedEvidenceWithoutTreatingItAsValid() {
        Query metadataQuery = chainableQuery();
        when(metadataQuery.getSingleResult()).thenReturn(new Object[]{0L, BigDecimal.ZERO});
        Query dataQuery = chainableQuery();
        when(dataQuery.getResultList()).thenReturn(List.of());
        when(em.createNativeQuery(anyString())).thenReturn(metadataQuery, dataQuery);

        service().whereUsed(
                UUID.randomUUID(), "subcontract", null, null, 1, 50, null, null);

        ArgumentCaptor<String> sql = ArgumentCaptor.forClass(String.class);
        verify(em, org.mockito.Mockito.times(2)).createNativeQuery(sql.capture());
        String reportSql = compact(sql.getAllValues().get(1));
        assertThat(reportSql)
                .contains("WHERE (row.execution_subcontract_evidence_count > 0 "
                        + "OR row.subcontract_order_evidence_count > 0 "
                        + "OR row.subcontract_issue_evidence_count > 0)")
                .contains("COUNT(DISTINCT cost.order_id) AS evidence_count")
                .contains("COUNT(DISTINCT cost.order_id) FILTER (WHERE orders.status = 1) AS order_count")
                .contains("COUNT(DISTINCT issue_item.issue_id) AS evidence_count")
                .contains("COUNT(DISTINCT issue_item.issue_id) FILTER (WHERE issue.status = 1) AS issue_count");
    }


    @Test
    void allSourceKeepsEveryRelationshipSourceEvidenceSemanticsAndStableProductId() {
        UUID productId = UUID.randomUUID();
        Query metadataQuery = chainableQuery();
        when(metadataQuery.getSingleResult()).thenReturn(new Object[]{0L, BigDecimal.ZERO});
        Query dataQuery = chainableQuery();
        when(dataQuery.getResultList()).thenReturn(List.<Object[]>of(reportRow(productId)));
        when(em.createNativeQuery(anyString())).thenReturn(metadataQuery, dataQuery);

        ReportTableResponse result = service().whereUsed(
                UUID.randomUUID(), "all", null, null, 1, 50, null, null);

        assertThat(result.rows()).singleElement().satisfies(row -> {
            assertThat(row.get("__productId")).isEqualTo(productId.toString());
            assertThat(row.get("__srcId")).isEqualTo(productId.toString());
            assertThat(row.get("__subcontractReturnedQty"))
                    .isEqualTo(new BigDecimal("2.50"));
            assertThat(row.get("__subcontractWastedQty"))
                    .isEqualTo(new BigDecimal("0.25"));
            assertThat(row.get("__subcontractFirstUsed")).isEqualTo("2026-01-02");
            assertThat(row.get("__subcontractLastUsed")).isEqualTo("2026-01-31");
        });
        assertThat(result.total()).isEqualTo(1L);

        ArgumentCaptor<String> sql = ArgumentCaptor.forClass(String.class);
        verify(em, org.mockito.Mockito.times(2)).createNativeQuery(sql.capture());
        assertThat(sql.getAllValues()).hasSize(2);
        String metadataSql = compact(sql.getAllValues().get(0));
        String reportSql = compact(sql.getAllValues().get(1));

        assertThat(metadataSql)
                .contains("demand.execution_segment_id IS NULL")
                .contains("demand.status NOT IN ('RELEASED', 'REVERSED')")
                .contains("plan.status = 1")
                .contains("plan.is_stopped = FALSE")
                .contains("plan.is_canceled = FALSE");
        int legacyStart = reportSql.indexOf("legacy_production AS (");
        int executionStart = reportSql.indexOf("execution_demands AS (");
        int subcontractStart = reportSql.indexOf("subcontract_planned AS (");
        assertThat(legacyStart).isGreaterThanOrEqualTo(0);
        assertThat(executionStart).isGreaterThan(legacyStart);
        assertThat(subcontractStart).isGreaterThan(executionStart);
        String legacySql = reportSql.substring(legacyStart, executionStart);
        String executionSql = reportSql.substring(executionStart, subcontractStart);
        assertThat(legacySql).contains(
                "COUNT(DISTINCT COALESCE(plan.id, c.bill_item_id)) AS evidence_count, "
                        + "COUNT(DISTINCT plan.id) FILTER (WHERE plan.status = 1 "
                        + "AND plan.is_stopped = FALSE AND plan.is_canceled = FALSE) AS plan_count");
        assertThat(occurrences(legacySql,
                "FILTER (WHERE plan.status = 1 AND plan.is_stopped = FALSE AND plan.is_canceled = FALSE)"))
                .isEqualTo(9);
        assertThat(executionSql).contains(
                "COUNT(DISTINCT demand.execution_segment_id) AS evidence_count, "
                        + "COUNT(DISTINCT demand.execution_segment_id) "
                        + "FILTER (WHERE demand.supply_route = 'SUBCONTRACT') "
                        + "AS subcontract_evidence_count");
        assertThat(occurrences(executionSql,
                "AND plan.status = 1 AND plan.is_stopped = FALSE AND plan.is_canceled = FALSE)"))
                .isEqualTo(8);
        assertThat(reportSql)
                .contains("WITH RECURSIVE")
                .contains("WHERE goods.id <> :material")
                .contains("goods_bom_items")
                .contains("production_material_demands")
                .contains("production_execution_segments")
                .contains("production_plan_costs")
                .contains("subcontract_order_cost_items")
                .contains("order_item.id = cost.order_item_id AND order_item.is_deleted = FALSE "
                        + "AND order_item.order_id = cost.order_id")
                .contains("subcontract_material_issue_items")
                .contains("COUNT(DISTINCT COALESCE(plan.id, c.bill_item_id)) AS evidence_count")
                .contains("COUNT(DISTINCT plan.id) FILTER (WHERE plan.status = 1 AND plan.is_stopped = FALSE AND plan.is_canceled = FALSE) AS plan_count")
                .contains("COUNT(DISTINCT demand.execution_segment_id) AS evidence_count")
                .contains("demand.status NOT IN ('RELEASED', 'REVERSED')")
                .contains("segment.status NOT IN ('CANCELLED', 'REVERSED')")
                .contains("COUNT(DISTINCT cost.order_id) AS evidence_count")
                .contains("COUNT(DISTINCT cost.order_id) FILTER (WHERE orders.status = 1) AS order_count")
                .contains("COUNT(DISTINCT issue_item.issue_id) AS evidence_count")
                .contains("COUNT(DISTINCT issue_item.issue_id) FILTER (WHERE issue.status = 1) AS issue_count")
                .contains("row.product_id AS \"__productId\"")
                .contains("ORDER BY \"__currentBom\" DESC, \"lastUsed\" DESC NULLS LAST, \"goodsCode\" ASC, \"__productId\" ASC");

        int recursiveStart = reportSql.indexOf("bom_walk(product_id, valid_path) AS");
        int recursiveEnd = reportSql.indexOf("current_ancestors(product_id)");
        assertThat(recursiveStart).isGreaterThanOrEqualTo(0);
        assertThat(recursiveEnd).isGreaterThan(recursiveStart);
        assertThat(reportSql.substring(recursiveStart, recursiveEnd))
                .contains(" UNION ")
                .doesNotContain("UNION ALL");
    }

    @Test
    void v186AddsWhereUsedReadIndexesWithoutBackportingThemToOlderMigrations()
            throws Exception {
        Path migrationRoot = Path.of("src/main/resources/db/migration");
        if (!Files.isDirectory(migrationRoot)) {
            migrationRoot = Path.of("server/src/main/resources/db/migration");
        }
        Path migration = migrationRoot.resolve(
                "V186__production_where_used_read_indexes.sql");
        assertThat(migration).exists();

        String sql = compact(Files.readString(migration, StandardCharsets.UTF_8));
        assertThat(sql)
                .contains("CREATE EXTENSION IF NOT EXISTS pg_trgm;")
                .contains("CREATE INDEX IF NOT EXISTS idx_gbi_where_used_active "
                        + "ON goods_bom_items(component_goods_id, goods_id) "
                        + "INCLUDE (qty) WHERE is_deleted = FALSE;")
                .contains("CREATE INDEX IF NOT EXISTS idx_ppc_where_used_active "
                        + "ON production_plan_costs(goods_id, bill_date, "
                        + "master_goods_id, bill_item_id) "
                        + "INCLUDE (dqty, qty, pdraw_qty, owdraw_qty) "
                        + "WHERE is_deleted = FALSE AND node_class = 0 "
                        + "AND master_goods_id IS NOT NULL;")
                .contains("CREATE INDEX IF NOT EXISTS idx_scoci_where_used_active "
                        + "ON subcontract_order_cost_items(goods_id, bill_date, "
                        + "order_item_id) INCLUDE (order_id, unit_qty, qty)")
                .contains("CREATE INDEX IF NOT EXISTS idx_smisi_where_used_active "
                        + "ON subcontract_material_issue_items(goods_id, bill_date, "
                        + "order_item_id) INCLUDE (issue_id, parent_goods_id, qty, "
                        + "returned_qty, wasted_qty)")
                .contains("CREATE INDEX IF NOT EXISTS idx_goods_where_used_search_trgm "
                        + "ON goods USING GIN")
                .contains("COALESCE(code, '') || ' ' || COALESCE(name, '')")
                .contains("COALESCE(material, '') || ' ' || "
                        + "COALESCE(require_remark, '')")
                .contains("gin_trgm_ops");

        int allEvidenceStart = sql.indexOf(
                "CREATE INDEX IF NOT EXISTS idx_pmd_where_used_all_evidence");
        int attributedStart = sql.indexOf(
                "CREATE INDEX IF NOT EXISTS idx_pmd_where_used_segment");
        assertThat(allEvidenceStart).isGreaterThanOrEqualTo(0);
        assertThat(attributedStart).isGreaterThan(allEvidenceStart);
        assertThat(sql.substring(allEvidenceStart, attributedStart))
                .contains("ON production_material_demands"
                        + "(goods_id, execution_segment_id, need_date)")
                .contains("INCLUDE (status, supply_route, required_qty, "
                        + "per_product_qty, plan_id)")
                .contains("WHERE is_deleted = FALSE;")
                .doesNotContain("status <>")
                .doesNotContain("execution_segment_id IS NOT NULL")
                .doesNotContain("execution_segment_id IS NULL");

        List<String> newIndexNames = List.of(
                "idx_gbi_where_used_active",
                "idx_ppc_where_used_active",
                "idx_pmd_where_used_all_evidence",
                "idx_pmd_where_used_segment",
                "idx_pmd_where_used_unattributed",
                "idx_scoci_where_used_active",
                "idx_smisi_where_used_active",
                "idx_goods_where_used_search_trgm");
        try (var migrations = Files.list(migrationRoot)) {
            for (Path older : migrations.filter(Files::isRegularFile).toList()) {
                String name = older.getFileName().toString();
                if (!name.matches("V\\d+__.*\\.sql")) continue;
                int version = Integer.parseInt(name.substring(1, name.indexOf("__")));
                if (version >= 186) continue;
                assertThat(Files.readString(older, StandardCharsets.UTF_8))
                        .as("%s must remain free of V186 index definitions", name)
                        .doesNotContain(newIndexNames.toArray(String[]::new));
            }
        }
    }

    private ProductionWhereUsedQueryService service() {
        return new ProductionWhereUsedQueryService(em);
    }

    private Query chainableQuery() {
        Query query = org.mockito.Mockito.mock(Query.class);
        when(query.setParameter(anyString(), any())).thenReturn(query);
        return query;
    }

    private static Object[] reportRow(UUID productId) {
        Object[] row = new Object[49];
        row[0] = productId;
        row[1] = true;
        row[2] = false;
        row[3] = true;
        row[29] = new BigDecimal("2.50");
        row[30] = new BigDecimal("0.25");
        row[31] = java.sql.Date.valueOf("2026-01-02");
        row[32] = java.sql.Date.valueOf("2026-01-31");
        row[36] = "FG-001";
        row[37] = "Finished product";
        row[48] = 1L;
        return row;
    }


    private static int occurrences(String text, String needle) {
        int count = 0;
        int cursor = 0;
        while ((cursor = text.indexOf(needle, cursor)) >= 0) {
            count++;
            cursor += needle.length();
        }
        return count;
    }

    private static String compact(String sql) {
        return sql.replaceAll("\\s+", " ").trim();
    }
}
