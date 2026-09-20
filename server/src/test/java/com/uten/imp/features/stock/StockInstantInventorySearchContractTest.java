package com.uten.imp.features.stock;

import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;

import java.util.List;
import java.util.Set;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class StockInstantInventorySearchContractTest {

    @Test
    void locationQueryUsesTheSameKeywordAndDeletionContractAsInventoryRows() {
        EntityManager em = mock(EntityManager.class);
        Query query = mock(Query.class);
        when(em.createNativeQuery(anyString())).thenReturn(query);
        when(query.setParameter(anyString(), org.mockito.ArgumentMatchers.any())).thenReturn(query);
        UUID categoryId = UUID.randomUUID();
        when(query.getResultList()).thenReturn(List.of(categoryId));
        StockQueryService service = new StockQueryService(
                null, null, em, mock(StockCostMasker.class));

        var result = service.instantInventoryMatchingCategoryIds(
                "  G-001  ", Set.of(UUID.randomUUID()));

        assertThat(result).containsExactly(categoryId);
        var sql = org.mockito.ArgumentCaptor.forClass(String.class);
        verify(em).createNativeQuery(sql.capture());
        assertThat(sql.getValue())
                .contains("g.is_deleted = false")
                .contains("g.name ILIKE :kw", "g.code ILIKE :kw")
                .contains("g.model ILIKE :kw", "g.c_number ILIKE :kw")
                .doesNotContain("g.spec ILIKE", "g.series ILIKE", "auto_created", "status");
        verify(query).setParameter("kw", "%G-001%");
    }

    @Test
    void locationQueryFailsClosedWithoutABoundedTreeScope() {
        StockQueryService service = new StockQueryService(
                null, null, mock(EntityManager.class), mock(StockCostMasker.class));
        assertThatThrownBy(() -> service.instantInventoryMatchingCategoryIds("G", Set.of()))
                .isInstanceOf(com.uten.imp.common.web.ApiException.class);
        assertThatThrownBy(() -> service.instantInventoryMatchingCategoryIds(
                "G", java.util.stream.IntStream.range(0, 33)
                        .mapToObj(ignored -> UUID.randomUUID()).collect(java.util.stream.Collectors.toSet())))
                .isInstanceOf(com.uten.imp.common.web.ApiException.class);
    }

    @Test
    void shelfLabelRackFilterIsSeparatedFromOrderBy() {
        EntityManager em = mock(EntityManager.class);
        Query query = mock(Query.class);
        when(em.createNativeQuery(anyString())).thenReturn(query);
        when(query.setParameter(anyString(), org.mockito.ArgumentMatchers.any())).thenReturn(query);
        when(query.getResultList()).thenReturn(List.of());
        StockQueryService service = new StockQueryService(
                null, null, em, mock(StockCostMasker.class));

        service.shelfLabelRows(" A31 ", null, null, false);

        var sql = org.mockito.ArgumentCaptor.forClass(String.class);
        verify(em).createNativeQuery(sql.capture());
        assertThat(sql.getValue())
                .contains("= :rack\n")
                .contains("r.parsed AND split_part(r.place, '-', 1) = :rack")
                .doesNotContain(":rackORDER BY", ":rack ORDER BY")
                // 残值不参与库行筛选、禁用默认不列、未选仓 = 全部核算仓（无子树递归、无 :warehouseId）
                .contains("COALESCE(g.status, '') <> '禁用'")
                .doesNotContain("warehouse_tree", ":warehouseId")
                .contains("WHERE is_accountable AND NOT is_deleted AND NOT is_line_side")
                .contains(ShelfPlaceParser.SQL_PATTERN)
                .contains("LIMIT " + ShelfLabelSql.ROW_LIMIT);
        verify(query).setParameter("rack", "A31");
    }

    @Test
    void shelfLabelRowsWithWarehouseUseSubtreePreferenceAndBalancesAndCanIncludeDisabled() {
        EntityManager em = mock(EntityManager.class);
        Query query = mock(Query.class);
        when(em.createNativeQuery(anyString())).thenReturn(query);
        when(query.setParameter(anyString(), org.mockito.ArgumentMatchers.any())).thenReturn(query);
        when(query.getResultList()).thenReturn(List.of());
        StockQueryService service = new StockQueryService(
                null, null, em, mock(StockCostMasker.class));
        UUID warehouseId = UUID.randomUUID();

        service.shelfLabelRows(null, " 风扇 ", warehouseId, true);

        var sql = org.mockito.ArgumentCaptor.forClass(String.class);
        verify(em).createNativeQuery(sql.capture());
        assertThat(sql.getValue())
                // V607-V627：递归树改名 warehouse_tree，树根锚定 :warehouseId 且软删仓不入树
                .contains("WITH RECURSIVE warehouse_tree AS")
                .contains("WHERE id = :warehouseId AND is_deleted = false")
                .contains("JOIN warehouse_tree tree ON w.parent_id = tree.id")
                .contains("w.is_accountable AND NOT w.is_line_side")
                // 偏好与余额都只取本仓树（JOIN wh），偏好优先于货品主档建议
                .contains("FROM warehouse_goods_place_preferences p JOIN wh ON wh.id=p.warehouse_id")
                .contains("COALESCE(NULLIF(BTRIM(pref.place), ''), NULLIF(BTRIM(g.stock_place), ''))")
                .contains("FROM stock_balances b JOIN wh ON wh.id=b.warehouse_id")
                .contains("r.name ILIKE :kw", "r.code ILIKE :kw", "r.series ILIKE :kw", "r.place ILIKE :kw")
                .contains("= '禁用') AS disabled")
                .doesNotContain("<> '禁用'", ":rack");
        verify(query).setParameter("warehouseId", warehouseId);
        verify(query).setParameter("kw", "%风扇%");
    }

    @Test
    void shelfLabelRowsMapColumnsAndParsePlaceOnJavaSide() {
        EntityManager em = mock(EntityManager.class);
        Query query = mock(Query.class);
        when(em.createNativeQuery(anyString())).thenReturn(query);
        when(query.setParameter(anyString(), org.mockito.ArgumentMatchers.any())).thenReturn(query);
        UUID g1 = UUID.randomUUID();
        UUID g2 = UUID.randomUUID();
        UUID warehouseId = UUID.randomUUID();
        UUID colorId = UUID.randomUUID();
        // 列序 = goods_id, place, code, series, name, color_name, unit_name, qty,
        // disabled, parsed(仅 SQL 筛选/排序用), warehouse_id, warehouse_name, color_id, place_source
        when(query.getResultList()).thenReturn(List.of(
                new Object[] {g1, "A31-3-1", "GL-1", "YF", "风扇电机", "黑色", "个",
                        new java.math.BigDecimal("12.5"), Boolean.FALSE, Boolean.FALSE,
                        warehouseId, "主仓", colorId, "WAREHOUSE_MASTER"},
                new Object[] {g2, "Y12", "GL-2", null, "残值件", "", "", null, Boolean.TRUE, Boolean.TRUE,
                        null, null, null, "GOODS_MASTER"}));
        StockQueryService service = new StockQueryService(
                null, null, em, mock(StockCostMasker.class));

        var rows = service.shelfLabelRows(null, null, null, true);

        var sql = org.mockito.ArgumentCaptor.forClass(String.class);
        verify(em).createNativeQuery(sql.capture());
        // Java 按下标取数，SQL 列清单（三行 SELECT）一动这个映射就得跟着改
        assertThat(sql.getValue())
                .contains("SELECT r.goods_id, r.place, r.code, r.series, r.name,")
                .contains("r.color_name, r.unit_name, r.qty, r.disabled, r.parsed,")
                .contains("r.warehouse_id, r.warehouse_name, r.color_id, r.place_source");
        assertThat(rows).hasSize(2);
        var first = rows.get(0);
        assertThat(first.getGoodsId()).isEqualTo(g1);
        assertThat(first.getRack()).isEqualTo("A31");
        assertThat(first.getLevel()).isEqualTo(3);
        assertThat(first.getSlot()).isEqualTo(1);
        // DTO 的 parsed/层/位以 Java 侧 ShelfPlaceParser 为真值（SQL 列故意给反值证明不被采信）
        assertThat(first.isParsed()).isTrue();
        assertThat(first.getUnitName()).isEqualTo("个");
        assertThat(first.getQty()).isEqualByComparingTo("12.5");
        assertThat(first.isDisabled()).isFalse();
        assertThat(first.getWarehouseId()).isEqualTo(warehouseId);
        assertThat(first.getWarehouseName()).isEqualTo("主仓");
        assertThat(first.getColorId()).isEqualTo(colorId);
        assertThat(first.getPlaceSource()).isEqualTo("WAREHOUSE_MASTER");
        var second = rows.get(1);
        assertThat(second.getRack()).isEmpty();
        assertThat(second.getLevel()).isNull();
        assertThat(second.getSlot()).isNull();
        assertThat(second.isParsed()).isFalse();
        assertThat(second.getPlace()).isEqualTo("Y12");
        assertThat(second.getQty()).isEqualByComparingTo("0");
        assertThat(second.isDisabled()).isTrue();
        assertThat(second.getWarehouseId()).isNull();
        assertThat(second.getWarehouseName()).isNull();
        assertThat(second.getColorId()).isNull();
        assertThat(second.getPlaceSource()).isEqualTo("GOODS_MASTER");
    }

    @Test
    void shelfLabelLayoutAppendsUnparsedBucketWithEmptyRack() {
        EntityManager em = mock(EntityManager.class);
        Query query = mock(Query.class);
        when(em.createNativeQuery(anyString())).thenReturn(query);
        when(query.setParameter(anyString(), org.mockito.ArgumentMatchers.any())).thenReturn(query);
        when(query.getResultList()).thenReturn(List.of(
                new Object[] {"A30", 2, 9, 4L},
                new Object[] {"", null, null, java.math.BigInteger.valueOf(2)}));
        StockQueryService service = new StockQueryService(
                null, null, em, mock(StockCostMasker.class));

        var layout = service.shelfLabelLayout(null, false);

        var sql = org.mockito.ArgumentCaptor.forClass(String.class);
        verify(em).createNativeQuery(sql.capture());
        assertThat(sql.getValue())
                .contains("MAX(split_part(r.place, '-', 2)::int) AS max_level")
                .contains("WHERE NOT r.parsed")
                .contains("ORDER BY (t.rack = ''), t.rack");
        assertThat(layout).hasSize(2);
        assertThat(layout.get(0).rack()).isEqualTo("A30");
        assertThat(layout.get(0).maxLevel()).isEqualTo(2);
        assertThat(layout.get(0).maxSlot()).isEqualTo(9);
        assertThat(layout.get(0).count()).isEqualTo(4L);
        assertThat(layout.get(0).unparsedBucket()).isFalse();
        assertThat(layout.get(1).unparsedBucket()).isTrue();
        assertThat(layout.get(1).count()).isEqualTo(2L);
        assertThat(layout.get(1).maxLevel()).isNull();
    }

    @Test
    void shelfLabelRacksOnlyReturnParsedRacks() {
        EntityManager em = mock(EntityManager.class);
        Query query = mock(Query.class);
        when(em.createNativeQuery(anyString())).thenReturn(query);
        when(query.setParameter(anyString(), org.mockito.ArgumentMatchers.any())).thenReturn(query);
        when(query.getResultList()).thenReturn(List.of("A30", "A31"));
        StockQueryService service = new StockQueryService(
                null, null, em, mock(StockCostMasker.class));

        var racks = service.shelfLabelRacks(null, false);

        var sql = org.mockito.ArgumentCaptor.forClass(String.class);
        verify(em).createNativeQuery(sql.capture());
        assertThat(sql.getValue()).contains("WHERE r.parsed").contains("SELECT DISTINCT split_part(r.place, '-', 1) AS rack");
        assertThat(racks).containsExactly("A30", "A31");
    }
}
