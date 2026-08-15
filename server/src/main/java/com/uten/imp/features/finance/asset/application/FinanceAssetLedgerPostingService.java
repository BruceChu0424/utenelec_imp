package com.uten.imp.features.finance.asset.application;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.finance.asset.domain.AssetPeriod;
import com.uten.imp.application.concurrency.PaymentStyleHierarchyLock;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.ArrayList;
import java.util.List;
import java.util.UUID;

/** Asset-subledger owned GL writer. It never participates in legacy GL regeneration. */
@Service
@RequiredArgsConstructor
public class FinanceAssetLedgerPostingService {

    private final EntityManager em;
    private final TxSessionVars tx;
    private final FinanceAssetAuthorization authorization;

    @Transactional(propagation = Propagation.MANDATORY)
    public UUID post(
            String voucherNo,
            String period,
            LocalDate voucherDate,
            String sourceType,
            UUID sourceDocumentId,
            String sourceDocumentType,
            String remark,
            List<Entry> entries) {
        PaymentStyleHierarchyLock.lock(em);
        return postInternal(voucherNo, period, voucherDate, sourceType, sourceDocumentId,
                sourceDocumentType, remark, entries, null);
    }

    private UUID postInternal(
            String voucherNo,
            String period,
            LocalDate voucherDate,
            String sourceType,
            UUID sourceDocumentId,
            String sourceDocumentType,
            String remark,
            List<Entry> entries,
            UUID reversalOfVoucherId) {
        tx.bind();
        UUID actorId = authorization.requireActorId(FinanceAssetAuthorization.POST);
        AssetPeriod.parse(period);
        validateEntries(entries);
        if (entries.isEmpty()) {
            return null;
        }

        UUID voucherId = UUID.randomUUID();
        String sourceRef = sourceDocumentType + ":" + sourceDocumentId;
        String idempotencyKey = sourceType + "|" + sourceRef + "|" + period;
        em.createNativeQuery("""
                INSERT INTO gl_vouchers
                    (id, voucher_no, period, voucher_date, source, source_type, remark,
                      source_ref, idempotency_key, reversal_of_voucher_id,
                      status, created_by, updated_by)
                VALUES
                    (:id, :no, :period, :voucherDate, 'AUTO', :sourceType, :remark,
                      :sourceRef, :idempotencyKey, :reversalOf,
                      0, :actor, :actor)
                """)
                .setParameter("id", voucherId)
                .setParameter("no", voucherNo)
                .setParameter("period", period)
                .setParameter("voucherDate", voucherDate)
                .setParameter("sourceType", sourceType)
                .setParameter("remark", remark)
                .setParameter("sourceRef", sourceRef)
                .setParameter("idempotencyKey", idempotencyKey)
                .setParameter("reversalOf", reversalOfVoucherId)
                .setParameter("actor", actorId)
                .executeUpdate();

        int lineNo = 0;
        for (Entry entry : entries) {
            em.createNativeQuery("""
                    INSERT INTO gl_entries
                        (voucher_id, line_no, style_id, direction, amount, entry_date, period,
                         source_doc_type, source_doc_id, source_bill_no, summary,
                         created_by, updated_by)
                    VALUES
                        (:voucher, :lineNo, :style, :direction, :amount, :entryDate, :period,
                         :documentType, :documentId, :billNo, :summary,
                         :actor, :actor)
                    """)
                    .setParameter("voucher", voucherId)
                    .setParameter("lineNo", ++lineNo)
                    .setParameter("style", entry.styleId())
                    .setParameter("direction", entry.direction())
                    .setParameter("amount", entry.amount())
                    .setParameter("entryDate", voucherDate)
                    .setParameter("period", period)
                    .setParameter("documentType", sourceDocumentType)
                    .setParameter("documentId", sourceDocumentId)
                    .setParameter("billNo", voucherNo)
                    .setParameter("summary", entry.summary())
                    .setParameter("actor", actorId)
                    .executeUpdate();
        }
        int posted = em.createNativeQuery("""
                UPDATE gl_vouchers
                SET status=1, updated_at=now(), updated_by=:actor
                WHERE id=:id AND status=0
                """)
                .setParameter("actor", actorId)
                .setParameter("id", voucherId)
                .executeUpdate();
        if (posted != 1) {
            throw new ApiException(ErrorCode.CONFLICT, "Asset voucher draft could not be finalized");
        }
        return voucherId;
    }

    @Transactional(propagation = Propagation.MANDATORY)
    public UUID reverse(
            UUID originalVoucherId,
            String voucherNo,
            String period,
            LocalDate voucherDate,
            String sourceType,
            UUID sourceDocumentId,
            String sourceDocumentType,
            String reason) {
        tx.bind();
        PaymentStyleHierarchyLock.lock(em);
        authorization.require(FinanceAssetAuthorization.POST);
        @SuppressWarnings("unchecked")
        List<Object[]> rows = em.createNativeQuery("""
                SELECT style_id, direction, amount, summary
                FROM gl_entries
                WHERE voucher_id=:voucher AND is_deleted=false
                ORDER BY line_no, id
                """)
                .setParameter("voucher", originalVoucherId)
                .getResultList();
        if (rows.isEmpty()) {
            throw new ApiException(ErrorCode.NOT_FOUND, "Original voucher has no active entries");
        }
        List<Entry> reverseEntries = new ArrayList<>(rows.size());
        for (Object[] row : rows) {
            reverseEntries.add(new Entry(
                    asUuid(row[0]),
                    -((Number) row[1]).intValue(),
                    (BigDecimal) row[2],
                    "Reversal: " + (row[3] == null ? reason : row[3])));
        }
        UUID reversalVoucherId = postInternal(
                voucherNo,
                period,
                voucherDate,
                sourceType,
                sourceDocumentId,
                sourceDocumentType,
                reason,
                reverseEntries,
                originalVoucherId);
        UUID actorId = authorization.requireActorId(FinanceAssetAuthorization.POST);
        em.createNativeQuery("""
                UPDATE gl_vouchers
                SET status=-1, reversed_by_voucher_id=:reversal,
                    updated_at=now(), updated_by=:actor
                WHERE id=:original AND status=1
                """)
                .setParameter("reversal", reversalVoucherId)
                .setParameter("actor", actorId)
                .setParameter("original", originalVoucherId)
                .executeUpdate();
        return reversalVoucherId;
    }

    static void validateEntries(List<Entry> entries) {
        if (entries == null) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "Voucher entries are required");
        }
        BigDecimal debit = BigDecimal.ZERO;
        BigDecimal credit = BigDecimal.ZERO;
        for (Entry entry : entries) {
            if (entry.styleId() == null || (entry.direction() != 1 && entry.direction() != -1)
                    || entry.amount() == null || entry.amount().signum() <= 0) {
                throw new ApiException(ErrorCode.VALIDATION_FAILED, "Invalid asset voucher entry");
            }
            if (entry.direction() == 1) debit = debit.add(entry.amount());
            else credit = credit.add(entry.amount());
        }
        if (debit.compareTo(credit) != 0) {
            throw new ApiException(
                    ErrorCode.VALIDATION_FAILED,
                    "Asset voucher is not balanced: debit=" + debit + ", credit=" + credit);
        }
    }

    private static UUID asUuid(Object value) {
        return value instanceof UUID uuid ? uuid : UUID.fromString(value.toString());
    }

    public record Entry(UUID styleId, int direction, BigDecimal amount, String summary) {}
}
