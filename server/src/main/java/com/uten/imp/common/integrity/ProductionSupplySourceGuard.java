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

    @Transactional(propagation = Propagation.MANDATORY, readOnly = true)
    public boolean isPurchaseRequestLinked(UUID requestId) {
        return hasProtectedPeg(
                requestId,
                """
                SELECT COUNT(*)
                FROM purchase_request_items item
                JOIN production_material_supply_pegs peg
                  ON peg.supply_type = 'PURCHASE_REQUEST_ITEM'
                 AND peg.supply_item_id = item.id
                WHERE item.request_id = :headerId
                """);
    }

    @Transactional(propagation = Propagation.MANDATORY, readOnly = true)
    public boolean isPurchaseOrderLinked(UUID orderId) {
        return hasProtectedPeg(
                orderId,
                """
                SELECT COUNT(*)
                FROM purchase_order_items item
                JOIN production_material_supply_pegs peg
                  ON peg.supply_type = 'PURCHASE_ORDER_ITEM'
                 AND peg.supply_item_id = item.id
                WHERE item.order_id = :headerId
                """);
    }

    @Transactional(propagation = Propagation.MANDATORY, readOnly = true)
    public boolean isSubcontractApplicationLinked(UUID applicationId) {
        return hasProtectedPeg(
                applicationId,
                """
                SELECT COUNT(*)
                FROM subcontract_application_items item
                JOIN production_material_supply_pegs peg
                  ON peg.supply_type =
                        'SUBCONTRACT_APPLICATION_ITEM'
                 AND peg.supply_item_id = item.id
                WHERE item.application_id = :headerId
                """);
    }

    @Transactional(propagation = Propagation.MANDATORY, readOnly = true)
    public boolean isSubcontractOrderLinked(UUID orderId) {
        return hasProtectedPeg(
                orderId,
                """
                SELECT COUNT(*)
                FROM subcontract_order_items item
                JOIN production_material_supply_pegs peg
                  ON peg.supply_type = 'SUBCONTRACT_ORDER_ITEM'
                 AND peg.supply_item_id = item.id
                WHERE item.order_id = :headerId
                """);
    }

    @Transactional(propagation = Propagation.MANDATORY)
    public void requirePurchaseRequestMutable(UUID requestId) {
        requireNoProtectedPeg(
                requestId,
                """
                SELECT COUNT(*)
                FROM purchase_request_items item
                JOIN production_material_supply_pegs peg
                  ON peg.supply_type = 'PURCHASE_REQUEST_ITEM'
                 AND peg.supply_item_id = item.id
                WHERE item.request_id = :headerId
                """,
                "该采购申请已关联生产物料需求，"
                        + "请先在生产计划包中取消或红冲来源计划");
    }

    @Transactional(propagation = Propagation.MANDATORY)
    public void requireSubcontractApplicationMutable(UUID applicationId) {
        requireNoProtectedPeg(
                applicationId,
                """
                SELECT COUNT(*)
                FROM subcontract_application_items item
                JOIN production_material_supply_pegs peg
                  ON peg.supply_type =
                        'SUBCONTRACT_APPLICATION_ITEM'
                 AND peg.supply_item_id = item.id
                WHERE item.application_id = :headerId
                """,
                "该委外申请已关联生产物料需求，"
                        + "请先在生产计划包中取消或红冲来源计划");
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

    private void requireNoProtectedPeg(
            UUID headerId, String sql, String message) {
        if (hasProtectedPeg(headerId, sql)) {
            throw new ApiException(ErrorCode.CONFLICT, message);
        }
    }

    private boolean hasProtectedPeg(UUID headerId, String sql) {
        Number count = (Number) em.createNativeQuery(sql)
                .setParameter("headerId", headerId)
                .getSingleResult();
        return count.longValue() > 0;
    }
}
