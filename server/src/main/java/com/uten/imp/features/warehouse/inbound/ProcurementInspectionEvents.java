package com.uten.imp.features.warehouse.inbound;

import jakarta.persistence.EntityManager;

import java.math.BigDecimal;
import java.time.OffsetDateTime;
import java.util.List;
import java.util.UUID;

/**
 * IQC 追加式事件账({@code procurement_inspection_events})的唯一写入口。
 *
 * <p>2026-09-16 从 {@link ProcurementInspectionService#appendEvent} 抽出：先入库后检(V596)
 * 也要写 {@code PRE_STOCKED} 事件，两个服务共用同一条 INSERT，避免第二份 SQL 各自漂移。
 * 只负责落行；品质切片冻结与价值账钩子仍由调用方按动作决定。
 */
final class ProcurementInspectionEvents {

    static final String RECEIVED = "RECEIVED";
    static final String PASS = "PASS";
    static final String FAIL = "FAIL";
    static final String PRE_STOCKED = "PRE_STOCKED";
    static final String PRODUCTION_WOKEN = "PRODUCTION_WOKEN";
    static final String RECEIPT_RESOLVED = "RECEIPT_RESOLVED";
    static final String RECEIPT_REVERSED = "RECEIPT_REVERSED";

    private ProcurementInspectionEvents() {
    }

    /** 无金额/重量切片的简单事件(RECEIVED / PRE_STOCKED / 结案 / 撤销)。 */
    static void append(EntityManager em, UUID eventId, UUID inspectionItemId, String action,
                       BigDecimal baseQty, String reason, UUID actorEmployeeId, OffsetDateTime occurredAt) {
        append(em, eventId, inspectionItemId, action, baseQty, reason, actorEmployeeId, occurredAt,
                null, null, null);
    }

    /** releasedWeight 为放行重量切片(千克), 到货没称时为空。 */
    static void append(EntityManager em, UUID eventId, UUID inspectionItemId, String action,
                       BigDecimal baseQty, String reason, UUID actorEmployeeId, OffsetDateTime occurredAt,
                       BigDecimal releasedAmountLocal, BigDecimal releasedWeight, String batchRequestHash) {
        append(em,eventId,inspectionItemId,action,baseQty,reason,actorEmployeeId,occurredAt,
                releasedAmountLocal,releasedWeight,batchRequestHash,null);
    }

    static void append(EntityManager em, UUID eventId, UUID inspectionItemId, String action,
                       BigDecimal baseQty, String reason, UUID actorEmployeeId, OffsetDateTime occurredAt,
                       BigDecimal releasedAmountLocal, BigDecimal releasedWeight, String batchRequestHash,
                       UUID actorUserId) {
        em.createNativeQuery("""
                INSERT INTO procurement_inspection_events (
                    id, inspection_item_id, action, base_qty, reason,
                    actor_employee_id, occurred_at, requires_warehouse_stock_in,
                    released_amount_local, released_weight, batch_request_hash, actor_user_id
                ) VALUES (
                    :id, :iid, :action, :qty, :reason,
                    :actor, :at, :requiresWarehouseStockIn,
                    :releasedAmountLocal, :releasedWeight, :batchRequestHash, :actorUserId)
                """)
                .setParameter("id", eventId)
                .setParameter("iid", inspectionItemId)
                .setParameter("action", action)
                .setParameter("qty", baseQty)
                .setParameter("reason", reason)
                .setParameter("actor", actorEmployeeId)
                .setParameter("at", occurredAt)
                .setParameter("requiresWarehouseStockIn", PASS.equals(action))
                .setParameter("releasedAmountLocal", releasedAmountLocal)
                .setParameter("releasedWeight", releasedWeight)
                .setParameter("batchRequestHash", batchRequestHash)
                .setParameter("actorUserId", actorUserId)
                .executeUpdate();
    }

    /** One event row of a batched append; columns mirror {@link #append} one to one. */
    record EventRow(UUID id, UUID inspectionItemId, String action, BigDecimal baseQty, String reason,
                    UUID actorEmployeeId, OffsetDateTime occurredAt, BigDecimal releasedAmountLocal,
                    BigDecimal releasedWeight, String batchRequestHash, UUID actorUserId) { }

    /**
     * W6-F (2026-11-08)：整份结论的事件落账合并为一条多行 INSERT。行序 = 事件顺序，
     * 同一行先后 PASS/FAIL 的累计切片数学在调用方内存里按同一顺序完成，occurred_at
     * 顺序与逐条路径一致(pass_release_value 依赖)；列与单条 INSERT 完全同构。
     */
    static void appendAll(EntityManager em, List<EventRow> rows) {
        if (rows == null || rows.isEmpty()) return;
        StringBuilder sql = new StringBuilder("""
                INSERT INTO procurement_inspection_events (
                    id, inspection_item_id, action, base_qty, reason,
                    actor_employee_id, occurred_at, requires_warehouse_stock_in,
                    released_amount_local, released_weight, batch_request_hash, actor_user_id
                ) VALUES
                """);
        for (int i = 0; i < rows.size(); i++) {
            sql.append(i == 0
                    ? "(?::uuid,?::uuid,?::text,?::numeric,?::text,?::uuid,?::timestamptz,?::boolean,?::numeric,?::numeric,?::text,?::uuid)"
                    : ",(?,?,?,?,?,?,?,?,?,?,?,?)");
        }
        var query = em.createNativeQuery(sql.toString());
        int parameter = 1;
        for (EventRow row : rows) {
            query.setParameter(parameter++, row.id());
            query.setParameter(parameter++, row.inspectionItemId());
            query.setParameter(parameter++, row.action());
            query.setParameter(parameter++, row.baseQty());
            query.setParameter(parameter++, row.reason());
            query.setParameter(parameter++, row.actorEmployeeId());
            query.setParameter(parameter++, row.occurredAt());
            query.setParameter(parameter++, PASS.equals(row.action()));
            query.setParameter(parameter++, row.releasedAmountLocal());
            query.setParameter(parameter++, row.releasedWeight());
            query.setParameter(parameter++, row.batchRequestHash());
            query.setParameter(parameter++, row.actorUserId());
        }
        query.executeUpdate();
    }
}
