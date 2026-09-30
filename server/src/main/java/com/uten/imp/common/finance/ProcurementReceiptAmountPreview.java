package com.uten.imp.common.finance;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import java.math.BigDecimal;
import java.util.List;
import java.util.Map;
import java.util.HashMap;
import java.util.UUID;

/** Read-only draft projection of the same source consideration used at posting. */
@Service
@RequiredArgsConstructor
public class ProcurementReceiptAmountPreview {
    private final EntityManager em;
    private final ProcurementIqcReplacementAllocationService replacementAllocation;

    public MoneyPolicy.LineAmounts line(String kind, UUID orderItemId, UUID receiptId,
            BigDecimal qty, BigDecimal price, BigDecimal rate) {
        return line(kind, orderItemId, receiptId, qty, price, rate, new HashMap<>());
    }

    /** One draft can contain several rows for the same source; they share a cumulative remainder. */
    public Draft draft(String kind, UUID receiptId) { return new Draft(kind, receiptId); }

    public final class Draft {
        private final String kind;
        private final UUID receiptId;
        private final Map<UUID, Pending> pending = new HashMap<>();
        private Draft(String kind, UUID receiptId) { this.kind = kind; this.receiptId = receiptId; }
        public MoneyPolicy.LineAmounts line(UUID orderItemId, BigDecimal qty, BigDecimal price, BigDecimal rate) {
            return ProcurementReceiptAmountPreview.this.line(kind, orderItemId, receiptId, qty, price, rate, pending);
        }
    }

    private record Pending(BigDecimal qty, BigDecimal original, BigDecimal local, boolean unresolved) { }

    private MoneyPolicy.LineAmounts line(String kind, UUID orderItemId, UUID receiptId,
            BigDecimal qty, BigDecimal price, BigDecimal rate, Map<UUID, Pending> pending) {
        String prefix = switch (kind) {
            case "PURCHASE" -> "purchase";
            case "SUBCONTRACT" -> "subcontract";
            default -> throw new IllegalArgumentException("Unknown receipt kind");
        };
        if (orderItemId == null) return MoneyPolicy.line(qty, price, null, rate);
        @SuppressWarnings("unchecked")
        List<Object[]> sources = em.createNativeQuery("SELECT i.qty,i.price,i.amount_original,i.amount_local,"
                + "h.exchange_rate,COALESCE(i.arrival_overage_posted_qty,0),i.extra_columns::text "
                + "FROM " + prefix + "_order_items i JOIN " + prefix + "_orders h ON h.id=i.order_id "
                + "WHERE i.id=:id AND NOT i.is_deleted AND NOT h.is_deleted")
                .setParameter("id", orderItemId).getResultList();
        if (sources.isEmpty()) return MoneyPolicy.line(qty, price, null, rate);
        Object[] source = sources.getFirst();
        // Ordinary documents retain the established preview behavior. Additional
        // consideration always comes from the source, never a caller's amount.
        if (source[6] == null || "[]".equals(source[6].toString()))
            return MoneyPolicy.line(qty, price, null, rate);
        BigDecimal sourceQty = decimal(source[0]);
        BigDecimal sourcePrice = decimal(source[1]);
        BigDecimal sourceOriginal = decimal(source[2]);
        BigDecimal sourceLocal = decimal(source[3]);
        BigDecimal sourceRate = decimal(source[4]);
        if (sourceQty == null || sourcePrice == null || sourceOriginal == null || sourceLocal == null
                || sourceRate == null || qty == null || qty.signum() <= 0)
            throw new ApiException(ErrorCode.CONFLICT, "扩展费用来源金额不完整，请先核对订货单");
        Object[] prior = (Object[]) em.createNativeQuery("SELECT COALESCE(SUM(i.qty),0),"
                + "COALESCE(SUM(i.amount_original),0),COALESCE(SUM(i.amount_local),0) "
                + "FROM " + prefix + "_receipt_items i JOIN " + prefix + "_receipts h ON h.id=i.receipt_id "
                + "WHERE i.order_item_id=:id AND h.id<>:receipt AND h.status=1 "
                + "AND NOT i.is_deleted AND NOT h.is_deleted")
                .setParameter("id", orderItemId).setParameter("receipt", receiptId).getSingleResult();
        var released = replacementAllocation.releasedCapacity(kind, orderItemId);
        boolean exactPriceBasis = MoneyPolicy.exactProduct(sourceQty, sourcePrice).compareTo(sourceOriginal) == 0
                && MoneyPolicy.local(sourceOriginal, sourceRate).compareTo(sourceLocal) == 0;
        if (!exactPriceBasis && (released.amountOriginal() == null || released.amountLocal() == null))
            throw new ApiException(ErrorCode.CONFLICT, "扩展费用的退回金额缺失，请先核对历史批次");
        BigDecimal priorQty = decimal(prior[0]).subtract(released.qty());
        BigDecimal priorOriginal = exactPriceBasis ? MoneyPolicy.exactProduct(priorQty, sourcePrice)
                : decimal(prior[1]).subtract(released.amountOriginal());
        BigDecimal priorLocal = exactPriceBasis ? MoneyPolicy.local(priorOriginal, sourceRate)
                : decimal(prior[2]).subtract(released.amountLocal());
        Pending earlier = pending.get(orderItemId);
        if (earlier != null) {
            if (earlier.unresolved()) return new MoneyPolicy.LineAmounts(null, null);
            priorQty = priorQty.add(earlier.qty());
            priorOriginal = priorOriginal.add(earlier.original());
            priorLocal = priorLocal.add(earlier.local());
        }
        BigDecimal allowance = decimal(em.createNativeQuery("SELECT COALESCE(SUM(approved_excess_qty),0) "
                + "FROM procurement_arrival_exceptions WHERE order_type=:kind AND receipt_id=:receipt "
                + "AND order_item_id=:id AND status='RECEIPT_ADJUSTED' "
                + "AND decision IN('APPROVE_ALL','APPROVE_CUSTOM')")
                .setParameter("kind", kind).setParameter("receipt", receiptId)
                .setParameter("id", orderItemId).getSingleResult());
        BigDecimal overage = decimal(source[5]).add(allowance);
        BigDecimal overageOriginal = MoneyPolicy.exactProduct(overage, sourcePrice);
        MoneyPolicy.LineAmounts result = allocated(qty, priorQty, sourceQty.add(overage), sourceOriginal.add(overageOriginal),
                sourceLocal.add(MoneyPolicy.local(overageOriginal, sourceRate)), priorOriginal, priorLocal);
        boolean unresolved = result.original() == null || result.local() == null;
        pending.put(orderItemId, new Pending(
                qty.add(earlier == null ? BigDecimal.ZERO : earlier.qty()),
                unresolved ? BigDecimal.ZERO : result.original().add(earlier == null ? BigDecimal.ZERO : earlier.original()),
                unresolved ? BigDecimal.ZERO : result.local().add(earlier == null ? BigDecimal.ZERO : earlier.local()), unresolved));
        return result;
    }

    static MoneyPolicy.LineAmounts allocated(BigDecimal qty, BigDecimal priorQty, BigDecimal sourceQty,
            BigDecimal original, BigDecimal local, BigDecimal priorOriginal, BigDecimal priorLocal) {
        // Unapproved overage remains a draft requiring the existing exception
        // workflow. Show no invented fee/authorization for its excess quantity.
        if (priorQty.signum() < 0 || priorOriginal.signum() < 0 || priorLocal.signum() < 0
                || priorQty.add(qty).compareTo(sourceQty) > 0)
            return new MoneyPolicy.LineAmounts(null, null);
        return MoneyPolicy.prorateBatch(qty, priorQty, sourceQty, original, local, priorOriginal, priorLocal);
    }

    private static BigDecimal decimal(Object value) {
        return value == null ? null : value instanceof BigDecimal d ? d : new BigDecimal(value.toString());
    }
}
