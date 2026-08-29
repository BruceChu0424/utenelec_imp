package com.uten.imp.features.finance.accountflow;

import com.uten.imp.common.util.NativeQueryResults;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.time.OffsetDateTime;
import java.util.HashSet;
import java.util.List;
import java.util.Set;
import java.util.UUID;

/**
 * Appends account-flow reversals without deleting the original posting facts.
 *
 * <p>The surrounding business service remains responsible for reversing its
 * denormalized account totals and domain subledger. This service owns only the
 * append-only {@code finance_reconciliations} reversal facts and must therefore
 * run inside the caller's transaction.
 */
@Service
@RequiredArgsConstructor
public class AccountFlowLedgerService {

    private static final String POSTING = "POSTING";
    private static final String REVERSAL = "REVERSAL";

    private final EntityManager em;

    /**
     * Mirrors every effective posting for one business source as a reversal row.
     * Original rows remain untouched. A source-level advisory lock makes a retry
     * observe the first committed reversal before it attempts another insert.
     *
     * @return number of reversal rows appended
     */
    @Transactional(propagation = Propagation.MANDATORY)
    public int reverse(
            String sourceType,
            UUID sourceId,
            OffsetDateTime reversalAt,
            String reason) {
        String normalizedType = normalizeSourceType(sourceType);
        String normalizedReason = normalizeReason(reason);
        if (sourceId == null || reversalAt == null) {
            throw new ApiException(
                    ErrorCode.VALIDATION_FAILED,
                    "账户流水红冲缺少来源 UUID 或红冲时间");
        }

        em.createNativeQuery(
                        "SELECT pg_advisory_xact_lock(hashtextextended(:key,0))")
                .setParameter("key", "uten:account-flow-reversal:"
                        + normalizedType + ":" + sourceId)
                .getSingleResult();

        List<Object[]> rows = NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT reconciliation.id,
                       reconciliation.bill_no,
                       reconciliation.account_id,
                       reconciliation.check_no,
                       reconciliation.counterpart_name,
                       reconciliation.in_amount,
                       reconciliation.out_amount,
                       reconciliation.source_remark,
                       reconciliation.remark,
                       reconciliation.legacy_bstyle,
                       reconciliation.account_currency_id,
                       reconciliation.amount_local,
                       reconciliation.entry_kind,
                       reconciliation.reversal_of_id
                FROM finance_reconciliations reconciliation
                WHERE reconciliation.source_doc_type=:sourceType
                  AND reconciliation.source_doc_id=:sourceId
                  AND COALESCE(reconciliation.is_deleted,FALSE)=FALSE
                  AND reconciliation.entry_kind IN ('POSTING','REVERSAL')
                ORDER BY reconciliation.account_id NULLS LAST,
                         reconciliation.id
                FOR UPDATE
                """)
                .setParameter("sourceType", normalizedType)
                .setParameter("sourceId", sourceId));

        List<Posting> postings = rows.stream()
                .filter(row -> POSTING.equals(text(row[12])))
                .map(this::posting)
                .toList();
        long reversalCount = rows.stream()
                .filter(row -> REVERSAL.equals(text(row[12])))
                .count();
        if (postings.isEmpty()) {
            throw new ApiException(
                    ErrorCode.CONFLICT,
                    "账户流水原始入账缺失，禁止红冲：" + normalizedType + "/" + sourceId);
        }
        if (reversalCount != 0) {
            throw new ApiException(
                    ErrorCode.CONFLICT,
                    "账户流水已经存在反向分录，禁止重复红冲："
                            + normalizedType + "/" + sourceId);
        }

        Set<UUID> accountIds = new HashSet<>();
        for (Posting posting : postings) {
            if (posting.accountId() == null || !accountIds.add(posting.accountId())) {
                throw new ApiException(
                        ErrorCode.CONFLICT,
                        "账户流水原始入账账户缺失或重复，禁止自动红冲："
                                + normalizedType + "/" + sourceId);
            }
            requireOneSided(posting);
        }

        int appended = 0;
        for (Posting posting : postings) {
            int inserted = em.createNativeQuery("""
                    INSERT INTO finance_reconciliations(
                        bill_no,source_doc_type,source_doc_id,account_id,
                        check_no,counterpart_name,in_amount,out_amount,
                        bill_date,settled_date,source_remark,remark,legacy_bstyle,
                        account_currency_id,amount_local,
                        entry_kind,reversal_of_id,reversal_reason,
                        created_at,updated_at,is_deleted)
                    VALUES(
                        :billNo,:sourceType,:sourceId,:accountId,
                        :checkNo,:counterpartName,:inAmount,:outAmount,
                        :reversalAt,:reversalAt,:sourceRemark,:remark,:legacyBstyle,
                        :accountCurrencyId,:amountLocal,
                        'REVERSAL',:reversalOfId,:reversalReason,
                        now(),now(),FALSE)
                    """)
                    .setParameter("billNo", posting.billNo())
                    .setParameter("sourceType", normalizedType)
                    .setParameter("sourceId", sourceId)
                    .setParameter("accountId", posting.accountId())
                    .setParameter("checkNo", posting.checkNo())
                    .setParameter("counterpartName", posting.counterpartName())
                    .setParameter("inAmount", posting.outAmount())
                    .setParameter("outAmount", posting.inAmount())
                    .setParameter("reversalAt", reversalAt)
                    .setParameter("sourceRemark", posting.sourceRemark())
                    .setParameter("remark", normalizedReason)
                    .setParameter("legacyBstyle", posting.legacyBstyle())
                    .setParameter("accountCurrencyId", posting.accountCurrencyId())
                    .setParameter("amountLocal", posting.amountLocal())
                    .setParameter("reversalOfId", posting.id())
                    .setParameter("reversalReason", normalizedReason)
                    .executeUpdate();
            if (inserted != 1) {
                throw new ApiException(
                        ErrorCode.CONFLICT,
                        "账户流水反向分录写入失败：" + posting.id());
            }
            appended += inserted;
        }
        return appended;
    }

    private Posting posting(Object[] row) {
        return new Posting(
                (UUID) row[0],
                text(row[1]),
                (UUID) row[2],
                text(row[3]),
                text(row[4]),
                decimal(row[5]),
                decimal(row[6]),
                text(row[7]),
                row[9] == null ? null : ((Number) row[9]).intValue(),
                (UUID) row[10],
                nullableDecimal(row[11]));
    }

    private static void requireOneSided(Posting posting) {
        boolean incoming = posting.inAmount().signum() > 0
                && posting.outAmount().signum() == 0;
        boolean outgoing = posting.outAmount().signum() > 0
                && posting.inAmount().signum() == 0;
        if (!incoming && !outgoing) {
            throw new ApiException(
                    ErrorCode.CONFLICT,
                    "账户流水必须且只能有一个正向金额，禁止自动红冲：" + posting.id());
        }
    }

    private static String normalizeSourceType(String sourceType) {
        if (sourceType == null || sourceType.isBlank()) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "账户流水红冲来源类型不能为空");
        }
        String normalized = sourceType.trim();
        if (normalized.length() > 64) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "账户流水红冲来源类型过长");
        }
        return normalized;
    }

    private static String normalizeReason(String reason) {
        if (reason == null || reason.isBlank()) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "账户流水红冲原因不能为空");
        }
        String normalized = reason.trim();
        if (normalized.length() > 500) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "账户流水红冲原因不能超过 500 个字符");
        }
        return normalized;
    }

    private static BigDecimal decimal(Object value) {
        if (value == null) return BigDecimal.ZERO;
        return value instanceof BigDecimal decimal
                ? decimal : new BigDecimal(value.toString());
    }

    private static BigDecimal nullableDecimal(Object value) {
        return value == null ? null : decimal(value);
    }

    private static String text(Object value) {
        return value == null ? null : value.toString();
    }

    private record Posting(
            UUID id,
            String billNo,
            UUID accountId,
            String checkNo,
            String counterpartName,
            BigDecimal inAmount,
            BigDecimal outAmount,
            String sourceRemark,
            Integer legacyBstyle,
            UUID accountCurrencyId,
            BigDecimal amountLocal) {
    }
}
