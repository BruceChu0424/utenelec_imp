package com.uten.imp.common.util;

import org.junit.jupiter.api.Test;

import java.util.List;
import java.util.Set;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;

class CategoryKeywordSearchTest {
    @Test
    void crossBatchRanksUseTheSameTrimSemanticsAsTheDatabase() {
        var plan = CategoryKeywordSearch.plan("Metric Screw", List.of());
        assertEquals(0, plan.rankValue(null, "OTHER", " Metric Screw ", List.of(" Metric Screw ")));
        assertEquals(3, plan.rankValue(null, "OTHER", "Metric  Screw", List.of("Metric  Screw")));
        assertEquals(2, plan.rankValue(null, "OTHER", "\tMetric Screw", List.of("\tMetric Screw")));
        UUID category = UUID.randomUUID();
        var doubleSpace = CategoryKeywordSearch.plan("Metric Screw", List.of(
                new CategoryKeywordSearch.Node(category, null, "Metric  Screw", "CATEGORY")));
        assertEquals(14, doubleSpace.rankValue(category, "OTHER", "Widget", List.of("Widget")));
        var leadingTab = CategoryKeywordSearch.plan("Screw", List.of(
                new CategoryKeywordSearch.Node(category, null, "\tScrew", "CATEGORY")));
        assertEquals(14, leadingTab.rankValue(category, "OTHER", "Widget", List.of("Widget")));
    }

    @Test
    void namesOutrankCodesAndOtherPrimaryCategoryAndIndirectMatches() {
        UUID category = UUID.randomUUID();
        var plan = CategoryKeywordSearch.plan("Screw", List.of(new CategoryKeywordSearch.Node(category, null, "Screw", "C")));
        assertEquals(0, plan.rankValue(null, "OTHER", "Screw", List.of("Screw", "OTHER")));
        assertEquals(1, plan.rankValue(null, "OTHER", "Screw M3", List.of("Screw M3", "OTHER")));
        assertEquals(2, plan.rankValue(null, "OTHER", "Metric Screw", List.of("Metric Screw", "OTHER")));
        assertEquals(4, plan.rankValue(null, "SCREW", "Widget", List.of("Widget", "SCREW")));
        assertEquals(8, plan.rankValue(null, "OTHER", "Widget", List.of("Widget", "OTHER", "Screw")));
        assertEquals(12, plan.rankValue(category, "OTHER", "Widget", List.of("Widget", "OTHER")));
        assertEquals(15, plan.rankValue(null, "OTHER", "Widget", List.of("Widget", "OTHER")));
    }

    @Test
    void categoryWordsIncludeEveryDescendantAndHandleCyclesWithoutCrossingToSiblings() {
        UUID root = UUID.randomUUID(), screws = UUID.randomUUID(), coated = UUID.randomUUID(), switches = UUID.randomUUID();
        var plan = CategoryKeywordSearch.plan("螺丝 M3", List.of(
                new CategoryKeywordSearch.Node(root, null, "原材料", "ROOT"),
                new CategoryKeywordSearch.Node(screws, root, "螺丝类", "FL000189"),
                new CategoryKeywordSearch.Node(coated, screws, "镀锌件", "FL189A"),
                new CategoryKeywordSearch.Node(switches, root, "开关", "FL_OTHER")));
        assertEquals(Set.of(screws, coated), plan.containingCategories("螺丝"));
        assertEquals(Set.of(), plan.containingCategories("m3"));
        var cycle = CategoryKeywordSearch.plan("螺丝", List.of(
                new CategoryKeywordSearch.Node(screws, coated, "螺丝", "A"),
                new CategoryKeywordSearch.Node(coated, screws, "镀锌", "B")));
        assertEquals(Set.of(screws, coated), cycle.containingCategories("螺丝"));
    }
}
