package com.uten.imp.features.production.analysis;

import com.uten.imp.application.port.WorkshopPlanningGapReadPort;
import com.uten.imp.common.util.NativeQueryResults;
import com.uten.imp.common.util.NativeValueConverters;
import com.uten.imp.features.production.ProductionDocumentAccessPolicy;
import com.uten.imp.security.DocumentAccessPolicy.NativeReadScope;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;
import org.springframework.stereotype.Component;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.time.OffsetDateTime;
import java.util.ArrayList;
import java.util.Collection;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.Set;
import java.util.UUID;

import static com.uten.imp.features.production.analysis.MaterialAnalysisContracts.AnalysisView;
import static com.uten.imp.features.production.analysis.MaterialAnalysisContracts.MaterialView;

/**
 * 车间任务「计划还没下单」的缺料(ADR-117)与计划侧看到的车间催办，只读。
 *
 * <p>缺口判据只有一个数：物料分析那一行的「还缺数量」(netShortageQty，与主表同一列同一个数)。
 * 车间任务里某种物料缺(SHORT / SHORT_MAKE)，而它在分析里对应的行还缺，说明计划还没为它下够单；
 * 分析那一行不缺了(已下采购 / 委外、已排子件计划、仓库现货已分到)，就只是「等到货 / 等子件做完」。
 *
 * <p>车间需求行到分析物料行的对应关系沿用 {@code fn_analysis_plan_material_matches}(计划明细所在
 * 分析行的直接下层) + 货品 / 颜色 / 单位三键——与分析详情里「计划覆盖」同一条连接，不另造口径。
 * 每个分析只算一次完整视图({@link MaterialAnalysisService#detailInternal})，同一请求里的多个车间
 * 任务共用。
 */
@Slf4j
@Component
@RequiredArgsConstructor
public class MaterialAnalysisPlanningGapReader implements WorkshopPlanningGapReadPort {

    private final EntityManager em;
    private final MaterialAnalysisService analyses;
    private final ProductionDocumentAccessPolicy access;
    private final com.uten.imp.features.production.SubcontractDraftPreparationAccessPolicy draftPreparationAccess;

    /**
     * 车间任务需求 → 分析物料行。只取「还缺」的需求(缺口桶)，已领齐、可领、待仓库发料、线边
     * 待投入、备料中的都不是在等计划。没有分析来源的计划(手工计划、品质补产)自然连不上；追加用料
     * 申请(V702)与品质补料周期生成的需求不在物料分析里，也排除。
     */
    private static final String SHORT_DEMAND_SQL = """
            SELECT segment.id, facts.demand_id, plan.material_analysis_id, material.id,
                   facts.shortage_qty, goods.id, goods.code, goods.name, color.name, unit.name,
                   facts.color_id, facts.unit_id
            FROM production_execution_segments segment
            JOIN production_plans plan ON plan.id = segment.plan_id AND NOT plan.is_deleted
             AND plan.material_analysis_id IS NOT NULL AND plan.material_analysis_item_id IS NOT NULL
            CROSS JOIN LATERAL fn_execution_segment_material_facts(segment.id) facts
            JOIN production_material_demands demand ON demand.id = facts.demand_id
             AND demand.material_increment_request_id IS NULL
             AND demand.fqc_replenishment_cycle_id IS NULL
            JOIN production_material_analysis_materials material
              ON material.analysis_id = plan.material_analysis_id AND material.active
             AND material.goods_id = facts.goods_id
             AND material.color_id IS NOT DISTINCT FROM facts.color_id
             AND material.unit_id = facts.unit_id
             AND fn_analysis_plan_material_matches(plan.material_analysis_item_id, material.id)
            JOIN goods ON goods.id = facts.goods_id
            LEFT JOIN colors color ON color.id = facts.color_id
            LEFT JOIN units unit ON unit.id = facts.unit_id
            WHERE segment.id IN (:ids) AND NOT segment.is_deleted
              AND facts.state IN ('SHORT', 'SHORT_MAKE') AND facts.shortage_qty > 0
            ORDER BY segment.id, goods.name, goods.code, facts.demand_id, material.id
            """;

    /** 显示用的分析快照复用多久。 */
    static final long DISPLAY_CACHE_NANOS = java.util.concurrent.TimeUnit.SECONDS.toNanos(20);
    private static final int DISPLAY_CACHE_LIMIT = 256;

    /** 分析 id → (算好的时刻, 表头版本戳, 各物料行的计划口径；null = 这份分析此刻读不出来)。 */
    private final java.util.concurrent.ConcurrentHashMap<UUID, CachedNodes> displayCache =
            new java.util.concurrent.ConcurrentHashMap<>();

    @Override
    @Transactional(readOnly = true)
    public PlanningGaps planningGaps(Collection<UUID> segmentIds) {
        return compute(segmentIds, true);
    }

    @Override
    @Transactional(readOnly = true)
    public PlanningGaps freshPlanningGaps(Collection<UUID> segmentIds) {
        return compute(segmentIds, false);
    }

    private PlanningGaps compute(Collection<UUID> segmentIds, boolean reuse) {
        List<UUID> ids = segmentIds == null ? List.of()
                : segmentIds.stream().filter(Objects::nonNull).distinct().toList();
        if (ids.isEmpty()) return PlanningGaps.NONE;
        List<Object[]> rows = NativeQueryResults.objectArrayRows(
                em.createNativeQuery(SHORT_DEMAND_SQL).setParameter("ids", ids));
        if (rows.isEmpty()) return PlanningGaps.NONE;
        Map<UUID, Map<UUID, Node>> nodesByAnalysis = new HashMap<>();
        Map<UUID, String> stamps = reuse ? stamps(rows) : Map.of();
        Set<UUID> unknown = new LinkedHashSet<>();
        // (任务, 货品 + 颜色 + 单位) → 一条缺口。同一物料可能挂在几条需求上(不同需用日期)、也可能
        // 对上分析里的几行(同一父件下两条 BOM)：需求按条合计自己的缺口，分析行按行各计一次。
        Map<UUID, Map<List<Object>, MaterialGap>> bySegment = new LinkedHashMap<>();
        for (Object[] row : rows) {
            UUID segmentId = (UUID) row[0];
            UUID demandId = (UUID) row[1];
            UUID analysisId = (UUID) row[2];
            UUID materialLineId = (UUID) row[3];
            Map<UUID, Node> nodes = nodesByAnalysis.computeIfAbsent(analysisId,
                    id -> reuse ? cachedNodes(id, stamps.get(id)) : nodesOf(id));
            if (nodes == null) {
                unknown.add(segmentId);
                continue;
            }
            Node node = nodes.get(materialLineId);
            if (node == null || !node.production()) continue;
            List<Object> key = java.util.Arrays.asList(row[5], row[10], row[11]);
            bySegment.computeIfAbsent(segmentId, ignored -> new LinkedHashMap<>())
                    .computeIfAbsent(key, ignored -> new MaterialGap(segmentId, analysisId, (UUID) row[5],
                            (String) row[6], (String) row[7], (String) row[8], (String) row[9]))
                    .add(demandId, positive(NativeValueConverters.toBigDecimal(row[4])), materialLineId, node);
        }
        Map<UUID, List<Gap>> result = new LinkedHashMap<>();
        bySegment.forEach((segmentId, materials) -> {
            if (unknown.contains(segmentId)) return;
            List<Gap> gaps = materials.values().stream().map(MaterialGap::toGap)
                    .filter(Objects::nonNull).toList();
            if (!gaps.isEmpty()) result.put(segmentId, gaps);
        });
        return new PlanningGaps(result, unknown);
    }

    /**
     * 分析表头的版本戳(版本号 + 指纹 + 更新时间)。计划员下单 / 下达、刷新分析都会改它，缓存
     * 随之作废，车间立刻看到新数；只有不经分析的外部变化(比如到货)才最多晚一个缓存周期。
     */
    private Map<UUID, String> stamps(List<Object[]> rows) {
        List<UUID> analysisIds = rows.stream().map(row -> (UUID) row[2]).distinct().toList();
        Map<UUID, String> stamps = new HashMap<>();
        for (Object[] row : NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT id, version::text || '|' || fingerprint || '|' || updated_at::text
                FROM production_material_analyses WHERE id IN (:ids)
                """).setParameter("ids", analysisIds))) {
            stamps.put((UUID) row[0], (String) row[1]);
        }
        return stamps;
    }

    private Map<UUID, Node> cachedNodes(UUID analysisId, String stamp) {
        long now = System.nanoTime();
        CachedNodes cached = displayCache.get(analysisId);
        if (cached != null && stamp != null && stamp.equals(cached.stamp())
                && now - cached.at() < DISPLAY_CACHE_NANOS) {
            return cached.nodes();
        }
        Map<UUID, Node> nodes = nodesOf(analysisId);
        if (displayCache.size() >= DISPLAY_CACHE_LIMIT) {
            displayCache.entrySet().removeIf(entry -> now - entry.getValue().at() >= DISPLAY_CACHE_NANOS);
            if (displayCache.size() >= DISPLAY_CACHE_LIMIT) displayCache.clear();
        }
        if (stamp != null) displayCache.put(analysisId, new CachedNodes(now, stamp, nodes));
        return nodes;
    }

    /**
     * 一个分析每个物料行的计划口径。读不出来(分析已删、BOM 变了要重新分析、视图计算出错)时返回
     * null——「不知道」，不当成「计划已下够单」；数据库错误照常上抛(事务已经不能用了)。
     */
    private Map<UUID, Node> nodesOf(UUID analysisId) {
        try {
            AnalysisView view = analyses.detailInternal(analysisId, false);
            Map<UUID, Node> byLine = new HashMap<>();
            for (MaterialView material : view.flatMaterials()) {
                byLine.put(material.materialLineId(), new Node(
                        positive(material.netShortageQty()),
                        !isNonProductionStage(material.controlStage()),
                        material.routeConfirmed(),
                        material.sourceConfirmed() != null ? material.sourceConfirmed() : material.sourceSuggestion()));
            }
            return byLine;
        } catch (jakarta.persistence.PersistenceException | org.springframework.dao.DataAccessException database) {
            throw database;
        } catch (RuntimeException unavailable) {
            log.warn("车间催计划: 物料分析 {} 暂不可读({}), 本次不判计划缺口",
                    analysisId, unavailable.getClass().getSimpleName());
            return null;
        }
    }

    private static boolean isNonProductionStage(String stage) {
        return MaterialAnalysisService.STAGE_SHIP.equals(stage)
                || MaterialAnalysisService.STAGE_REFERENCE.equals(stage);
    }

    private static BigDecimal positive(BigDecimal value) {
        return value == null || value.signum() < 0 ? BigDecimal.ZERO : value;
    }

    private record CachedNodes(long at, String stamp, Map<UUID, Node> nodes) {
    }

    /** 分析物料行里本功能要的几项：还缺数量、是否生产阶段、路线确认与供应方式。 */
    record Node(BigDecimal net, boolean production, boolean routeConfirmed, String route) {
    }

    /** 任务里一种物料(货品 + 颜色 + 单位)：几条需求的缺口合计、对上的分析行各计一次还缺数量。 */
    static final class MaterialGap {
        private final UUID segmentId;
        private final UUID analysisId;
        private final UUID goodsId;
        private final String goodsCode;
        private final String goodsName;
        private final String colorName;
        private final String unitName;
        private final Map<UUID, BigDecimal> demandShortage = new LinkedHashMap<>();
        private final Map<UUID, Node> lines = new LinkedHashMap<>();

        MaterialGap(UUID segmentId, UUID analysisId, UUID goodsId, String goodsCode, String goodsName,
                    String colorName, String unitName) {
            this.segmentId = segmentId;
            this.analysisId = analysisId;
            this.goodsId = goodsId;
            this.goodsCode = goodsCode;
            this.goodsName = goodsName;
            this.colorName = colorName;
            this.unitName = unitName;
        }

        void add(UUID demandId, BigDecimal shortage, UUID materialLineId, Node node) {
            demandShortage.putIfAbsent(demandId, shortage);
            lines.putIfAbsent(materialLineId, node);
        }

        Gap toGap() {
            BigDecimal net = lines.values().stream().map(Node::net).reduce(BigDecimal.ZERO, BigDecimal::add);
            if (net.signum() <= 0) return null;
            BigDecimal shortage = demandShortage.values().stream().reduce(BigDecimal.ZERO, BigDecimal::add);
            BigDecimal gapQty = net.min(shortage);
            if (gapQty.signum() <= 0) return null;
            // 逐条需求填到它自己的缺口为止，物料表逐行显示「还差多少没下单」。
            Map<UUID, BigDecimal> perDemand = new LinkedHashMap<>();
            BigDecimal left = gapQty;
            for (Map.Entry<UUID, BigDecimal> demand : demandShortage.entrySet()) {
                if (left.signum() <= 0) break;
                BigDecimal share = left.min(demand.getValue());
                if (share.signum() > 0) perDemand.put(demand.getKey(), share);
                left = left.subtract(share);
            }
            Map.Entry<UUID, Node> first = lines.entrySet().iterator().next();
            boolean confirmed = lines.values().stream().allMatch(Node::routeConfirmed);
            return new Gap(segmentId, analysisId, first.getKey(), goodsId, goodsCode, goodsName, colorName,
                    unitName, gapQty, java.util.Collections.unmodifiableMap(perDemand), first.getValue().route(),
                    confirmed);
        }
    }

    // ==================== 计划侧：本分析上的车间催办 ====================

    /**
     * 催了本分析的车间任务(在催的)：哪个任务、谁什么时候催的、催了几次，以及这个任务此刻还缺
     * 的物料对应分析里的哪几行。「计划还缺多少」由前端拿同一份分析快照的「还缺数量」判断——
     * 与主表看到的是同一个数，不在这里再算一遍完整视图。
     */
    @Transactional(readOnly = true)
    public List<WorkshopUrgeView> urges(UUID analysisId) {
        analyses.requireReadableAnalysis(analysisId);
        List<Object[]> rows = NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT urge.id, urge.execution_segment_id, segment.segment_code, plan.bill_no,
                       goods.name, goods.code, department.name, urge.urge_count,
                       urge.last_urged_by_name, urge.last_urged_at, urge.first_urged_at,
                       urge.gap_kind_count, urge.gap_summary
                FROM production_planning_urges urge
                JOIN production_execution_segments segment ON segment.id = urge.execution_segment_id
                JOIN production_plans plan ON plan.id = segment.plan_id
                LEFT JOIN goods ON goods.id = segment.product_goods_id
                LEFT JOIN departments department ON department.id = segment.workshop_department_id
                WHERE urge.material_analysis_id = :analysisId AND urge.status = 'OPEN'
                  AND NOT segment.is_deleted
                ORDER BY urge.last_urged_at DESC, urge.id
                """).setParameter("analysisId", analysisId));
        if (rows.isEmpty()) return List.of();
        Map<UUID, Set<UUID>> linesBySegment = shortMaterialLines(
                rows.stream().map(row -> (UUID) row[1]).toList());
        List<WorkshopUrgeView> result = new ArrayList<>(rows.size());
        for (Object[] row : rows) {
            UUID segmentId = (UUID) row[1];
            result.add(new WorkshopUrgeView((UUID) row[0], segmentId, (String) row[2], (String) row[3],
                    (String) row[4], (String) row[5], (String) row[6], ((Number) row[7]).intValue(),
                    (String) row[8], NativeValueConverters.toOffsetDateTime(row[9]),
                    NativeValueConverters.toOffsetDateTime(row[10]), ((Number) row[11]).intValue(),
                    (String) row[12], List.copyOf(linesBySegment.getOrDefault(segmentId, Set.of()))));
        }
        return result;
    }

    /** 车间任务此刻还缺(缺口桶)的物料在分析里对应的行，不看计划缺不缺——那一步交给前端的快照。 */
    private Map<UUID, Set<UUID>> shortMaterialLines(List<UUID> segmentIds) {
        Map<UUID, Set<UUID>> result = new HashMap<>();
        for (Object[] row : NativeQueryResults.objectArrayRows(
                em.createNativeQuery(SHORT_DEMAND_SQL).setParameter("ids", segmentIds))) {
            result.computeIfAbsent((UUID) row[0], ignored -> new LinkedHashSet<>()).add((UUID) row[3]);
        }
        return result;
    }

    /**
     * 计划员徽章：本人能看到的物料分析上、仍在催的车间任务数。与分析列表同一可见范围
     * (制单人数据范围 + 委外备料直接来源对计划池开放)；缺口已补上但核对任务还没轮到的，最多多计一个核对周期。
     */
    @Transactional(readOnly = true)
    public long openUrgeCount() {
        NativeReadScope scope = access.nativeReadScope("analysis.maker_id", "analysisOwners", access.scope());
        Query count = em.createNativeQuery("""
                SELECT COUNT(*)
                FROM production_planning_urges urge
                JOIN production_material_analyses analysis ON analysis.id = urge.material_analysis_id
                 AND NOT analysis.is_deleted
                WHERE urge.status = 'OPEN' AND %s
                """.formatted(draftPreparationAccess.readPredicate("analysis.id", "(" + scope.predicate() + ")")));
        scope.bind(count);
        return ((Number) count.getSingleResult()).longValue();
    }

    /** 计划侧与车间任务写端共用的可见性闸门：与 GET 物料分析详情同一口径。 */
    public void requireReadableAnalysis(UUID analysisId) {
        analyses.requireReadableAnalysis(analysisId);
    }

    /**
     * 计划侧看到的一条车间催办。
     *
     * @param shortMaterialLineIds 这个车间任务此刻还缺的物料在本分析里对应的物料行
     */
    public record WorkshopUrgeView(
            UUID urgeId,
            UUID segmentId,
            String segmentCode,
            String planNo,
            String productName,
            String productCode,
            String workshopName,
            int urgeCount,
            String lastUrgedByName,
            OffsetDateTime lastUrgedAt,
            OffsetDateTime firstUrgedAt,
            int gapKindCount,
            String gapSummary,
            List<UUID> shortMaterialLineIds) {
    }
}
