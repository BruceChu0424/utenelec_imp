package com.uten.imp.features.stock.valuation;

import com.uten.imp.application.port.InventoryMovementCostReference.SalesReturnQuality;
import com.uten.imp.application.port.InventoryPositionPort;
import com.uten.imp.application.port.InventoryPositionPort.*;
import com.uten.imp.application.port.InventoryValuationPort;
import com.uten.imp.application.port.InventoryValuationPort.*;
import com.uten.imp.application.port.SalesReturnInventoryValuePort;
import com.uten.imp.features.stock.StockService;
import jakarta.persistence.EntityManager;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.nio.charset.StandardCharsets;
import java.time.OffsetDateTime;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;

import static com.uten.imp.features.stock.valuation.InventoryBusinessValueSupport.pool;
import static com.uten.imp.features.stock.valuation.InventoryBusinessValueSupport.time;
import static com.uten.imp.features.stock.valuation.ValueMath.conflict;

/** Returned goods retain their real sales cost and remain outside saleable stock until released. */
@Service
@Transactional(propagation = Propagation.MANDATORY)
public class SalesReturnInventoryValueService implements SalesReturnInventoryValuePort {
    private final EntityManager em;
    private final NamedParameterJdbcTemplate db;
    private final InventoryPositionPort positions;
    private final InventoryValuationPort values;
    private final InventoryBusinessValueSupport support;

    public SalesReturnInventoryValueService(EntityManager em, NamedParameterJdbcTemplate db,
            InventoryPositionPort positions, InventoryValuationPort values, InventoryBusinessValueSupport support) {
        this.em = em;
        this.db = db;
        this.positions = positions;
        this.values = values;
        this.support = support;
    }

    @Override
    public void receivedForInspection(UUID returnId, UUID actorUserId) {
        em.flush();
        List<UUID> events = receiptEvents(returnId, "RECEIVED");
        if (events.isEmpty()) throw conflict("退货缺少真实收货和待检记录，不能建立成本");
        for (UUID id : events) {
            Quality event = quality(id);
            requireStatus(event, 1);
            if (done("SALES_RETURN_RECEIVED", event.id())) continue;
            EventContext context = context("SALES_RETURN_RECEIVED", event, actorUserId, 0);
            SourceMovement original = originalMovement(event);
            ensureOriginalCost(original, context);
            support.ensureActive(event.pool(), context);
            moveQuantity(event, actorUserId, "SALES_RETURN_RECEIVED", Owner.COGS,
                    event.shipmentItemId(), Owner.RETURN_INSPECTION, event.qualityId(), event.pool());
        }
    }

    @Override
    public void untouchedReceiptReversed(UUID returnId, UUID actorUserId) {
        em.flush();
        // Historical returns without the quality ledger stay on their existing
        // physical reversal path; no retrospective inspection event is invented.
        for (UUID id : receiptEvents(returnId, "RECEIPT_REVERSED")) {
            Quality event = quality(id);
            requireStatus(event, -1);
            if (done("SALES_RETURN_RECEIPT_REVERSED", event.id())) continue;
            SourceMovement original = originalMovement(event);
            EventContext context = context("SALES_RETURN_RECEIPT_REVERSED", event, actorUserId, 0);
            support.ensureActive(original.pool(), context);
            moveQuantity(event, actorUserId, "SALES_RETURN_RECEIPT_REVERSED", Owner.RETURN_INSPECTION,
                    event.qualityId(), Owner.COGS, event.shipmentItemId(), original.pool());
        }
    }

    /** Invoked by the single stock posting boundary; it creates no second physical movement. */
    public MovementValue movement(SalesReturnQuality reference, UUID movementId, PoolKey target,
            BigDecimal qty, BigDecimal before, EventContext movementContext, short direction) {
        em.flush();
        Quality event = quality(reference.qualityEventId());
        requireStatus(event, 1);
        if (!event.qualityId().equals(reference.qualityItemId()) || !event.pool().equals(target)
                || event.qty().compareTo(qty) != 0
                || !event.returnId().equals(movementContext.sourceDocId())
                || !event.id().equals(movementContext.sourceItemId())) {
            throw conflict("退货库存流水与真实质检事件的来源、仓库或数量不一致");
        }
        support.ensureActive(target, movementContext);
        if ("GOOD_RELEASE_REVOKED".equals(event.action()) && direction == StockService.DIR_OUT) {
            // This is a new physical classification of the current mixed pool,
            // not a rewrite of a previously received lot or an earlier sale.
            return values.issue(new Issue(movementContext, movementId, target, qty, before,
                    Destination.RETURN_INSPECTION, event.qualityId()));
        }
        if (!"GOOD_RELEASE".equals(event.action()) || direction != StockService.DIR_IN) {
            throw conflict("只有真实良品释放或其撤回可以改变可用库存");
        }
        List<UUID> readyRoots = moveQuantity(event, movementContext.actorUserId(),
                "SALES_RETURN_GOOD_READY", Owner.RETURN_INSPECTION, event.qualityId(),
                Owner.QUALITY_PASSED, event.id(), target);
        List<Slice> ready = new ArrayList<>();
        for (UUID root : readyRoots) {
            var position = positions.position(root);
            ready.add(new Slice(root, position.remainingQtyBase(), root));
        }
        // A quality command is bounded by the physical document line limit.
        // Each intermediate root combines up to 100 exact, immutable sources.
        if (ready.size() > 100) throw conflict("本次退货成本来源过多，请分批确认良品入库");
        return positions.store(new Store(movementContext, movementId, target, before, List.copyOf(ready)));
    }

    @Override
    public void qualityEventRecorded(UUID qualityEventId, UUID actorUserId) {
        em.flush();
        Quality event = quality(qualityEventId);
        requireStatus(event, 1);
        switch (event.action()) {
            case "GOOD_RELEASE", "GOOD_RELEASE_REVOKED" -> requirePhysicalValue(event);
            case "SCRAP" -> moveQuantity(event, actorUserId, "SALES_RETURN_SCRAP",
                    Owner.RETURN_INSPECTION, event.qualityId(), Owner.LOSS, event.qualityId(), event.pool());
            case "REWORK" -> moveQuantity(event, actorUserId, "SALES_RETURN_REWORK",
                    Owner.RETURN_INSPECTION, event.qualityId(), Owner.WIP, event.qualityId(), event.pool());
            case "SCRAP_REVOKED" -> moveQuantity(event, actorUserId, "SALES_RETURN_SCRAP_REVOKED",
                    Owner.LOSS, event.qualityId(), Owner.RETURN_INSPECTION, event.qualityId(), event.pool());
            case "REWORK_REVOKED" -> moveQuantity(event, actorUserId, "SALES_RETURN_REWORK_REVOKED",
                    Owner.WIP, event.qualityId(), Owner.RETURN_INSPECTION, event.qualityId(), event.pool());
            default -> throw conflict("该退货事件必须走对应的收货或收货撤回流程");
        }
    }

    private List<UUID> moveQuantity(Quality event, UUID actor, String kind,
            Owner sourceOwner, UUID sourceOwnerId, Owner targetOwner, UUID targetOwnerId, PoolKey target) {
        List<UUID> prior = resultRoots(kind, event.id());
        if (!prior.isEmpty()) return prior;
        List<Slice> slices = sourceSlices(sourceOwner, sourceOwnerId, target, event.qty());
        List<UUID> moved = new ArrayList<>();
        for (int start = 0, index = 0; start < slices.size(); start += 100, index++) {
            EventContext context = context(kind, event, actor, index);
            support.ensureActive(target, context);
            var result = positions.move(new Move(context, target, targetOwner, targetOwnerId,
                    slices.subList(start, Math.min(start + 100, slices.size()))));
            moved.add(result.positionRootId());
        }
        return List.copyOf(moved);
    }

    private List<Slice> sourceSlices(Owner owner, UUID ownerId, PoolKey target, BigDecimal required) {
        Map<String, Object> parameters = new HashMap<>();
        parameters.put("owner", owner.name()); parameters.put("id", ownerId);
        parameters.put("goods", target.goodsId()); parameters.put("color", target.colorId());
        var rows = db.queryForList("""
                SELECT root.id,head.range_to-head.range_from AS available
                FROM stock_value_nodes root
                JOIN stock_value_nodes head ON head.id=root.return_head_id
                JOIN stock_value_pools pool ON pool.id=head.pool_id
                JOIN stock_value_events event ON event.id=root.creation_event_id
                WHERE root.kind='ISSUE_POSITION' AND root.id=root.root_issue_id
                  AND root.owner_kind=:owner AND root.owner_id=:id
                  AND head.active AND head.range_to>head.range_from
                  AND pool.goods_id=:goods AND pool.color_id IS NOT DISTINCT FROM CAST(:color AS uuid)
                ORDER BY event.occurred_at,root.id
                """, parameters);
        BigDecimal remaining = required;
        List<Slice> slices = new ArrayList<>();
        for (Map<String, Object> row : rows) {
            if (remaining.signum() == 0) break;
            BigDecimal take = remaining.min((BigDecimal) row.get("available"));
            UUID root = (UUID) row.get("id");
            // The source root is the precise immutable value-allocation fact;
            // the enclosing context also retains the real quality event UUID.
            slices.add(new Slice(root, take, root));
            remaining = remaining.subtract(take);
        }
        if (remaining.signum() > 0) throw conflict("退货原成本位置的可用数量不足，请先核对已处置或已使用的来源");
        return List.copyOf(slices);
    }

    private void ensureOriginalCost(SourceMovement original, EventContext actor) {
        Boolean known = db.queryForObject("""
                SELECT EXISTS(SELECT 1 FROM stock_value_events WHERE movement_id=:id)
                    OR EXISTS(SELECT 1 FROM stock_value_acquisition_sources WHERE evidence_id=:id)
                """, Map.of("id", original.id()), Boolean.class);
        if (Boolean.TRUE.equals(known)) return;
        EventContext context = support.context("LEGACY_SALES_COST", original.id(), original.shipmentId(),
                original.shipmentItemId(), actor.actorUserId(), original.occurredAt());
        support.ensureActive(original.pool(), context);
        positions.acquire(new Acquire(context, original.pool(), original.id(), 1,
                Owner.COGS, original.shipmentItemId(), List.of()));
    }

    private void requirePhysicalValue(Quality event) {
        boolean released = "GOOD_RELEASE".equals(event.action());
        Integer matches = db.queryForObject("""
                SELECT count(*) FROM stock_movements movement
                JOIN stock_value_events value_event ON value_event.movement_id=movement.id
                WHERE movement.source_doc_type='SALES_RETURN' AND movement.source_doc_id=:returnId
                  AND movement.source_item_id=:event AND movement.movement_type=4
                  AND movement.direction=:direction AND movement.qty=:qty
                  AND value_event.operation=:operation
                """, Map.of("returnId", event.returnId(), "event", event.id(), "qty", event.qty(),
                        "direction", released ? 1 : -1, "operation", released ? "POSITION_STORE" : "ISSUE"), Integer.class);
        if (matches == null || matches != 1) throw conflict("退货良品库存与成本必须由同一个真实质检事件完成");
    }

    private SourceMovement originalMovement(Quality event) {
        var rows = db.queryForList("""
                SELECT movement.id,movement.source_doc_id,movement.source_item_id,
                       movement.warehouse_id,movement.goods_id,movement.color_id,movement.transaction_date
                FROM sales_shipment_items item
                JOIN sales_shipments shipment ON shipment.id=item.shipment_id
                    AND shipment.status=1 AND shipment.warehouse_work_status='SHIPPED' AND NOT shipment.is_deleted
                JOIN stock_movements movement ON movement.source_doc_type='SALES_SHIPMENT'
                    AND movement.source_doc_id=shipment.id AND movement.source_item_id=item.id
                    AND movement.direction=-1 AND movement.movement_type IN (3,20)
                    AND movement.goods_id=item.goods_id AND movement.color_id IS NOT DISTINCT FROM item.color_id
                    AND movement.warehouse_id=shipment.warehouse_id
                WHERE item.id=:id AND NOT item.is_deleted
                """, Map.of("id", event.shipmentItemId()));
        if (rows.size() != 1) throw conflict("退货必须对应唯一真实已发货库存流水，不能猜测原成本");
        Map<String, Object> row = rows.getFirst();
        PoolKey originalPool = pool(row);
        if (!originalPool.goodsId().equals(event.pool().goodsId())
                || !java.util.Objects.equals(originalPool.colorId(), event.pool().colorId())) {
            throw conflict("退货货品或颜色与原发货库存不一致");
        }
        return new SourceMovement((UUID) row.get("id"), (UUID) row.get("source_doc_id"),
                (UUID) row.get("source_item_id"), originalPool, time(row.get("transaction_date")));
    }

    private List<UUID> receiptEvents(UUID returnId, String action) {
        return db.queryForList("""
                SELECT event.id FROM sales_return_quality_events event
                JOIN sales_return_quality_items quality ON quality.id=event.quality_item_id
                WHERE quality.return_id=:id AND event.action=:action ORDER BY quality.id,event.id
                """, Map.of("id", returnId, "action", action), UUID.class);
    }

    private Quality quality(UUID id) {
        var rows = db.queryForList("""
                SELECT event.id,event.action,event.base_qty,event.occurred_at,event.actor_employee_id,
                       quality.id AS quality_id,quality.return_id,quality.return_item_id,
                       quality.warehouse_id,quality.goods_id,quality.color_id,
                       item.out_item_id,document.status
                FROM sales_return_quality_events event
                JOIN sales_return_quality_items quality ON quality.id=event.quality_item_id
                JOIN sales_return_items item ON item.id=quality.return_item_id
                    AND item.return_id=quality.return_id AND NOT item.is_deleted
                    AND item.goods_id=quality.goods_id AND item.color_id IS NOT DISTINCT FROM quality.color_id
                JOIN sales_returns document ON document.id=quality.return_id AND NOT document.is_deleted
                    AND document.warehouse_id=quality.warehouse_id
                WHERE event.id=:id
                """, Map.of("id", id));
        if (rows.size() != 1 || rows.getFirst().get("out_item_id") == null) {
            throw conflict("退货质检缺少对应的真实单据和原发货明细");
        }
        Map<String, Object> row = rows.getFirst();
        return new Quality(id, (UUID) row.get("quality_id"), (UUID) row.get("return_id"),
                (UUID) row.get("out_item_id"), (String) row.get("action"),
                (BigDecimal) row.get("base_qty"), pool(row), time(row.get("occurred_at")),
                ((Number) row.get("status")).intValue());
    }

    private EventContext context(String kind, Quality event, UUID actor, int part) {
        UUID slice = UUID.nameUUIDFromBytes((event.id() + ":" + kind + ":" + part)
                .getBytes(StandardCharsets.UTF_8));
        return support.context(kind, event.id(), event.returnId(), slice, actor, event.occurredAt());
    }

    private boolean done(String kind, UUID event) { return !resultRoots(kind, event).isEmpty(); }

    private List<UUID> resultRoots(String kind, UUID event) {
        return db.queryForList("""
                SELECT result_node_id FROM stock_value_events
                WHERE source_doc_type=:kind AND source_event_id=:event
                  AND operation='POSITION_MOVE' ORDER BY source_item_id
                """, Map.of("kind", kind, "event", event), UUID.class);
    }

    private static void requireStatus(Quality event, int expected) {
        if (event.returnStatus() != expected) throw conflict("退货单状态与本次成本操作不一致");
    }

    private record Quality(UUID id, UUID qualityId, UUID returnId, UUID shipmentItemId,
            String action, BigDecimal qty, PoolKey pool, OffsetDateTime occurredAt, int returnStatus) {}
    private record SourceMovement(UUID id, UUID shipmentId, UUID shipmentItemId,
            PoolKey pool, OffsetDateTime occurredAt) {}
}
