package com.uten.imp.features.warehouse.inbound;

import jakarta.persistence.EntityManager;

import java.math.BigDecimal;
import java.time.OffsetDateTime;
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
}
