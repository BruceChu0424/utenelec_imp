package com.uten.imp.common.finance;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import jakarta.persistence.EntityManager;
import java.math.BigDecimal;
import java.math.RoundingMode;
import java.util.UUID;
import java.util.Collection;

/** Physical receipt bounds shared by approved purchase/subcontract quantity revisions.
 * Callers hold the order header before reading these facts and keep it through the revision.
 * Expectation OPEN/CLOSED is presentation state, never authority for physical quantities.
 */
public final class ProcurementOrderQuantityBounds {
    private ProcurementOrderQuantityBounds() {}

    /**
     * @param allowedOverReceiptPct purchase line over-receipt allowance (ADR-144); always null for
     *                              subcontract lines, null means 0.
     */
    public record ReceiptBound(BigDecimal retainedBase, BigDecimal postedExcessBase,
                               BigDecimal allowedOverReceiptPct,BigDecimal adoptedRetainedBase) {
        public ReceiptBound(BigDecimal retainedBase,BigDecimal postedExcessBase,BigDecimal allowedOverReceiptPct){this(retainedBase,postedExcessBase,allowedOverReceiptPct,retainedBase);}
        /** Actual retained source in order units; distinct from the conservative edit bound. */
        public BigDecimal retainedOrderedQty(BigDecimal orderUnitRate) {
            return coveringQuantity(requireAdoptedBase(),orderUnitRate,"procurement.order.retained-quantity","订单已实收保留数量");
        }
        public BigDecimal requireAdoptedBase(){if(adoptedRetainedBase==null)throw new ApiException(ErrorCode.CONFLICT,"实收或实退尚缺已采用的冻结数量证据，不能按原输入乘积推定实际剩余量");return adoptedRetainedBase;}
        /** Smallest order qty N (order units) with N + T(N, p) covering the retained receipts. */
        public BigDecimal minimumOrderedQty(BigDecimal orderUnitRate) {
            return PurchaseOverReceiptTolerance.minimumOrderedQty(
                    retainedBase.subtract(postedExcessBase).max(BigDecimal.ZERO)
                            .divide(orderUnitRate,4,RoundingMode.CEILING),
                    allowedOverReceiptPct);
        }
        /** Subcontract normal finished allowance uses its own floor ceiling, not purchase tolerance rounding. */
        public BigDecimal minimumSubcontractTargetQty(BigDecimal orderUnitRate,BigDecimal allowedLossPct) {
            return SubcontractReceiptAllowance.minimumTargetForRetainedBase(
                    retainedBase.subtract(postedExcessBase).max(BigDecimal.ZERO),orderUnitRate,allowedLossPct);
        }
    }

    public static ReceiptBound receipts(EntityManager em, String orderType, UUID itemId) {
        String prefix=prefix(orderType);
        requireKnownReceiptBasis(em,orderType,java.util.List.of(itemId));
        Object[] row=(Object[])em.createNativeQuery("""
                SELECT GREATEST(COALESCE(oi.received_qty,0)*oi.unit_rate,
                           COALESCE(facts.received_base,0)),
                       GREATEST(COALESCE(oi.returned_qty,0)*oi.unit_rate,
                           COALESCE(facts.returned_base,0)),
                       COALESCE(facts.iqc_returned_base,0), COALESCE(facts.excess_base,0),
                       %2$s
                FROM %1$s_order_items oi
                LEFT JOIN LATERAL (
                    SELECT SUM(ri.qty*ri.unit_rate) AS received_base,
                           SUM(COALESCE(returns.qty_base,0)) AS returned_base,
                           SUM(COALESCE(iqc.qty_base,0)) AS iqc_returned_base,
                           SUM(LEAST(COALESCE(excess.qty_base,0), GREATEST(
                               ri.qty*ri.unit_rate-COALESCE(returns.qty_base,0)
                                   -COALESCE(iqc.qty_base,0),0))) AS excess_base
                    FROM %1$s_receipt_items ri
                    JOIN %1$s_receipts receipt ON receipt.id=ri.receipt_id
                      AND receipt.status=1 AND receipt.is_deleted=FALSE
                    LEFT JOIN LATERAL (
                        SELECT SUM(ret.qty*ret.unit_rate) AS qty_base
                        FROM %1$s_return_items ret JOIN %1$s_returns rh ON rh.id=ret.return_id
                        WHERE ret.receipt_item_id=ri.id AND ret.order_item_id=oi.id
                          AND ret.is_deleted=FALSE AND rh.status=1 AND rh.is_deleted=FALSE
                    ) returns ON TRUE
                    LEFT JOIN LATERAL (
                        SELECT SUM(rejection.failed_base_qty) AS qty_base
                        FROM procurement_iqc_rejection_cases rejection
                        WHERE rejection.receipt_type=:orderType AND rejection.receipt_id=receipt.id
                          AND rejection.receipt_item_id=ri.id AND rejection.order_item_id=oi.id
                          AND rejection.is_deleted=FALSE AND rejection.return_recorded_at IS NOT NULL
                          AND NOT EXISTS(SELECT 1 FROM procurement_inspection_items gift WHERE gift.id=rejection.inspection_item_id AND gift.quantity_tranche='GIFT')
                          AND rejection.status IN ('RETURN_RECORDED','CREDIT_CONFIRMED',
                              'CLOSED_NO_CREDIT','FINANCE_EXCEPTION')
                    ) iqc ON TRUE
                    LEFT JOIN LATERAL (
                        SELECT SUM(exception.approved_excess_qty*ri.unit_rate) AS qty_base
                        FROM procurement_arrival_exceptions exception
                        WHERE exception.order_type=:orderType AND exception.order_item_id=oi.id
                          AND exception.receipt_id=receipt.id AND exception.receipt_item_id=ri.id
                          AND exception.status IN ('RECEIPT_POSTED','CLOSED')
                    ) excess ON TRUE
                    WHERE ri.order_item_id=oi.id AND ri.is_deleted=FALSE
                ) facts ON TRUE
                WHERE oi.id=:itemId AND oi.is_deleted=FALSE
                """.formatted(prefix,"PURCHASE".equals(orderType)
                        ? "oi.allowed_over_receipt_pct" : "CAST(NULL AS numeric)"))
                .setParameter("orderType",orderType)
                .setParameter("itemId",itemId).getSingleResult();
        // Imported aggregate-only history remains a conservative lower bound; do not silently
        // discard recorded receipts because a legacy detail is unavailable. Replacement receipts
        // are already in received_base. Their allocation ledger must not be subtracted a second time.
        BigDecimal retained=decimal(row[0]).subtract(decimal(row[1])).subtract(decimal(row[2])).max(BigDecimal.ZERO);
        return new ReceiptBound(retained,decimal(row[3]).min(retained),(BigDecimal)row[4],adoptedRetainedBase(em,orderType,itemId));
    }

    /** Current actual quantity comes from frozen charged tranches/inspection
     * facts and recorded physical returns. The separate legacy/aggregate bound
     * above remains conservative for order-edit validation. */
    private static BigDecimal adoptedRetainedBase(EntityManager em,String orderType,UUID itemId){
        String prefix=prefix(orderType),family=orderType+"_RETURN";
        String received="PURCHASE".equals(orderType)?"CASE WHEN ri.quantity_semantics='CHARGED_PLUS_GIFT_V1' THEN ri.charged_base_qty ELSE inspection.received END":"inspection.received";
        String returned="PURCHASE".equals(orderType)?"CASE WHEN ret.quantity_semantics='CHARGED_PLUS_GIFT_V1' THEN ret.charged_base_qty ELSE movement.returned END":"movement.returned";
        Object[] actual=(Object[])em.createNativeQuery("""
                WITH received AS (
                  SELECT ri.id,CASE WHEN ri.qty=0 THEN 0 ELSE %2$s END base
                  FROM %1$s_receipt_items ri JOIN %1$s_receipts header ON header.id=ri.receipt_id
                  LEFT JOIN LATERAL (SELECT SUM(i.received_base_qty) received FROM procurement_inspection_items i
                    WHERE i.receipt_type=:orderType AND i.receipt_id=header.id AND i.receipt_item_id=ri.id
                      AND i.quantity_tranche<>'GIFT' AND i.status<>'REVERSED') inspection ON TRUE
                  WHERE ri.order_item_id=:itemId AND NOT ri.is_deleted AND header.status=1 AND NOT header.is_deleted
                ), returned AS (
                  SELECT ret.id,CASE WHEN ret.qty=0 THEN 0 ELSE %3$s END base
                  FROM %1$s_return_items ret JOIN %1$s_returns header ON header.id=ret.return_id
                  LEFT JOIN LATERAL (SELECT CASE WHEN count(*)>0 THEN -SUM(m.qty*m.direction) END returned
                    FROM stock_movements m WHERE m.source_doc_type=:family AND m.source_doc_id=header.id
                      AND m.source_item_id=ret.id AND m.movement_type IN(2,18)) movement ON TRUE
                  WHERE ret.order_item_id=:itemId AND NOT ret.is_deleted AND header.status=1 AND NOT header.is_deleted
                ), iqc AS (
                  SELECT COALESCE(SUM(rejection.failed_base_qty),0) returned
                  FROM procurement_iqc_rejection_cases rejection
                  JOIN procurement_inspection_items inspection ON inspection.id=rejection.inspection_item_id
                  WHERE rejection.receipt_type=:orderType AND rejection.order_item_id=:itemId
                    AND NOT rejection.is_deleted AND rejection.return_recorded_at IS NOT NULL
                    AND inspection.quantity_tranche<>'GIFT'
                    AND rejection.status IN('RETURN_RECORDED','CREDIT_CONFIRMED','CLOSED_NO_CREDIT','FINANCE_EXCEPTION')
                )
                SELECT (SELECT COALESCE(SUM(base),0) FROM received),(SELECT COALESCE(SUM(base),0) FROM returned),iqc.returned,
                   (SELECT count(*) FROM received WHERE base IS NULL)+(SELECT count(*) FROM returned WHERE base IS NULL),
                   (SELECT count(*) FROM received),(SELECT count(*) FROM returned),oi.received_qty,oi.returned_qty
                FROM %1$s_order_items oi CROSS JOIN iqc WHERE oi.id=:itemId
                """.formatted(prefix,received,returned)).setParameter("orderType",orderType).setParameter("itemId",itemId).setParameter("family",family).getSingleResult();
        if(((Number)actual[3]).longValue()>0||((Number)actual[4]).longValue()==0&&decimal(actual[6]).signum()>0
                ||((Number)actual[5]).longValue()==0&&decimal(actual[7]).signum()>0)return null;
        BigDecimal value=decimal(actual[0]).subtract(decimal(actual[1])).subtract(decimal(actual[2]));
        return value.signum()<0?null:value;
    }

    /** Never turn a missing historical order/receipt/return conversion into a one-to-one quantity. */
    public static void requireKnownReceiptBasis(EntityManager em,String orderType,Collection<UUID> orderItemIds) {
        if(orderItemIds.isEmpty())return;
        String prefix=prefix(orderType);
        var unknown=em.createNativeQuery("""
                SELECT source_id FROM (
                    SELECT item.id AS source_id FROM %1$s_order_items item
                    WHERE item.id IN(:ids) AND item.is_deleted=FALSE
                      AND (item.unit_id IS NULL OR item.unit_rate IS NULL OR item.unit_rate<=0)
                    UNION ALL
                    SELECT item.id FROM %1$s_receipt_items item
                    JOIN %1$s_receipts header ON header.id=item.receipt_id
                    WHERE item.order_item_id IN(:ids) AND item.is_deleted=FALSE
                      AND header.status=1 AND header.is_deleted=FALSE AND item.qty<>0
                      AND (item.unit_id IS NULL OR item.unit_rate IS NULL OR item.unit_rate<=0)
                    UNION ALL
                    SELECT item.id FROM %1$s_return_items item
                    JOIN %1$s_returns header ON header.id=item.return_id
                    WHERE item.order_item_id IN(:ids) AND item.is_deleted=FALSE
                      AND header.status=1 AND header.is_deleted=FALSE AND item.qty<>0
                      AND (item.unit_id IS NULL OR item.unit_rate IS NULL OR item.unit_rate<=0)
                ) unknown_basis LIMIT 1
                """.formatted(prefix)).setParameter("ids",orderItemIds).getResultList();
        if(!unknown.isEmpty())throw new ApiException(ErrorCode.CONFLICT,
                "来源订单或已生效收退货的单位/换算率尚未核验，不能默认按1换算、忽略旧数量或继续累计，请先核对原始计量依据");
    }

    /** Set the active expectation from current order capacity, including CLOSED rows on increase. */
    public static void synchronizeExpectation(EntityManager em, String orderType, UUID itemId,
                                              BigDecimal orderedQty, BigDecimal orderUnitRate,
                                              ReceiptBound bound) {
        String prefix=prefix(orderType);
        @SuppressWarnings("unchecked")
        java.util.List<Object[]> rows=em.createNativeQuery("""
                SELECT item.id,item.unit_rate,COALESCE(oi.arrival_overage_posted_qty,0)*oi.unit_rate,
                    COALESCE(to_jsonb(oi)->>'charged_base_qty',to_jsonb(oi)->>'adopted_base_qty'),oi.qty,oi.unit_rate
                FROM inbound_expectation_items item JOIN inbound_expectations header ON item.expectation_id=header.id
                JOIN %s_order_items oi ON oi.id=item.order_item_id
                WHERE header.order_type=:orderType
                  AND header.status IN ('OPEN','CLOSED') AND item.order_item_id=:itemId AND oi.id=item.order_item_id
                ORDER BY item.id FOR UPDATE OF item
                """.formatted(prefix)).setParameter("orderType",orderType).setParameter("itemId",itemId).getResultList();
        var selected=new java.util.ArrayList<Object[]>();
        for(Object[] row:rows){
            BigDecimal rate=(BigDecimal)row[1];
            if(row[3]!=null&&(orderedQty.compareTo((BigDecimal)row[4])!=0||orderUnitRate.compareTo((BigDecimal)row[5])!=0))
                throw new ApiException(ErrorCode.CONFLICT,"入库预期的订货数量与原已保存采用不一致，请刷新来源");
            BigDecimal orderBase=row[3]==null?orderedQty.multiply(orderUnitRate):new BigDecimal(row[3].toString());
            BigDecimal orderedBase=orderBase.add(decimal(row[2]));
            BigDecimal ordered=coveringQuantity(orderedBase,rate,"procurement.expectation.ordered-quantity","入库预期订货数量");
            BigDecimal acceptedBase=bound.requireAdoptedBase().min(orderedBase);
            BigDecimal accepted=coveringQuantity(acceptedBase,rate,"procurement.expectation.accepted-quantity","入库预期已实收数量");
            if(accepted.compareTo(ordered)>0)throw rejected("procurement.expectation.accepted-quantity","入库预期已实收数量",acceptedBase,rate);
            selected.add(new Object[]{row[0],ordered,accepted});
        }
        // Resolve every selected projection before writing any expectation row.
        for(Object[] row:selected){
            int changed=em.createNativeQuery("UPDATE inbound_expectation_items SET ordered_qty=:ordered,accepted_qty=:accepted,updated_at=now() WHERE id=:id")
                    .setParameter("ordered",row[1]).setParameter("accepted",row[2]).setParameter("id",row[0]).executeUpdate();
            if(changed!=1)throw new ApiException(ErrorCode.CONFLICT,"入库预期来源已变化，请重新核对数量");
        }
        em.createNativeQuery("""
                UPDATE inbound_expectations header
                SET status=CASE WHEN EXISTS(SELECT 1 FROM inbound_expectation_items item
                    WHERE item.expectation_id=header.id AND %s)
                    THEN 'OPEN' ELSE 'CLOSED' END,updated_at=now()
                WHERE header.order_type=:orderType AND header.status IN ('OPEN','CLOSED')
                  AND EXISTS(SELECT 1 FROM inbound_expectation_items item
                      WHERE item.expectation_id=header.id AND item.order_item_id=:itemId)
                """.formatted("SUBCONTRACT".equals(orderType)
                        ? SubcontractLossSettlementSql.expectationRemainingQty("item", "header.order_type") + " > 0"
                        : "item.accepted_qty<item.ordered_qty"))
                .setParameter("orderType",orderType).setParameter("itemId",itemId).executeUpdate();
    }

    private static String prefix(String orderType) {
        return switch(orderType) {
            case "PURCHASE" -> "purchase";
            case "SUBCONTRACT" -> "subcontract";
            default -> throw new ApiException(ErrorCode.VALIDATION_FAILED,"未知采购订单类型");
        };
    }
    private static BigDecimal coveringQuantity(BigDecimal base,BigDecimal rate,String key,String label){
        if(base==null||base.signum()<0||rate==null||rate.signum()<=0)throw new ApiException(ErrorCode.CONFLICT,label+"的真实数量或换算率尚未核对");
        BigDecimal result=BusinessPrecisionContext.divide(base,rate,key,label,24);
        if(result.multiply(rate).compareTo(base)<0)throw rejected(key,label,base,rate);
        return result;
    }
    private static BusinessPrecisionRequiredException rejected(String key,String label,BigDecimal base,BigDecimal rate){
        String reason;try{base.divide(rate);reason="PRECISION_LIMIT";}catch(ArithmeticException nonTerminating){reason="NON_TERMINATING";}
        return new BusinessPrecisionRequiredException(key,label+"：本次选择不足以保留原实收来源，请明确重新选择",24,reason,true);
    }
    private static BigDecimal decimal(Object value) { return value==null ? BigDecimal.ZERO : (BigDecimal)value; }
}
