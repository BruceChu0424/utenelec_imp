package com.uten.imp.features.finance.asset.application;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.finance.asset.api.AssetWorkbenchResponses;
import com.uten.imp.features.finance.asset.domain.AssetPeriod;
import com.uten.imp.features.finance.asset.domain.AssetPeriodClosePolicy;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.sql.Timestamp;
import java.time.Instant;
import java.util.ArrayList;
import java.util.List;
import java.util.Set;
import java.util.UUID;

/** Asset-subledger period control and close reconciliation. */
@Service
@RequiredArgsConstructor
public class FinanceAssetPeriodService {

    private final EntityManager em;
    private final TxSessionVars tx;
    private final FinanceAssetAuthorization authorization;

    @Transactional(readOnly = true)
    @PreAuthorize("hasAuthority('finance_asset:view')")
    public List<AssetWorkbenchResponses.Period> list() {
        authorization.require(FinanceAssetAuthorization.VIEW);
        @SuppressWarnings("unchecked")
        List<Object[]> rows = em.createNativeQuery("""
                SELECT period, status,
                       depreciation_run_id, amortization_run_id,
                       COALESCE(reconciliation_difference, 0),
                       COALESCE(close_reason, reopen_reason), closed_at, row_version
                FROM finance_asset_accounting_periods
                WHERE is_deleted=false
                ORDER BY period DESC
                """).getResultList();
        boolean manage = authorization.has(FinanceAssetAuthorization.PERIOD_MANAGE);
        List<AssetWorkbenchResponses.Period> result = new ArrayList<>(rows.size());
        for (Object[] row : rows) {
            String status = text(row[1]);
            result.add(new AssetWorkbenchResponses.Period(
                    text(row[0]),
                    status,
                    "CLOSED".equals(status),
                    row[2] != null,
                    row[3] != null,
                    decimal(row[4]),
                    text(row[5]),
                    instant(row[6]),
                    number(row[7]).longValue(),
                    manage ? Set.of("CLOSED".equals(status) ? "REOPEN" : "CLOSE") : Set.of()));
        }
        return List.copyOf(result);
    }

    @Transactional
    public void ensureOpen(String period, String requiredPermission) {
        tx.bind();
        UUID actorId = authorization.requireActorId(requiredPermission);
        AssetPeriod.parse(period);
        em.createNativeQuery("SELECT pg_advisory_xact_lock(hashtextextended(:key, 0))")
                .setParameter("key", "FINANCE_ASSET_PERIOD|" + period)
                .getSingleResult();
        em.createNativeQuery("""
                INSERT INTO finance_asset_accounting_periods
                    (period, status, created_by, updated_by)
                VALUES (:period, 'OPEN', :actor, :actor)
                ON CONFLICT (period) DO NOTHING
                """)
                .setParameter("period", period)
                .setParameter("actor", actorId)
                .executeUpdate();
        String status = text(em.createNativeQuery("""
                SELECT status FROM finance_asset_accounting_periods
                WHERE period=:period AND is_deleted=false
                """).setParameter("period", period).getSingleResult());
        if (!"OPEN".equals(status)) {
            throw new ApiException(ErrorCode.CONFLICT, "Asset accounting period is closed: " + period);
        }
    }

    /**
     * Close an asset period under advisory lock + optimistic version: requires both
     * DEPRECIATION and AMORTIZATION effective runs posted with no blocking exceptions,
     * then stores reconciliation_difference = subledger total − GL debit as the close artifact.
     */
    @Transactional
    @PreAuthorize("hasAuthority('finance_asset_period:manage')")
    public AssetWorkbenchResponses.Period close(String period, String reason, Long expectedVersion) {
        tx.bind();
        UUID actorId = authorization.requireActorId(FinanceAssetAuthorization.PERIOD_MANAGE);
        AssetPeriod.parse(period);
        if (reason == null || reason.isBlank()) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "Close reason is required");
        }
        lockPeriod(period, actorId);
        PeriodRow current = periodForUpdate(period);
        requireVersion(current.rowVersion(), expectedVersion);
        if (!"OPEN".equals(current.status())) {
            throw new ApiException(ErrorCode.CONFLICT, "Asset accounting period is already closed");
        }

        List<RunEvidence> runs = effectiveCorporateRuns(period);
        RunEvidence depreciation = uniqueRun(runs, "DEPRECIATION");
        RunEvidence amortization = uniqueRun(runs, "AMORTIZATION");
        int blocking = runs.stream().mapToInt(RunEvidence::blockingExceptions).sum();
        BigDecimal subledger = runs.stream()
                .map(RunEvidence::totalAmount)
                .reduce(BigDecimal.ZERO, BigDecimal::add);
        BigDecimal glDebit = BigDecimal.ZERO;
        BigDecimal glCredit = BigDecimal.ZERO;
        for (RunEvidence run : runs) {
            if (run.voucherId() == null) continue;
            Object[] totals = singleRow(em.createNativeQuery("""
                    SELECT COALESCE(SUM(CASE WHEN direction=1 THEN amount ELSE 0 END),0),
                           COALESCE(SUM(CASE WHEN direction=-1 THEN amount ELSE 0 END),0)
                    FROM gl_entries
                    WHERE voucher_id=:voucher AND is_deleted=false
                    """).setParameter("voucher", run.voucherId()).getSingleResult());
            glDebit = glDebit.add(decimal(totals[0]));
            glCredit = glCredit.add(decimal(totals[1]));
        }
        AssetPeriodClosePolicy.requireClosable(new AssetPeriodClosePolicy.Evidence(
                depreciation != null,
                amortization != null,
                blocking,
                subledger,
                glDebit,
                glCredit));

        BigDecimal difference = subledger.subtract(glDebit);
        int changed = em.createNativeQuery("""
                UPDATE finance_asset_accounting_periods
                SET status='CLOSED', depreciation_run_id=:depreciation,
                    amortization_run_id=:amortization,
                    reconciliation_difference=:difference,
                    closed_at=now(), closed_by=:actor, close_reason=:reason,
                    close_count=close_count+1, row_version=row_version+1,
                    updated_at=now(), updated_by=:actor
                WHERE period=:period AND status='OPEN' AND row_version=:version AND is_deleted=false
                """)
                .setParameter("depreciation", depreciation.id())
                .setParameter("amortization", amortization.id())
                .setParameter("difference", difference)
                .setParameter("actor", actorId)
                .setParameter("reason", reason.trim())
                .setParameter("period", period)
                .setParameter("version", current.rowVersion())
                .executeUpdate();
        if (changed != 1) throw concurrentChange();
        return get(period);
    }

    @Transactional
    @PreAuthorize("hasAuthority('finance_asset_period:manage')")
    public AssetWorkbenchResponses.Period reopen(String period, String reason, Long expectedVersion) {
        tx.bind();
        UUID actorId = authorization.requireActorId(FinanceAssetAuthorization.PERIOD_MANAGE);
        AssetPeriod.parse(period);
        if (reason == null || reason.isBlank()) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "Reopen reason is required");
        }
        lockPeriod(period, actorId);
        PeriodRow current = periodForUpdate(period);
        requireVersion(current.rowVersion(), expectedVersion);
        if (!"CLOSED".equals(current.status())) {
            throw new ApiException(ErrorCode.CONFLICT, "Asset accounting period is already open");
        }
        int changed = em.createNativeQuery("""
                UPDATE finance_asset_accounting_periods
                SET status='OPEN', depreciation_run_id=NULL, amortization_run_id=NULL,
                    reconciliation_difference=0, close_reason=NULL, closed_at=NULL, closed_by=NULL,
                    reopened_at=now(), reopened_by=:actor, reopen_reason=:reason,
                    row_version=row_version+1, updated_at=now(), updated_by=:actor
                WHERE period=:period AND status='CLOSED' AND row_version=:version AND is_deleted=false
                """)
                .setParameter("actor", actorId)
                .setParameter("reason", reason.trim())
                .setParameter("period", period)
                .setParameter("version", current.rowVersion())
                .executeUpdate();
        if (changed != 1) throw concurrentChange();
        return get(period);
    }

    @Transactional(readOnly = true)
    public AssetWorkbenchResponses.Period get(String period) {
        AssetPeriod.parse(period);
        Object[] row = singleRow(em.createNativeQuery("""
                SELECT period, status, depreciation_run_id, amortization_run_id,
                       COALESCE(reconciliation_difference,0),
                       COALESCE(close_reason,reopen_reason), closed_at, row_version
                FROM finance_asset_accounting_periods
                WHERE period=:period AND is_deleted=false
                """).setParameter("period", period).getSingleResult());
        String status = text(row[1]);
        return new AssetWorkbenchResponses.Period(
                text(row[0]), status, "CLOSED".equals(status), row[2] != null, row[3] != null,
                decimal(row[4]), text(row[5]), instant(row[6]), number(row[7]).longValue(),
                authorization.has(FinanceAssetAuthorization.PERIOD_MANAGE)
                        ? Set.of("CLOSED".equals(status) ? "REOPEN" : "CLOSE") : Set.of());
    }

    private void lockPeriod(String period, UUID actorId) {
        em.createNativeQuery("SELECT pg_advisory_xact_lock(hashtextextended(:key, 0))")
                .setParameter("key", "FINANCE_ASSET_PERIOD|" + period)
                .getSingleResult();
        em.createNativeQuery("""
                INSERT INTO finance_asset_accounting_periods
                    (period, status, created_by, updated_by)
                VALUES (:period, 'OPEN', :actor, :actor)
                ON CONFLICT (period) DO NOTHING
                """)
                .setParameter("period", period)
                .setParameter("actor", actorId)
                .executeUpdate();
    }

    private PeriodRow periodForUpdate(String period) {
        Object[] row = singleRow(em.createNativeQuery("""
                SELECT status, row_version
                FROM finance_asset_accounting_periods
                WHERE period=:period AND is_deleted=false
                FOR UPDATE
                """).setParameter("period", period).getSingleResult());
        return new PeriodRow(text(row[0]), number(row[1]).longValue());
    }

    private List<RunEvidence> effectiveCorporateRuns(String period) {
        @SuppressWarnings("unchecked")
        List<Object[]> rows = em.createNativeQuery("""
                SELECT id, run_type, total_amount, voucher_id,
                       (SELECT COUNT(*) FROM jsonb_array_elements(exception_snapshot) issue
                        WHERE COALESCE(issue->>'severity','BLOCKING')='BLOCKING')
                FROM finance_asset_posting_runs
                WHERE period=:period AND book_type='CORPORATE'
                  AND run_kind='NORMAL' AND status='POSTED' AND is_deleted=false
                ORDER BY run_type, created_at DESC
                """).setParameter("period", period).getResultList();
        List<RunEvidence> result = new ArrayList<>(rows.size());
        for (Object[] row : rows) {
            result.add(new RunEvidence(
                    uuid(row[0]), text(row[1]), decimal(row[2]), uuid(row[3]), number(row[4]).intValue()));
        }
        return result;
    }

    private static RunEvidence uniqueRun(List<RunEvidence> runs, String type) {
        List<RunEvidence> matches = runs.stream().filter(run -> type.equals(run.runType())).toList();
        if (matches.size() > 1) {
            throw new ApiException(ErrorCode.CONFLICT, "Multiple effective posted runs exist for " + type);
        }
        return matches.isEmpty() ? null : matches.getFirst();
    }

    private static void requireVersion(long current, Long expected) {
        if (expected != null && current != expected) throw concurrentChange();
    }

    private static ApiException concurrentChange() {
        return new ApiException(ErrorCode.CONFLICT, "The accounting period changed; refresh and retry");
    }

    private static Object[] singleRow(Object value) {
        return value instanceof Object[] row ? row : new Object[]{value};
    }

    private static UUID uuid(Object value) {
        return value == null ? null : value instanceof UUID id ? id : UUID.fromString(value.toString());
    }

    private static String text(Object value) {
        return value == null ? null : value.toString();
    }

    private static Number number(Object value) {
        return (Number) value;
    }

    private static BigDecimal decimal(Object value) {
        return value == null ? BigDecimal.ZERO : (BigDecimal) value;
    }

    private static Instant instant(Object value) {
        if (value == null) return null;
        if (value instanceof Instant instant) return instant;
        if (value instanceof Timestamp timestamp) return timestamp.toInstant();
        return ((java.time.OffsetDateTime) value).toInstant();
    }

    private record PeriodRow(String status, long rowVersion) {}

    private record RunEvidence(
            UUID id,
            String runType,
            BigDecimal totalAmount,
            UUID voucherId,
            int blockingExceptions) {}
}
