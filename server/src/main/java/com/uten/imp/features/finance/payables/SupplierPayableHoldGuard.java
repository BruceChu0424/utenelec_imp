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
                || targetLedgerIds == null || targetLedgerIds.size() != 1) return false;
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
        List<Object[]> rows = em.createNativeQuery("""
                        WITH inspection_link AS (
                            SELECT 'PURCHASE_RECEIPT'::text source_type,
                                   receipt_item.receipt_id source_id,
                                   inspection.id inspection_item_id,
                                   inspection.received_base_qty,
                                   inspection.passed_base_qty,
                                   inspection.failed_base_qty,
                                   inspection.status
                            FROM procurement_inspection_items inspection
                            JOIN purchase_receipt_items receipt_item
                              ON receipt_item.id=inspection.receipt_item_id
                            WHERE inspection.receipt_type='PURCHASE'
                              AND inspection.status<>'REVERSED'
                            UNION ALL
                            SELECT 'SUBCONTRACT_RECEIPT',receipt_item.receipt_id,
                                   inspection.id,inspection.received_base_qty,
                                   inspection.passed_base_qty,inspection.failed_base_qty,
                                   inspection.status
                            FROM procurement_inspection_items inspection
                            JOIN subcontract_receipt_items receipt_item
                              ON receipt_item.id=inspection.receipt_item_id
                            WHERE inspection.receipt_type='SUBCONTRACT'
                              AND inspection.status<>'REVERSED'
                        )
                        SELECT ledger.id,ledger.source_doc_no,
                               COALESCE(SUM(link.received_base_qty-link.passed_base_qty
                                   -link.failed_base_qty)
                                   FILTER(WHERE link.status IN('PENDING','PARTIAL')),0),
                               COALESCE(SUM(link.failed_base_qty),0)
                        FROM ar_ap_ledger ledger
                        JOIN inspection_link link
                          ON link.source_type=ledger.source_doc_type
                         AND link.source_id=ledger.source_doc_id
                        LEFT JOIN procurement_iqc_rejection_cases rejection
                          ON rejection.inspection_item_id=link.inspection_item_id
                         AND COALESCE(rejection.is_deleted,FALSE)=FALSE
                        WHERE ledger.id IN (:ledgerIds)
                          AND NOT (
                              CAST(:allowedCaseId AS uuid) IS NOT NULL
                              AND EXISTS(
                                  SELECT 1
                                  FROM procurement_iqc_rejection_cases allowed_case
                                  JOIN ar_ap_ledger allowed_credit
                                    ON allowed_credit.source_doc_id=allowed_case.id
                                   AND allowed_credit.source_doc_type=CASE
                                       WHEN allowed_case.receipt_type='PURCHASE'
                                       THEN 'PURCHASE_IQC_CREDIT'
                                       ELSE 'SUBCONTRACT_IQC_CREDIT' END
                                   AND allowed_credit.direction='AP'
                                   AND allowed_credit.status=1
                                   AND COALESCE(allowed_credit.is_deleted,FALSE)=FALSE
                                  WHERE allowed_case.id=:allowedCaseId
                                    AND allowed_case.status='RETURN_RECORDED'
                                    AND allowed_case.source_ap_ledger_id=ledger.id
                              )
                          )
                          AND (
                              link.status IN('PENDING','PARTIAL')
                              OR (link.failed_base_qty>0
                                  AND NOT (
                                      COALESCE(rejection.status,'') IN(
                                          'CREDIT_CONFIRMED','CLOSED_NO_CREDIT')
                                      OR (CAST(:allowedCaseId AS uuid) IS NOT NULL
                                          AND rejection.id=:allowedCaseId
                                          AND rejection.status='RETURN_RECORDED'
                                          AND rejection.source_ap_ledger_id=ledger.id)
                                  ))
                          )
                        GROUP BY ledger.id,ledger.source_doc_no
                        ORDER BY ledger.id
                        """)
                .setParameter("ledgerIds", ledgerIds)
                .setParameter("allowedCaseId", allowedIqcCaseId)
                .getResultList();
        return rows;
    }

    private static BigDecimal decimal(Object value) {
        return value == null ? BigDecimal.ZERO
                : value instanceof BigDecimal decimal ? decimal : new BigDecimal(value.toString());
    }

    public record HoldInfo(boolean held, String reason, BigDecimal failedBaseQty) {
    }
}
