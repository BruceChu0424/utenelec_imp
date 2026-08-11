package com.uten.imp.common.integrity;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import java.util.UUID;

/**
 * Friendly service-layer counterpart to V162's database backstop.
 *
 * <p>Only generic document CRUD calls this guard. The planning-package
 * lifecycle uses its dedicated adapter so it can release every supply peg and
 * close the generated document in one transaction.
 */
@Component
@RequiredArgsConstructor
public class ProductionSupplySourceGuard {

    private final EntityManager em;

    /*
     * A pre-plan action owns the downstream document from the moment that
     * document is generated.  Keep the action branch deliberately free of
     * status/is_deleted predicates: cancelled source history is still
     * production-owned history and generic CRUD must not rewrite it.
     */
    private static final String PURCHASE_REQUEST_SOURCE_SQL = """
            SELECT COUNT(*)
            FROM (
                SELECT peg.id AS source_id
                FROM purchase_request_items item
                JOIN production_material_supply_pegs peg
                  ON peg.supply_type = 'PURCHASE_REQUEST_ITEM'
                 AND peg.supply_item_id = item.id
                WHERE item.request_id = :headerId
                UNION ALL
                SELECT action.id AS source_id
                FROM preplan_supply_actions action
                WHERE action.external_document_type = 'PURCHASE_REQUEST'
                  AND action.external_document_id = :headerId
            ) protected_source
            """;

    private static final String PURCHASE_ORDER_SOURCE_SQL = """
            SELECT COUNT(*)
            FROM (
                SELECT peg.id AS source_id
                FROM purchase_order_items item
                JOIN production_material_supply_pegs peg
                  ON peg.supply_type = 'PURCHASE_ORDER_ITEM'
                 AND peg.supply_item_id = item.id
                WHERE item.order_id = :headerId
                UNION ALL
                SELECT action.id AS source_id
                FROM purchase_order_items order_item
                JOIN purchase_request_items request_item
                  ON request_item.id = order_item.request_item_id
                JOIN preplan_supply_actions action
                  ON action.external_document_type = 'PURCHASE_REQUEST'
                 AND action.external_document_id = request_item.request_id
                WHERE order_item.order_id = :headerId
            ) protected_source
            """;

    private static final String SUBCONTRACT_APPLICATION_SOURCE_SQL = """
            SELECT COUNT(*)
            FROM (
                SELECT peg.id AS source_id
                FROM subcontract_application_items item
                JOIN production_material_supply_pegs peg
                  ON peg.supply_type = 'SUBCONTRACT_APPLICATION_ITEM'
                 AND peg.supply_item_id = item.id
                WHERE item.application_id = :headerId
                UNION ALL
                SELECT action.id AS source_id
                FROM preplan_supply_actions action
                WHERE action.external_document_type = 'SUBCONTRACT_APPLICATION'
                  AND action.external_document_id = :headerId
            ) protected_source
            """;

    private static final String SUBCONTRACT_ORDER_SOURCE_SQL = """
            SELECT COUNT(*)
            FROM (
                SELECT peg.id AS source_id
                FROM subcontract_order_items item
                JOIN production_material_supply_pegs peg
                  ON peg.supply_type = 'SUBCONTRACT_ORDER_ITEM'
                 AND peg.supply_item_id = item.id
                WHERE item.order_id = :headerId
                UNION ALL
                SELECT action.id AS source_id
                FROM subcontract_order_items order_item
                JOIN subcontract_application_items application_item
                  ON application_item.id = order_item.application_item_id
                JOIN preplan_supply_actions action
                  ON action.external_document_type = 'SUBCONTRACT_APPLICATION'
                 AND action.external_document_id = application_item.application_id
                WHERE order_item.order_id = :headerId
            ) protected_source
            """;

    @Transactional(propagation = Propagation.MANDATORY, readOnly = true)
    public boolean isPurchaseRequestLinked(UUID requestId) {
        return hasProtectedSource(requestId, PURCHASE_REQUEST_SOURCE_SQL);
    }

    @Transactional(propagation = Propagation.MANDATORY, readOnly = true)
    public boolean isPurchaseOrderLinked(UUID orderId) {
        return hasProtectedSource(orderId, PURCHASE_ORDER_SOURCE_SQL);
    }

    @Transactional(propagation = Propagation.MANDATORY, readOnly = true)
    public boolean isSubcontractApplicationLinked(UUID applicationId) {
        return hasProtectedSource(
                applicationId, SUBCONTRACT_APPLICATION_SOURCE_SQL);
    }

    @Transactional(propagation = Propagation.MANDATORY, readOnly = true)
    public boolean isSubcontractOrderLinked(UUID orderId) {
        return hasProtectedSource(orderId, SUBCONTRACT_ORDER_SOURCE_SQL);
    }

    @Transactional(propagation = Propagation.MANDATORY)
    public void requirePurchaseRequestMutable(UUID requestId) {
        requireNoProtectedSource(
                requestId, PURCHASE_REQUEST_SOURCE_SQL,
                "该采购申请已关联生产物料需求，"
                        + "请从物料分析/生产计划专用流程取消或红冲来源需求");
    }

    @Transactional(propagation = Propagation.MANDATORY)
    public void requireSubcontractApplicationMutable(UUID applicationId) {
        requireNoProtectedSource(
                applicationId, SUBCONTRACT_APPLICATION_SOURCE_SQL,
                "该委外申请已关联生产物料需求，"
                        + "请从物料分析/生产计划专用流程取消或红冲来源需求");
    }

    @Transactional(propagation = Propagation.MANDATORY)
    public void requirePurchaseOrderMutable(UUID orderId) {
        if (isPurchaseOrderLinked(orderId)) {
            throw new ApiException(ErrorCode.CONFLICT,
                    "该采购订单承接生产物料需求，请从生产计划专用流程调整");
        }
    }

    @Transactional(propagation = Propagation.MANDATORY)
    public void requireSubcontractOrderMutable(UUID orderId) {
        if (isSubcontractOrderLinked(orderId)) {
            throw new ApiException(ErrorCode.CONFLICT,
                    "该委外订单承接生产物料需求，请从生产计划专用流程调整");
        }
    }

    private void requireNoProtectedSource(
            UUID headerId, String sql, String message) {
        if (hasProtectedSource(headerId, sql)) {
            throw new ApiException(ErrorCode.CONFLICT, message);
        }
    }

    private boolean hasProtectedSource(UUID headerId, String sql) {
        Number count = (Number) em.createNativeQuery(sql)
                .setParameter("headerId", headerId)
                .getSingleResult();
        return count.longValue() > 0;
    }
}
