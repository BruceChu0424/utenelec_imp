package com.uten.imp.features.finance.payables;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.Collection;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;

/** Central fail-closed hold for AP rows whose IQC rejection has not reached confirmed credit. */
@Service
@RequiredArgsConstructor
public class SupplierPayableHoldGuard {
    private final EntityManager em;

    public void requireUnheld(Collection<UUID> ledgerIds, String subject) {
        requireUnheld(ledgerIds, subject, null);
    }

    void requireUnheld(
            Collection<UUID> ledgerIds, String subject, UUID allowedIqcCaseId) {
        if (ledgerIds == null || ledgerIds.isEmpty()) return;
        List<Object[]> rows = holdRows(ledgerIds, allowedIqcCaseId);
        if (!rows.isEmpty()) {
            Object[] row = rows.getFirst();
            throw new ApiException(ErrorCode.CONFLICT,
                    subject + "被 IQC 待检/不合格退回/供应商贷项冻结："
                            + row[1] + "，待检基本量 "
                            + decimal(row[2]).stripTrailingZeros().toPlainString()
                            + "，失败基本量 "
                            + decimal(row[3]).stripTrailingZeros().toPlainString());
        }
    }

    public void requireSettlementUnheld(
            UUID supplierId, UUID currencyId, LocalDate periodEnd) {
        @SuppressWarnings("unchecked")
        List<UUID> ledgerIds = em.createNativeQuery("""
                        SELECT id FROM ar_ap_ledger
                        WHERE supplier_id=:supplierId AND currency_id=:currencyId
                          AND direction='AP' AND status=1
                          AND COALESCE(is_deleted,FALSE)=FALSE
                          AND bill_date<=:periodEnd
                        """)
                .setParameter("supplierId", supplierId)
                .setParameter("currencyId", currencyId)
                .setParameter("periodEnd", periodEnd)
                .getResultList();
        requireUnheld(ledgerIds, "应付月结冻结");
    }

    public HoldInfo holdInfo(UUID ledgerId) {
        return holdInfos(List.of(ledgerId)).getOrDefault(
                ledgerId, new HoldInfo(false, null, BigDecimal.ZERO));
    }

    public Map<UUID, HoldInfo> holdInfos(Collection<UUID> ledgerIds) {
        if (ledgerIds == null || ledgerIds.isEmpty()) return Map.of();
        Map<UUID, HoldInfo> result = new HashMap<>();
        for (Object[] row : holdRows(ledgerIds, null)) {
            result.put((UUID) row[0], new HoldInfo(
                    true,
                    row[1] + "：IQC待检/不合格退回及贷项尚未闭环",
                    decimal(row[3])));
        }
        return Map.copyOf(result);
    }

    boolean authorizedIqcCreditOffset(
            UUID caseId, UUID sourceCreditLedgerId, Collection<UUID> targetLedgerIds) {
        if (caseId == null || sourceCreditLedgerId == null
                || targetLedgerIds == null || targetLedgerIds.isEmpty()) return false;
        long covered=((Number)em.createNativeQuery("""
                SELECT COUNT(DISTINCT funding.source_ap_ledger_id)
                FROM procurement_iqc_credit_slices credit
                JOIN procurement_iqc_funding_slices funding ON funding.id=credit.funding_slice_id
                WHERE credit.case_id=:caseId AND funding.source_ap_ledger_id IN (:targets)
                  AND fn_procurement_iqc_slice_offset_authorized(:caseId,:source,funding.source_ap_ledger_id)
                """).setParameter("caseId",caseId).setParameter("source",sourceCreditLedgerId)
                .setParameter("targets",targetLedgerIds).getSingleResult()).longValue();
        if(covered==new java.util.HashSet<>(targetLedgerIds).size())return true;
        if(targetLedgerIds.size()!=1)return false;
        UUID target = targetLedgerIds.iterator().next();
        long count = ((Number) em.createNativeQuery("""
                        SELECT COUNT(*)
                        FROM procurement_iqc_rejection_cases rejection
                        JOIN ar_ap_ledger credit ON credit.id=:sourceCreditLedgerId
                        WHERE rejection.id=:caseId
                          AND rejection.status='RETURN_RECORDED'
                          AND rejection.source_ap_ledger_id=:targetLedgerId
                          AND credit.source_doc_id=rejection.id
                          AND credit.source_doc_type=CASE rejection.receipt_type
                              WHEN 'PURCHASE' THEN 'PURCHASE_IQC_CREDIT'
                              ELSE 'SUBCONTRACT_IQC_CREDIT' END
                          AND credit.status=1 AND COALESCE(credit.is_deleted,FALSE)=FALSE
                        """)
                .setParameter("caseId", caseId)
                .setParameter("sourceCreditLedgerId", sourceCreditLedgerId)
                .setParameter("targetLedgerId", target)
                .getSingleResult()).longValue();
        return count == 1;
    }

    private List<Object[]> holdRows(
            Collection<UUID> ledgerIds, UUID allowedIqcCaseId) {
        @SuppressWarnings("unchecked")
        List<Object[]> rows=em.createNativeQuery("""
                SELECT ledger.id,ledger.source_doc_no,
                       COALESCE(inspection.pending,0),
                       COALESCE(funding.unresolved,inspection.failed,0)
                FROM ar_ap_ledger ledger
                LEFT JOIN LATERAL (
                    SELECT SUM(received_base_qty-passed_base_qty-failed_base_qty)
                               FILTER(WHERE status IN ('PENDING','PARTIAL')) pending,
                           SUM(failed_base_qty) failed
                    FROM procurement_inspection_items
                    WHERE receipt_id=ledger.source_doc_id
                      AND receipt_type||'_RECEIPT'=ledger.source_doc_type AND status<>'REVERSED'
                ) inspection ON TRUE
                LEFT JOIN LATERAL (
                    SELECT SUM(fn_procurement_iqc_funding_unresolved(id)) unresolved
                    FROM procurement_iqc_funding_slices
                    WHERE source_ap_ledger_id=ledger.id AND parent_funding_slice_id IS NULL
                      AND fn_procurement_consideration_active('FUNDING',id)
                ) funding ON TRUE
                WHERE ledger.id IN (:ledgerIds)
                  AND fn_procurement_iqc_ap_hold_reason(ledger.id,CAST(:allowedCaseId AS uuid)) IS NOT NULL
                ORDER BY ledger.id
                """).setParameter("ledgerIds",ledgerIds)
                .setParameter("allowedCaseId",allowedIqcCaseId).getResultList();
        return rows;
    }
    private static BigDecimal decimal(Object value) {
        return value == null ? BigDecimal.ZERO
                : value instanceof BigDecimal decimal ? decimal : new BigDecimal(value.toString());
    }

    public record HoldInfo(boolean held, String reason, BigDecimal failedBaseQty) {
    }
}
