package com.uten.imp.features.production.analysis;

import java.math.BigDecimal;
import java.util.ArrayList;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;

import static com.uten.imp.features.production.analysis.MaterialAnalysisContracts.DownstreamReference;
import static com.uten.imp.features.production.analysis.MaterialAnalysisContracts.SupplyActionView;

/**
 * 「按货品档案自动确认供应方式」的唯一判据 (ADR-102, 2026-09-27 起在服务端).
 *
 * <p>以前这条规则在页面里 (进页后再发一次 PUT /routes, 盖全屏遮罩); 现在服务端在「新建/刷新分析」
 * 与「人工改路线」这两类重算里、同一事务直接确认, 页面只显示结果. 详情接口用同一个判据数出
 * 「还有几组可以自动确认」, 页面据此静默刷新一次, 不再自己判断.
 *
 * <p>一个操作组 (与 PUT /routes 按组生效同一粒度, 分组见 {@link MaterialAnalysisService.MaterialGroupIndex})
 * 会被自动确认, 当且仅当组里每一行都满足:
 * <ol>
 *   <li>还没有人确认过路线, 且当前有独立需求 ({@link MaterialAnalysisService.MaterialRow#actionable()});</li>
 *   <li>所属产品没有被计划闸挡住 (与 PUT /routes 同一份 planningBlockedReasons);</li>
 *   <li>路线是「定了的」: 顶层行若已有历史生产计划, 就是自制; 否则取货品档案推出的建议
 *       (采购/自制/委外). 档案空且没有下层 (建议为 REVIEW) 的不碰, 留给人补选;</li>
 *   <li>没有仍有效的下游任务 (未撤销的采购/委外/自制行动、未红冲的顶层产出交接), 挂在它上面的
 *       自制计划也没下达过 —— 这些行改路线要先撤回, 自动确认更不能替人决定;</li>
 *   <li>组里各行定下的路线相同.</li>
 * </ol>
 * 组上还有未撤销的供给行动时整组不动 (人工确认在这里会被「已有不同路线的下游任务」拦下).
 */
final class MaterialAnalysisRouteAutoConfirm {
    /** 与页面「已下达计划量 > 0.0001」同一阈值: 小于这个的尾差不算真的下达过. */
    static final BigDecimal ISSUED_EPSILON = new BigDecimal("0.0001");
    private static final Set<String> ROUTES = Set.of("BUY", "MAKE", "SUBCONTRACT");
    private static final Set<String> ROOT_OUTPUT_DOCUMENTS = Set.of("ROOT_STOCK_ALLOCATION", "ROOT_OUTPUT_FULFILLMENT");

    private MaterialAnalysisRouteAutoConfirm() {}

    /**
     * 自动确认要用到的库内事实. 由 {@link #facts} 从详情投影同一批读取 (来源行、计划状态、锚点、
     * 下游引用、供给行动) 推出, 重算写入与详情计数用的是同一份.
     *
     * @param itemsWithRootPlan 有历史生产计划 (提交/审核量或有效计划关联) 的产品行
     * @param itemsWithIssuedPlan 已下达过计划 (已下达计划量超过尾差) 的产品行
     * @param anchorByMaterial 物料行 → 它的自制锚点产品行 (自制子件任务, 含合单批次成员)
     * @param materialsWithLiveDownstream 挂着仍有效下游单据的物料行
     * @param groupKeysWithLiveAction 还有未撤销供给行动的操作组
     */
    record Facts(Set<UUID> itemsWithRootPlan, Set<UUID> itemsWithIssuedPlan, Map<UUID, UUID> anchorByMaterial,
                 Set<UUID> materialsWithLiveDownstream, Set<String> groupKeysWithLiveAction) {
        Facts {
            itemsWithRootPlan = Set.copyOf(itemsWithRootPlan);
            itemsWithIssuedPlan = Set.copyOf(itemsWithIssuedPlan);
            anchorByMaterial = Map.copyOf(anchorByMaterial);
            materialsWithLiveDownstream = Set.copyOf(materialsWithLiveDownstream);
            groupKeysWithLiveAction = Set.copyOf(groupKeysWithLiveAction);
        }

        /** 这一行自己 (顶层) 或它的锚点子件是否已下达过自制计划. */
        boolean issuedMakePlan(MaterialAnalysisService.MaterialRow row) {
            UUID anchor = row.depth() == 0 ? row.analysisItemId() : anchorByMaterial.get(row.id());
            return anchor != null && itemsWithIssuedPlan.contains(anchor);
        }
    }

    /** 一次判定的结果: 要写的确认 (按行) 与涉及的操作组数 (提示文案里的 N). */
    record Plan(List<MaterialAnalysisRouteBatchWriter.Change> changes, int groupCount) {
        static final Plan NONE = new Plan(List.of(), 0);
    }

    /**
     * 从详情投影的同一批读取推出判据事实.
     *
     * @param planStates 产品行 → 计划执行状态 (只看有没有有效计划)
     * @param anchorByMaterial 物料行 → 自制锚点产品行 (与详情里 planAnchorAnalysisLineId 同一份)
     * @param references 物料行 → 下游引用 (含顶层产出交接)
     * @param actions 本分析的全部供给行动
     */
    static Facts facts(List<MaterialAnalysisService.SourceLine> sources,
                       Map<UUID, MaterialAnalysisService.ProductPlanState> planStates,
                       Map<UUID, UUID> anchorByMaterial,
                       Map<UUID, List<DownstreamReference>> references,
                       List<SupplyActionView> actions) {
        Set<UUID> rootPlan = new HashSet<>();
        Set<UUID> issuedPlan = new HashSet<>();
        for (var source : sources) {
            var state = planStates.getOrDefault(source.analysisItemId(), MaterialAnalysisService.ProductPlanState.NONE);
            if (source.submittedQty().signum() > 0 || source.approvedQty().signum() > 0 || state.planId() != null) {
                rootPlan.add(source.analysisItemId());
            }
            if (issued(source.issuedPlanQty())) issuedPlan.add(source.analysisItemId());
        }
        Set<UUID> liveDownstream = new HashSet<>();
        references.forEach((materialId, refs) -> {
            if (refs.stream().anyMatch(MaterialAnalysisRouteAutoConfirm::live)) liveDownstream.add(materialId);
        });
        Set<String> liveGroups = new HashSet<>();
        for (var action : actions) {
            if (!"CANCELLED".equals(action.status()) && action.actionGroupKey() != null) liveGroups.add(action.actionGroupKey());
        }
        return new Facts(rootPlan, issuedPlan, anchorByMaterial, liveDownstream, liveGroups);
    }

    /**
     * 纯内存预筛 (不查库): 有没有可能被自动确认的行. 为 false 时重算里连事实都不用读.
     */
    static boolean hasCandidates(List<MaterialAnalysisService.MaterialRow> rows, Map<UUID, String> planningBlocks) {
        return rows.stream().anyMatch(row -> row.confirmedRoute() == null && row.actionable()
                && !planningBlocks.containsKey(row.analysisItemId())
                && (row.depth() == 0 || route(row.suggestion()) != null));
    }

    /**
     * 按操作组给出要写的确认. 分组与 PUT /routes 解析决定用的同一份
     * {@link MaterialAnalysisService.MaterialGroupIndex} (只含有独立需求的行).
     */
    static Plan plan(List<MaterialAnalysisService.MaterialRow> rows, Map<UUID, String> planningBlocks, Facts facts) {
        if (!hasCandidates(rows, planningBlocks)) return Plan.NONE;
        List<MaterialAnalysisRouteBatchWriter.Change> result = new ArrayList<>();
        int groups = 0;
        for (var group : MaterialAnalysisService.MaterialGroupIndex.of(rows).byKey().entrySet()) {
            String key = group.getKey();
            if (facts.groupKeysWithLiveAction().contains(key)) continue;
            String route = null;
            boolean eligible = !group.getValue().isEmpty();
            for (var row : group.getValue()) {
                String decided = decide(row, planningBlocks, facts);
                if (decided == null || (route != null && !route.equals(decided))) {
                    eligible = false;
                    break;
                }
                route = decided;
            }
            if (!eligible) continue;
            groups++;
            for (var row : group.getValue()) {
                result.add(new MaterialAnalysisRouteBatchWriter.Change(row.id(), key, row.goodsId(), route, null));
            }
        }
        return new Plan(List.copyOf(result), groups);
    }

    /** 已下达计划量是否算「下达过」. */
    static boolean issued(BigDecimal issuedPlanQty) {
        return issuedPlanQty != null && issuedPlanQty.compareTo(ISSUED_EPSILON) > 0;
    }

    /** 下游引用是否仍然有效: 已撤销的行动、已红冲的顶层产出交接不算. */
    static boolean live(DownstreamReference reference) {
        if ("CANCELLED".equals(reference.status())) return false;
        return !(ROOT_OUTPUT_DOCUMENTS.contains(reference.documentType()) && "REVERSED".equals(reference.status()));
    }

    /** 这一行可以自动定下的路线; 不能自动确认返回 null. */
    private static String decide(MaterialAnalysisService.MaterialRow row, Map<UUID, String> planningBlocks, Facts facts) {
        if (row.confirmedRoute() != null || planningBlocks.containsKey(row.analysisItemId())) return null;
        if (facts.materialsWithLiveDownstream().contains(row.id()) || facts.issuedMakePlan(row)) return null;
        if (row.depth() == 0 && facts.itemsWithRootPlan().contains(row.analysisItemId())) return "MAKE";
        return route(row.suggestion());
    }

    private static String route(String suggestion) {
        return suggestion != null && ROUTES.contains(suggestion) ? suggestion : null;
    }
}
