package com.uten.imp.common.finance;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import jakarta.persistence.EntityManager;

import java.util.Collection;
import java.util.Objects;
import java.util.UUID;

/** Finance reviewed the final receipt basis; later quantity corrections need a separate reviewed process. */
public final class ProcurementTerminatedReceiptBasis {
    public static final String MESSAGE="该订单已按当前实收量取消剩余数量并结束，不能直接新增退货或红冲原收退货；请先联系财务核对后续处置。";
    public static final String SETTLED_LOSS_MESSAGE="该损耗已计入订单结束时核定的履约数量，不能直接红冲；请联系财务核对后续处置。";
    private ProcurementTerminatedReceiptBasis() {}

    public static void requireMutable(EntityManager em,String type,Collection<UUID> orderItemIds) {
        var ids=orderItemIds.stream().filter(Objects::nonNull).distinct().toList();
        if(ids.isEmpty()) return;
        String prefix=switch(type) {case "PURCHASE"->"purchase";case "SUBCONTRACT"->"subcontract";default->throw new IllegalArgumentException("Unknown procurement type");};
        boolean terminated=Boolean.TRUE.equals(em.createNativeQuery("SELECT EXISTS(SELECT 1 FROM "+prefix
                +"_order_items i JOIN "+prefix+"_orders h ON h.id=i.order_id WHERE i.id IN (:ids) AND h.termination_case_id IS NOT NULL)")
                .setParameter("ids",ids).getSingleResult());
        if(terminated) throw new ApiException(ErrorCode.CONFLICT,MESSAGE);
    }

    public static void requireReceiptItemsMutable(EntityManager em,String type,Collection<UUID> receiptItemIds) {
        var ids=receiptItemIds.stream().filter(Objects::nonNull).distinct().toList();
        if(ids.isEmpty()) return;
        String prefix=switch(type) {case "PURCHASE"->"purchase";case "SUBCONTRACT"->"subcontract";default->throw new IllegalArgumentException("Unknown procurement type");};
        boolean terminated=Boolean.TRUE.equals(em.createNativeQuery("SELECT EXISTS(SELECT 1 FROM "+prefix
                +"_receipt_items r JOIN "+prefix+"_order_items i ON i.id=r.order_item_id JOIN "+prefix
                +"_orders h ON h.id=i.order_id WHERE r.id IN (:ids) AND h.termination_case_id IS NOT NULL)")
                .setParameter("ids",ids).getSingleResult());
        if(terminated) throw new ApiException(ErrorCode.CONFLICT,MESSAGE);
    }

    /** Independent component losses remain reversible; only accepted finished-order settlement is final. */
    public static void requireSettledLossMutable(EntityManager em,UUID wasteId) {
        if(wasteId==null) return;
        boolean finalBasis=Boolean.TRUE.equals(em.createNativeQuery("""
                SELECT EXISTS(SELECT 1 FROM subcontract_short_delivery_cases loss
                    JOIN subcontract_orders orders ON orders.id=loss.order_id
                    WHERE loss.waste_id=:wasteId AND loss.status='ACCEPTED_LOSS' AND loss.decision='ACCEPT_LOSS'
                      AND loss.closed_at IS NOT NULL AND loss.loss_qty>0 AND loss.qty_change_log_id IS NULL
                      AND orders.termination_case_id IS NOT NULL)
                """).setParameter("wasteId",wasteId).getSingleResult());
        if(finalBasis) throw new ApiException(ErrorCode.CONFLICT,SETTLED_LOSS_MESSAGE);
    }
}
