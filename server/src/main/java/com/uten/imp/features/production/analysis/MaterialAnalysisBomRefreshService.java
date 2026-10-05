package com.uten.imp.features.production.analysis;

import com.uten.imp.application.port.MaterialAnalysisBomRefreshPort;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SubmitterPrincipalRestorer;
import lombok.extern.slf4j.Slf4j;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.context.SecurityContext;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.stereotype.Service;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.TransactionDefinition;
import org.springframework.transaction.support.TransactionTemplate;

import java.util.List;
import java.util.UUID;

/**
 * 研发完善委外件 BOM 后自动刷新物料分析(ADR-143 §二.3, 实现 {@link MaterialAnalysisBomRefreshPort})。
 *
 * <p>只挑「组件表还没展开出这个委外件可发外直属物料」的未结束分析: 货品现在有
 * {@code fn_subcontract_draw_edges} 行, 而分析里该货品的委外节点(任何层级, 含顶层供给行)下面一个对应的
 * 物料行都没有。BOM 学习、改用量这类不改结构的 BOM 事件因此不会惊动任何分析。
 *
 * <p>通知侧给每张这样的分析排一条 outbox 事件, 事件投递时才逐张刷新: 一个独立事务, 以分析负责人的身份
 * (按其当前账号与授权重建, 与后台识别任务同一套重建规则)走与页面其他重算入口相同的加锁刷新。
 * 刷新失败原样抛出, 让那条事件退避重试; 负责人账号已停用或授权已变属于长期状态, 跳过并记日志。
 */
@Slf4j
@Service
public class MaterialAnalysisBomRefreshService implements MaterialAnalysisBomRefreshPort {

    /** 分析(别名 material 的分析)里这个货品的委外节点还没展开出任何一个可发外直属物料行; 一个参数: 货品。 */
    private static final String UNEXPANDED_SUBCONTRACT_NODE = """
            material.goods_id = ?
              AND material.active = TRUE
              AND COALESCE(material.confirmed_route, material.source_suggestion) = 'SUBCONTRACT'
              AND EXISTS (SELECT 1 FROM fn_subcontract_draw_edges(material.goods_id))
              AND NOT EXISTS (
                  SELECT 1
                  FROM production_material_analysis_materials child
                  JOIN fn_subcontract_draw_edges(material.goods_id) edge
                    ON edge.component_goods_id = child.goods_id
                  WHERE child.analysis_id = material.analysis_id
                    AND child.analysis_item_id = material.analysis_item_id
                    AND child.active = TRUE
                    AND child.node_role = 'BOM_COMPONENT'
                    AND child.depth = material.depth + 1
                    AND (material.depth = 0 OR child.parent_node_key = material.node_key))
            """;

    private static final String CANDIDATES_SQL = """
            SELECT analysis.id
            FROM production_material_analyses analysis
            WHERE analysis.id IN (
                    SELECT material.analysis_id
                    FROM production_material_analysis_materials material
                    WHERE %s)
              AND analysis.is_deleted = FALSE
              AND analysis.status IN ('ACTIVE', 'PARTIALLY_PLANNED')
              AND EXISTS (
                  SELECT 1 FROM users account
                  WHERE account.employee_id = analysis.maker_id
                    AND account.is_deleted = FALSE
                    AND account.status = 'active')
            ORDER BY analysis.analysis_no, analysis.id
            """.formatted(UNEXPANDED_SUBCONTRACT_NODE);

    /** 一张分析此刻的状态; 三个参数: 货品、货品、分析。分析已结束或已删除时没有行。 */
    private static final String ANALYSIS_STATE_SQL = """
            SELECT analysis.analysis_no,
                   (SELECT account.id
                    FROM users account
                    WHERE account.employee_id = analysis.maker_id
                      AND account.is_deleted = FALSE
                      AND account.status = 'active'
                    ORDER BY account.id
                    LIMIT 1) AS maker_user_id,
                   EXISTS (
                       SELECT 1
                       FROM production_material_analysis_materials material
                       WHERE material.analysis_id = analysis.id
                         AND material.goods_id = ?
                         AND material.active = TRUE
                         AND COALESCE(material.confirmed_route, material.source_suggestion) = 'SUBCONTRACT'
                   ) AS has_node,
                   EXISTS (
                       SELECT 1
                       FROM production_material_analysis_materials material
                       WHERE material.analysis_id = analysis.id
                         AND %s
                   ) AS needs_refresh
            FROM production_material_analyses analysis
            WHERE analysis.id = ?
              AND analysis.is_deleted = FALSE
              AND analysis.status IN ('ACTIVE', 'PARTIALLY_PLANNED')
            """.formatted(UNEXPANDED_SUBCONTRACT_NODE);

    private final JdbcTemplate jdbc;
    private final MaterialAnalysisService analyses;
    private final SubmitterPrincipalRestorer principals;
    private final TransactionTemplate requiresNew;

    public MaterialAnalysisBomRefreshService(JdbcTemplate jdbc, MaterialAnalysisService analyses,
                                             SubmitterPrincipalRestorer principals,
                                             PlatformTransactionManager transactionManager) {
        this.jdbc = jdbc;
        this.analyses = analyses;
        this.principals = principals;
        this.requiresNew = new TransactionTemplate(transactionManager);
        this.requiresNew.setPropagationBehavior(TransactionDefinition.PROPAGATION_REQUIRES_NEW);
    }

    private record AnalysisState(String analysisNo, UUID makerUserId, boolean hasNode, boolean needsRefresh) {
    }

    @Override
    public List<UUID> analysesAwaitingBomRefresh(UUID goodsId) {
        if (goodsId == null) return List.of();
        return jdbc.queryForList(CANDIDATES_SQL, UUID.class, goodsId);
    }

    @Override
    public Outcome refreshAnalysisAfterBomUpdated(UUID analysisId, UUID goodsId) {
        if (analysisId == null || goodsId == null) return Outcome.SKIPPED;
        List<AnalysisState> states = jdbc.query(ANALYSIS_STATE_SQL, (rs, rowNum) -> new AnalysisState(
                rs.getString("analysis_no"),
                rs.getObject("maker_user_id", UUID.class),
                rs.getBoolean("has_node"),
                rs.getBoolean("needs_refresh")), goodsId, goodsId, analysisId);
        if (states.isEmpty() || !states.get(0).hasNode()) return Outcome.SKIPPED;
        AnalysisState state = states.get(0);
        if (!state.needsRefresh()) return Outcome.ALREADY_CURRENT;
        AuthUser maker;
        try {
            maker = makerPrincipal(state.makerUserId());
        } catch (SubmitterPrincipalRestorer.PrincipalChangedException | IllegalStateException unusable) {
            log.warn("Material analysis auto refresh after BOM update skipped: analysis={} goods={}: maker {}",
                    state.analysisNo(), goodsId, unusable.getMessage());
            return Outcome.SKIPPED;
        }
        SecurityContext previous = SecurityContextHolder.getContext();
        try {
            SecurityContext context = SecurityContextHolder.createEmptyContext();
            context.setAuthentication(new UsernamePasswordAuthenticationToken(maker, null, maker.getAuthorities()));
            SecurityContextHolder.setContext(context);
            Boolean refreshed = requiresNew.execute(status -> analyses.refreshForBomUpdate(analysisId));
            return Boolean.TRUE.equals(refreshed) ? Outcome.REFRESHED : Outcome.SKIPPED;
        } finally {
            SecurityContextHolder.setContext(previous);
        }
    }

    /** 按负责人当前账号状态与授权戳重建身份(账号停用、首登待改密、授权已变等抛 PrincipalChangedException)。 */
    private AuthUser makerPrincipal(UUID userId) {
        if (userId == null) throw new IllegalStateException("analysis maker account missing");
        var stamps = principals.currentStamps(userId)
                .orElseThrow(() -> new IllegalStateException("analysis maker account missing"));
        return principals.restore(userId, stamps.authVersion(), stamps.authorizationEpoch());
    }
}
