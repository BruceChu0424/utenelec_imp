package com.uten.imp.features.stock.allocation;

import com.uten.imp.application.port.ProductionMaterialUsageReadPort;
import com.uten.imp.common.util.NativeQueryResults;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.stock.allocation.dto.ProductionMaterialClearanceRow;
import com.uten.imp.features.stock.allocation.dto.ProductionMaterialSettlementRequest;
import com.uten.imp.features.stock.allocation.dto.ProductionMaterialSettlementSourceRow;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.nio.charset.StandardCharsets;
import java.sql.Timestamp;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.time.Instant;
import java.time.OffsetDateTime;
import java.time.ZoneOffset;
import java.util.ArrayList;
import java.util.Collection;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.Comparator;
import java.util.HexFormat;
import java.util.List;
import java.util.Objects;
import java.util.Set;
import java.util.UUID;

/** Explicit material clearing; never derives actual use from BOM quantities. */
@Service
@RequiredArgsConstructor
public class ProductionMaterialSettlementService implements ProductionMaterialUsageReadPort {

    private static final Set<String> TYPES =
            Set.of("CONSUMED", "APPROVED_LOSS", "LEGAL_WIP");

    private final EntityManager em;
    private final TxSessionVars tx;
    private final ProductionMaterialTaskAccessPolicy taskAccess;
    private final com.uten.imp.features.stock.valuation.ProductionInventoryValueService inventoryValue;

    @Override
    @Transactional(readOnly = true)
    public Map<UUID, UsageFlags> forVisibleSegments(Collection<UUID> segmentIds) {
        if (segmentIds == null || segmentIds.isEmpty()) return Map.of();
        if (segmentIds.size() > 100 || segmentIds.stream().anyMatch(Objects::isNull)) {
            throw new IllegalArgumentException("Material usage requires a bounded page of exact segment IDs");
        }
        var query = em.createNativeQuery("""
                SELECT segment.id,
                       EXISTS (
                           SELECT 1 FROM production_material_demands demand
                           WHERE demand.execution_segment_id=segment.id
                             AND (EXISTS (
                                 SELECT 1 FROM production_material_stock_postings posting
                                 WHERE posting.demand_id=demand.id
                                   AND posting.posting_type='ISSUE' AND posting.qty_base>0)
                               OR EXISTS (
                                 SELECT 1 FROM production_material_settlement_postings posting
                                 JOIN production_material_settlement_events event ON event.id=posting.event_id
                                 WHERE posting.demand_id=demand.id
                                   AND event.event_type='POST' AND posting.qty_base>0))),
                       EXISTS (
                           SELECT 1 FROM v_production_material_clearance clearance
                           JOIN production_material_demands demand ON demand.id=clearance.demand_id
                           WHERE demand.execution_segment_id=segment.id
                             AND clearance.issued_qty>0 AND clearance.uncleared_qty>0)
                FROM production_execution_segments segment
                WHERE segment.id IN (:segments) AND segment.is_deleted=FALSE
                """).setParameter("segments", segmentIds.stream().distinct().sorted().toList());
        Map<UUID, UsageFlags> result = new LinkedHashMap<>();
        for (Object[] row : NativeQueryResults.objectArrayRows(query)) {
            result.put((UUID) row[0], new UsageFlags(Boolean.TRUE.equals(row[1]), Boolean.TRUE.equals(row[2])));
        }
        return Map.copyOf(result);
    }

    @Transactional(readOnly=true)
    public ProductionMaterialTaskAccessPolicy.Capabilities capabilities(UUID planId, UUID segmentId) {
        requirePlanExists(planId,false);
        return taskAccess.capabilities(planId,segmentId);
    }

    @Transactional(readOnly = true)
    public List<ProductionMaterialClearanceRow> clearance(UUID planId) {
        return clearance(planId,null);
    }

    @Transactional(readOnly = true)
    public List<ProductionMaterialClearanceRow> clearance(UUID planId, UUID segmentId) {
        var scope = taskAccess.readable(planId,segmentId);
        requirePlanExists(planId, false);
        return readClearance(planId,scope);
    }

    /**
     * Exact positive postings offered to the reversal editor.  Reversals must
     * reference one of these ids; demand/type guessing is never permitted.
     */
    @Transactional(readOnly = true)
    public List<ProductionMaterialSettlementSourceRow> settlementSources(
            UUID planId) {
        return settlementSources(planId,null);
    }

    @Transactional(readOnly = true)
    public List<ProductionMaterialSettlementSourceRow> settlementSources(UUID planId, UUID segmentId) {
        var scope = taskAccess.readable(planId,segmentId);
        requirePlanExists(planId, false);
        var query = em.createNativeQuery("""
                        SELECT posting.id, event.id, posting.demand_id,
                               demand.execution_segment_id,
                               segment.segment_code,
                               demand.goods_id, goods.code, goods.name,
                               demand.color_id, color.name,
                               posting.settlement_type, posting.qty_base,
                               COALESCE(reversal.reversed_qty, 0),
                               posting.qty_base
                                   - COALESCE(reversal.reversed_qty, 0),
                               event.reason, event.created_at, event.created_by
                        FROM production_material_settlement_postings posting
                        JOIN production_material_settlement_events event
                          ON event.id = posting.event_id
                         AND event.event_type = 'POST'
                        JOIN production_material_demands demand
                          ON demand.id = posting.demand_id
                        JOIN goods ON goods.id = demand.goods_id
                        LEFT JOIN production_execution_segments segment
                          ON segment.id = demand.execution_segment_id
                        LEFT JOIN colors color ON color.id = demand.color_id
                        LEFT JOIN LATERAL (
                            SELECT SUM(child.qty_base) AS reversed_qty
                            FROM production_material_settlement_postings child
                            JOIN production_material_settlement_events reverse_event
                              ON reverse_event.id = child.event_id
                             AND reverse_event.event_type = 'REVERSE'
                            WHERE child.source_posting_id = posting.id
                        ) reversal ON TRUE
                        WHERE event.plan_id = :planId
                          AND posting.source_posting_id IS NULL
                          AND posting.qty_base
                              > COALESCE(reversal.reversed_qty, 0)
                        """ + (scope.all() ? "" : " AND demand.execution_segment_id IN (:segments)")
                        + " ORDER BY event.created_at DESC, posting.id").setParameter("planId",planId);
        if (!scope.all()) query.setParameter("segments",scope.segmentIds());
        return NativeQueryResults.objectArrayRows(query)
                .stream()
                .map(row -> new ProductionMaterialSettlementSourceRow(
                        (UUID) row[0], (UUID) row[1], (UUID) row[2],
                        (UUID) row[3], (String) row[4],
                        (UUID) row[5], (String) row[6], (String) row[7],
                        (UUID) row[8], (String) row[9], (String) row[10],
                        decimal(row[11]), decimal(row[12]), decimal(row[13]),
                        (String) row[14], offsetDateTime(row[15]),
                        (UUID) row[16]))
                .toList();
    }

    @Transactional
    public List<ProductionMaterialClearanceRow> post(
            UUID planId,
            ProductionMaterialSettlementRequest request,
            UUID actorId) {
        return mutate(planId, request, actorId, false);
    }

    @Transactional
    public List<ProductionMaterialClearanceRow> reverse(
            UUID planId,
            ProductionMaterialSettlementRequest request,
            UUID actorId) {
        return mutate(planId, request, actorId, true);
    }

    @Transactional
    public List<ProductionMaterialClearanceRow> close(UUID planId) {
        tx.bind();
        requirePlanExists(planId, true);
        taskAccess.requireClose(planId);
        Number packages = (Number) em.createNativeQuery("""
                        SELECT COUNT(*)
                        FROM production_planning_packages
                        WHERE plan_id = :planId
                          AND status = 'CONFIRMED'
                          AND is_deleted = FALSE
                        """)
                .setParameter("planId", planId)
                .getSingleResult();
        if (packages.longValue() != 1L) {
            throw new ApiException(
                    ErrorCode.CONFLICT,
                    "计划必须且只能有一个有效物料计划包才能清账结案");
        }
        Number unfinishedProduct = (Number) em.createNativeQuery("""
                        SELECT COUNT(*)
                        FROM production_plan_items
                        WHERE plan_id = :planId
                          AND is_deleted = FALSE
                          AND COALESCE(iqty, 0) < COALESCE(qty, 0)
                        """)
                .setParameter("planId", planId)
                .getSingleResult();
        if (unfinishedProduct.longValue() > 0) {
            throw new ApiException(
                    ErrorCode.CONFLICT,
                    "成品尚未全部入库，不能完成生产任务");
        }
        List<ProductionMaterialClearanceRow> rows = readClearance(planId);
        if (rows.isEmpty() || rows.stream().anyMatch(row -> !row.canClose())) {
            throw new ApiException(
                    ErrorCode.CONFLICT,
                    "物料尚未清账：发出量必须等于耗用、良品退回、审批损耗和合法在制之和");
        }
        em.createNativeQuery("""
                        UPDATE production_plans
                        SET is_closed = TRUE, updated_at = now()
                        WHERE id = :planId
                        """)
                .setParameter("planId", planId)
                .executeUpdate();
        return rows;
    }

    private List<ProductionMaterialClearanceRow> mutate(
            UUID planId,
            ProductionMaterialSettlementRequest request,
            UUID actorId,
            boolean reverse) {
        tx.bind();
        requirePlanExists(planId, true);
        List<Line> lines = normalize(request, reverse);
        List<UUID> demandIds = lines.stream().map(Line::demandId).distinct().toList();
        taskAccess.requireDemandWrite(planId,demandIds,request.getExecutionSegmentId(),
                reverse ? "production_material:reverse" : "production_material:settle");
        var responseScope = taskAccess.readable(planId,request.getExecutionSegmentId());
        String eventType = reverse ? "REVERSE" : "POST";
        String reason = normalizeReason(request.getReason());
        String requestHash = hash(lines, reason);
        List<Object[]> replay = NativeQueryResults.objectArrayRows(
                em.createNativeQuery("""
                                SELECT id, request_hash
                                FROM production_material_settlement_events
                                WHERE plan_id = :planId
                                  AND event_type = :eventType
                                  AND idempotency_key = :key
                                FOR UPDATE
                                """)
                        .setParameter("planId", planId)
                        .setParameter("eventType", eventType)
                        .setParameter("key", request.getIdempotencyKey().strip()));
        if (!replay.isEmpty()) {
            if (!Objects.equals(replay.getFirst()[1], requestHash)) {
                throw new ApiException(
                        ErrorCode.CONFLICT,
                        "相同幂等键对应不同的物料清账请求");
            }
            return readClearance(planId,responseScope);
        }

        List<UUID> locked = NativeQueryResults.typedRows(em.createNativeQuery("""
                        SELECT id
                        FROM production_material_demands
                        WHERE id IN (:ids)
                          AND plan_id = :planId
                          AND is_deleted = FALSE
                          AND status NOT IN ('RELEASED', 'REVERSED')
                        ORDER BY id
                        FOR UPDATE
                        """, UUID.class)
                .setParameter("ids", demandIds)
                .setParameter("planId", planId), UUID.class);
        if (locked.size() != demandIds.size()) {
            throw new ApiException(
                    ErrorCode.CONFLICT,
                    "清账物料需求不属于当前有效计划");
        }

        UUID eventId = UUID.randomUUID();
        em.createNativeQuery("""
                        INSERT INTO production_material_settlement_events(
                            id, plan_id, event_type, idempotency_key,
                            request_hash, reason, created_at, created_by
                        ) VALUES (
                            :id, :planId, :eventType, :key,
                            :requestHash, :reason, now(), :actorId
                        )
                        """)
                .setParameter("id", eventId)
                .setParameter("planId", planId)
                .setParameter("eventType", eventType)
                .setParameter("key", request.getIdempotencyKey().strip())
                .setParameter("requestHash", requestHash)
                .setParameter("reason", reason)
                .setParameter("actorId", actorId)
                .executeUpdate();
        if(reverse)reopenCompletedSegments(eventId,demandIds,requestHash,actorId);
        for (Line line : lines) {
            List<Object[]> sources;
            if(reverse){
                sources=NativeQueryResults.objectArrayRows(em.createNativeQuery(
                        "SELECT issue_posting_id,qty_base FROM production_material_settlement_postings WHERE id=:id")
                        .setParameter("id",line.sourcePostingId()));
            }else{
                sources=NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                        SELECT id,fn_material_issue_unsettled(id) FROM production_material_stock_postings
                        WHERE demand_id=:id AND posting_type='ISSUE' AND fn_material_issue_unsettled(id)>0
                        ORDER BY created_at,id FOR UPDATE
                        """).setParameter("id",line.demandId()));
            }
            BigDecimal remaining=line.qty();
            for(Object[] source:sources){
            if(remaining.signum()==0)break;
            if(source[0]==null)throw new ApiException(ErrorCode.CONFLICT,"历史实耗尚无原领料来源，请先核对");
            BigDecimal part=remaining.min(decimal(source[1]));
            em.createNativeQuery("""
                            INSERT INTO production_material_settlement_postings(
                                id, event_id, demand_id, settlement_type,
                                qty_base, source_posting_id, issue_posting_id, created_at, created_by
                            ) VALUES (
                                gen_random_uuid(), :eventId, :demandId, :type,
                                :qty, :sourceId, :issueId, now(), :actorId
                            )
                            """)
                    .setParameter("eventId", eventId)
                    .setParameter("demandId", line.demandId())
                    .setParameter("type", line.type())
                    .setParameter("qty", part)
                    .setParameter("sourceId", line.sourcePostingId())
                    .setParameter("issueId",source[0])
                    .setParameter("actorId", actorId)
                    .executeUpdate();
            remaining=remaining.subtract(part);
            }
            if(remaining.signum()!=0)throw new ApiException(ErrorCode.CONFLICT,"本次清账超过准确原领料未耗用数量");
        }
        inventoryValue.settled(eventId,actorId);
        // Any material correction re-opens the plan. Explicit close performs
        // the product-inbound and equation checks again.
        em.createNativeQuery("""
                        UPDATE production_plans
                        SET is_closed = FALSE, updated_at = now()
                        WHERE id = :planId
                        """)
                .setParameter("planId", planId)
                .executeUpdate();
        return readClearance(planId,responseScope);
    }

    private void reopenCompletedSegments(UUID eventId,List<UUID> demandIds,String requestHash,UUID actor){
        List<Object[]> segments=NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT segment.id,segment.lock_version FROM production_execution_segments segment
                WHERE segment.status='COMPLETED' AND NOT segment.is_deleted AND EXISTS(
                    SELECT 1 FROM production_material_demands demand WHERE demand.id IN(:ids) AND demand.execution_segment_id=segment.id)
                ORDER BY segment.id FOR UPDATE OF segment
                """).setParameter("ids",demandIds));
        if(segments.isEmpty())return;
        em.createNativeQuery("SELECT set_config('app.production_completion_reopen_settlement_id',:id,true)")
                .setParameter("id",eventId.toString()).getSingleResult();
        for(Object[] segment:segments){
            long version=((Number)segment[1]).longValue();
            em.createNativeQuery("""
                    INSERT INTO production_execution_segment_events(id,execution_segment_id,action,idempotency_key,
                        request_hash,expected_version,resulting_version,created_by)
                    VALUES(gen_random_uuid(),:segment,'REOPEN_COMPLETION',:key,:hash,:version,:next,:actor)
                    """).setParameter("segment",segment[0]).setParameter("key","MATERIAL_SETTLEMENT_REVERSE:"+eventId)
                    .setParameter("hash",requestHash).setParameter("version",version).setParameter("next",version+1)
                    .setParameter("actor",actor).executeUpdate();
            int changed=em.createNativeQuery("""
                    UPDATE production_execution_segments SET status='IN_PROGRESS',completion_reopened=true
                    WHERE id=:id AND lock_version=:version AND status='COMPLETED'
                    """).setParameter("id",segment[0]).setParameter("version",version).executeUpdate();
            if(changed!=1)throw new ApiException(ErrorCode.CONFLICT,"执行段已变化，实耗纠正已全部撤回");
        }
    }

    private void requirePlanExists(UUID planId, boolean writeLock) {
        String suffix = writeLock ? " FOR UPDATE" : "";
        List<?> rows = em.createNativeQuery("""
                        SELECT id
                        FROM production_plans
                        WHERE id = :planId
                          AND is_deleted = FALSE
                          AND is_canceled = FALSE
                          AND is_stopped = FALSE
                        """ + suffix)
                .setParameter("planId", planId)
                .getResultList();
        if (rows.size() != 1) {
            throw new ApiException(
                    ErrorCode.NOT_FOUND,
                    "有效生产计划不存在");
        }
    }

    private List<ProductionMaterialClearanceRow> readClearance(UUID planId) {
        return readClearance(planId,new ProductionMaterialTaskAccessPolicy.ReadScope(true,List.of()));
    }

    private List<ProductionMaterialClearanceRow> readClearance(UUID planId, ProductionMaterialTaskAccessPolicy.ReadScope scope) {
        var query = em.createNativeQuery("""
                        SELECT c.plan_id, c.demand_id,
                               demand.execution_segment_id,
                               segment.segment_code, c.goods_id,
                               g.code, g.name, c.color_id, color.name,
                               c.required_qty, c.issued_qty, c.returned_qty,
                               c.confirmed_consumed_qty, c.approved_loss_qty,
                               c.legal_wip_qty,
                               GREATEST(c.uncleared_qty, 0),
                               c.uncleared_qty, c.can_close, demand_unit.name
                        FROM v_production_material_clearance c
                        JOIN production_material_demands demand
                          ON demand.id = c.demand_id
                        LEFT JOIN production_execution_segments segment
                          ON segment.id = demand.execution_segment_id
                        JOIN goods g ON g.id = c.goods_id
                        LEFT JOIN units demand_unit ON demand_unit.id = demand.unit_id
                        LEFT JOIN colors color ON color.id = c.color_id
                        WHERE c.plan_id = :planId
                        """ + (scope.all() ? "" : " AND demand.execution_segment_id IN (:segments)")
                        + " ORDER BY g.code, c.color_id NULLS FIRST, c.demand_id").setParameter("planId",planId);
        if (!scope.all()) query.setParameter("segments",scope.segmentIds());
        return NativeQueryResults.objectArrayRows(query)
                .stream()
                .map(row -> new ProductionMaterialClearanceRow(
                        (UUID) row[0], (UUID) row[1], (UUID) row[2],
                        (String) row[3], (UUID) row[4], (String) row[5],
                        (String) row[6], (UUID) row[7], (String) row[8],
                        decimal(row[9]), decimal(row[10]), decimal(row[11]),
                        decimal(row[12]), decimal(row[13]), decimal(row[14]),
                        decimal(row[15]), decimal(row[16]),
                        Boolean.TRUE.equals(row[17]), (String) row[18]))
                .toList();
    }

    private static List<Line> normalize(
            ProductionMaterialSettlementRequest request,
            boolean reverse) {
        if (request == null
                || request.getIdempotencyKey() == null
                || request.getIdempotencyKey().strip().length() < 8
                || request.getIdempotencyKey().strip().length() > 128
                || request.getLines() == null
                || request.getLines().isEmpty()) {
            throw new ApiException(
                    ErrorCode.VALIDATION_FAILED,
                    "物料清账缺少有效幂等键或明细");
        }
        List<Line> result = new ArrayList<>();
        for (ProductionMaterialSettlementRequest.Line line : request.getLines()) {
            String type = line.getSettlementType() == null
                    ? "" : line.getSettlementType().strip().toUpperCase();
            if (line.getDemandId() == null
                    || !TYPES.contains(type)
                    || line.getQtyBase() == null
                    || line.getQtyBase().signum() <= 0
                    || (reverse != (line.getSourcePostingId() != null))) {
                throw new ApiException(
                        ErrorCode.VALIDATION_FAILED,
                        "清账明细的需求、类型、正数基本量或红冲来源无效");
            }
            result.add(new Line(
                    line.getDemandId(), type, line.getQtyBase(),
                    line.getSourcePostingId()));
        }
        result.sort(Comparator
                .comparing(Line::demandId)
                .thenComparing(Line::type)
                .thenComparing(
                        Line::sourcePostingId,
                        Comparator.nullsFirst(Comparator.naturalOrder())));
        return List.copyOf(result);
    }

    private static String hash(List<Line> lines, String reason) {
        StringBuilder value = new StringBuilder()
                .append("reason=").append(reason).append('\n');
        lines.forEach(line -> value.append(line.demandId()).append('|')
                .append(line.type()).append('|')
                .append(line.qty().stripTrailingZeros().toPlainString()).append('|')
                .append(line.sourcePostingId()).append('\n'));
        try {
            return HexFormat.of().formatHex(
                    MessageDigest.getInstance("SHA-256")
                            .digest(value.toString().getBytes(StandardCharsets.UTF_8)));
        } catch (NoSuchAlgorithmException impossible) {
            throw new IllegalStateException(impossible);
        }
    }

    static OffsetDateTime offsetDateTime(Object value) {
        if (value == null) return null;
        if (value instanceof OffsetDateTime dateTime) return dateTime;
        if (value instanceof Instant instant) return instant.atOffset(ZoneOffset.UTC);
        if (value instanceof Timestamp timestamp) {
            return timestamp.toInstant().atOffset(ZoneOffset.UTC);
        }
        throw new ApiException(
                ErrorCode.CONFLICT,
                "物料清账事件时间字段类型异常");
    }

    private static BigDecimal decimal(Object value) {
        if (value == null) return BigDecimal.ZERO;
        if (value instanceof BigDecimal number) return number;
        return new BigDecimal(value.toString());
    }

    private static String normalizeReason(String reason) {
        if (reason == null || reason.isBlank()) return "未填写";
        String normalized = reason.strip();
        return normalized.substring(0, Math.min(500, normalized.length()));
    }

    private record Line(
            UUID demandId,
            String type,
            BigDecimal qty,
            UUID sourcePostingId) {
    }
}
