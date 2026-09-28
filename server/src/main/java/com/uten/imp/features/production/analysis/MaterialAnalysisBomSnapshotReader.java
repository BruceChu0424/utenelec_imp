package com.uten.imp.features.production.analysis;

import com.uten.imp.common.util.NativeQueryResults;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;

/**
 * Reads an admitted batch's BOM graphs in two bounded database round trips.
 * Validation retains cycle, depth and deleted-master guards. Rows remain keyed
 * by the analysis item UUID so repeated goods never merge independent demand.
 * The result is scoped to this invocation; no cache survives a master-data edit.
 * Parameterized lateral edge reads retain the current root/frontier bound when
 * PostgreSQL estimates a large recursive forest; unrelated historical BOMs must
 * not become the recursive step's input. OFFSET 0 preserves that query boundary.
 *
 * <p>ADR-129: each edge carries the results of {@code v_goods_bom_item_usage} as they
 * are: design usage, the live actual usage (the view's own rounded effective value,
 * null unless the view uses it), status, linearity, sample count and the defect rate
 * that goes with that actual usage. Which one a node
 * adopts, and its per-product quantity, is decided in Java
 * ({@code MaterialAnalysisService.bomNodes}); no usage rule is re-derived here.</p>
 */
final class MaterialAnalysisBomSnapshotReader {
    private final EntityManager em;

    MaterialAnalysisBomSnapshotReader(EntityManager em) { this.em = em; }

    Map<UUID, List<Object[]>> read(List<MaterialAnalysisService.SourceLine> sources) {
        if (sources.isEmpty()) return Map.of();
        for (var source : sources) {
            if (source.unitRate() == null || source.unitRate().signum() <= 0) {
                throw conflict("生产需求单位换算率必须大于零");
            }
        }
        validate(sources.stream().map(MaterialAnalysisService.SourceLine::goodsId).distinct().toList());
        StringBuilder roots = new StringBuilder("VALUES ");
        for (int i = 0; i < sources.size(); i++) {
            if (i > 0) roots.append(',');
            roots.append("(CAST(:source").append(i).append(" AS uuid),CAST(:goods")
                    .append(i).append(" AS uuid))");
        }
        Query query = em.createNativeQuery(TREE_SQL.formatted(roots));
        for (int i = 0; i < sources.size(); i++) {
            var source = sources.get(i);
            query.setParameter("source" + i, source.analysisItemId())
                    .setParameter("goods" + i, source.goodsId());
        }
        Map<UUID, List<Object[]>> result = new LinkedHashMap<>();
        for (Object[] row : NativeQueryResults.objectArrayRows(query)) {
            result.computeIfAbsent((UUID) row[24], ignored -> new ArrayList<>()).add(row);
        }
        return result;
    }

    /**
     * 同一条查询、同样的判定口径(循环、超过十层、非正用量、组件已删、单位/颜色失效或老库
     * 颜色未桥接)，但不再只回一个布尔：返回具体违规行(父件 → 组件 + 原因)，按问题去重，
     * 报错列出前 {@value #SHOWN_FINDINGS} 条并说明怎么修(ADR-111)。
     */
    private void validate(List<UUID> goodsIds) {
        List<Object[]> findings = NativeQueryResults.objectArrayRows(em.createNativeQuery(VALIDATION_SQL)
                .setParameter("goodsIds", goodsIds.stream().map(UUID::toString)
                        .collect(java.util.stream.Collectors.joining(","))));
        if (findings.isEmpty()) return;
        long total = ((Number) findings.getFirst()[8]).longValue();
        StringBuilder message = new StringBuilder("物料分析用到的 BOM 有 ").append(total)
                .append(" 处问题，修好后才能分析：");
        int index = 1;
        for (Object[] finding : findings) {
            message.append('\n').append(index++).append(") ").append(describe(finding));
        }
        if (total > findings.size()) {
            message.append("\n……还有 ").append(total - findings.size()).append(" 处未列出，修好上面几处后再试一次会继续提示");
        }
        throw conflict(message.toString());
    }

    /** 一条违规：「成品」的 BOM 里「父件」→ 组件「组件」：原因。怎么修。 */
    private static String describe(Object[] finding) {
        String root = label(finding[1], finding[2]);
        String parent = label(finding[3], finding[4]);
        String component = label(finding[5], finding[6]);
        int depth = ((Number) finding[7]).intValue();
        List<String> reasons = new ArrayList<>();
        java.util.Set<String> fixes = new java.util.LinkedHashSet<>();
        for (String code : String.valueOf(finding[0]).split(",")) {
            Problem problem = PROBLEMS.get(code);
            if (problem == null) continue;
            reasons.add(problem.reason());
            fixes.add(problem.fix());
        }
        String where = depth == 1 || root.equals(parent)
                ? "「" + parent + "」的 BOM 里，组件「" + component + "」"
                : "「" + root + "」往下第 " + depth + " 层，「" + parent + "」→ 组件「" + component + "」";
        return where + "：" + String.join("、", reasons) + "。" + String.join("；", fixes) + "。";
    }

    private static String label(Object code, Object name) {
        String text = (code == null ? "" : code.toString().strip()) + " "
                + (name == null ? "" : name.toString().strip());
        return text.isBlank() ? "(未命名货品)" : text.strip();
    }

    private record Problem(String reason, String fix) { }

    /** SQL 里的原因代号 → 给人看的原因与修法(代号不出现在界面上)。 */
    private static final Map<String, Problem> PROBLEMS = Map.of(
            "CYCLE", new Problem("组装关系绕回了上层(循环引用)",
                    "请检查这几层 BOM，去掉把上层货品加成下层组件的那一行"),
            "TOO_DEEP", new Problem("组装层级超过十层",
                    "请检查是否误把上层货品加成了下层组件，或合并中间层"),
            "QTY", new Problem(MaterialConsumptionMath.NON_POSITIVE_BOM_QTY_REASON,
                    MaterialConsumptionMath.NON_POSITIVE_BOM_QTY_FIX),
            "COMPONENT_DELETED", new Problem("组件货品已被删除", "请在父件的 BOM 里移除或换掉这个组件"),
            "UNIT_MISSING", new Problem("组件没有设置基本单位", "请到货品资料里给组件设置基本单位"),
            "UNIT_DELETED", new Problem("组件的基本单位已被删除", "请到货品资料里给组件换一个有效的基本单位"),
            "ROW_COLOR_DELETED", new Problem("这一行指定的颜色已被删除", "请在父件的 BOM 里给这一行换一个颜色"),
            "COMPONENT_COLOR_DELETED", new Problem("组件的主颜色已被删除", "请到货品资料里给组件换一个颜色"),
            "ROW_COLOR_LEGACY", new Problem("这一行的颜色是老系统颜色，还没对应到新颜色",
                    "请在父件的 BOM 里给这一行重新选择颜色"),
            "COMPONENT_COLOR_LEGACY", new Problem("组件的主颜色是老系统颜色，还没对应到新颜色",
                    "请到货品资料里给组件重新选择颜色"));

    /** 报错里最多列出的违规条数。 */
    private static final int SHOWN_FINDINGS = 5;

    private static ApiException conflict(String message) { return new ApiException(ErrorCode.CONFLICT, message); }

    /**
     * 列序：0-7 边与层级路径；8 设计使用数量(b.qty)；9 现时真实使用数量(视图算好的采用值，
     * 不采用真实值时为 NULL)；10 真实使用数量状态；11-23 组件与计量规则；24 来源行；25 有效批次；
     * 26 该边是否线性(视图口径)；27 与真实值一起的报工不良率(没有真实值时为 NULL)。用量按边做参数化
     * LATERAL 读取，与递归边读取一样不把无关的历史 BOM 拉进来。
     */
    private static final String TREE_SQL = """
                WITH RECURSIVE roots(analysis_item_id, goods_id) AS (%s), exp AS (
                    SELECT roots.analysis_item_id AS source_id, b.id AS bom_item_id, b.goods_id AS parent_goods_id,
                           b.component_goods_id AS goods_id,
                           resolved_color.id AS color_id,
                           component_unit.id AS unit_id,
                           1 AS depth, ARRAY[b.id]::uuid[] AS bom_path,
                           b.qty AS design_qty,
                           component.code, component.name, component.spec,
                           resolved_color.name AS color_name,
                           component_unit.name AS unit_name,
                           GREATEST(COALESCE(component.min_qty,0),0)::numeric AS safety_stock,
                           component.source_type,
                           EXISTS (SELECT 1 FROM goods_bom_items child
                                   WHERE child.goods_id = b.component_goods_id
                                     AND child.is_deleted = FALSE LIMIT 1 OFFSET 0) AS has_children,
                           b.control_stage, b.consumption_basis,
                           b.basis_output_qty, b.allow_partial_package, b.hard_gate
                    FROM roots
                    JOIN LATERAL (
                        SELECT edge.* FROM goods_bom_items edge
                        WHERE edge.goods_id = roots.goods_id AND edge.is_deleted = FALSE
                        OFFSET 0
                    ) b ON TRUE
                    JOIN goods component ON component.id = b.component_goods_id
                                         AND component.is_deleted = FALSE
                    LEFT JOIN colors resolved_color ON resolved_color.id =
                        COALESCE(b.color_id, component.color_id)
                                                    AND resolved_color.is_deleted = FALSE
                    LEFT JOIN units component_unit ON component_unit.id = component.unit_id
                                                   AND component_unit.is_deleted = FALSE
                    WHERE b.is_deleted = FALSE
                    UNION ALL
                    SELECT exp.source_id, b.id, b.goods_id, b.component_goods_id,
                           resolved_color.id,
                           component_unit.id,
                           exp.depth + 1, exp.bom_path || b.id,
                           b.qty,
                           component.code, component.name, component.spec,
                           resolved_color.name,
                           component_unit.name,
                           GREATEST(COALESCE(component.min_qty,0),0)::numeric,
                           component.source_type,
                           EXISTS (SELECT 1 FROM goods_bom_items child
                                   WHERE child.goods_id = b.component_goods_id
                                     AND child.is_deleted = FALSE LIMIT 1 OFFSET 0),
                           b.control_stage, b.consumption_basis,
                           b.basis_output_qty, b.allow_partial_package, b.hard_gate
                    FROM exp
                    JOIN LATERAL (
                        SELECT edge.* FROM goods_bom_items edge
                        WHERE edge.goods_id = exp.goods_id AND edge.is_deleted = FALSE
                        OFFSET 0
                    ) b ON TRUE
                    JOIN goods component ON component.id = b.component_goods_id
                                         AND component.is_deleted = FALSE
                    LEFT JOIN colors resolved_color ON resolved_color.id =
                        COALESCE(b.color_id, component.color_id)
                                                    AND resolved_color.is_deleted = FALSE
                    LEFT JOIN units component_unit ON component_unit.id = component.unit_id
                                                   AND component_unit.is_deleted = FALSE
                    WHERE exp.depth < 10 AND NOT b.id = ANY(exp.bom_path)
                )
                SELECT exp.bom_item_id, exp.parent_goods_id, exp.goods_id, exp.color_id, exp.unit_id,
                       exp.depth, array_to_string(exp.bom_path, '/'),
                        CASE WHEN exp.depth = 1 THEN NULL
                             ELSE array_to_string(trim_array(exp.bom_path, 1), '/') END,
                       exp.design_qty, edge_usage.actual_qty, edge_usage.actual_status,
                       exp.code, exp.name, exp.spec, exp.color_name, exp.unit_name,
                       exp.safety_stock, exp.source_type, exp.has_children,
                       exp.control_stage, exp.consumption_basis, exp.basis_output_qty,
                       exp.allow_partial_package, exp.hard_gate, exp.source_id,
                       edge_usage.sample_count, edge_usage.linear, edge_usage.defect_rate
                FROM exp
                """ + edgeUsageLateral("exp.bom_item_id") + """
                ORDER BY exp.source_id, exp.bom_path
                """;

    /**
     * 一条 BOM 边的现时用量，别名 edge_usage，全部原样取 {@code v_goods_bom_item_usage} 的结果：
     * 设计使用数量、真实使用数量(视图采用真实值时的 effective_qty，即视图的取整结果；否则为 NULL)、
     * 状态、线性、有效批次，以及与真实值一起的报工不良率(同一条件，没有真实值时为 NULL；按落库的
     * NUMERIC(9,6) 在这里四舍五入到 6 位，只此一处)。快照读取与人工刷新采用
     * ({@code MaterialAnalysisService.adoptLatestBomUsage}) 共用这一段；取整、线性与状态规则只在视图里
     * 定义一次。视图只按边主键参数化读取(OFFSET 0 保住查询边界)，不作 FOR UPDATE 目标。
     */
    static String edgeUsageLateral(String bomItemIdExpression) {
        return """
                LEFT JOIN LATERAL (
                    SELECT usage_row.design_qty,
                           CASE WHEN usage_row.usage_basis = 'ACTUAL' THEN usage_row.effective_qty END AS actual_qty,
                           usage_row.actual_status, usage_row.sample_count, usage_row.linear,
                           CASE WHEN usage_row.usage_basis = 'ACTUAL' THEN round(usage_row.defect_rate, 6) END
                               AS defect_rate
                    FROM v_goods_bom_item_usage usage_row
                    WHERE usage_row.bom_item_id = %s
                    OFFSET 0
                ) edge_usage ON TRUE
                """.formatted(bomItemIdExpression);
    }

    /**
     * 每条边自己的问题代号(逗号分隔，没问题为 NULL)。锚点与递归两段共用同一表达式，
     * 判定口径与原先的 invalid 布尔完全一致，只是把「哪一条」「为什么」一并带出来。
     */
    private static final String EDGE_PROBLEMS = """
                NULLIF(concat_ws(',',
                    CASE WHEN b.qty <= 0 THEN 'QTY' END,
                    CASE WHEN component.is_deleted THEN 'COMPONENT_DELETED' END,
                    CASE WHEN component.unit_id IS NULL THEN 'UNIT_MISSING'
                         WHEN component_unit.id IS NULL THEN 'UNIT_DELETED' END,
                    CASE WHEN COALESCE(b.color_id, component.color_id) IS NOT NULL
                              AND resolved_color.id IS NULL
                         THEN CASE WHEN b.color_id IS NOT NULL THEN 'ROW_COLOR_DELETED'
                                   ELSE 'COMPONENT_COLOR_DELETED' END END,
                    CASE WHEN b.color_id IS NULL
                              AND NULLIF(b.color_legacy_id,0) IS NOT NULL THEN 'ROW_COLOR_LEGACY' END,
                    CASE WHEN component.color_id IS NULL
                              AND NULLIF(component.color_legacy_id,0) IS NOT NULL THEN 'COMPONENT_COLOR_LEGACY' END
                ), '')""";

    private static final String VALIDATION_SQL = """
                WITH RECURSIVE roots(goods_id) AS (
                    SELECT DISTINCT unnest(CAST(string_to_array(:goodsIds, ',') AS uuid[]))
                ), walk AS (
                    SELECT b.id, roots.goods_id AS root_goods_id, b.goods_id AS parent_goods_id,
                           b.component_goods_id AS goods_id, 1 AS depth,
                           ARRAY[b.id]::uuid[] AS path, FALSE AS cycle,
                           %1$s AS problems
                    FROM roots
                    JOIN LATERAL (
                        SELECT edge.* FROM goods_bom_items edge
                        WHERE edge.goods_id=roots.goods_id AND edge.is_deleted=FALSE OFFSET 0
                    ) b ON TRUE
                    JOIN goods component ON component.id = b.component_goods_id
                    LEFT JOIN units component_unit ON component_unit.id = component.unit_id
                                                   AND component_unit.is_deleted = FALSE
                    LEFT JOIN colors resolved_color ON resolved_color.id =
                        COALESCE(b.color_id, component.color_id)
                                                    AND resolved_color.is_deleted = FALSE
                    UNION ALL
                    SELECT b.id, walk.root_goods_id, b.goods_id, b.component_goods_id, walk.depth + 1,
                           walk.path || b.id, b.id = ANY(walk.path),
                           %1$s
                    FROM walk
                    JOIN LATERAL (
                        SELECT edge.* FROM goods_bom_items edge
                        WHERE edge.goods_id = walk.goods_id AND edge.is_deleted = FALSE
                        OFFSET 0
                    ) b ON TRUE
                    JOIN goods component ON component.id = b.component_goods_id
                    LEFT JOIN units component_unit ON component_unit.id = component.unit_id
                                                   AND component_unit.is_deleted = FALSE
                    LEFT JOIN colors resolved_color ON resolved_color.id =
                        COALESCE(b.color_id, component.color_id)
                                                    AND resolved_color.is_deleted = FALSE
                    WHERE walk.depth <= 10 AND walk.cycle = FALSE
                ), flagged AS (
                    SELECT CASE WHEN cycle THEN 'CYCLE' WHEN depth > 10 THEN 'TOO_DEEP' ELSE problems END AS kind,
                           CASE WHEN cycle THEN 0 WHEN depth > 10 THEN 1 ELSE 2 END AS priority,
                           root_goods_id, parent_goods_id, goods_id, depth
                    FROM walk
                    WHERE cycle OR depth > 10 OR problems IS NOT NULL
                ), findings AS (
                    SELECT DISTINCT ON (kind, parent_goods_id, goods_id)
                           kind, priority, root_goods_id, parent_goods_id, goods_id, depth
                    FROM flagged
                    ORDER BY kind, parent_goods_id, goods_id, depth
                )
                SELECT f.kind, root.code, root.name, parent.code, parent.name,
                       component.code, component.name, f.depth, count(*) OVER () AS total
                FROM findings f
                JOIN goods root ON root.id = f.root_goods_id
                JOIN goods parent ON parent.id = f.parent_goods_id
                JOIN goods component ON component.id = f.goods_id
                ORDER BY f.priority, f.depth, parent.code, component.code
                LIMIT %2$d
                """.formatted(EDGE_PROBLEMS, SHOWN_FINDINGS);
}
