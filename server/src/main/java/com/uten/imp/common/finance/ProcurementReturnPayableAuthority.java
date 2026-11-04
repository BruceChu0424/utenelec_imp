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

    /** A pending receipt is a real obligation, with a distinct typed UUID; never return it as an AP id. */
    public record Reference(String sourceKind,UUID sourceId,UUID ledgerId,UUID candidateId) { }

    public static Reference lockAndValidateConsideration(EntityManager em,String receiptType,UUID receiptId,
            UUID supplierId,UUID currencyId,BigDecimal exchangeRate,UUID settlementMethodId,
            BigDecimal receiptTotalOriginal,BigDecimal receiptTotalLocal,boolean sourceMarkedPosted){
        if(!java.util.Set.of("PURCHASE","SUBCONTRACT").contains(receiptType))throw conflict("退货来源类型不正确");
        var rows=com.uten.imp.common.util.NativeQueryResults.objectArrayRows(em.createNativeQuery("""
            SELECT candidate.id,candidate.supplier_id,candidate.currency_id,candidate.exchange_rate,candidate.settlement_method_id,
                   candidate.amount_original,candidate.amount_local,candidate.ledger_id,
                   (SELECT sum(part.payable_original) FROM procurement_receipt_consideration_parts part
                     WHERE part.receipt_type=:type AND part.receipt_id=:receipt AND fn_procurement_consideration_active('CONSIDERATION',part.id)),
                   (SELECT sum(part.payable_local) FROM procurement_receipt_consideration_parts part
                     WHERE part.receipt_type=:type AND part.receipt_id=:receipt AND fn_procurement_consideration_active('CONSIDERATION',part.id))
            FROM finance_procurement_payable_candidates candidate WHERE candidate.source_type=:sourceType AND candidate.source_id=:receipt
              AND candidate.status<>'SOURCE_REVERSED' ORDER BY candidate.id FOR UPDATE OF candidate
            """).setParameter("type",receiptType).setParameter("receipt",receiptId).setParameter("sourceType",receiptType+"_RECEIPT"));
        if(rows.isEmpty()){
            UUID ledger=lockAndValidate(em,receiptType,receiptId,supplierId,currencyId,exchangeRate,settlementMethodId,receiptTotalOriginal,receiptTotalLocal,sourceMarkedPosted);
            return new Reference("AP",ledger,ledger,null);
        }
        if(rows.size()!=1)throw conflict("来源暂估债务重复，不能生成退货贷项");Object[] row=rows.getFirst();
        if(!Objects.equals(supplierId,uuid(row[1]))||!Objects.equals(currencyId,uuid(row[2]))||!same(exchangeRate,decimal(row[3]))
            ||!Objects.equals(settlementMethodId,uuid(row[4]))||!same(decimal(row[5]),decimal(row[8]))||!same(decimal(row[6]),decimal(row[9])))
            throw conflict("来源暂估债务与冻结计款供应商、币别、汇率、结算或双币金额不一致");
        return new Reference("PENDING_RECEIPT",uuid(row[0]),uuid(row[7]),uuid(row[0]));
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
