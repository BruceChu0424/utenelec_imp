package com.uten.imp.common.finance;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import jakarta.persistence.EntityManager;

import java.math.BigDecimal;
import java.util.List;
import java.util.UUID;

/** Locks IQC evidence and limits a procurement return to stock physically confirmed by warehouse. */
public final class ProcurementReturnQualityPolicy {

    private ProcurementReturnQualityPolicy() {
    }

    public static void lockInspectionRows(
            EntityManager em,
            String receiptType,
            List<UUID> receiptItemIds) {
        List<UUID> ids = receiptItemIds == null ? List.of()
                : receiptItemIds.stream().filter(java.util.Objects::nonNull)
                    .distinct().sorted().toList();
        if (ids.isEmpty()) return;
        em.createNativeQuery("""
                        SELECT id
                        FROM procurement_inspection_items
                        WHERE receipt_type=:receiptType AND receipt_item_id IN (:receiptItemIds)
                        ORDER BY id
                        FOR UPDATE
                        """)
                .setParameter("receiptType", receiptType)
                .setParameter("receiptItemIds", ids)
                .getResultList();
    }

    public static ReturnableSource lockAndLimit(
            EntityManager em,
            String receiptType,
            UUID receiptItemId,
            BigDecimal receiptQty,
            BigDecimal unitRate,
            BigDecimal receiptOriginal,
            BigDecimal receiptLocal) {
        @SuppressWarnings("unchecked")
        List<Object[]> rows = em.createNativeQuery("""
                        SELECT received_base_qty, passed_base_qty, failed_base_qty, status,
                               warehouse_stocked_base_qty, id
                        FROM procurement_inspection_items
                        WHERE receipt_type=:receiptType AND receipt_item_id=:receiptItemId
                        FOR UPDATE
                        """)
                .setParameter("receiptType", receiptType)
                .setParameter("receiptItemId", receiptItemId)
                .getResultList();
        if (rows.size() > 1) {
            throw conflict("来源收货明细存在重复 IQC 冻结行，禁止退货");
        }
        if (rows.isEmpty()) {
            // Pre-V222 historical receipts have no inspection sidecar. Preserve their audited
            // receipt quantity/amount as the only available authority; never fabricate PASS rows.
            return new ReturnableSource(receiptQty, receiptOriginal, receiptLocal, true);
        }
        Object[] row = rows.getFirst();
        BigDecimal receivedBase = decimal(row[0]);
        BigDecimal passedBase = decimal(row[1]);
        BigDecimal failedBase = decimal(row[2]);
        String status = row[3] == null ? null : row[3].toString();
        BigDecimal stockedBase = decimal(row[4]);
        if (!"RESOLVED".equals(status)) {
            throw conflict("来源收货尚未完成 IQC，禁止用待检数量生成退货或应付贷项");
        }
        if (receiptQty == null || receiptQty.signum() <= 0
                || unitRate == null || unitRate.signum() <= 0
                || receivedBase == null || receivedBase.signum() <= 0
                || passedBase == null || passedBase.signum() < 0
                || failedBase == null || failedBase.signum() < 0
                || stockedBase == null || stockedBase.signum() < 0
                || stockedBase.compareTo(passedBase) > 0
                || passedBase.add(failedBase).compareTo(receivedBase) != 0
                || MoneyPolicy.quantity(receiptQty.multiply(unitRate))
                        .compareTo(MoneyPolicy.quantity(receivedBase)) != 0) {
            throw conflict("来源收货 IQC 数量、单位换算或结案守恒不一致，禁止退货");
        }
        // 可退额度与不合格金额同一口径(ProcurementIqcAmountSplit): 合格金额 = 收货金额 − 不合格金额,
        // 可退 = 合格金额中仓库已实收的累计份额, 全部实收时就是合格金额本身。
        // 不合格贷项 + 合格件全部退货 恰好冲平收货应付, 原币与本币都不留尾差。
        BigDecimal returnableQty = MoneyPolicy.quantityShare(receiptQty, stockedBase, receivedBase);
        ProcurementIqcAmountSplit.Amounts failed = ProcurementIqcAmountSplit.failedForReturnLimit(
                em, (UUID) row[5], receivedBase, failedBase, receiptOriginal, receiptLocal);
        return new ReturnableSource(
                returnableQty,
                stockedShare(receiptOriginal, failed.original(), stockedBase, passedBase),
                stockedShare(receiptLocal, failed.local(), stockedBase, passedBase),
                false);
    }

    private static BigDecimal stockedShare(
            BigDecimal receiptAmount, BigDecimal failedAmount, BigDecimal stockedBase, BigDecimal passedBase) {
        BigDecimal passedAmount = receiptAmount.subtract(failedAmount);
        if (passedAmount.signum() < 0) {
            throw conflict("来源收货的不合格金额超过收货金额，禁止退货");
        }
        if (passedBase.signum() == 0) return BigDecimal.ZERO;
        return MoneyPolicy.cumulativeShare(MoneyPolicy.canonical(passedAmount), stockedBase, passedBase);
    }

    private static BigDecimal decimal(Object value) {
        return value == null ? null : value instanceof BigDecimal decimal
                ? decimal : new BigDecimal(value.toString());
    }

    private static ApiException conflict(String message) {
        return new ApiException(ErrorCode.CONFLICT, message);
    }

    public record ReturnableSource(
            BigDecimal qty,
            BigDecimal amountOriginal,
            BigDecimal amountLocal,
            boolean legacyFallback) {
    }
}
