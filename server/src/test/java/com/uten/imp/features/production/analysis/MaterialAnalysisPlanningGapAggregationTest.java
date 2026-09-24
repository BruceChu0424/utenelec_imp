package com.uten.imp.features.production.analysis;

import org.junit.jupiter.api.Test;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;

import java.math.BigDecimal;
import java.util.List;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.*;

/**
 * ADR-117 车间任务里同一种物料(货品 + 颜色 + 单位)挂在几条需求上、对上分析里几行时的合计口径：
 * 需求各计自己的缺口一次，分析行各计自己的「还缺数量」一次，不交叉重复计。
 */
class MaterialAnalysisPlanningGapAggregationTest {

    private static final UUID SEGMENT = UUID.randomUUID();
    private static final UUID ANALYSIS = UUID.randomUUID();

    private static MaterialAnalysisPlanningGapReader.MaterialGap gap() {
        return new MaterialAnalysisPlanningGapReader.MaterialGap(SEGMENT, ANALYSIS, UUID.randomUUID(),
                "TP-01", "铜片", null, "个");
    }

    private static MaterialAnalysisPlanningGapReader.Node node(String net, boolean confirmed) {
        return new MaterialAnalysisPlanningGapReader.Node(new BigDecimal(net), true, confirmed, "BUY");
    }

    @Test
    void twoDemandsOnOneAnalysisLineCountTheLineOnceAndSpreadTheGapInOrder() {
        var gap = gap();
        UUID line = UUID.randomUUID(), early = UUID.randomUUID(), late = UUID.randomUUID();
        var n = node("60", true);
        // SQL 每条(需求 × 分析行)出一行：两条需求都对上同一行。
        gap.add(early, new BigDecimal("30"), line, n);
        gap.add(late, new BigDecimal("70"), line, n);
        var result = gap.toGap();
        assertEquals(0, new BigDecimal("60").compareTo(result.gapQty()), "分析行只计一次: 60, 不是 120");
        assertEquals(0, new BigDecimal("30").compareTo(result.demandGapQty().get(early)));
        assertEquals(0, new BigDecimal("30").compareTo(result.demandGapQty().get(late)));
        assertEquals(line, result.materialLineId());
        assertTrue(result.routeConfirmed());
    }

    @Test
    void twoAnalysisLinesAddUpButNeverExceedTheTaskShortage() {
        var gap = gap();
        UUID demand = UUID.randomUUID();
        gap.add(demand, new BigDecimal("100"), UUID.randomUUID(), node("40", true));
        gap.add(demand, new BigDecimal("100"), UUID.randomUUID(), node("50", false));
        var result = gap.toGap();
        assertEquals(0, new BigDecimal("90").compareTo(result.gapQty()));
        assertFalse(result.routeConfirmed(), "有一行还没定供应方式");

        var capped = gap();
        capped.add(demand, new BigDecimal("20"), UUID.randomUUID(), node("400", true));
        assertEquals(0, new BigDecimal("20").compareTo(capped.toGap().gapQty()), "封顶到任务自己的缺口");
    }

    @Test
    void noNetShortageMeansPlanningAlreadyOrdered() {
        var gap = gap();
        gap.add(UUID.randomUUID(), new BigDecimal("100"), UUID.randomUUID(), node("0", true));
        assertNull(gap.toGap());
    }

    @Test
    void unclaimedPublicCandidateNeverSettlesThePlanningGap() {
        var em = mock(EntityManager.class);
        var analyses = mock(MaterialAnalysisService.class);
        var query = mock(Query.class);
        UUID materialId = UUID.randomUUID();
        when(em.createNativeQuery(anyString())).thenReturn(query);
        when(query.setParameter("ids", List.of(SEGMENT))).thenReturn(query);
        when(query.getResultList()).thenReturn(java.util.Collections.singletonList(shortRow(materialId)));
        var view = mock(MaterialAnalysisContracts.AnalysisView.class);
        var material = mock(MaterialAnalysisContracts.MaterialView.class);
        when(analyses.detailInternal(ANALYSIS, false)).thenReturn(view);
        when(view.flatMaterials()).thenReturn(List.of(material));
        when(material.materialLineId()).thenReturn(materialId);
        when(material.planningUncoveredQty()).thenReturn(new BigDecimal("100"));
        when(material.netShortageQty()).thenReturn(BigDecimal.ZERO);
        when(material.controlStage()).thenReturn("START");

        var reader = new MaterialAnalysisPlanningGapReader(em, analyses, null, null);
        var result = reader.freshPlanningGaps(List.of(SEGMENT));
        assertFalse(result.isUnknown(SEGMENT));
        assertEquals(1, result.of(SEGMENT).size());
        assertEquals(0, new BigDecimal("100").compareTo(result.of(SEGMENT).getFirst().gapQty()));

        // 缺少权威字段时是未知，绝不能被默认 0 误办结。
        when(material.planningUncoveredQty()).thenReturn(null);
        assertTrue(reader.freshPlanningGaps(List.of(SEGMENT)).isUnknown(SEGMENT));
    }

    @Test
    void failedAnalysisIsReadOnlyOnceAcrossItsMultipleDemands() {
        var em = mock(EntityManager.class);
        var analyses = mock(MaterialAnalysisService.class);
        var query = mock(Query.class);
        when(em.createNativeQuery(anyString())).thenReturn(query);
        when(query.setParameter("ids", List.of(SEGMENT))).thenReturn(query);
        when(query.getResultList()).thenReturn(List.of(shortRow(UUID.randomUUID()), shortRow(UUID.randomUUID())));
        when(analyses.detailInternal(ANALYSIS, false))
                .thenThrow(new ApiException(ErrorCode.CONFLICT, "需要重新分析"));

        var reader = new MaterialAnalysisPlanningGapReader(em, analyses, null, null);
        var result = reader.freshPlanningGaps(List.of(SEGMENT));
        assertTrue(result.isUnknown(SEGMENT));
        assertTrue(result.of(SEGMENT).isEmpty());
        verify(analyses, times(1)).detailInternal(ANALYSIS, false);
    }

    private static Object[] shortRow(UUID materialId) {
        return new Object[]{SEGMENT, UUID.randomUUID(), ANALYSIS, materialId, new BigDecimal("100"),
                UUID.randomUUID(), "TP-01", "铜片", null, "个", null, UUID.randomUUID()};
    }
}
