package com.uten.imp.common.finance;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import jakarta.persistence.EntityManager;

import java.math.BigDecimal;
import java.util.List;
import java.util.Objects;
import java.util.UUID;

/** Requires one exact active source AP before a procurement return may create a supplier credit. */
public final class ProcurementReturnPayableAuthority {
    private ProcurementReturnPayableAuthority() {
    }

    public static UUID lockAndValidate(
            EntityManager em,
            String receiptType,
            UUID receiptId,
            UUID supplierId,
            UUID currencyId,
            BigDecimal exchangeRate,
            UUID settlementMethodId,
            BigDecimal receiptTotalOriginal,
            BigDecimal receiptTotalLocal,
            boolean sourceMarkedPosted) {
        if (!sourceMarkedPosted) {
            throw conflict("委外进仓尚未标记应付已立账，禁止生成退货贷项");
        }
        String sourceType = "PURCHASE".equals(receiptType)
                ? "PURCHASE_RECEIPT" : "SUBCONTRACT_RECEIPT";
        @SuppressWarnings("unchecked")
        List<Object[]> rows = em.createNativeQuery("""
                        SELECT id,supplier_id,currency_id,exchange_rate,
                               settlement_type_id,amount_original,amount_original_local
                        FROM ar_ap_ledger
                        WHERE source_doc_type=:sourceType AND source_doc_id=:receiptId
                          AND direction='AP' AND status=1
                          AND COALESCE(is_deleted,FALSE)=FALSE
                        ORDER BY id FOR UPDATE
                        """)
                .setParameter("sourceType", sourceType)
                .setParameter("receiptId", receiptId)
                .getResultList();
        if (rows.size() != 1) {
            throw conflict("来源收货有效应付缺失或重复，禁止无债务生成退货贷项");
        }
        Object[] row = rows.getFirst();
        if (!Objects.equals(supplierId, uuid(row[1]))
                || !Objects.equals(currencyId, uuid(row[2]))
                || !same(exchangeRate, decimal(row[3]))
                || !Objects.equals(settlementMethodId, uuid(row[4]))
                || !same(receiptTotalOriginal, decimal(row[5]))
                || !same(receiptTotalLocal, decimal(row[6]))) {
            throw conflict("来源应付与收货供应商、币种、汇率、结算或双币总额不一致");
        }
        return uuid(row[0]);
    }

    private static boolean same(BigDecimal left, BigDecimal right) {
        return left != null && right != null && left.compareTo(right) == 0;
    }

    private static UUID uuid(Object value) {
        return value instanceof UUID id ? id
                : value == null ? null : UUID.fromString(value.toString());
    }

    private static BigDecimal decimal(Object value) {
        return value == null ? null : value instanceof BigDecimal decimal
                ? decimal : new BigDecimal(value.toString());
    }

    private static ApiException conflict(String message) {
        return new ApiException(ErrorCode.CONFLICT, message);
    }
}
