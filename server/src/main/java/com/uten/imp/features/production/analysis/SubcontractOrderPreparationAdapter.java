package com.uten.imp.features.production.analysis;

import com.uten.imp.application.port.SubcontractOrderPreparationPort;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.notice.ChainNoticeService;
import com.uten.imp.features.production.analysis.MaterialAnalysisContracts.AnalysisView;
import com.uten.imp.features.production.analysis.MaterialAnalysisContracts.CancelRequest;
import com.uten.imp.features.production.analysis.MaterialAnalysisContracts.PreviewItem;
import com.uten.imp.features.production.analysis.MaterialAnalysisContracts.PreviewRequest;
import com.uten.imp.features.production.analysis.SubcontractPreparationContracts.StartRequest;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.util.Collection;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.UUID;

/**
 * {@link SubcontractOrderPreparationPort} 生产侧实现（2026-09-05 委外收敛）。
 *
 * <p>直接下单的有子层目标件在草稿保存期即「发单给计划」：以
 * source_ref=SC-ORDER:{orderItemId} 创建独立前置生产分析（复用既有
 * SUBCONTRACT_PREPARATION 分析机制，无权益桥——需求为本单新增，不承接既有
 * 权益），计划部在物料分析工作台安排车间；生产完成入库后回调通知委外制单人
 * 可提交财务审核。委外准备中心页面与手工 start 入口已退役，MAKE_THEN 计划行
 * 由 {@link #autoStartPlanLinePreparation} 自动启动。
 */
@Service
@RequiredArgsConstructor
public class SubcontractOrderPreparationAdapter
        implements SubcontractOrderPreparationPort {

    /** 与 MaterialAnalysisService 校验及协调器启动路径统一的谱系前缀。 */
    static final String SOURCE_REF_PREFIX = "SC-ORDER:";
    static final String SOURCE_TYPE = "SUBCONTRACT_PREPARATION";

    private final MaterialAnalysisService analyses;
    private final MaterialAnalysisCommandService commands;
    private final SubcontractPreparationCoordinator preparationCoordinator;
    private final ChainNoticeService chainNotice;
    private final EntityManager em;
    private final JdbcTemplate jdbc;

    @Override
    @Transactional(propagation = Propagation.MANDATORY)
    public void ensureDraftPreparation(DraftPreparationCommand command) {
        if (command.baseQty() == null || command.baseQty().signum() <= 0) {
            // 库存已覆盖该行：无缺口即无需前置生产。尚未排产的分析取消；
            // 已排产的生产继续（产出入库为公共库存，不会被浪费性拦截）。
            Object[] stale = findDraftPreparation(command.orderItemId());
            if (stale != null && !toBoolean(stale[3])) {
                cancelQuietly((UUID) stale[0], (Long) stale[1],
                        (String) stale[4], "订货行库存已覆盖，前置生产缺口取消");
            }
            return;
        }
        if (command.warehouseId() == null) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED,
                    "有子层委外件必须先指定仓库（订货单或申请来源仓），"
                            + "才能发单给计划安排前置生产");
        }
        Object[] existing = findDraftPreparation(command.orderItemId());
        if (existing != null) {
            BigDecimal existingQty = toDecimal(existing[2]);
            boolean started = toBoolean(existing[3]);
            if (existingQty.compareTo(command.baseQty()) == 0) {
                return;
            }
            if (started) {
                throw new ApiException(ErrorCode.CONFLICT,
                        "订货单 " + command.orderBillNo()
                                + " 第行前置生产已排产（当前 "
                                + existingQty.stripTrailingZeros().toPlainString()
                                + "），不能改量；请保留该行原数量，或联系计划取消生产后重试");
            }
            cancelQuietly((UUID) existing[0], (Long) existing[1],
                    (String) existing[4], "委外草稿改量，重建前置生产缺口");
        }
        String sourceRef = SOURCE_REF_PREFIX + command.orderItemId();
        AnalysisView analysis =
                analyses.previewSubcontractPreparation(new PreviewRequest(
                        null,
                        null,
                        null,
                        command.warehouseId(),
                        sourceRef + ":" + command.baseQty().stripTrailingZeros().toPlainString()
                                + ":" + System.currentTimeMillis(),
                        List.of(new PreviewItem(
                                SOURCE_TYPE,
                                null,
                                command.goodsId(),
                                command.colorId(),
                                command.unitId(),
                                sourceRef,
                                "委外订货 " + command.orderBillNo()
                                        + " 的目标件需先完成内部自制并经仓库实收入库",
                                command.needDate(),
                                command.baseQty()))));
        chainNotice.notifySubcontractOrderPreparationDispatched(
                analysis.analysisId(), command.orderItemId(),
                command.orderBillNo(), command.goodsId(), command.baseQty());
    }

    @Override
    @Transactional(propagation = Propagation.MANDATORY)
    public void releaseDraftPreparations(
            Collection<UUID> orderItemIds, String reason) {
        if (orderItemIds == null || orderItemIds.isEmpty()) {
            return;
        }
        for (UUID orderItemId : orderItemIds) {
            Object[] existing = findDraftPreparation(orderItemId);
            if (existing == null) {
                continue;
            }
            if (toBoolean(existing[3])) {
                throw new ApiException(ErrorCode.CONFLICT,
                        "委外草稿某行的前置生产已排产，不能删除或移除该行；"
                                + "请保留该行，或联系计划取消生产后重试");
            }
            cancelQuietly((UUID) existing[0], (Long) existing[1],
                    (String) existing[4], reason);
        }
    }

    @Override
    @Transactional(propagation = Propagation.MANDATORY, readOnly = true)
    public void requireDraftPreparationsIdle(Collection<UUID> orderItemIds) {
        if (orderItemIds == null || orderItemIds.isEmpty()) {
            return;
        }
        for (UUID orderItemId : orderItemIds) {
            Object[] existing = findDraftPreparation(orderItemId);
            if (existing != null && toBoolean(existing[3])) {
                throw new ApiException(ErrorCode.CONFLICT,
                        "委外草稿某行的前置生产已排产，不能删除整单；"
                                + "请联系计划取消生产，或先提交财务走完流程后红冲");
            }
        }
    }

    @Override
    @Transactional(propagation = Propagation.MANDATORY)
    public void remapDraftPreparation(UUID oldOrderItemId, UUID newOrderItemId) {
        if (oldOrderItemId == null || newOrderItemId == null
                || oldOrderItemId.equals(newOrderItemId)) {
            return;
        }
        em.createNativeQuery("""
                UPDATE production_material_analysis_items
                SET source_ref = :newRef
                WHERE source_type = 'SUBCONTRACT_PREPARATION'
                  AND source_ref = :oldRef
                  AND is_deleted = FALSE
                """)
                .setParameter("newRef", SOURCE_REF_PREFIX + newOrderItemId)
                .setParameter("oldRef", SOURCE_REF_PREFIX + oldOrderItemId)
                .executeUpdate();
    }

    @Override
    @Transactional(propagation = Propagation.MANDATORY)
    public void autoStartPlanLinePreparation(UUID planItemId) {
        Map<String, Object> line = jdbc.queryForMap("""
                SELECT item.preparation_version, item.preparation_warehouse_id,
                       item.preparation_status
                FROM subcontract_material_plan_items item
                WHERE item.id = ?
                """, planItemId);
        if (!"ACTION_REQUIRED".equals(Objects.toString(
                line.get("preparation_status"), ""))) {
            return;
        }
        UUID warehouseId = (UUID) line.get("preparation_warehouse_id");
        if (warehouseId == null) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED,
                    "前置自制计划行缺少目标仓，无法自动启动；请在订货单指定仓库后重试");
        }
        preparationCoordinator.start(planItemId, new StartRequest(
                ((Number) line.get("preparation_version")).longValue(),
                "SC-AUTO:" + planItemId,
                warehouseId));
    }

    /**
     * 完工入库回调：草稿订货行的前置生产分析若关联本入库单的产出行，且该订单
     * 全部有子层行库存已备齐（按全局可用量池），通知制单人可提交财务审核。
     * 幂等：通知键按订单聚合，办结在提交财务后发生（提交通知类型不同，不冲突）。
     */
    @Override
    @Transactional(propagation = Propagation.MANDATORY)
    public void afterFinishedInboundApproved(UUID stockDocumentId) {
        @SuppressWarnings("unchecked")
        List<Object[]> affected = em.createNativeQuery("""
                SELECT DISTINCT source_item.source_ref,
                       source_item.analysis_id, source_item.id AS analysis_item_id
                FROM production_material_analysis_items source_item
                JOIN production_plans production_plan
                  ON production_plan.material_analysis_id = source_item.analysis_id
                 AND production_plan.material_analysis_item_id = source_item.id
                 AND production_plan.is_deleted = FALSE
                JOIN plan_draw_links finished_link
                  ON finished_link.plan_id = production_plan.id
                 AND finished_link.is_deleted = FALSE
                JOIN stock_documents finished_in
                  ON finished_in.id = finished_link.draw_id
                 AND finished_in.doc_type = 'FINISHED_IN'
                WHERE finished_in.id = :documentId
                  AND source_item.source_type = 'SUBCONTRACT_PREPARATION'
                  AND source_item.source_ref LIKE 'SC-ORDER:%'
                  AND source_item.is_deleted = FALSE
                """).setParameter("documentId", stockDocumentId).getResultList();
        for (Object[] row : affected) {
            String sourceRef = Objects.toString(row[0], "");
            UUID orderItemId = parseOrderItemId(sourceRef);
            if (orderItemId == null) {
                continue;
            }
            chainNotice.notifySubcontractOrderPreparationArrived(orderItemId);
            chainNotice.resolveReviewNotices(
                    "MATERIAL_ANALYSIS", (UUID) row[1], "PREPARATION_ARRIVED");
        }
    }

    /**
     * 查找草稿订货行当前的前置生产分析：
     * [analysisId, version, requestedQty, productionStarted, fingerprint]。
     */
    private Object[] findDraftPreparation(UUID orderItemId) {
        @SuppressWarnings("unchecked")
        List<Object[]> rows = em.createNativeQuery("""
                SELECT analysis.id,
                       analysis.version,
                       source_item.requested_qty,
                       (EXISTS (
                           SELECT 1
                           FROM production_plans production_plan
                           WHERE production_plan.material_analysis_id = analysis.id
                             AND production_plan.material_analysis_item_id =
                                 source_item.id
                             AND production_plan.is_deleted = FALSE
                             AND production_plan.is_canceled = FALSE
                       )) AS production_started,
                       analysis.fingerprint
                FROM production_material_analysis_items source_item
                JOIN production_material_analyses analysis
                  ON analysis.id = source_item.analysis_id
                WHERE source_item.source_type = 'SUBCONTRACT_PREPARATION'
                  AND source_item.source_ref = :sourceRef
                  AND source_item.is_deleted = FALSE
                  AND analysis.is_deleted = FALSE
                  AND analysis.status <> 'CANCELLED'
                ORDER BY analysis.created_at DESC
                LIMIT 1
                """).setParameter("sourceRef", SOURCE_REF_PREFIX + orderItemId)
                .getResultList();
        return rows.isEmpty() ? null : rows.getFirst();
    }

    private void cancelQuietly(
            UUID analysisId, Long version, String fingerprint, String reason) {
        commands.cancelAnalysis(analysisId, new CancelRequest(
                version, fingerprint,
                "SC-ORDER-RELEASE:" + analysisId + ":" + System.currentTimeMillis(),
                reason));
        chainNotice.resolveReviewNotices(
                "MATERIAL_ANALYSIS", analysisId, "ANALYSIS_CANCELLED");
    }

    private static UUID parseOrderItemId(String sourceRef) {
        String raw = sourceRef.substring(SOURCE_REF_PREFIX.length()).trim();
        try {
            return UUID.fromString(raw);
        } catch (IllegalArgumentException error) {
            return null;
        }
    }

    private static BigDecimal toDecimal(Object value) {
        return value == null
                ? BigDecimal.ZERO
                : (value instanceof BigDecimal decimal
                        ? decimal
                        : new BigDecimal(Objects.toString(value)));
    }

    private static boolean toBoolean(Object value) {
        return value instanceof Boolean flag?flag:value != null && ((Number) value).intValue() != 0;
    }
}
