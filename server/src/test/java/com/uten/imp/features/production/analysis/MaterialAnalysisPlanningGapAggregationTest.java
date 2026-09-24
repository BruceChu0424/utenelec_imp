package com.uten.imp.features.production.analysis;

import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertTrue;

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
}
