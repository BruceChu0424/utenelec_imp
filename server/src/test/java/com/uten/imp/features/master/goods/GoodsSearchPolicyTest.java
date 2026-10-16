package com.uten.imp.features.master.goods;

import com.uten.imp.common.util.CategoryKeywordSearch;
import com.uten.imp.common.util.GoodsSearchPolicy;
import org.junit.jupiter.api.Test;
import java.util.Arrays;
import java.util.List;
import java.util.UUID;
import static org.junit.jupiter.api.Assertions.*;

class GoodsSearchPolicyTest {
    private final UUID screws = UUID.randomUUID(), coated = UUID.randomUUID(), sockets = UUID.randomUUID();
    private final List<CategoryKeywordSearch.Node> nodes = List.of(
            new CategoryKeywordSearch.Node(screws, null, "螺丝类", "C1"),
            new CategoryKeywordSearch.Node(coated, screws, "镀锌件", "C2"),
            new CategoryKeywordSearch.Node(sockets, null, "插座", "C3"));

    @Test void completeCategorySubjectUsesItsBranchWithoutGuessingSubstringOrParentheses() {
        GoodsSearchPolicy policy = new GoodsSearchPolicy("螺丝", nodes, true, false);
        assertTrue(policy.hasCategoryIntent());
        assertEquals("PRIMARY", kind(policy, coated, "M3x20", ""));
        assertEquals("RELATED", kind(policy, sockets, "电话插座（螺丝接线式）", ""));
        assertEquals("PRIMARY", kind(policy, sockets, "螺丝", ""));
        assertEquals(0, policy.rankValue(sockets, "S1", "螺丝", List.of("螺丝", "S1")));
        assertEquals(1, policy.rankValue(sockets, "螺丝", "另一货品", List.of("另一货品", "螺丝")));
        assertTrue(policy.rankValue(coated, "M3", "M3x20", List.of("M3x20", "M3")) < 100);
        assertTrue(policy.rankValue(sockets, "S1", "电话插座（螺丝接线式）", List.of("电话插座（螺丝接线式）", "S1")) >= 100);
        GoodsSearchPolicy connector = new GoodsSearchPolicy("螺丝接线式", nodes, true, false);
        assertFalse(connector.hasCategoryIntent());
        assertEquals("PRIMARY", kind(connector, sockets, "电话插座（螺丝接线式）", ""));
    }

    @Test void mixedWordsAndGenericSuffixStillRequireRemainingIdentityWords() {
        for (String query : List.of("螺丝\u3000M3", "螺丝类 M3", "螺丝类别 M3")) {
            GoodsSearchPolicy policy = new GoodsSearchPolicy(query, nodes, true, true);
            assertEquals("PRIMARY", kind(policy, coated, "M3x20", ""));
            assertEquals("RELATED", kind(policy, coated, "M4x20", ""));
            assertEquals("RELATED", kind(policy, sockets, "M3电话插座（螺丝接线式）", ""));
        }
    }

    @Test void callerCanDisableInferenceAndEmptyQueryDoesNotActivateMetadata() {
        GoodsSearchPolicy selected = new GoodsSearchPolicy("螺丝", nodes, false, false);
        assertFalse(selected.hasCategoryIntent());
        assertEquals("PRIMARY", kind(selected, sockets, "电话插座（螺丝接线式）", ""));
        for (boolean related : List.of(false, true)) {
            GoodsSearchPolicy empty = new GoodsSearchPolicy(" \u3000\t ", nodes, true, related);
            assertFalse(empty.active());
            assertNull(empty.matchKind(null, null, null, Arrays.asList(null, null)));
            assertEquals(0, empty.rankValue(null, null, null, Arrays.asList(null, null)));
            assertEquals("TRUE", empty.nativeSearch("q", "g.category_id", "g.code", "g.name", List.of("g.name"), List.of("g.paper")).condition());
        }
    }

    @Test void preferKeepsIdentityMatchesButPlacesActualSubjectsBeforeFeatureMentions() {
        GoodsSearchPolicy prefer = new GoodsSearchPolicy("螺丝", nodes, true, false, GoodsSearchPolicy.SubjectMode.PREFER);
        assertEquals("PRIMARY", kind(prefer, sockets, "电话插座（螺丝接线式）", ""));
        int actual=prefer.rankValue(coated,"P","M3x20",List.of("M3x20","P"));
        int feature=prefer.rankValue(sockets,"F","电话插座（螺丝接线式）",List.of("电话插座（螺丝接线式）","F"));
        assertTrue(actual<feature);assertTrue(feature<100);
    }

    @Test void subjectHeadProofRetainsOriginalDimensionWordsAndDoesNotPromoteParentheticalFeatures() {
        GoodsSearchPolicy policy = new GoodsSearchPolicy("螺丝 4*50", nodes, true, true);
        for(String name:List.of("螺丝","加长安装螺丝","铁螺丝（4*50）","加长安装螺丝4*50","加长\u00a0安装螺丝 4*50")) {
            assertEquals("PRIMARY",kind(policy,null,name,"4*50"),name);
        }
        for(String name:List.of("电话插座（螺丝接线式4*50）","出线片组件(铁螺丝4*50)","出线片组件【铁螺丝4*50】","螺丝4位接线式4*50")) {
            assertEquals("RELATED",kind(policy,null,name,"4*50"),name);
        }
        assertEquals(2,policy.rankValue(null,"Z","螺丝",List.of("螺丝","4*50")));
        assertTrue(policy.rankValue(null,"Z","螺丝",List.of("螺丝","4*50"))
                <policy.rankValue(null,"A","加长安装螺丝",List.of("加长安装螺丝","4*50")));
        var english=List.of(new CategoryKeywordSearch.Node(UUID.randomUUID(),null,"lock类","L"));
        GoodsSearchPolicy lock=new GoodsSearchPolicy("lock",english,true,true);
        assertEquals("RELATED",kind(lock,null,"clock",""));
    }

    @Test void fullVisibleIdentityExactMatchSurvivesAnOverlappingSeriesCategory() {
        var seriesNodes=List.of(new CategoryKeywordSearch.Node(UUID.randomUUID(),null,"V9.1","S"));
        GoodsSearchPolicy series=new GoodsSearchPolicy("V9.1",seriesNodes,true,true);
        assertEquals("PRIMARY",kind(series,null,"型号本体","V9.1"));
        assertEquals("RELATED",kind(series,null,"部分型号描述","X V9.1 feature"));
        assertTrue(series.rankValue(null,"M","型号本体",List.of("型号本体","M","V9.1"))<100);
    }

    @Test void disjointSubjectsFallBackWhileNestedSubjectsRetainTheirCommonBranch() {
        GoodsSearchPolicy ambiguous = new GoodsSearchPolicy("螺丝 插座", nodes, true, false);
        assertFalse(ambiguous.hasCategoryIntent());
        assertEquals("PRIMARY", kind(ambiguous, sockets, "电话插座（螺丝接线式）", ""));
        UUID cross = UUID.randomUUID();
        var nestedNodes = new java.util.ArrayList<>(nodes);
        nestedNodes.add(new CategoryKeywordSearch.Node(cross, screws, "十字螺丝", "C4"));
        GoodsSearchPolicy nested = new GoodsSearchPolicy("螺丝 十字螺丝", nestedNodes, true, true);
        assertTrue(nested.hasCategoryIntent());
        assertEquals("PRIMARY", kind(nested, cross, "M3x20", ""));
        assertEquals("RELATED", kind(nested, sockets, "电话插座（十字螺丝接线式）", ""));
    }

    private String kind(GoodsSearchPolicy policy, UUID category, String name, String model) {
        return policy.matchKind(category, "CODE", name, Arrays.asList(name, "CODE", model));
    }
}
