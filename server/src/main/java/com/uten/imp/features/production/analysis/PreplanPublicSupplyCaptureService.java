package com.uten.imp.features.production.analysis;

import com.uten.imp.application.port.PreplanPublicSupplyCapturePort;
import com.uten.imp.common.util.NativeQueryResults;
import com.uten.imp.features.production.fulfillment.PlanningPackageFingerprint;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.util.ArrayList;
import java.util.List;
import java.util.Locale;
import java.util.Objects;
import java.util.UUID;

/** Captures finance-effective direct over-ordering without mutating old actions. */
@Service
@RequiredArgsConstructor
public class PreplanPublicSupplyCaptureService
        implements PreplanPublicSupplyCapturePort {

    private final EntityManager em;
    private final SecurityContextCurrentUser currentUser;
    private final TxSessionVars tx;

    @Override
    @Transactional(propagation = Propagation.MANDATORY)
    public void afterOrderApproved(String orderType, UUID orderId) {
        reconcile(orderType, orderId, "APPROVED");
    }

    @Override
    @Transactional(propagation = Propagation.MANDATORY)
    public void afterOrderReversed(String orderType, UUID orderId) {
        reconcile(orderType, orderId, "REVERSED");
    }

    private void reconcile(String rawType, UUID orderId, String transition) {
        tx.bind();
        String type = normalize(rawType);
        if (orderId == null) return;
        List<Candidate> candidates = candidates(type, orderId);
        if (candidates.isEmpty()) return;
        List<UUID> actionIds = candidates.stream().map(Candidate::actionId)
                .distinct().sorted().toList();
        em.createNativeQuery("""
                SELECT id FROM preplan_supply_actions
                WHERE id IN (:ids) ORDER BY id FOR UPDATE
                """).setParameter("ids", actionIds).getResultList();

        UUID actorId = currentUser.requireId();
        for (Candidate candidate : candidates) {
            BigDecimal approvedOverage = decimal(em.createNativeQuery("""
                    SELECT fn_preplan_direct_overorder_capacity(
                        :actionId,:externalItemId)
                    """).setParameter("actionId", candidate.actionId())
                    .setParameter("externalItemId", candidate.externalItemId())
                    .getSingleResult());
            // V472 may already represent the same demand-item overage in the
            // immutable action columns. Runtime events only become authoritative
            // when the approved overage exceeds that frozen representation.
            BigDecimal targetRuntime = "DEMAND".equals(candidate.anchorKind())
                    && candidate.declaredSameItemQty().compareTo(approvedOverage) >= 0
                    ? BigDecimal.ZERO : approvedOverage;
            BigDecimal current = decimal(em.createNativeQuery("""
                    SELECT fn_preplan_runtime_public_supply_balance(
                        :actionId,:externalItemId)
                    """).setParameter("actionId", candidate.actionId())
                    .setParameter("externalItemId", candidate.externalItemId())
                    .getSingleResult());
            int comparison = targetRuntime.compareTo(current);
            if (comparison == 0) continue;
            String eventType = comparison > 0 ? "GRANT" : "REVERSE";
            BigDecimal quantity = targetRuntime.subtract(current).abs();
            UUID eventOrderId = "GRANT".equals(eventType)
                    && "REVERSED".equals(transition)
                    ? approvedSourceOrderId(type, candidate.externalItemId())
                    : orderId;
            if (eventOrderId == null) {
                throw new IllegalStateException(
                        "runtime public supply grant lacks an approved source order");
            }
            String key = "PREPLAN-PUBLIC-SUPPLY:"
                    + PlanningPackageFingerprint.sha256(List.of(
                    type, orderId.toString(), eventOrderId.toString(),
                    candidate.actionId().toString(),
                    candidate.externalItemId().toString(), candidate.anchorKind(),
                    transition, eventType));
            em.createNativeQuery("""
                    INSERT INTO preplan_public_supply_events(
                        id,source_action_id,source_external_item_id,
                        trigger_order_type,trigger_order_id,event_type,qty,
                        warehouse_id,goods_id,color_id,unit_id,route,
                        idempotency_key,created_by)
                    SELECT gen_random_uuid(),action.id,:externalItemId,
                           :orderType,:orderId,:eventType,:qty,
                           action.warehouse_id,action.goods_id,action.color_id,
                           action.unit_id,action.route,:key,:actorId
                    FROM preplan_supply_actions action
                    WHERE action.id=:actionId
                    ON CONFLICT (idempotency_key) DO NOTHING
                    """).setParameter("externalItemId", candidate.externalItemId())
                    .setParameter("orderType", type)
                    .setParameter("orderId", eventOrderId)
                    .setParameter("eventType", eventType)
                    .setParameter("qty", quantity)
                    .setParameter("key", key)
                    .setParameter("actorId", actorId)
                    .setParameter("actionId", candidate.actionId())
                    .executeUpdate();
        }
    }

    private List<Candidate> candidates(String type, UUID orderId) {
        boolean purchase = PURCHASE.equals(type);
        String orderItems = purchase ? "purchase_order_items" : "subcontract_order_items";
        String sources = purchase
                ? "purchase_order_item_sources" : "subcontract_order_item_sources";
        String external = purchase ? "request_item_id" : "application_item_id";
        String route = purchase ? "BUY" : "SUBCONTRACT";
        List<Object[]> rows = NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                WITH anchor AS (
                    SELECT action.id AS action_id,allocation.external_item_id,
                           'DEMAND'::text AS anchor_kind
                    FROM preplan_supply_actions action
                    JOIN preplan_supply_action_allocations allocation
                      ON allocation.action_id=action.id
                     AND allocation.external_item_id IS NOT NULL
                    UNION ALL
                    SELECT action.id,action.public_surplus_external_item_id,'PUBLIC'
                    FROM preplan_supply_actions action
                    WHERE action.public_surplus_external_item_id IS NOT NULL
                      AND NOT EXISTS (
                          SELECT 1 FROM preplan_supply_action_allocations allocation
                          WHERE allocation.action_id=action.id
                            AND allocation.external_item_id=
                                action.public_surplus_external_item_id)
                    UNION ALL
                    SELECT action.id,action.safety_external_item_id,'SAFETY'
                    FROM preplan_supply_actions action
                    WHERE action.safety_external_item_id IS NOT NULL
                      AND action.safety_external_item_id IS DISTINCT FROM
                          action.public_surplus_external_item_id
                      AND NOT EXISTS (
                          SELECT 1 FROM preplan_supply_action_allocations allocation
                          WHERE allocation.action_id=action.id
                            AND allocation.external_item_id=
                                action.safety_external_item_id)
                )
                SELECT DISTINCT action.id,anchor.external_item_id,
                       anchor.anchor_kind,
                       CASE WHEN anchor.anchor_kind='DEMAND'
                                  AND action.public_surplus_external_item_id
                                      =anchor.external_item_id
                            THEN action.public_surplus_qty ELSE 0 END
                FROM %2$s item
                JOIN %3$s source ON source.order_item_id=item.id
                JOIN anchor ON anchor.external_item_id=source.%1$s
                JOIN preplan_supply_actions action
                  ON action.id=anchor.action_id
                 AND action.operation_type='SUPPLY'
                 AND action.route=:route
                 AND action.status <> 'CANCELLED'
                WHERE item.order_id=:orderId AND item.is_deleted=FALSE
                  AND (%4$s)
                ORDER BY action.id,anchor.external_item_id,anchor.anchor_kind
                """.formatted(
                external,
                orderItems,
                sources,
                purchase
                        ? "TRUE"
                        : "NOT EXISTS (SELECT 1 FROM goods_bom_items bom "
                                + "WHERE bom.goods_id=action.goods_id "
                                + "AND bom.is_deleted=FALSE)"))
                .setParameter("route", route)
                .setParameter("orderId", orderId));
        List<Candidate> result = new ArrayList<>(rows.size());
        for (Object[] row : rows) {
            result.add(new Candidate(
                    uuid(row[0]),uuid(row[1]),Objects.toString(row[2]),
                    decimal(row[3])));
        }
        return List.copyOf(result);
    }

    private UUID approvedSourceOrderId(String type, UUID externalItemId) {
        boolean purchase = PURCHASE.equals(type);
        String orderItems = purchase ? "purchase_order_items" : "subcontract_order_items";
        String orders = purchase ? "purchase_orders" : "subcontract_orders";
        String sources = purchase
                ? "purchase_order_item_sources" : "subcontract_order_item_sources";
        String external = purchase ? "request_item_id" : "application_item_id";
        List<UUID> ids = NativeQueryResults.typedRows(em.createNativeQuery("""
                SELECT header.id
                FROM %1$s header
                JOIN %2$s item ON item.order_id=header.id
                 AND item.is_deleted=FALSE
                JOIN %3$s source ON source.order_item_id=item.id
                 AND source.%4$s=:externalItemId
                WHERE header.status=1 AND header.is_deleted=FALSE
                ORDER BY header.bill_date,header.id,item.id,source.line_no
                LIMIT 1
                """.formatted(orders, orderItems, sources, external))
                .setParameter("externalItemId", externalItemId), UUID.class);
        return ids.isEmpty() ? null : ids.getFirst();
    }

    private static String normalize(String value) {
        String type = Objects.toString(value, "").strip().toUpperCase(Locale.ROOT);
        if (!List.of(PURCHASE, SUBCONTRACT).contains(type)) {
            throw new IllegalArgumentException("unsupported procurement order type");
        }
        return type;
    }

    private static UUID uuid(Object value) {
        return value instanceof UUID id ? id : UUID.fromString(value.toString());
    }

    private static BigDecimal decimal(Object value) {
        return value == null ? BigDecimal.ZERO : new BigDecimal(value.toString());
    }

    private record Candidate(
            UUID actionId, UUID externalItemId, String anchorKind,
            BigDecimal declaredSameItemQty) {
    }
}
