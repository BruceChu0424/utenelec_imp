package com.uten.imp.features.production.analysis;

import com.uten.imp.common.util.NativeQueryResults;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import jakarta.persistence.EntityManager;
import java.math.BigDecimal;
import java.util.*;

/** Exact original private shares of an aggregate order, excluding public/safety output. */
final class AggregatePrivateIntentReader {
    private final EntityManager em;
    AggregatePrivateIntentReader(EntityManager em) { this.em=em; }
    record Coverage(Map<UUID,Map<UUID,BigDecimal>> byTarget) { }
    record Share(UUID batch,UUID target,UUID original,BigDecimal qty,
                 BigDecimal allocatedQty,BigDecimal effectiveQty) { }
    private record Slice(UUID batch,UUID target) { }

    /**
     * 行动 -> 分配的在途量与已收量, 一个行动只判一次、分配按创建先后切片 (集合写法, 2026-09-27).
     *
     * <p>与库函数 fn_preplan_aggregate_allocation_pending_qty / fn_preplan_allocation_received_qty
     * 逐条结果完全一致: 分支判定 (已结束 / 在途转拨 / 各路线的行动在途总量) 每个行动只算一次,
     * 「排在前面的分配先占」用窗口累计代替逐条回查, 叶子量仍调同一批库函数
     * (fn_preplan_allocation_admitted_qty 等). 以前逐条调用时一个行动 N 条分配要回查 N^2 次,
     * 一份分析详情光这一段就要 100 ms 以上.
     *
     * <p>调用方先给出 CTE {@code scoped_actions(action_id)}; 产出 {@code allocation_pending}
     * (id, action_id, analysis_material_id, allocated_qty, status, pending_qty, received_qty).
     * 与库函数的逐条一致性由测试辅助 AggregateAllocationPendingParity 在合单/在途转拨端到端测试
     * 收尾时对库里全部分配比对守住, 库函数改口径而这里没跟上时那些测试会先红.
     */
    static final String ALLOCATION_PENDING_CTES = """
            batch_actions AS MATERIALIZED (
              SELECT action.id,action.status,action.operation_type,action.route,
                     action.external_document_type,action.external_document_id
              FROM preplan_supply_actions action
              WHERE action.id IN (SELECT scoped.action_id FROM scoped_actions scoped)
            ), action_head AS MATERIALIZED (
              SELECT action.*,
                     CASE WHEN action.status NOT IN('OPEN','CREATED','IN_PROGRESS') THEN 'CLOSED'
                          WHEN action.operation_type='FUTURE_TRANSFER' OR fn_preplan_action_has_future_transfer(action.id)
                               OR fn_preplan_action_has_shared_claim_history(action.id) THEN 'FUTURE'
                          ELSE 'SLICED' END AS mode
              FROM batch_actions action
            ), action_pending AS MATERIALIZED (
              SELECT action.id,action.status,action.mode,
                     CASE WHEN action.mode<>'SLICED' THEN NULL
                          WHEN action.operation_type='SHARED_FUTURE_CLAIM' THEN fn_preplan_shared_action_pending_qty(action.id)
                          WHEN action.route='BUY' THEN (SELECT CASE WHEN progress.demand_source_valid
                                   THEN LEAST(GREATEST(progress.demand_requested_qty-progress.demand_qualified_qty,0),progress.demand_future_qty)
                                   ELSE 0 END
                               FROM v_preplan_buy_action_slice_progress progress WHERE progress.action_id=action.id)
                          WHEN action.external_document_type='PREPLAN_MAKE_TASK' THEN
                               CASE WHEN EXISTS(SELECT 1 FROM production_material_analysis_items child
                                   WHERE child.id=action.external_document_id AND NOT child.is_deleted
                                     AND (child.requested_qty>child.approved_qty OR EXISTS(SELECT 1 FROM production_material_analysis_plan_links link
                                       JOIN production_plans plan ON plan.id=link.plan_id AND plan.status IN(0,1) AND NOT plan.is_deleted
                                         AND NOT plan.is_canceled AND NOT plan.is_closed
                                       WHERE link.analysis_item_id=child.id AND link.allocation_status IN('SUBMITTED','APPROVED'))))
                                    THEN GREATEST(fn_preplan_action_admitted_qty(action.id)-fn_preplan_action_received_qty(action.id),0)
                                    ELSE 0 END
                          WHEN action.external_document_type='SUBCONTRACT_APPLICATION' AND EXISTS(SELECT 1 FROM subcontract_applications application
                               WHERE application.id=action.external_document_id AND NOT application.is_deleted AND application.status IN(0,1))
                               THEN GREATEST(fn_preplan_action_admitted_qty(action.id)-fn_preplan_action_received_qty(action.id),0)
                          ELSE 0 END AS total_pending
              FROM action_head action
            ), allocation_capacity AS MATERIALIZED (
              SELECT allocation.id,allocation.action_id,allocation.analysis_material_id,allocation.allocated_qty,
                     allocation.created_at,action.status,action.mode,action.total_pending,received.qty AS received_qty,
                     CASE WHEN action.mode='SLICED'
                          THEN GREATEST(fn_preplan_allocation_admitted_qty(allocation.id)-received.qty,0) END AS own_capacity
              FROM action_pending action
              JOIN preplan_supply_action_allocations allocation ON allocation.action_id=action.id
              CROSS JOIN LATERAL (SELECT CASE WHEN action.status='CANCELLED' THEN NULL
                  ELSE fn_preplan_allocation_received_qty(allocation.id) END AS qty) received
            ), allocation_pending AS (
              SELECT capacity.id,capacity.action_id,capacity.analysis_material_id,capacity.allocated_qty,
                     capacity.status,capacity.received_qty,
                     CASE capacity.mode WHEN 'CLOSED' THEN 0
                          WHEN 'FUTURE' THEN fn_preplan_future_allocation_pending_qty(capacity.id)
                          ELSE LEAST(capacity.own_capacity,GREATEST(COALESCE(capacity.total_pending,0)
                              -COALESCE(SUM(capacity.own_capacity) OVER (PARTITION BY capacity.action_id
                                  ORDER BY capacity.created_at,capacity.id ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING),0),0))
                     END AS pending_qty
              FROM allocation_capacity capacity
            )
            """;

    Coverage read(UUID analysisId) {
        List<Share> shares=new ArrayList<>();
        for(Object[] row:NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                WITH complete_batches AS (
                  SELECT batch.id,batch.action_id
                  FROM preplan_aggregate_batches batch JOIN preplan_aggregate_batch_events event ON event.batch_id=batch.id
                  WHERE batch.analysis_id=:analysis AND event.event_type IN('CREATE','APPEND')
                  GROUP BY batch.id,batch.action_id
                  HAVING bool_and(jsonb_typeof(event.intent_snapshot->'sourcePrivateQtyByTargetMaterialLineId') IS NOT DISTINCT FROM 'object')
                ), recorded AS (
                  SELECT batch.id batch_id,batch.action_id,target.key::uuid target_id,origin.key::uuid original_id,
                         SUM(origin.value::numeric) qty
                  FROM complete_batches batch JOIN preplan_aggregate_batch_events event ON event.batch_id=batch.id
                  CROSS JOIN LATERAL jsonb_each(event.intent_snapshot->'sourcePrivateQtyByTargetMaterialLineId') target
                  CROSS JOIN LATERAL jsonb_each_text(target.value) origin
                  WHERE event.event_type IN('CREATE','APPEND')
                  GROUP BY batch.id,batch.action_id,target.key,origin.key
                ), scoped_actions AS (
                  SELECT DISTINCT batch.action_id FROM complete_batches batch
                ), %s, actual AS (
                  SELECT batch.id batch_id,pending.analysis_material_id target_id,
                         SUM(pending.allocated_qty) allocated_qty,
                         SUM(CASE WHEN pending.status='CANCELLED' THEN 0
                             ELSE LEAST(pending.allocated_qty,pending.pending_qty+pending.received_qty) END) effective_qty
                  FROM complete_batches batch JOIN allocation_pending pending ON pending.action_id=batch.action_id
                  GROUP BY batch.id,pending.analysis_material_id
                )
                SELECT recorded.batch_id,recorded.target_id,recorded.original_id,recorded.qty,
                       COALESCE(actual.allocated_qty,0),COALESCE(actual.effective_qty,0)
                FROM recorded LEFT JOIN actual ON actual.batch_id=recorded.batch_id AND actual.target_id=recorded.target_id
                """.formatted(ALLOCATION_PENDING_CTES.strip())).setParameter("analysis",analysisId))) {
            shares.add(new Share((UUID)row[0],(UUID)row[1],(UUID)row[2],(BigDecimal)row[3],(BigDecimal)row[4],(BigDecimal)row[5]));
        }
        return project(shares);
    }

    static Coverage project(List<Share> shares) {
        Map<Slice,List<Share>> slices=new LinkedHashMap<>();
        for(Share share:shares) {
            if(share.batch()==null||share.target()==null||share.original()==null||share.qty()==null
                    ||share.qty().signum()<0||share.allocatedQty()==null||share.effectiveQty()==null)throw invalid();
            slices.computeIfAbsent(new Slice(share.batch(),share.target()),ignored->new ArrayList<>()).add(share);
        }
        Map<UUID,Map<UUID,BigDecimal>> targets=new LinkedHashMap<>();
        for(var entry:slices.entrySet()) {
            Share first=entry.getValue().getFirst();Map<UUID,BigDecimal> weights=new LinkedHashMap<>();
            for(Share share:entry.getValue()) {
                if(share.allocatedQty().compareTo(first.allocatedQty())!=0||share.effectiveQty().compareTo(first.effectiveQty())!=0)throw invalid();
                weights.merge(share.original(),share.qty(),BigDecimal::add);
            }
            BigDecimal recorded=weights.values().stream().reduce(BigDecimal.ZERO,BigDecimal::add);
            if(recorded.compareTo(first.allocatedQty())!=0||first.effectiveQty().signum()<0
                    ||first.effectiveQty().compareTo(recorded)>0)throw invalid();
            Map<UUID,BigDecimal> target=targets.computeIfAbsent(entry.getKey().target(),ignored->new LinkedHashMap<>());
            AggregateDelegationProjection.proportional(first.effectiveQty(),weights)
                    .forEach((id,qty)->target.merge(id,qty,BigDecimal::add));
        }
        Map<UUID,Map<UUID,BigDecimal>> result=new LinkedHashMap<>();
        targets.forEach((id,values)->result.put(id,Map.copyOf(values)));
        return new Coverage(Map.copyOf(result));
    }
    private static ApiException invalid() {
        return new ApiException(ErrorCode.CONFLICT,"合单原行私有份额与真实供给不一致，请核对来源后重试");
    }
}
