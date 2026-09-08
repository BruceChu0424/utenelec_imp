package com.uten.imp.features.subcontract.preparation;

import com.uten.imp.application.port.SubcontractPreparationPort;
import com.uten.imp.common.util.NativeQueryResults;
import com.uten.imp.common.util.NativeValueConverters;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.util.HexFormat;
import java.util.List;
import java.util.Locale;
import java.util.Objects;
import java.util.Set;
import java.util.UUID;

@Service
@RequiredArgsConstructor
public class SubcontractPreparationTaskAdapter
        implements SubcontractPreparationPort {

    private static final Set<String> TASK_STATUSES = Set.of(
            "ACTION_REQUIRED", "IN_PREPARATION", "WAITING_FQC",
            "WAITING_INBOUND", "READY_OUTBOUND", "OUTBOUND_COMPLETE",
            "CANCELLED");

    private final EntityManager em;
    private final JdbcTemplate jdbc;


    @Override
    @Transactional(readOnly = true)
    public StartContext prepareStart(UUID planItemId, UUID requestedWarehouseId) {
        LockedTask seed = startSeed(planItemId, false);
        UUID warehouseId = requestedWarehouseId == null
                ? seed.warehouseId() : requestedWarehouseId;
        if (seed.warehouseId() != null && requestedWarehouseId != null
                && !seed.warehouseId().equals(requestedWarehouseId)) {
            throw conflict("前置自制目标仓已冻结，不能静默改仓");
        }
        if (warehouseId == null) {
            throw validation("启动委外前置自制必须选择目标仓");
        }
        SourceLineage source = sourceLineage(seed.orderItemId());
        if (source == null) {
            return new StartContext(planItemId, null, null, null, null, null,
                    List.of());
        }
        if (!warehouseId.equals(source.warehouseId())) {
            throw conflict("原物料分析目标仓与委外前置自制目标仓不一致，禁止跨仓接管专属库存");
        }
        List<InventoryDimension> dimensions = NativeQueryResults.objectArrayRows(
                em.createNativeQuery("""
                        WITH RECURSIVE descendants AS (
                            SELECT child.id, child.analysis_item_id, child.node_key,
                                   child.goods_id, child.color_id
                            FROM production_material_analysis_materials parent
                            JOIN production_material_analysis_materials child
                              ON child.analysis_id = parent.analysis_id
                             AND child.analysis_item_id = parent.analysis_item_id
                             AND child.parent_node_key = parent.node_key
                             AND child.active = TRUE
                            WHERE parent.id = :parentMaterialId
                              AND parent.analysis_id = :analysisId
                              AND parent.active = TRUE
                            UNION ALL
                            SELECT child.id, child.analysis_item_id, child.node_key,
                                   child.goods_id, child.color_id
                            FROM descendants parent
                            JOIN production_material_analysis_materials child
                              ON child.analysis_id = :analysisId
                             AND child.analysis_item_id = parent.analysis_item_id
                             AND child.parent_node_key = parent.node_key
                             AND child.active = TRUE
                        )
                        SELECT DISTINCT goods_id, color_id
                        FROM descendants
                        ORDER BY goods_id, color_id NULLS FIRST
                        """)
                        .setParameter("parentMaterialId", source.materialId())
                        .setParameter("analysisId", source.analysisId())).stream()
                .map(row -> new InventoryDimension(
                        (UUID) row[0], (UUID) row[1]))
                .toList();
        return new StartContext(planItemId, source.actionId(), source.allocationId(),
                source.analysisId(), source.analysisItemId(), source.materialId(),
                dimensions);
    }

    @Override
    @Transactional(propagation = Propagation.MANDATORY)
    public StartClaim beginStart(
            UUID planItemId,
             long expectedVersion,
             String rawIdempotencyKey,
             UUID requestedWarehouseId,
             StartContext expectedContext) {
        String idempotencyKey = rawIdempotencyKey == null
                ? "" : rawIdempotencyKey.strip();
        if (idempotencyKey.length() < 8 || idempotencyKey.length() > 128) {
            throw validation("启动委外前置自制的幂等键长度必须为 8 至 128");
        }
        LockedTask task = lockTask(planItemId);
        SourceLineage source = sourceLineage(task.orderItemId());
        requireExpectedSource(expectedContext, planItemId, source);
        UUID warehouseId = requestedWarehouseId == null
                ? task.warehouseId() : requestedWarehouseId;
        if (task.warehouseId() != null && requestedWarehouseId != null
                && !task.warehouseId().equals(requestedWarehouseId)) {
            throw conflict("前置自制目标仓已冻结，不能静默改仓");
        }
        if (warehouseId == null) {
            throw validation("启动委外前置自制必须选择目标仓");
        }
        requireAccountableWarehouse(warehouseId);
        String requestHash = requestHash(task, expectedVersion, warehouseId, source);
        StartClaim replay = commandReplay(planItemId, idempotencyKey, requestHash, task);
        if (replay != null) return replay;
        BomSnapshot currentBom = currentBomSnapshot(task.goodsId());
        if (!task.bomHasChildren()
                || !currentBom.hasChildren()
                || !Objects.equals(task.bomFingerprint(), currentBom.fingerprint())) {
            throw conflict("委外目标件 BOM 已在审批后变化，必须受控重评准备路线");
        }
        if (task.version() != expectedVersion) {
            throw conflict("委外前置自制任务已被其他操作更新，请刷新后重试");
        }
        if (!"ACTION_REQUIRED".equals(task.status())) {
            throw conflict("该委外前置自制任务已启动或已结束，请刷新任务状态");
        }
        return new StartClaim(false, task.id(), task.orderItemId(), task.orderBillNo(),
                 task.goodsId(), task.colorId(), task.unitId(), task.requiredQty(),
                 task.needDate(), warehouseId, expectedVersion, expectedVersion + 1,
                 idempotencyKey, requestHash,
                 source == null ? null : source.actionId(),
                 source == null ? null : source.allocationId(),
                 source == null ? null : source.analysisId(),
                 source == null ? null : source.analysisItemId(),
                 source == null ? null : source.materialId(),
                 source == null ? 0 : source.analysisVersion(),
                 source == null ? null : source.analysisFingerprint(),
                 null, null, null);
    }

    @Override
    @Transactional(propagation = Propagation.MANDATORY)
    public StartResult completeStart(
            StartClaim claim,
            UUID analysisId,
            UUID analysisItemId,
            UUID actorUserId) {
         if (claim.replay()) {
            HandoffSummary handoff = handoffSummary(claim.planItemId());
            return new StartResult(claim.planItemId(), "IN_PREPARATION",
                     claim.replayAnalysisId(), claim.replayAnalysisItemId(),
                     claim.resultingVersion(), claim.sourceAnalysisId(),
                     claim.sourceMaterialLineId(), handoff.id(), handoff.status(),
                     handoff.takeoverQty(), handoff.entitlementQty());
        }
        int updated = em.createNativeQuery("""
                UPDATE subcontract_material_plan_items
                SET preparation_status = 'IN_PREPARATION',
                    preparation_warehouse_id = :warehouseId,
                    preparation_analysis_id = :analysisId,
                    preparation_analysis_item_id = :analysisItemId,
                    preparation_started_by = :actorId,
                    preparation_started_at = now(),
                    preparation_version = preparation_version + 1,
                    updated_at = now(), updated_by = :actorId
                WHERE id = :planItemId
                  AND flow_mode = 'MAKE_THEN_OUTBOUND'
                  AND preparation_status = 'ACTION_REQUIRED'
                  AND preparation_version = :expectedVersion
                  AND is_deleted = FALSE
                """)
                .setParameter("warehouseId", claim.warehouseId())
                .setParameter("analysisId", analysisId)
                .setParameter("analysisItemId", analysisItemId)
                .setParameter("actorId", actorUserId)
                .setParameter("planItemId", claim.planItemId())
                .setParameter("expectedVersion", claim.expectedVersion())
                .executeUpdate();
        if (updated != 1) {
            throw conflict("委外前置自制任务已被其他操作更新，分析创建已回滚");
        }
        em.createNativeQuery("""
                INSERT INTO subcontract_outbound_preparation_commands(
                    id, plan_item_id, operation, idempotency_key, request_hash,
                    expected_version, resulting_version, analysis_id,
                    analysis_item_id, created_by)
                VALUES (:id, :planItemId, 'START_PREPARATION', :idempotencyKey,
                    :requestHash, :expectedVersion, :resultingVersion,
                    :analysisId, :analysisItemId, :actorId)
                """)
                .setParameter("id", UUID.randomUUID())
                .setParameter("planItemId", claim.planItemId())
                .setParameter("idempotencyKey", claim.idempotencyKey())
                .setParameter("requestHash", claim.requestHash())
                .setParameter("expectedVersion", claim.expectedVersion())
                .setParameter("resultingVersion", claim.resultingVersion())
                .setParameter("analysisId", analysisId)
                .setParameter("analysisItemId", analysisItemId)
                .setParameter("actorId", actorUserId)
                .executeUpdate();
        HandoffSummary handoff = handoffSummary(claim.planItemId());
        return new StartResult(claim.planItemId(), "IN_PREPARATION",
                 analysisId, analysisItemId, claim.resultingVersion(),
                 claim.sourceAnalysisId(), claim.sourceMaterialLineId(),
                 handoff.id(), handoff.status(), handoff.takeoverQty(),
                 handoff.entitlementQty());
    }

    @Override
    @Transactional(propagation = Propagation.MANDATORY, readOnly = true)
    public void requireRefresh(
            UUID analysisId, UUID warehouseId, String sourceRef,
            UUID goodsId, UUID colorId, UUID unitId,
            BigDecimal requestedQty) {
        Number matches = (Number) em.createNativeQuery("""
                SELECT COUNT(*)
                FROM subcontract_material_plan_items plan_item
                JOIN production_material_analysis_items analysis_item
                  ON analysis_item.analysis_id = plan_item.preparation_analysis_id
                 AND analysis_item.id = plan_item.preparation_analysis_item_id
                 AND analysis_item.is_deleted = FALSE
                WHERE plan_item.preparation_analysis_id = :analysisId
                  AND plan_item.flow_mode = 'MAKE_THEN_OUTBOUND'
                  AND plan_item.is_deleted = FALSE
                  AND plan_item.preparation_warehouse_id = :warehouseId
                  AND plan_item.goods_id = :goodsId
                  AND plan_item.color_id IS NOT DISTINCT FROM CAST(:colorId AS uuid)
                  AND plan_item.unit_id = :unitId
                  AND plan_item.planned_qty = :requestedQty
                  AND analysis_item.source_type = 'SUBCONTRACT_PREPARATION'
                  AND analysis_item.source_ref = :sourceRef
                  AND analysis_item.source_ref =
                      'SC-PREP:' || plan_item.order_item_id::text
                  AND analysis_item.goods_id = :goodsId
                  AND analysis_item.color_id IS NOT DISTINCT FROM CAST(:colorId AS uuid)
                  AND analysis_item.unit_id = :unitId
                  AND analysis_item.requested_qty = :requestedQty
                """).setParameter("analysisId", analysisId)
                .setParameter("warehouseId", warehouseId)
                .setParameter("goodsId", goodsId)
                .setParameter("colorId", colorId)
                .setParameter("unitId", unitId)
                .setParameter("requestedQty", requestedQty)
                .setParameter("sourceRef", sourceRef)
                .getSingleResult();
        if (matches.longValue() != 1) {
            throw new ApiException(ErrorCode.FORBIDDEN,
                    "委外前置自制刷新来源、数量或冻结仓与任务不一致");
        }
    }

    private LockedTask lockTask(UUID planItemId) {
        return loadTask(planItemId, true);
    }

    private LockedTask startSeed(UUID planItemId, boolean forUpdate) {
        return loadTask(planItemId, forUpdate);
    }

    private LockedTask loadTask(UUID planItemId, boolean forUpdate) {
        String lock = forUpdate ? " FOR UPDATE OF item" : "";
        List<Object[]> rows = NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT item.id, item.order_item_id, plan.order_bill_no,
                       item.goods_id, item.color_id, item.unit_id,
                       item.planned_qty, order_header.deliver_date,
                       item.preparation_status, item.preparation_warehouse_id,
                       item.preparation_version, plan.status, order_header.status,
                       item.bom_has_children_snapshot,
                       item.preparation_bom_fingerprint
                FROM subcontract_material_plan_items item
                JOIN subcontract_material_plans plan ON plan.id = item.plan_id
                JOIN subcontract_orders order_header ON order_header.id = plan.order_id
                WHERE item.id = :id AND item.is_deleted = FALSE
                  AND plan.is_deleted = FALSE AND order_header.is_deleted = FALSE
                  AND item.flow_mode = 'MAKE_THEN_OUTBOUND'
                """ + lock).setParameter("id", planItemId));
        if (rows.isEmpty()) throw new ApiException(ErrorCode.NOT_FOUND,
                "委外前置自制任务不存在");
        Object[] row = rows.getFirst();
        if (!"OPEN".equals(row[11]) || ((Number) row[12]).shortValue() != 1) {
            throw conflict("委外订货或出仓计划已关闭，禁止启动前置自制");
        }
        return new LockedTask((UUID) row[0], (UUID) row[1], Objects.toString(row[2]),
                (UUID) row[3], (UUID) row[4], (UUID) row[5], decimal(row[6]),
                row[7] == null ? null : NativeValueConverters.toLocalDate(row[7]),
                Objects.toString(row[8]), (UUID) row[9],
                 ((Number) row[10]).longValue(), Boolean.TRUE.equals(row[13]),
                 Objects.toString(row[14], ""));
    }

    private SourceLineage sourceLineage(UUID orderItemId) {
        List<Object[]> rows = NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT source_action.id, source_allocation.id,
                       source_allocation.analysis_id,
                       source_material.analysis_item_id, source_material.id,
                       source_analysis.warehouse_id, source_analysis.version,
                       source_analysis.fingerprint
                FROM subcontract_order_items order_item
                JOIN subcontract_order_item_sources src
                  ON src.order_item_id = order_item.id
                JOIN subcontract_application_items application_item
                  ON application_item.id = src.application_item_id
                 AND application_item.is_deleted = FALSE
                JOIN preplan_supply_action_allocations source_allocation
                  ON source_allocation.external_item_id = application_item.id
                JOIN preplan_supply_actions source_action
                  ON source_action.id = source_allocation.action_id
                 AND source_action.analysis_id = source_allocation.analysis_id
                 AND source_action.external_document_id = application_item.application_id
                 AND source_action.external_document_type = 'SUBCONTRACT_APPLICATION'
                 AND source_action.route = 'SUBCONTRACT'
                 AND source_action.status <> 'CANCELLED'
                JOIN production_material_analyses source_analysis
                  ON source_analysis.id = source_allocation.analysis_id
                 AND source_analysis.is_deleted = FALSE
                 AND source_analysis.status IN ('ACTIVE','PARTIALLY_PLANNED')
                JOIN production_material_analysis_materials source_material
                  ON source_material.id = source_allocation.analysis_material_id
                 AND source_material.analysis_id = source_allocation.analysis_id
                 AND source_material.active = TRUE
                 AND source_material.confirmed_route = 'SUBCONTRACT'
                WHERE order_item.id = :orderItemId
                  AND order_item.is_deleted = FALSE
                ORDER BY source_action.id, source_allocation.id
                """).setParameter("orderItemId", orderItemId));
        if (rows.isEmpty()) return null;
        if (rows.size() != 1) {
            throw conflict("委外订货行对应多个原物料分析节点，禁止猜测前置自制权益来源");
        }
        Object[] row = rows.getFirst();
        return new SourceLineage(
                (UUID) row[0], (UUID) row[1], (UUID) row[2], (UUID) row[3],
                (UUID) row[4], (UUID) row[5], ((Number) row[6]).longValue(),
                Objects.toString(row[7], null));
    }

    private static void requireExpectedSource(
            StartContext expected, UUID planItemId, SourceLineage actual) {
        if (expected == null || !planItemId.equals(expected.planItemId())) {
            throw conflict("委外前置自制启动上下文已失效，请刷新后重试");
        }
        boolean matches = actual == null
                ? !expected.hasSourceAnalysis()
                : Objects.equals(expected.sourceSupplyActionId(), actual.actionId())
                    && Objects.equals(expected.sourceSupplyActionAllocationId(),
                            actual.allocationId())
                    && Objects.equals(expected.sourceAnalysisId(), actual.analysisId())
                    && Objects.equals(expected.sourceAnalysisItemId(),
                            actual.analysisItemId())
                    && Objects.equals(expected.sourceMaterialLineId(), actual.materialId());
        if (!matches) {
            throw conflict("委外前置自制原物料分析来源已变化，请刷新后重试");
        }
    }

    private StartClaim commandReplay(
            UUID planItemId, String idempotencyKey, String requestHash,
            LockedTask task) {
        List<Object[]> rows = NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT command.request_hash, command.analysis_id,
                       command.analysis_item_id,
                       command.expected_version, command.resulting_version,
                       handoff.id
                FROM subcontract_outbound_preparation_commands
                     command
                LEFT JOIN preplan_subcontract_requirement_handoffs handoff
                  ON handoff.plan_item_id = command.plan_item_id
                WHERE command.plan_item_id = :planItemId
                  AND command.operation = 'START_PREPARATION'
                  AND command.idempotency_key = :idempotencyKey
                FOR UPDATE OF command
                """).setParameter("planItemId", planItemId)
                .setParameter("idempotencyKey", idempotencyKey));
        if (rows.isEmpty()) return null;
        Object[] row = rows.getFirst();
        if (!requestHash.equals(row[0])) {
            throw conflict("相同幂等键对应不同的委外前置自制请求");
        }
        SourceLineage source = sourceLineage(task.orderItemId());
        return new StartClaim(true, task.id(), task.orderItemId(), task.orderBillNo(),
                 task.goodsId(), task.colorId(), task.unitId(), task.requiredQty(),
                 task.needDate(), task.warehouseId(), ((Number) row[3]).longValue(),
                 ((Number) row[4]).longValue(), idempotencyKey, requestHash,
                 source == null ? null : source.actionId(),
                 source == null ? null : source.allocationId(),
                 source == null ? null : source.analysisId(),
                 source == null ? null : source.analysisItemId(),
                 source == null ? null : source.materialId(),
                 source == null ? 0 : source.analysisVersion(),
                 source == null ? null : source.analysisFingerprint(),
                 (UUID) row[1], (UUID) row[2], (UUID) row[5]);
    }

    private void requireAccountableWarehouse(UUID warehouseId) {
        Number count = (Number) em.createNativeQuery("""
                SELECT COUNT(*) FROM warehouses
                WHERE id = :id AND is_deleted = FALSE AND is_accountable = TRUE
                """).setParameter("id", warehouseId).getSingleResult();
        if (count.longValue() != 1) throw validation(
                "委外前置自制目标仓不存在或不参与库存核算");
    }

    private BomSnapshot currentBomSnapshot(UUID goodsId) {
        List<Object[]> rows = NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT bom.id, bom.component_goods_id, bom.color_id, bom.qty
                FROM goods_bom_items bom
                JOIN goods child ON child.id = bom.component_goods_id
                 AND child.is_deleted = FALSE
                 AND COALESCE(child.auto_created, FALSE) = FALSE
                WHERE bom.goods_id = :goodsId AND bom.is_deleted = FALSE
                ORDER BY bom.id
                """).setParameter("goodsId", goodsId));
        StringBuilder canonical = new StringBuilder("GOODS|")
                .append(goodsId).append('\n');
        for (Object[] row : rows) {
            canonical.append(row[0]).append('|').append(row[1]).append('|')
                    .append(Objects.toString(row[2], "")).append('|')
                    .append(decimal(row[3]).stripTrailingZeros().toPlainString())
                    .append('\n');
        }
        try {
            return new BomSnapshot(!rows.isEmpty(), HexFormat.of().formatHex(
                    MessageDigest.getInstance("SHA-256").digest(
                            canonical.toString().getBytes(StandardCharsets.UTF_8))));
        } catch (NoSuchAlgorithmException impossible) {
            throw new IllegalStateException("SHA-256 is unavailable", impossible);
        }
    }

    private static List<String> allowedActions(
            String status, UUID analysisId, boolean canStart, boolean canOpen,
            boolean sourceLineageValid) {
        if ("ACTION_REQUIRED".equals(status) && canStart && sourceLineageValid) {
            return List.of("START_PREPARATION");
        }
        return analysisId != null && canOpen ? List.of("OPEN_ANALYSIS") : List.of();
    }

    private static String blocker(String status, UUID warehouseId) {
        return switch (status) {
            case "ACTION_REQUIRED" -> warehouseId == null
                    ? "请选择目标仓并启动物料分析"
                    : "需由计划员启动委外前置自制物料分析";
            case "IN_PREPARATION" -> "前置自制尚未完成领料、报工、FQC 与仓库实收";
            case "WAITING_FQC" -> "前置自制已报工，等待品质检验";
            case "WAITING_INBOUND" -> "前置自制已合格，等待仓库实收入库";
            case "READY_OUTBOUND" -> "目标件已整批实收并专属占用，可委外出仓";
            case "OUTBOUND_COMPLETE" -> "目标件已完成委外出仓";
            case "CANCELLED" -> "委外订货或出仓计划已取消";
            default -> "状态异常，请刷新";
        };
    }

    private static String handoffStatus(
            long sourceLinkCount, UUID analysisId, UUID handoffId,
            BigDecimal takeoverQty) {
        if (sourceLinkCount == 0) return "NOT_APPLICABLE";
        if (sourceLinkCount != 1) return "BLOCKED";
        if (analysisId == null) return "PENDING";
        if (handoffId == null) return "BLOCKED";
        return takeoverQty.signum() > 0 ? "ACTIVE" : "RESTORED";
    }

    private static String handoffBlocker(
            long sourceLinkCount, UUID analysisId, UUID handoffId) {
        if (sourceLinkCount > 1) {
            return "委外订货行对应多个原物料分析节点，必须先修复来源谱系";
        }
        if (sourceLinkCount == 1 && analysisId != null && handoffId == null) {
            return "前置自制分析缺少 V447 权益交接账，禁止继续或重复启动";
        }
        return null;
    }

    private HandoffSummary handoffSummary(UUID planItemId) {
        List<Object[]> rows = NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT handoff.id,
                       COALESCE(SUM(CASE requirement_event.event_type
                           WHEN 'TAKEOVER' THEN requirement_event.qty
                           ELSE -requirement_event.qty END), 0),
                       COALESCE((
                           SELECT SUM(slice.qty)
                           FROM preplan_subcontract_entitlement_handoff_slices slice
                           JOIN preplan_subcontract_requirement_handoff_items mapped
                             ON mapped.id = slice.handoff_item_id
                           WHERE mapped.handoff_id = handoff.id
                       ), 0)
                FROM preplan_subcontract_requirement_handoffs handoff
                LEFT JOIN preplan_subcontract_requirement_handoff_events
                     requirement_event ON requirement_event.handoff_id = handoff.id
                WHERE handoff.plan_item_id = :planItemId
                GROUP BY handoff.id
                """).setParameter("planItemId", planItemId));
        if (rows.isEmpty()) return HandoffSummary.NONE;
        Object[] row = rows.getFirst();
        BigDecimal takeover = decimal(row[1]);
        return new HandoffSummary((UUID) row[0],
                takeover.signum() > 0 ? "ACTIVE" : "RESTORED",
                takeover, decimal(row[2]));
    }

    private static String normalizeStatus(String raw) {
        if (raw == null || raw.isBlank()) return null;
        String status = raw.strip().toUpperCase(Locale.ROOT);
        if (!TASK_STATUSES.contains(status)) throw validation(
                "委外前置自制任务状态无效");
        return status;
    }

    private static Object[] filters(
            String status, String like, UUID planItemId,
            UUID sourceAnalysisId, UUID sourceMaterialLineId) {
        List<Object> values = new java.util.ArrayList<>();
        if (status != null) values.add(status);
        if (like != null) {
            values.add(like);
            values.add(like);
            values.add(like);
        }
        if (planItemId != null) values.add(planItemId);
        if (sourceAnalysisId != null && sourceMaterialLineId != null) {
            values.add(sourceAnalysisId);
            values.add(sourceMaterialLineId);
        }
        return values.toArray();
    }

    private static Object[] append(Object[] source, Object... values) {
        Object[] result = new Object[source.length + values.length];
        System.arraycopy(source, 0, result, 0, source.length);
        System.arraycopy(values, 0, result, source.length, values.length);
        return result;
    }

    private static String requestHash(
            LockedTask task, long expectedVersion, UUID warehouseId,
            SourceLineage source) {
        String raw = String.join("|", "START_PREPARATION", task.id().toString(),
                 task.orderItemId().toString(), warehouseId.toString(),
                 task.requiredQty().stripTrailingZeros().toPlainString(),
                 Long.toString(expectedVersion),
                 source == null ? "DIRECT" : source.actionId().toString(),
                 source == null ? "DIRECT" : source.allocationId().toString(),
                 source == null ? "DIRECT" : source.analysisId().toString(),
                 source == null ? "DIRECT" : source.materialId().toString());
        try {
            return HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256")
                    .digest(raw.getBytes(StandardCharsets.UTF_8)));
        } catch (NoSuchAlgorithmException impossible) {
            throw new IllegalStateException("SHA-256 is unavailable", impossible);
        }
    }

    private static BigDecimal decimal(Object value) {
        return value == null ? BigDecimal.ZERO : new BigDecimal(value.toString());
    }

    private static ApiException validation(String message) {
        return new ApiException(ErrorCode.VALIDATION_FAILED, message);
    }

    private static ApiException conflict(String message) {
        return new ApiException(ErrorCode.CONFLICT, message);
    }

    private record LockedTask(
            UUID id, UUID orderItemId, String orderBillNo, UUID goodsId,
            UUID colorId, UUID unitId, BigDecimal requiredQty,
            LocalDate needDate, String status, UUID warehouseId, long version,
            boolean bomHasChildren, String bomFingerprint) {
    }

    private record BomSnapshot(boolean hasChildren, String fingerprint) {
    }

    private record SourceLineage(
            UUID actionId, UUID allocationId, UUID analysisId,
            UUID analysisItemId, UUID materialId, UUID warehouseId,
            long analysisVersion, String analysisFingerprint) {
    }

    private record HandoffSummary(
            UUID id, String status, BigDecimal takeoverQty,
            BigDecimal entitlementQty) {
        private static final HandoffSummary NONE = new HandoffSummary(
                null, "NOT_APPLICABLE", BigDecimal.ZERO, BigDecimal.ZERO);
    }
}
