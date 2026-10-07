package com.uten.imp.features.production.analysis;

/**
 * 子树转发判定的唯一口径。需求侧是否展开子件
 * (MaterialAnalysisService#expandsChildren)、供给侧别名下钻
 * (AggregateMaterialOrderWriteService#SOURCE_DESCENDANTS_SQL)与历史补桥
 * (AggregateMissingDeepAliasRepair)共用同一规则，防止三份实现漂移后
 * 「需求搬走了、供给继承没跟上」再次出现(2026-10-07 现场双订事故)。
 */
final class AggregateRouteForwarding {
    private AggregateRouteForwarding() { }

    /**
     * 有效路线 = 确认路线，未确认用建议路线。自制与委外中间件随共享父件转发
     * 子树(委外节点的直属物料真实消耗，ADR-143 §4.5)；整件采购与无有效路线的
     * 中间件保留自己的子树。自建普通计划的中间件另有 {@code frozen} 判定，不在
     * 本谓词内。
     */
    static boolean forwardsSubtree(String confirmedRoute, String suggestedRoute) {
        String effective = confirmedRoute != null ? confirmedRoute : suggestedRoute;
        return "MAKE".equals(effective) || "SUBCONTRACT".equals(effective);
    }
}
