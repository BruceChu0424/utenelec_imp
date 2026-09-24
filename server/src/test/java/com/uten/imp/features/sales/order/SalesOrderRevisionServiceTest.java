package com.uten.imp.features.sales.order;

import com.fasterxml.jackson.databind.ObjectMapper;
import org.junit.jupiter.api.Test;

import java.time.OffsetDateTime;
import java.util.ArrayList;
import java.util.List;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;

class SalesOrderRevisionServiceTest {
    private final ObjectMapper mapper = new ObjectMapper();

    @Test
    void reviewShowsChangedHeaderAndAddedRemovedAndRevisedLinesWithoutLosingValues() throws Exception {
        var before = mapper.readTree("""
                {"订单信息":{"交货日期":"2026-09-10","备注":"旧备注"},
                 "产品明细":{"a":{"行号":1,"货品":"A","数量":10},
                               "b":{"行号":2,"货品":"B","数量":5}}}
                """);
        var after = mapper.readTree("""
                {"订单信息":{"交货日期":"2026-09-20","备注":"旧备注"},
                 "产品明细":{"a":{"行号":1,"货品":"A","数量":12},
                               "c":{"行号":3,"货品":"C","数量":7}}}
                """);
        var changes = new ArrayList<SalesOrderRevisionService.FieldChange>();
        SalesOrderRevisionService.collectChanges("", before, after,
                "销售员", OffsetDateTime.now(), changes);
        assertThat(changes).hasSize(4);
        assertThat(changes).anySatisfy(change -> {
            assertThat(change.field()).isEqualTo("订单信息 / 交货日期");
            assertThat(change.beforeValue()).isEqualTo("2026-09-10");
            assertThat(change.afterValue()).isEqualTo("2026-09-20");
        });
        assertThat(changes).anySatisfy(change -> {
            assertThat(change.field()).contains("第 2 行 B");
            assertThat(change.beforeValue()).contains("数量: 5");
            assertThat(change.afterValue()).isEqualTo("未设置");
        });
        assertThat(changes).noneMatch(change -> change.field().contains("备注"));
    }

    @Test
    void structuredDiffKeepsFullOriginalAndLatestRowsAndStableIdentity() throws Exception {
        var before = mapper.readTree("""
                {"订单信息":{"备注":"旧备注"},"产品明细":{
                  "unchanged":{"行号":1,"货品":{"id":"g0","label":"原货品"},"数量":2},
                  "modified":{"行号":2,"货品":{"id":"g1","label":"A · 货品A"},"数量":10,"颜色":"红色","单价":8,"备注":"需保留"},
                  "removed":{"行号":3,"货品":"被删货品","数量":5}}}
                """);
        var after = mapper.readTree("""
                {"订单信息":{"备注":"新备注"},"产品明细":{
                  "unchanged":{"行号":1,"货品":{"id":"g0","label":"原货品","code":"0","name":"原货品"},"数量":2.0000},
                  "modified":{"行号":2,"货品":{"id":"g1","label":"A · 货品A","code":"A","name":"货品A"},"数量":12,"颜色":"红色","单价":8,"备注":"需保留"},
                  "added":{"行号":4,"货品":{"id":"g2","label":"B · 新货品","code":"B","name":"新货品"},"数量":7}}}
                """);
        var diff = SalesOrderRevisionService.buildDiff(before, after, true, "销售员", OffsetDateTime.now());
        assertThat(diff.baselineComplete()).isTrue();
        assertThat(diff.changedItemIds()).containsExactly("modified", "removed", "added");
        assertThat(diff.beforeItems()).extracting(SalesOrderRevisionService.RevisionLine::itemId)
                .containsExactly("unchanged", "modified", "removed");
        assertThat(diff.beforeItems().get(1).values()).containsEntry("数量", "10")
                .containsEntry("颜色", "红色").containsEntry("单价", "8").containsEntry("备注", "需保留");
        assertThat(diff.beforeItems().get(1).goodsCode()).isNull();
        assertThat(diff.beforeItems().get(1).values()).containsEntry("货品", "A · 货品A");
        assertThat(diff.afterItems().get(1).goodsCode()).isEqualTo("A");
        assertThat(diff.afterItems().get(1).goodsName()).isEqualTo("货品A");
        assertThat(diff.afterItems().get(1).values()).containsEntry("数量", "12");
        assertThat(diff.headerChanges()).singleElement().satisfies(change -> {
            assertThat(change.field()).isEqualTo("备注");
            assertThat(change.beforeValue()).isEqualTo("旧备注");
            assertThat(change.afterValue()).isEqualTo("新备注");
        });
    }

    @Test
    void multipleEditsCompareFirstBeforeToLastAfterAndUndoHasNoNetDifference() {
        var entityManager = org.mockito.Mockito.mock(jakarta.persistence.EntityManager.class);
        var revisions = org.mockito.Mockito.mock(jakarta.persistence.Query.class);
        var quantities = org.mockito.Mockito.mock(jakarta.persistence.Query.class);
        org.mockito.Mockito.when(entityManager.createNativeQuery(org.mockito.ArgumentMatchers.contains("SELECT CAST(log.before_snapshot")))
                .thenReturn(revisions);
        org.mockito.Mockito.when(entityManager.createNativeQuery(org.mockito.ArgumentMatchers.contains("SELECT changes.order_item_id")))
                .thenReturn(quantities);
        org.mockito.Mockito.when(revisions.setParameter(org.mockito.ArgumentMatchers.eq("id"), org.mockito.ArgumentMatchers.any()))
                .thenReturn(revisions);
        org.mockito.Mockito.when(quantities.setParameter(org.mockito.ArgumentMatchers.eq("id"), org.mockito.ArgumentMatchers.any()))
                .thenReturn(quantities);
        var at = OffsetDateTime.now();
        String first = "{\"订单信息\":{},\"产品明细\":{\"a\":{\"行号\":1,\"数量\":10,\"单价\":1234567890123456.7891}}}";
        String middle = first.replace("\"数量\":10", "\"数量\":8");
        String last = first.replace("\"数量\":10", "\"数量\":6");
        org.mockito.Mockito.when(revisions.getResultList()).thenReturn(List.of(
                new Object[]{first, middle, "一", at}, new Object[]{middle, last, "二", at.plusSeconds(1)}));
        org.mockito.Mockito.when(quantities.getResultList()).thenReturn(List.of());
        var service = new SalesOrderRevisionService(entityManager, mapper, null);
        var diff = service.pendingDiff(UUID.randomUUID());
        assertThat(diff.beforeItems().getFirst().values()).containsEntry("数量", "10")
                .containsEntry("单价", "1234567890123456.7891");
        assertThat(diff.afterItems().getFirst().values()).containsEntry("数量", "6");
        org.mockito.Mockito.when(revisions.getResultList()).thenReturn(List.of(
                new Object[]{first, middle, "一", at}, new Object[]{middle, first, "二", at.plusSeconds(1)}));
        assertThat(service.pendingDiff(UUID.randomUUID()).changedItemIds()).isEmpty();
        org.mockito.Mockito.when(revisions.getResultList()).thenReturn(List.of());
        assertThat(service.pendingDiff(UUID.randomUUID())).isNull();
    }

    @Test
    void legacyQuantityRowsNeverPretendCurrentPricesAreHistoricalAndUndoIsUnchanged() throws Exception {
        var oldRows = mapper.readTree("""
                {"产品明细":{"a":{"数量":10},"b":{"数量":5}}}
                """);
        var current = mapper.readTree("""
                {"订单信息":{"备注":"现在的备注"},"产品明细":{
                  "a":{"行号":1,"货品":"A","数量":10,"单价":99},
                  "b":{"行号":2,"货品":"B","数量":7,"单价":888}}}
                """);
        var diff = SalesOrderRevisionService.buildDiff(oldRows, current, false, "", null);
        assertThat(diff.baselineComplete()).isFalse();
        assertThat(diff.changedItemIds()).containsExactly("b");
        assertThat(diff.beforeItems().getFirst().values()).containsOnlyKeys("数量");
        assertThat(diff.headerChanges()).isEmpty();
    }

    @Test
    void deletingAnEarlierLineDoesNotMarkAnUnchangedRenumberedProductAsEdited() throws Exception {
        var before=mapper.readTree("""
                {"产品明细":{"deleted":{"行号":1,"货品":"A","数量":3},
                             "kept":{"行号":2,"货品":"B","数量":5}}}
                """);
        var after=mapper.readTree("""
                {"产品明细":{"kept":{"行号":1,"货品":"B","数量":5}}}
                """);
        assertThat(SalesOrderRevisionService.buildDiff(before,after,true,"",null).changedItemIds())
                .containsExactly("deleted");
    }
}
