package com.uten.imp.features.finance.asset.application;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.core.type.TypeReference;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.common.web.Pageables;
import com.uten.imp.features.finance.asset.api.AssetWorkbenchRequests;
import com.uten.imp.features.finance.asset.api.AssetWorkbenchResponses;
import com.uten.imp.features.finance.asset.domain.AssetPeriod;
import com.uten.imp.features.finance.asset.domain.AssetPostingFingerprint;
import com.uten.imp.features.finance.asset.domain.AssetPostingPolicy;
import com.uten.imp.features.finance.asset.domain.FinanceAssetStateMachine;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.math.RoundingMode;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.sql.Timestamp;
import java.time.Instant;
import java.time.LocalDate;
import java.time.ZoneId;
import java.time.YearMonth;
import java.util.ArrayList;
import java.util.HexFormat;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;

/** Immutable monthly depreciation/amortization runs with preview-token and maker-checker controls. */
@Service
@RequiredArgsConstructor
public class FinanceAssetPostingService {

    private static final String ALGORITHM_VERSION = "STRAIGHT_LINE_V1";
    private static final ZoneId SHANGHAI = ZoneId.of("Asia/Shanghai");

    private final EntityManager em;
    private final TxSessionVars tx;
    private final FinanceAssetAuthorization authorization;
    private final FinanceAssetPeriodService periods;
    private final FinanceAssetLedgerPostingService ledger;
    private final ObjectMapper objectMapper;

    @Transactional
    @PreAuthorize("hasAuthority('finance_asset:post')")
    public AssetWorkbenchResponses.PostingRun preview(AssetWorkbenchRequests.PostingPreviewCommand command) {
        tx.bind();
        UUID actor = authorization.requireActorId(FinanceAssetAuthorization.POST);
        String bookType = command.bookType() == null ? "CORPORATE" : command.bookType();
        AssetPeriod period = AssetPeriod.parse(command.period());
        AssetPostingPolicy.requireCorporateGlBook(bookType);
        requireNormalRunHorizon(command.runType(), bookType, period);
        periods.ensureOpen(command.period(), FinanceAssetAuthorization.POST);

        List<Map<String, Object>> issues = new ArrayList<>();
        String continuity = continuityIssue(command.runType(), bookType, period);
        if (continuity != null) issues.add(issue("PERIOD_GAP", "BLOCKING", continuity, null));
        if ("AMORTIZATION".equals(command.runType())) {
            issues.addAll(deferredBacklogIssues(command.period()));
        }
        issues.addAll(unactivatedIssues(command.runType(), command.period()));

        List<Candidate> candidates = "DEPRECIATION".equals(command.runType())
                ? fixedCandidates(bookType, command.period())
                : deferredCandidates(command.period());
        List<Candidate> snapshotted = new ArrayList<>(candidates.size());
        for (Candidate candidate : candidates) {
            String message = continuity;
            if (message == null && candidate.amount().signum() <= 0) {
                message = "Calculated amount rounds to zero at four-decimal ledger precision; adjust policy";
            }
            if (message == null && candidate.expectedPeriod() != null
                    && !command.period().equals(candidate.expectedPeriod())) {
                message = "Object must post period " + candidate.expectedPeriod() + " before " + command.period();
            }
            if (message == null && !candidate.accountsReady()) {
                message = "Approved account snapshot is incomplete or no longer usable";
            }
            if (message == null) {
                message = postingAccountIssue(candidate);
            }
            if (message != null) {
                issues.add(issue("OBJECT_NOT_READY", "BLOCKING", message, candidate.objectId()));
                snapshotted.add(candidate.skipped(message));
            } else {
                snapshotted.add(candidate);
            }
        }

        String token = UUID.randomUUID().toString() + UUID.randomUUID();
        String fingerprint = fingerprint(command.runType(), bookType, period, snapshotted);
        UUID runId = UUID.randomUUID();
        int itemCount = (int) snapshotted.stream().filter(Candidate::included).count();
        BigDecimal total = snapshotted.stream().filter(Candidate::included)
                .map(Candidate::amount).reduce(BigDecimal.ZERO, BigDecimal::add);
        em.createNativeQuery("""
                INSERT INTO finance_asset_posting_runs
                    (id,run_type,book_type,period,run_kind,status,input_fingerprint,algorithm_version,
                     idempotency_key,preview_token_hash,preview_expires_at,item_count,total_amount,
                     exception_snapshot,created_by,updated_by)
                VALUES (:id,:type,:book,:period,'NORMAL','PREVIEWED',:fingerprint,:algorithm,
                        :idempotency,:tokenHash,now()+interval '15 minutes',:count,:total,
                        CAST(:issues AS jsonb),:actor,:actor)
                """)
                .setParameter("id", runId).setParameter("type", command.runType())
                .setParameter("book", bookType).setParameter("period", command.period())
                .setParameter("fingerprint", fingerprint).setParameter("algorithm", ALGORITHM_VERSION)
                .setParameter("idempotency", "PREVIEW|" + runId).setParameter("tokenHash", hash(token))
                .setParameter("count", itemCount).setParameter("total", total)
                .setParameter("issues", json(issues)).setParameter("actor", actor).executeUpdate();
        int sequence = 0;
        for (Candidate candidate : snapshotted) insertLine(runId, ++sequence, command.period(), candidate, actor);
        event(runId, "POSTING_PREVIEWED", "Posting preview created", command.period(), null, actor);
        return get(runId, token);
    }

    @Transactional
    @PreAuthorize("hasAuthority('finance_asset:post')")
    public AssetWorkbenchResponses.PostingRun submit(UUID runId, AssetWorkbenchRequests.PostingActionCommand command) {
        tx.bind();
        UUID actor = authorization.requireActorId(FinanceAssetAuthorization.POST);
        Run locked = lock(runId);
        FinanceAssetStateMachine.requireRunTransition(locked.status(), "SUBMITTED");
        requireVersion(locked.version(), command.expectedVersion());
        if (command.token() == null || locked.tokenHash() == null || !hash(command.token()).equals(locked.tokenHash())
                || locked.tokenExpiresAt() == null || locked.tokenExpiresAt().isBefore(Instant.now())) {
            throw conflict("Posting preview token is invalid or expired; create a new preview");
        }
        if (blockingIssues(locked.exceptionJson()) > 0) {
            throw conflict("Posting preview has blocking exceptions");
        }
        changed(em.createNativeQuery("""
                UPDATE finance_asset_posting_runs
                SET status='SUBMITTED',submitted_at=now(),submitted_by=:actor,
                    row_version=row_version+1,updated_at=now(),updated_by=:actor
                WHERE id=:id AND status='PREVIEWED' AND row_version=:version AND is_deleted=false
                """).setParameter("actor", actor).setParameter("id", runId)
                .setParameter("version", locked.version()).executeUpdate());
        approval(runId, "SUBMIT", null, actor);
        event(runId, "POSTING_SUBMITTED", "Posting run submitted", locked.period(), null, actor);
        return get(runId, null);
    }

    @Transactional
    @PreAuthorize("hasAuthority('finance_asset:approve')")
    public AssetWorkbenchResponses.PostingRun approve(UUID runId, AssetWorkbenchRequests.ApprovalCommand command) {
        tx.bind();
        UUID actor = authorization.requireActorId(FinanceAssetAuthorization.APPROVE);
        Run locked = lock(runId);
        FinanceAssetStateMachine.requireRunTransition(locked.status(), "APPROVED");
        requireVersion(locked.version(), command.expectedVersion());
        AssetPostingPolicy.requireDifferentActor(actor, locked.submittedBy(), "approve");
        changed(em.createNativeQuery("""
                UPDATE finance_asset_posting_runs
                SET status='APPROVED',approved_at=now(),approved_by=:actor,
                    row_version=row_version+1,updated_at=now(),updated_by=:actor
                WHERE id=:id AND status='SUBMITTED' AND row_version=:version AND is_deleted=false
                """).setParameter("actor", actor).setParameter("id", runId)
                .setParameter("version", locked.version()).executeUpdate());
        approval(runId, "APPROVE", command.comment(), actor);
        event(runId, "POSTING_APPROVED", "Posting run approved", locked.period(), command.comment(), actor);
        return get(runId, null);
    }

    @Transactional
    @PreAuthorize("hasAuthority('finance_asset:post')")
    public AssetWorkbenchResponses.PostingRun post(UUID runId, AssetWorkbenchRequests.PostingActionCommand command) {
        tx.bind();
        UUID actor = authorization.requireActorId(FinanceAssetAuthorization.POST);
        Run locked = lock(runId);
        FinanceAssetStateMachine.requireRunTransition(locked.status(), "POSTED");
        requireVersion(locked.version(), command.expectedVersion());
        AssetPostingPolicy.requireDifferentActor(actor, locked.submittedBy(), "post");
        AssetPostingPolicy.requireCorporateGlBook(locked.bookType());
        periods.ensureOpen(locked.period(), FinanceAssetAuthorization.POST);
        advisoryLock(locked.runType(), locked.bookType(), locked.period());
        if ("NORMAL".equals(locked.runKind())) postNormal(locked, actor); else postReversal(locked, actor);
        return get(runId, null);
    }

    /** Starts, but does not bypass, the approval workflow for an immutable reversal run. */
    @Transactional
    @PreAuthorize("hasAuthority('finance_asset:post')")
    public AssetWorkbenchResponses.PostingRun reverse(UUID originalRunId, AssetWorkbenchRequests.PostingReasonCommand command) {
        tx.bind();
        UUID actor = authorization.requireActorId(FinanceAssetAuthorization.POST);
        Run original = lock(originalRunId);
        requireVersion(original.version(), command.expectedVersion());
        if (!"NORMAL".equals(original.runKind()) || !"POSTED".equals(original.status())) {
            throw conflict("Only an effective posted normal run can be reversed");
        }
        periods.ensureOpen(original.period(), FinanceAssetAuthorization.POST);
        advisoryLock(original.runType(), original.bookType(), original.period());
        Number later = (Number) em.createNativeQuery("""
                SELECT COUNT(*) FROM finance_asset_posting_runs
                WHERE run_type=:type AND book_type=:book AND run_kind='NORMAL' AND status='POSTED'
                  AND period>:period AND is_deleted=false
                """).setParameter("type", original.runType()).setParameter("book", original.bookType())
                .setParameter("period", original.period()).getSingleResult();
        if (later.intValue() > 0) throw conflict("Reverse later effective periods first");
        Number derecognized = (Number) em.createNativeQuery("""
                SELECT (SELECT COUNT(*) FROM finance_asset_posting_lines l
                        JOIN fixed_assets a ON a.id=l.fixed_asset_id
                        WHERE l.run_id=:run AND a.lifecycle_status='DISPOSED')
                     + (SELECT COUNT(*) FROM finance_asset_posting_lines l
                        JOIN deferred_expenses d ON d.id=l.deferred_expense_id
                        WHERE l.run_id=:run AND d.lifecycle_status='TERMINATED')
                """).setParameter("run", originalRunId).getSingleResult();
        if (derecognized.longValue() > 0) {
            throw conflict("Reverse the later disposal or termination workflow before reversing this run");
        }

        UUID reversalId = UUID.randomUUID();
        em.createNativeQuery("""
                INSERT INTO finance_asset_posting_runs
                    (id,run_type,book_type,period,run_kind,status,input_fingerprint,algorithm_version,
                     idempotency_key,item_count,total_amount,exception_snapshot,submitted_at,submitted_by,
                     reversal_of_run_id,reversal_reason,created_by,updated_by)
                SELECT :id,run_type,book_type,period,'REVERSAL','SUBMITTED',
                       encode(digest(input_fingerprint||'|REVERSAL','sha256'),'hex'),algorithm_version,
                       :idempotency,item_count,total_amount,'[]'::jsonb,now(),:actor,id,:reason,:actor,:actor
                FROM finance_asset_posting_runs WHERE id=:original AND status='POSTED'
                """).setParameter("id", reversalId).setParameter("idempotency", "REVERSAL|" + originalRunId)
                .setParameter("actor", actor).setParameter("reason", command.reason().trim())
                .setParameter("original", originalRunId).executeUpdate();
        em.createNativeQuery("""
                INSERT INTO finance_asset_posting_lines
                    (run_id,object_type,fixed_asset_id,deferred_expense_id,asset_book_id,
                     schedule_version_id,schedule_line_id,sequence,line_kind,period,
                     opening_balance,amount,accumulated_amount,closing_balance,
                     cost_style_id,accumulated_style_id,expense_style_id,clearing_style_id,
                     department_id_snapshot,calculation_snapshot,status,message,created_by,updated_by)
                SELECT :reversal,object_type,fixed_asset_id,deferred_expense_id,asset_book_id,
                       schedule_version_id,schedule_line_id,sequence,'REVERSAL',period,
                       closing_balance,amount,GREATEST(accumulated_amount-amount,0),opening_balance,
                       cost_style_id,accumulated_style_id,expense_style_id,clearing_style_id,
                       department_id_snapshot,
                       calculation_snapshot||jsonb_build_object('reversalOfLineId',id),
                       'INCLUDED',:reason,:actor,:actor
                FROM finance_asset_posting_lines
                WHERE run_id=:original AND status='POSTED' AND is_deleted=false
                ORDER BY sequence
                """).setParameter("reversal", reversalId).setParameter("reason", command.reason().trim())
                .setParameter("actor", actor).setParameter("original", originalRunId).executeUpdate();
        approval(reversalId, "SUBMIT", command.reason(), actor);
        event(reversalId, "POSTING_SUBMITTED", "Reversal run submitted", original.period(), command.reason(), actor);
        return get(reversalId, null);
    }

    @Transactional(readOnly = true)
    @PreAuthorize("hasAuthority('finance_asset:view')")
    public AssetWorkbenchResponses.PostingRun get(UUID runId) {
        authorization.require(FinanceAssetAuthorization.VIEW);
        return get(runId, null);
    }

    @Transactional(readOnly = true)
    @PreAuthorize("hasAuthority('finance_asset:view')")
    public PageResponse<AssetWorkbenchResponses.PostingRun> list(
            String period, String runType, String status, int page, int size) {
        authorization.require(FinanceAssetAuthorization.VIEW);
        StringBuilder sql = new StringBuilder("SELECT id FROM finance_asset_posting_runs WHERE is_deleted=false");
        if (period != null && !period.isBlank()) { AssetPeriod.parse(period); sql.append(" AND period=:period"); }
        if (runType != null && !runType.isBlank()) sql.append(" AND run_type=:type");
        if (status != null && !status.isBlank()) sql.append(" AND status=:status");
        sql.append(" ORDER BY created_at DESC");
        var query = em.createNativeQuery(sql.toString());
        if (period != null && !period.isBlank()) query.setParameter("period", period);
        if (runType != null && !runType.isBlank()) query.setParameter("type", runType);
        if (status != null && !status.isBlank()) query.setParameter("status", status);
        @SuppressWarnings("unchecked") List<Object> rows = query.getResultList();
        List<AssetWorkbenchResponses.PostingRun> all = rows.stream()
                .map(FinanceAssetPostingService::uuid).map(id -> get(id, null)).toList();
        var pageable = Pageables.of(page, size);
        int from = Math.min(pageable.getPageNumber() * pageable.getPageSize(), all.size());
        int to = Math.min(from + pageable.getPageSize(), all.size());
        int totalPages = all.isEmpty() ? 0 : (all.size() + pageable.getPageSize() - 1) / pageable.getPageSize();
        return new PageResponse<>(List.copyOf(all.subList(from, to)), page, pageable.getPageSize(), all.size(), totalPages);
    }

    private void postNormal(Run run, UUID actor) {
        requireNormalRunHorizon(run.runType(), run.bookType(), AssetPeriod.parse(run.period()));
        Number duplicate = (Number) em.createNativeQuery("""
                SELECT COUNT(*) FROM finance_asset_posting_runs
                WHERE run_type=:type AND book_type=:book AND period=:period
                  AND run_kind='NORMAL' AND status='POSTED' AND id<>:id AND is_deleted=false
                """).setParameter("type", run.runType()).setParameter("book", run.bookType())
                .setParameter("period", run.period()).setParameter("id", run.id()).getSingleResult();
        if (duplicate.intValue() > 0) throw conflict("An effective run is already posted for this period");
        String continuity = continuityIssue(run.runType(), run.bookType(), AssetPeriod.parse(run.period()));
        if (continuity != null) throw conflict(continuity);
        if (!unactivatedIssues(run.runType(), run.period()).isEmpty()) {
            throw conflict("Approved objects must be activated before posting this period");
        }
        if ("AMORTIZATION".equals(run.runType()) && !deferredBacklogIssues(run.period()).isEmpty()) {
            throw conflict("Earlier deferred-expense schedule periods must be posted first");
        }
        List<Candidate> current = "DEPRECIATION".equals(run.runType())
                ? fixedCandidates(run.bookType(), run.period()) : deferredCandidates(run.period());
        for (Candidate candidate : current) {
            String accountIssue = postingAccountIssue(candidate);
            if (accountIssue != null) throw conflict(accountIssue);
        }
        String currentFingerprint = fingerprint(run.runType(), run.bookType(), AssetPeriod.parse(run.period()), current);
        if (!run.fingerprint().equals(currentFingerprint)) {
            throw conflict("Posting candidate set changed after preview; create and approve a new preview");
        }
        verifySnapshot(run);
        List<PostingFact> facts = facts(run.id());
        List<FinanceAssetLedgerPostingService.Entry> entries = entries(run.runType(), facts);
        UUID voucher = ledger.post(voucherNo(run), run.period(), YearMonth.parse(run.period()).atEndOfMonth(),
                "DEPRECIATION".equals(run.runType()) ? "FA_DEP" : "DA_AMT", run.id(), "POSTING_RUN",
                run.runType() + " " + run.period(), entries);
        for (PostingFact fact : facts) {
            if ("FIXED_ASSET".equals(fact.objectType())) postFixedFact(run, fact, voucher, actor);
            else postDeferredFact(run, fact, voucher, actor);
        }
        finishRun(run, voucher, actor);
    }

    private void postReversal(Run run, UUID actor) {
        Run original = lock(run.reversalOf());
        if (!"POSTED".equals(original.status())) {
            throw conflict("Original posting run is no longer effective");
        }
        Number later = (Number) em.createNativeQuery("""
                SELECT COUNT(*) FROM finance_asset_posting_runs
                WHERE run_type=:type AND book_type=:book AND run_kind='NORMAL' AND status='POSTED'
                  AND period>:period AND is_deleted=false
                """).setParameter("type", original.runType()).setParameter("book", original.bookType())
                .setParameter("period", original.period()).getSingleResult();
        if (later.longValue() > 0) throw conflict("Reverse later effective periods first");
        String objectLockSql = "DEPRECIATION".equals(original.runType()) ? """
                SELECT a.id,a.lifecycle_status FROM finance_asset_posting_lines l
                JOIN fixed_assets a ON a.id=l.fixed_asset_id
                WHERE l.run_id=:run AND l.status='POSTED' AND l.is_deleted=false FOR UPDATE OF a
                """ : """
                SELECT d.id,d.lifecycle_status FROM finance_asset_posting_lines l
                JOIN deferred_expenses d ON d.id=l.deferred_expense_id
                WHERE l.run_id=:run AND l.status='POSTED' AND l.is_deleted=false FOR UPDATE OF d
                """;
        @SuppressWarnings("unchecked") List<Object[]> objectStates = em.createNativeQuery(objectLockSql)
                .setParameter("run",original.id()).getResultList();
        boolean derecognized = objectStates.stream().anyMatch(row ->
                "DISPOSED".equals(text(row[1])) || "TERMINATED".equals(text(row[1])));
        if (derecognized) throw conflict("Reverse the later disposal or termination workflow first");
        List<PostingFact> facts = facts(run.id());
        if (original.voucherId() == null && !facts.isEmpty()) {
            throw conflict("Original non-zero run has no voucher");
        }
        UUID voucher = original.voucherId() == null ? null : ledger.reverse(
                original.voucherId(), voucherNo(run), run.period(), YearMonth.parse(run.period()).atEndOfMonth(),
                "DEPRECIATION".equals(run.runType()) ? "FA_DEP_REV" : "DA_AMT_REV",
                run.id(), "POSTING_RUN", run.reversalReason());
        for (PostingFact fact : facts) {
            if ("FIXED_ASSET".equals(fact.objectType())) reverseFixedFact(run, original, fact, voucher, actor);
            else reverseDeferredFact(run, original, fact, voucher, actor);
        }
        finishRun(run, voucher, actor);
        changed(em.createNativeQuery("""
                UPDATE finance_asset_posting_runs
                SET status='REVERSED',reversed_by_run_id=:reversal,row_version=row_version+1,
                    updated_at=now(),updated_by=:actor
                WHERE id=:original AND status='POSTED'
                """).setParameter("reversal", run.id()).setParameter("actor", actor)
                .setParameter("original", original.id()).executeUpdate());
    }

    private void finishRun(Run run, UUID voucher, UUID actor) {
        em.createNativeQuery("""
                UPDATE finance_asset_posting_lines
                SET status='POSTED',voucher_id=:voucher,updated_at=now(),updated_by=:actor
                WHERE run_id=:run AND status='INCLUDED' AND is_deleted=false
                """).setParameter("voucher", voucher).setParameter("actor", actor)
                .setParameter("run", run.id()).executeUpdate();
        changed(em.createNativeQuery("""
                UPDATE finance_asset_posting_runs
                SET status='POSTED',posted_at=now(),posted_by=:actor,voucher_id=:voucher,
                    row_version=row_version+1,updated_at=now(),updated_by=:actor
                WHERE id=:id AND status='APPROVED' AND row_version=:version AND is_deleted=false
                """).setParameter("actor", actor).setParameter("voucher", voucher)
                .setParameter("id", run.id()).setParameter("version", run.version()).executeUpdate());
        event(run.id(), "POSTED", "Posting run posted", run.period(), null, actor);
    }

    private void verifySnapshot(Run run) {
        if (blockingIssues(run.exceptionJson()) > 0) throw conflict("Posting run contains blocking exceptions");
        String fixedSql = """
                SELECT COUNT(*) FROM finance_asset_posting_lines l
                JOIN finance_asset_books b ON b.id=l.asset_book_id
                JOIN fixed_assets a ON a.id=l.fixed_asset_id
                WHERE l.run_id=:run AND l.object_type='FIXED_ASSET' AND l.status='INCLUDED'
                  AND (b.row_version<>(l.calculation_snapshot->>'rowVersion')::bigint
                    OR b.net_book_value<>l.opening_balance
                    OR b.cost_style_id IS DISTINCT FROM l.cost_style_id
                    OR b.expense_style_id IS DISTINCT FROM l.expense_style_id
                    OR b.accumulated_style_id IS DISTINCT FROM l.accumulated_style_id
                    OR b.clearing_style_id IS DISTINCT FROM l.clearing_style_id
                    OR b.status<>'ACTIVE' OR b.is_deleted OR a.is_deleted
                    OR a.lifecycle_status NOT IN ('ACTIVE','DISPOSAL_PENDING'))
                """;
        String deferredSql = """
                SELECT COUNT(*) FROM finance_asset_posting_lines l
                JOIN finance_deferral_schedule_lines sl ON sl.id=l.schedule_line_id
                JOIN finance_deferral_schedule_versions sv ON sv.id=l.schedule_version_id
                JOIN deferred_expenses d ON d.id=l.deferred_expense_id
                WHERE l.run_id=:run AND l.object_type='DEFERRED_EXPENSE' AND l.status='INCLUDED'
                  AND (sl.opening_balance<>l.opening_balance OR sl.amount<>l.amount
                    OR sl.closing_balance<>l.closing_balance OR sv.status<>'APPROVED'
                    OR sv.cost_style_id IS DISTINCT FROM l.cost_style_id
                    OR sv.expense_style_id IS DISTINCT FROM l.expense_style_id
                    OR sv.clearing_style_id IS DISTINCT FROM l.clearing_style_id
                    OR sl.is_deleted OR sv.is_deleted OR d.is_deleted
                    OR d.lifecycle_status NOT IN ('ACTIVE','TERMINATION_PENDING'))
                """;
        int changed = ((Number) em.createNativeQuery(fixedSql).setParameter("run", run.id()).getSingleResult()).intValue()
                + ((Number) em.createNativeQuery(deferredSql).setParameter("run", run.id()).getSingleResult()).intValue();
        if (changed > 0) throw conflict("Asset inputs changed after preview; create and approve a new preview");
    }

    private List<Candidate> fixedCandidates(String bookType, String period) {
        @SuppressWarnings("unchecked") List<Object[]> rows = em.createNativeQuery("""
                SELECT a.id,b.id,a.code,a.name,b.original_value,b.accumulated_amount,b.net_book_value,
                       b.depreciable_amount,b.useful_months,b.start_period,b.expense_style_id,
                       b.accumulated_style_id,b.cost_style_id,b.clearing_style_id,a.department_id,b.row_version,
                       COALESCE((SELECT to_char((to_date(max(l.period),'YYYY-MM')+interval '1 month'),'YYYY-MM')
                                 FROM fa_depreciation_log l
                                 WHERE l.asset_id=a.id AND l.asset_book_id=b.id AND l.entry_kind='NORMAL'
                                   AND l.status='ACTIVE' AND l.is_deleted=false),b.start_period)
                FROM finance_asset_books b JOIN fixed_assets a ON a.id=b.asset_id
                WHERE b.book_type=:book AND b.status='ACTIVE' AND b.posting_enabled=true
                  AND b.start_period<=:period
                  AND :period <= to_char(to_date(b.start_period,'YYYY-MM') + interval '1 month'*(b.useful_months-1), 'YYYY-MM')
                  AND b.accumulated_amount<b.depreciable_amount
                  AND a.lifecycle_status IN ('ACTIVE','DISPOSAL_PENDING')
                  AND b.is_deleted=false AND a.is_deleted=false
                  AND NOT EXISTS (SELECT 1 FROM fa_depreciation_log l WHERE l.asset_id=a.id
                    AND l.asset_book_id=b.id AND l.period=:period AND l.entry_kind='NORMAL'
                    AND l.status='ACTIVE' AND l.is_deleted=false)
                ORDER BY a.code,a.id
                """).setParameter("book", bookType).setParameter("period", period).getResultList();
        List<Candidate> result = new ArrayList<>(rows.size());
        for (Object[] r : rows) {
            BigDecimal original = decimal(r[4]), accumulated = decimal(r[5]), opening = decimal(r[6]);
            BigDecimal depreciable = decimal(r[7]);
            long usefulMonths = number(r[8]).longValue();
            BigDecimal remaining = depreciable.subtract(accumulated);
            BigDecimal regular = depreciable.divide(BigDecimal.valueOf(usefulMonths), 4, RoundingMode.HALF_UP);
            String finalPeriod = YearMonth.parse(text(r[9])).plusMonths(usefulMonths - 1L).toString();
            BigDecimal amount = (period.equals(finalPeriod) ? remaining : regular.min(remaining))
                    .setScale(4, RoundingMode.HALF_UP);
            result.add(new Candidate("FIXED_ASSET", uuid(r[0]), uuid(r[1]), null, null, text(r[2]), text(r[3]),
                    original, opening, amount, accumulated.add(amount), opening.subtract(amount),
                    uuid(r[12]), uuid(r[11]), uuid(r[10]), uuid(r[13]), uuid(r[14]),
                    number(r[15]).longValue(), text(r[16]), true, null));
        }
        return result;
    }

    private List<Candidate> deferredCandidates(String period) {
        @SuppressWarnings("unchecked") List<Object[]> rows = em.createNativeQuery("""
                SELECT d.id,sv.id,sl.id,d.code,d.name,sv.total_amount,sl.opening_balance,sl.amount,
                       sl.accumulated_amount,sl.closing_balance,sv.cost_style_id,sv.expense_style_id,
                       sv.clearing_style_id,d.department_id,sv.row_version,
                       (SELECT min(pending.period)
                        FROM finance_deferral_schedule_lines pending
                        WHERE pending.schedule_version_id=sv.id AND pending.is_deleted=false
                          AND NOT EXISTS (SELECT 1 FROM da_amortization_log done
                              WHERE done.schedule_line_id=pending.id AND done.entry_kind='NORMAL'
                                AND done.status='ACTIVE' AND done.is_deleted=false))
                FROM finance_deferral_schedule_lines sl
                JOIN finance_deferral_schedule_versions sv ON sv.id=sl.schedule_version_id
                JOIN deferred_expenses d ON d.id=sv.deferred_id
                WHERE sl.period=:period AND sv.status='APPROVED'
                  AND d.lifecycle_status IN ('ACTIVE','TERMINATION_PENDING')
                  AND sl.is_deleted=false AND sv.is_deleted=false AND d.is_deleted=false
                  AND NOT EXISTS (SELECT 1 FROM da_amortization_log l WHERE l.deferred_id=d.id
                    AND l.schedule_version_id=sv.id AND l.period=:period AND l.entry_kind='NORMAL'
                    AND l.status='ACTIVE' AND l.is_deleted=false)
                ORDER BY d.code,d.id
                """).setParameter("period", period).getResultList();
        List<Candidate> result = new ArrayList<>(rows.size());
        for (Object[] r : rows) result.add(new Candidate("DEFERRED_EXPENSE", uuid(r[0]), null, uuid(r[1]), uuid(r[2]),
                text(r[3]), text(r[4]), decimal(r[5]), decimal(r[6]), decimal(r[7]), decimal(r[8]), decimal(r[9]),
                uuid(r[10]), null, uuid(r[11]), uuid(r[12]), uuid(r[13]), number(r[14]).longValue(), text(r[15]), true, null));
        return result;
    }

    private List<Map<String, Object>> deferredBacklogIssues(String period) {
        @SuppressWarnings("unchecked") List<Object[]> rows = em.createNativeQuery("""
                SELECT d.id,min(sl.period)
                FROM deferred_expenses d
                JOIN finance_deferral_schedule_versions sv ON sv.deferred_id=d.id AND sv.status='APPROVED' AND sv.is_deleted=false
                JOIN finance_deferral_schedule_lines sl ON sl.schedule_version_id=sv.id AND sl.is_deleted=false
                WHERE d.lifecycle_status IN ('ACTIVE','TERMINATION_PENDING') AND d.is_deleted=false
                  AND sl.period<:period
                  AND NOT EXISTS (SELECT 1 FROM da_amortization_log done
                      WHERE done.schedule_line_id=sl.id AND done.entry_kind='NORMAL'
                        AND done.status='ACTIVE' AND done.is_deleted=false)
                GROUP BY d.id
                """).setParameter("period",period).getResultList();
        return rows.stream().map(row -> issue("PERIOD_GAP","BLOCKING",
                "Deferred expense must post period "+text(row[1])+" first",uuid(row[0]))).toList();
    }

    private List<Map<String, Object>> unactivatedIssues(String runType, String period) {
        String sql = "DEPRECIATION".equals(runType) ? """
                SELECT a.id FROM fixed_assets a JOIN finance_asset_books b ON b.asset_id=a.id
                WHERE a.lifecycle_status='APPROVED' AND a.is_deleted=false
                  AND b.book_type='CORPORATE' AND b.status='DRAFT' AND b.start_period<=:period AND b.is_deleted=false
                """ : """
                SELECT d.id FROM deferred_expenses d JOIN finance_deferral_schedule_versions sv ON sv.deferred_id=d.id
                WHERE d.lifecycle_status='APPROVED' AND d.is_deleted=false
                  AND sv.status='APPROVED' AND sv.start_period<=:period AND sv.is_deleted=false
                """;
        @SuppressWarnings("unchecked") List<Object> rows=em.createNativeQuery(sql).setParameter("period",period).getResultList();
        return rows.stream().map(FinanceAssetPostingService::uuid)
                .map(id -> issue("APPROVED_NOT_ACTIVATED","BLOCKING",
                        "Approved object must be activated before this period can post",id)).toList();
    }

    private void insertLine(UUID run, int sequence, String period, Candidate c, UUID actor) {
        em.createNativeQuery("""
                INSERT INTO finance_asset_posting_lines
                    (run_id,object_type,fixed_asset_id,deferred_expense_id,asset_book_id,
                     schedule_version_id,schedule_line_id,sequence,line_kind,period,
                     opening_balance,amount,accumulated_amount,closing_balance,
                     cost_style_id,accumulated_style_id,expense_style_id,clearing_style_id,
                     department_id_snapshot,calculation_snapshot,status,message,created_by,updated_by)
                VALUES (:run,:objectType,:fixed,:deferred,:book,:scheduleVersion,:scheduleLine,:sequence,
                        'NORMAL',:period,:opening,:amount,:accumulated,:closing,:cost,:accumulatedStyle,
                        :expense,:clearing,:department,CAST(:snapshot AS jsonb),:status,:message,:actor,:actor)
                """).setParameter("run", run).setParameter("objectType", c.objectType())
                .setParameter("fixed", "FIXED_ASSET".equals(c.objectType()) ? c.objectId() : null)
                .setParameter("deferred", "DEFERRED_EXPENSE".equals(c.objectType()) ? c.objectId() : null)
                .setParameter("book", c.bookId()).setParameter("scheduleVersion", c.scheduleVersionId())
                .setParameter("scheduleLine", c.scheduleLineId()).setParameter("sequence", sequence)
                .setParameter("period", period).setParameter("opening", c.opening()).setParameter("amount", c.amount())
                .setParameter("accumulated", c.accumulatedAfter()).setParameter("closing", c.closing())
                .setParameter("cost", c.costStyle()).setParameter("accumulatedStyle", c.accumulatedStyle())
                .setParameter("expense", c.expenseStyle()).setParameter("clearing", c.clearingStyle())
                .setParameter("department", c.departmentId())
                .setParameter("snapshot", json(Map.of("rowVersion", c.rowVersion(), "algorithm", ALGORITHM_VERSION)))
                .setParameter("status", c.included() ? "INCLUDED" : "SKIPPED")
                .setParameter("message", c.message()).setParameter("actor", actor).executeUpdate();
    }

    private List<PostingFact> facts(UUID runId) {
        @SuppressWarnings("unchecked") List<Object[]> rows = em.createNativeQuery("""
                SELECT id,object_type,fixed_asset_id,deferred_expense_id,asset_book_id,
                       schedule_version_id,schedule_line_id,sequence,opening_balance,amount,
                       accumulated_amount,closing_balance,cost_style_id,accumulated_style_id,
                       expense_style_id,calculation_snapshot::text
                FROM finance_asset_posting_lines
                WHERE run_id=:run AND status='INCLUDED' AND is_deleted=false ORDER BY sequence
                """).setParameter("run", runId).getResultList();
        List<PostingFact> result = new ArrayList<>(rows.size());
        for (Object[] r : rows) result.add(new PostingFact(uuid(r[0]),text(r[1]),uuid(r[2]),uuid(r[3]),uuid(r[4]),
                uuid(r[5]),uuid(r[6]),number(r[7]).intValue(),decimal(r[8]),decimal(r[9]),decimal(r[10]),
                decimal(r[11]),uuid(r[12]),uuid(r[13]),uuid(r[14]),text(r[15])));
        return result;
    }

    private List<FinanceAssetLedgerPostingService.Entry> entries(String runType, List<PostingFact> facts) {
        List<FinanceAssetLedgerPostingService.Entry> result = new ArrayList<>(facts.size() * 2);
        for (PostingFact fact : facts) {
            UUID objectId = fact.fixedId() == null ? fact.deferredId() : fact.fixedId();
            String summary = runType + " " + objectId;
            result.add(new FinanceAssetLedgerPostingService.Entry(fact.expenseStyle(), 1, fact.amount(), summary));
            result.add(new FinanceAssetLedgerPostingService.Entry(
                    "DEPRECIATION".equals(runType) ? fact.accumulatedStyle() : fact.costStyle(), -1,
                    fact.amount(), summary));
        }
        return result;
    }

    private void postFixedFact(Run run, PostingFact fact, UUID voucher, UUID actor) {
        em.createNativeQuery("""
                INSERT INTO fa_depreciation_log
                    (asset_id,period,amount,voucher_id,asset_book_id,posting_run_id,posting_line_id,
                     sequence,opening_balance,accumulated_amount,closing_balance,entry_kind,status,
                     calculation_snapshot,created_by,updated_by)
                VALUES (:asset,:period,:amount,:voucher,:book,:run,:line,:sequence,:opening,:accumulated,
                        :closing,'NORMAL','ACTIVE',CAST(:snapshot AS jsonb),:actor,:actor)
                """).setParameter("asset", fact.fixedId()).setParameter("period", run.period())
                .setParameter("amount", fact.amount()).setParameter("voucher", voucher).setParameter("book", fact.bookId())
                .setParameter("run", run.id()).setParameter("line", fact.lineId()).setParameter("sequence", fact.sequence())
                .setParameter("opening", fact.opening()).setParameter("accumulated", fact.accumulated())
                .setParameter("closing", fact.closing()).setParameter("snapshot", fact.snapshot())
                .setParameter("actor", actor).executeUpdate();
        changed(em.createNativeQuery("""
                UPDATE finance_asset_books
                SET accumulated_amount=:accumulated,net_book_value=:closing,
                    status=CASE WHEN :closing=residual_amount THEN 'FULLY_DEPRECIATED' ELSE status END,
                    row_version=row_version+1,updated_at=now(),updated_by=:actor
                WHERE id=:book AND status='ACTIVE' AND net_book_value=:opening AND is_deleted=false
                """).setParameter("accumulated", fact.accumulated()).setParameter("closing", fact.closing())
                .setParameter("actor", actor).setParameter("book", fact.bookId())
                .setParameter("opening", fact.opening()).executeUpdate());
    }

    private void postDeferredFact(Run run, PostingFact fact, UUID voucher, UUID actor) {
        em.createNativeQuery("""
                INSERT INTO da_amortization_log
                    (deferred_id,period,amount,voucher_id,schedule_version_id,schedule_line_id,
                     posting_run_id,posting_line_id,sequence,opening_balance,accumulated_amount,
                     closing_balance,entry_kind,status,calculation_snapshot,created_by,updated_by)
                VALUES (:deferred,:period,:amount,:voucher,:version,:scheduleLine,:run,:line,:sequence,
                        :opening,:accumulated,:closing,'NORMAL','ACTIVE',CAST(:snapshot AS jsonb),:actor,:actor)
                """).setParameter("deferred", fact.deferredId()).setParameter("period", run.period())
                .setParameter("amount", fact.amount()).setParameter("voucher", voucher)
                .setParameter("version", fact.scheduleVersionId()).setParameter("scheduleLine", fact.scheduleLineId())
                .setParameter("run", run.id()).setParameter("line", fact.lineId()).setParameter("sequence", fact.sequence())
                .setParameter("opening", fact.opening()).setParameter("accumulated", fact.accumulated())
                .setParameter("closing", fact.closing()).setParameter("snapshot", fact.snapshot())
                .setParameter("actor", actor).executeUpdate();
        if (fact.closing().signum() == 0) {
            em.createNativeQuery("""
                    UPDATE deferred_expenses SET lifecycle_status='COMPLETED',completed_on=:date,
                        row_version=row_version+1,updated_at=now(),updated_by=:actor
                    WHERE id=:id AND lifecycle_status='ACTIVE'
                    """).setParameter("date", YearMonth.parse(run.period()).atEndOfMonth())
                    .setParameter("actor", actor).setParameter("id", fact.deferredId()).executeUpdate();
        }
    }

    private void reverseFixedFact(Run run, Run original, PostingFact fact, UUID voucher, UUID actor) {
        Object[] old = single(em.createNativeQuery("""
                SELECT id,calculation_snapshot::text FROM fa_depreciation_log
                WHERE posting_run_id=:run AND asset_id=:asset AND status='ACTIVE' AND is_deleted=false FOR UPDATE
                """).setParameter("run", original.id()).setParameter("asset", fact.fixedId()).getSingleResult());
        UUID logId = UUID.randomUUID();
        em.createNativeQuery("""
                INSERT INTO fa_depreciation_log
                    (id,asset_id,period,amount,voucher_id,asset_book_id,posting_run_id,posting_line_id,
                     sequence,opening_balance,accumulated_amount,closing_balance,entry_kind,status,
                     reversal_of_log_id,calculation_snapshot,created_by,updated_by)
                VALUES (:id,:asset,:period,:amount,:voucher,:book,:run,:line,:sequence,:opening,:accumulated,
                        :closing,'REVERSAL','ACTIVE',:original,CAST(:snapshot AS jsonb),:actor,:actor)
                """).setParameter("id", logId).setParameter("asset", fact.fixedId()).setParameter("period", run.period())
                .setParameter("amount", fact.amount()).setParameter("voucher", voucher).setParameter("book", fact.bookId())
                .setParameter("run", run.id()).setParameter("line", fact.lineId()).setParameter("sequence", fact.sequence())
                .setParameter("opening", fact.opening()).setParameter("accumulated", fact.accumulated())
                .setParameter("closing", fact.closing()).setParameter("original", uuid(old[0]))
                .setParameter("snapshot", fact.snapshot()).setParameter("actor", actor).executeUpdate();
        changed(em.createNativeQuery("UPDATE fa_depreciation_log SET status='REVERSED',reversed_by_log_id=:new,updated_at=now(),updated_by=:actor WHERE id=:old AND status='ACTIVE'")
                .setParameter("new", logId).setParameter("actor", actor).setParameter("old", uuid(old[0])).executeUpdate());
        changed(em.createNativeQuery("""
                UPDATE finance_asset_books SET accumulated_amount=accumulated_amount-:amount,
                    net_book_value=net_book_value+:amount,status='ACTIVE',row_version=row_version+1,
                    updated_at=now(),updated_by=:actor
                WHERE id=:book AND accumulated_amount>=:amount AND is_deleted=false
                """).setParameter("amount", fact.amount()).setParameter("actor", actor)
                .setParameter("book", fact.bookId()).executeUpdate());
    }

    private void reverseDeferredFact(Run run, Run original, PostingFact fact, UUID voucher, UUID actor) {
        Object[] old = single(em.createNativeQuery("""
                SELECT id,calculation_snapshot::text FROM da_amortization_log
                WHERE posting_run_id=:run AND deferred_id=:deferred AND status='ACTIVE' AND is_deleted=false FOR UPDATE
                """).setParameter("run", original.id()).setParameter("deferred", fact.deferredId()).getSingleResult());
        UUID logId = UUID.randomUUID();
        em.createNativeQuery("""
                INSERT INTO da_amortization_log
                    (id,deferred_id,period,amount,voucher_id,schedule_version_id,schedule_line_id,
                     posting_run_id,posting_line_id,sequence,opening_balance,accumulated_amount,
                     closing_balance,entry_kind,status,reversal_of_log_id,calculation_snapshot,created_by,updated_by)
                VALUES (:id,:deferred,:period,:amount,:voucher,:version,:scheduleLine,:run,:line,:sequence,
                        :opening,:accumulated,:closing,'REVERSAL','ACTIVE',:original,CAST(:snapshot AS jsonb),:actor,:actor)
                """).setParameter("id", logId).setParameter("deferred", fact.deferredId())
                .setParameter("period", run.period()).setParameter("amount", fact.amount()).setParameter("voucher", voucher)
                .setParameter("version", fact.scheduleVersionId()).setParameter("scheduleLine", fact.scheduleLineId())
                .setParameter("run", run.id()).setParameter("line", fact.lineId()).setParameter("sequence", fact.sequence())
                .setParameter("opening", fact.opening()).setParameter("accumulated", fact.accumulated())
                .setParameter("closing", fact.closing()).setParameter("original", uuid(old[0]))
                .setParameter("snapshot", fact.snapshot()).setParameter("actor", actor).executeUpdate();
        changed(em.createNativeQuery("UPDATE da_amortization_log SET status='REVERSED',reversed_by_log_id=:new,updated_at=now(),updated_by=:actor WHERE id=:old AND status='ACTIVE'")
                .setParameter("new", logId).setParameter("actor", actor).setParameter("old", uuid(old[0])).executeUpdate());
        em.createNativeQuery("""
                UPDATE deferred_expenses SET lifecycle_status='ACTIVE',completed_on=NULL,
                    row_version=row_version+1,updated_at=now(),updated_by=:actor
                WHERE id=:id AND lifecycle_status='COMPLETED'
                """).setParameter("actor", actor).setParameter("id", fact.deferredId()).executeUpdate();
    }

    private AssetWorkbenchResponses.PostingRun get(UUID id, String token) {
        @SuppressWarnings("unchecked") List<Object[]> rows = em.createNativeQuery("""
                SELECT r.id,r.run_type,r.book_type,r.period,r.run_kind,r.status,r.item_count,r.total_amount,
                       r.exception_snapshot::text,v.voucher_no,r.reversal_of_run_id,r.row_version,r.created_at,
                       r.input_fingerprint,r.preview_token_hash,r.preview_expires_at,r.submitted_by,r.voucher_id,
                       r.reversal_reason
                FROM finance_asset_posting_runs r LEFT JOIN gl_vouchers v ON v.id=r.voucher_id
                WHERE r.id=:id AND r.is_deleted=false
                """).setParameter("id", id).getResultList();
        if (rows.isEmpty()) throw new ApiException(ErrorCode.NOT_FOUND, "Posting run not found");
        Object[] r = rows.getFirst();
        List<AssetWorkbenchResponses.PostingLine> lines = lineResponses(id);
        String status = text(r[5]);
        boolean separatedFromMaker = !authorization.isCurrentActor(uuid(r[16]));
        Set<String> actions = switch (status) {
            case "PREVIEWED" -> authorization.has(FinanceAssetAuthorization.POST) ? Set.of("SUBMIT") : Set.of();
            case "SUBMITTED" -> authorization.has(FinanceAssetAuthorization.APPROVE) && separatedFromMaker ? Set.of("APPROVE") : Set.of();
            case "APPROVED" -> authorization.has(FinanceAssetAuthorization.POST) && separatedFromMaker ? Set.of("POST") : Set.of();
            case "POSTED" -> authorization.has(FinanceAssetAuthorization.POST) && "NORMAL".equals(text(r[4]))
                    ? Set.of("REVERSE") : Set.of();
            default -> Set.of();
        };
        return new AssetWorkbenchResponses.PostingRun(uuid(r[0]),text(r[1]),text(r[2]),text(r[3]),status,token,
                number(r[6]).intValue(),decimal(r[7]),exceptionsForResponse(text(r[8])),lines,text(r[9]),uuid(r[10]),
                number(r[11]).longValue(),instant(r[12]),actions);
    }

    private List<AssetWorkbenchResponses.PostingLine> lineResponses(UUID runId) {
        @SuppressWarnings("unchecked") List<Object[]> rows = em.createNativeQuery("""
                SELECT l.id,COALESCE(l.fixed_asset_id,l.deferred_expense_id),l.object_type,
                       COALESCE(a.code,d.code),COALESCE(a.name,d.name),l.opening_balance,l.amount,
                       l.closing_balance,l.status,l.message
                FROM finance_asset_posting_lines l
                LEFT JOIN fixed_assets a ON a.id=l.fixed_asset_id
                LEFT JOIN deferred_expenses d ON d.id=l.deferred_expense_id
                WHERE l.run_id=:run AND l.is_deleted=false ORDER BY l.sequence
                """).setParameter("run", runId).getResultList();
        List<AssetWorkbenchResponses.PostingLine> result = new ArrayList<>(rows.size());
        for (Object[] r : rows) result.add(new AssetWorkbenchResponses.PostingLine(uuid(r[0]),uuid(r[1]),text(r[2]),
                text(r[3]),text(r[4]),decimal(r[5]),decimal(r[6]),decimal(r[7]),text(r[8]),text(r[9])));
        return List.copyOf(result);
    }

    private Run lock(UUID id) {
        @SuppressWarnings("unchecked") List<Object[]> rows = em.createNativeQuery("""
                SELECT id,run_type,book_type,period,run_kind,status,input_fingerprint,preview_token_hash,
                       preview_expires_at,exception_snapshot::text,submitted_by,voucher_id,reversal_of_run_id,
                       reversal_reason,row_version
                FROM finance_asset_posting_runs WHERE id=:id AND is_deleted=false FOR UPDATE
                """).setParameter("id", id).getResultList();
        if (rows.isEmpty()) throw new ApiException(ErrorCode.NOT_FOUND, "Posting run not found");
        Object[] r = rows.getFirst();
        return new Run(uuid(r[0]),text(r[1]),text(r[2]),text(r[3]),text(r[4]),text(r[5]),text(r[6]),text(r[7]),
                instant(r[8]),text(r[9]),uuid(r[10]),uuid(r[11]),uuid(r[12]),text(r[13]),number(r[14]).longValue());
    }

    private String continuityIssue(String runType, String bookType, AssetPeriod requested) {
        @SuppressWarnings("unchecked") List<Object> rows = em.createNativeQuery("""
                SELECT period FROM finance_asset_posting_runs
                WHERE run_type=:type AND book_type=:book AND run_kind='NORMAL'
                  AND status='POSTED' AND is_deleted=false ORDER BY period DESC LIMIT 1
                """).setParameter("type", runType).setParameter("book", bookType).getResultList();
        if (rows.isEmpty()) {
            AssetPeriod cutover = new AssetPeriod(YearMonth.now(SHANGHAI));
            return cutover.equals(requested) ? null : "First posting period must be current cutover period " + cutover;
        }
        AssetPeriod expected = AssetPeriod.parse(text(rows.getFirst())).next();
        return expected.equals(requested) ? null : "Next posting period must be " + expected;
    }

    private void requireNormalRunHorizon(String runType, String bookType, AssetPeriod requested) {
        AssetPeriod current = new AssetPeriod(YearMonth.now(SHANGHAI));
        if (requested.value().isAfter(current.value())) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED,
                    "Posting period cannot be later than current Shanghai period " + current);
        }
        Number posted = (Number) em.createNativeQuery("""
                SELECT COUNT(*) FROM finance_asset_posting_runs
                WHERE run_type=:type AND book_type=:book AND run_kind='NORMAL'
                  AND status='POSTED' AND is_deleted=false
                """).setParameter("type", runType).setParameter("book", bookType).getSingleResult();
        if (posted.longValue() == 0 && !requested.equals(current)) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED,
                    "First posting period must be current cutover period " + current);
        }
    }

    private String fingerprint(String type, String book, AssetPeriod period, List<Candidate> candidates) {
        List<AssetPostingFingerprint.Input> inputs = candidates.stream().map(c -> new AssetPostingFingerprint.Input(
                c.objectId(), c.bookId() == null ? c.scheduleVersionId() : c.bookId(), c.original(),
                c.accumulatedAfter().subtract(c.amount()), c.amount(), c.expenseStyle(),
                "FIXED_ASSET".equals(c.objectType()) ? c.accumulatedStyle() : c.costStyle(),
                c.departmentId(), c.rowVersion())).toList();
        return AssetPostingFingerprint.calculate(type, book, period, inputs);
    }

    private void advisoryLock(String type, String book, String period) {
        em.createNativeQuery("SELECT pg_advisory_xact_lock(hashtextextended(:key,0))")
                .setParameter("key", "FINANCE_ASSET_RUN|" + type + "|" + book).getSingleResult();
    }

    private String postingAccountIssue(Candidate candidate) {
        if (!candidate.accountsReady()) {
            return "Approved account snapshot is incomplete";
        }
        List<UUID> accountIds = "FIXED_ASSET".equals(candidate.objectType())
                ? List.of(candidate.costStyle(), candidate.accumulatedStyle(),
                        candidate.expenseStyle(), candidate.clearingStyle())
                : List.of(candidate.costStyle(), candidate.expenseStyle(), candidate.clearingStyle());
        if (accountIds.stream().distinct().count() != accountIds.size()) {
            return "Approved cost, accumulated depreciation, expense and clearing accounts must be distinct";
        }
        if (!postableStyle(candidate.costStyle(), "ACCOUNT")) {
            return "Approved cost account is not an active postable ACCOUNT leaf";
        }
        if (candidate.accumulatedStyle() != null && !postableStyle(candidate.accumulatedStyle(), "ACCOUNT")) {
            return "Approved accumulated depreciation account is not an active postable ACCOUNT leaf";
        }
        if (!postableStyle(candidate.expenseStyle(), "EXPENSE")) {
            return "Approved expense account is not an active postable EXPENSE leaf";
        }
        if (!postableStyle(candidate.clearingStyle(), "ACCOUNT")) {
            return "Approved clearing account is not an active postable ACCOUNT leaf";
        }
        return null;
    }

    private boolean postableStyle(UUID id, String expectedCategory) {
        Number count = (Number) em.createNativeQuery("""
                SELECT COUNT(*) FROM payment_styles s
                WHERE s.id=:id AND s.is_deleted=false AND s.status='使用' AND s.category=:category
                  AND NOT EXISTS (
                      SELECT 1 FROM payment_styles child
                      WHERE child.parent_id=s.id AND child.is_deleted=false AND child.status='使用')
                """).setParameter("id", id).setParameter("category", expectedCategory).getSingleResult();
        return count.longValue() == 1;
    }

    private void approval(UUID id, String action, String comment, UUID actor) {
        Number step = (Number) em.createNativeQuery("SELECT COALESCE(MAX(step_no),0)+1 FROM finance_asset_approval_steps WHERE object_type='POSTING_RUN' AND object_id=:id AND workflow_type='POSTING'")
                .setParameter("id", id).getSingleResult();
        em.createNativeQuery("INSERT INTO finance_asset_approval_steps(object_type,object_id,workflow_type,step_no,action,status,actor_user_id,comment,created_by,updated_by) VALUES('POSTING_RUN',:id,'POSTING',:step,:action,'RECORDED',:actor,:comment,:actor,:actor)")
                .setParameter("id", id).setParameter("step", step.intValue()).setParameter("action", action)
                .setParameter("actor", actor).setParameter("comment", comment).executeUpdate();
    }

    private void event(UUID id, String type, String title, String period, String description, UUID actor) {
        em.createNativeQuery("""
                INSERT INTO finance_asset_events(object_type,object_id,event_type,title,description,effective_date,
                    payload,actor_user_id,created_by,updated_by)
                VALUES('POSTING_RUN',:id,:type,:title,:description,:date,'{}'::jsonb,:actor,:actor,:actor)
                """).setParameter("id", id).setParameter("type", type).setParameter("title", title)
                .setParameter("description", description).setParameter("date", YearMonth.parse(period).atEndOfMonth())
                .setParameter("actor", actor).executeUpdate();
    }

    private List<Map<String, Object>> exceptions(String value) {
        try { return objectMapper.readValue(value, new TypeReference<>() {}); }
        catch (JsonProcessingException exception) { throw new ApiException(ErrorCode.INTERNAL, "Invalid posting exception snapshot"); }
    }

    private int blockingIssues(String value) {
        return (int) exceptions(value).stream().filter(issue -> "BLOCKING".equals(issue.get("severity"))).count();
    }

    private List<AssetWorkbenchResponses.PostingException> exceptionsForResponse(String value) {
        return exceptions(value).stream().map(issue -> new AssetWorkbenchResponses.PostingException(
                text(issue.get("code")),text(issue.get("severity")),text(issue.get("message")),uuid(issue.get("objectId")))).toList();
    }

    private static Map<String, Object> issue(String code, String severity, String message, UUID objectId) {
        Map<String, Object> value = new LinkedHashMap<>();
        value.put("code", code); value.put("severity", severity); value.put("message", message);
        if (objectId != null) value.put("objectId", objectId.toString());
        return value;
    }

    private String json(Object value) {
        try { return objectMapper.writeValueAsString(value); }
        catch (JsonProcessingException exception) { throw new ApiException(ErrorCode.INTERNAL, "Unable to serialize posting snapshot"); }
    }

    private static String hash(String value) {
        try { return HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(value.getBytes(StandardCharsets.UTF_8))); }
        catch (NoSuchAlgorithmException exception) { throw new IllegalStateException("SHA-256 is unavailable", exception); }
    }

    private static String voucherNo(Run run) {
        return "AS-" + ("DEPRECIATION".equals(run.runType()) ? "DEP" : "AMT") + "-"
                + run.period() + "-" + run.id().toString().substring(0, 8);
    }

    private static void requireVersion(long actual, Long expected) {
        if (expected == null || actual != expected) throw conflict("Posting run changed; refresh and retry");
    }

    private static void changed(int count) { if (count != 1) throw conflict("Concurrent posting change; refresh and retry"); }
    private static ApiException conflict(String message) { return new ApiException(ErrorCode.CONFLICT, message); }
    private static Object[] single(Object value) { return value instanceof Object[] row ? row : new Object[]{value}; }
    private static UUID uuid(Object value) { return value == null ? null : value instanceof UUID id ? id : UUID.fromString(value.toString()); }
    private static String text(Object value) { return value == null ? null : value.toString(); }
    private static Number number(Object value) { return (Number) value; }
    private static BigDecimal decimal(Object value) { return value == null ? BigDecimal.ZERO : (BigDecimal) value; }
    private static Instant instant(Object value) {
        if (value == null) return null;
        if (value instanceof Instant instant) return instant;
        if (value instanceof Timestamp timestamp) return timestamp.toInstant();
        return ((java.time.OffsetDateTime) value).toInstant();
    }

    private record Candidate(String objectType, UUID objectId, UUID bookId, UUID scheduleVersionId,
                             UUID scheduleLineId, String code, String name, BigDecimal original,
                             BigDecimal opening, BigDecimal amount, BigDecimal accumulatedAfter,
                             BigDecimal closing, UUID costStyle, UUID accumulatedStyle, UUID expenseStyle,
                             UUID clearingStyle, UUID departmentId, long rowVersion, String expectedPeriod,
                             boolean included, String message) {
        boolean accountsReady() {
            return costStyle != null && expenseStyle != null && clearingStyle != null
                    && (!"FIXED_ASSET".equals(objectType) || accumulatedStyle != null);
        }
        Candidate skipped(String reason) {
            return new Candidate(objectType,objectId,bookId,scheduleVersionId,scheduleLineId,code,name,original,
                    opening,BigDecimal.ZERO,accumulatedAfter.subtract(amount),opening,costStyle,accumulatedStyle,
                    expenseStyle,clearingStyle,departmentId,rowVersion,expectedPeriod,false,reason);
        }
    }

    private record PostingFact(UUID lineId,String objectType,UUID fixedId,UUID deferredId,UUID bookId,
                               UUID scheduleVersionId,UUID scheduleLineId,int sequence,BigDecimal opening,
                               BigDecimal amount,BigDecimal accumulated,BigDecimal closing,UUID costStyle,
                               UUID accumulatedStyle,UUID expenseStyle,String snapshot) {}

    private record Run(UUID id,String runType,String bookType,String period,String runKind,String status,
                       String fingerprint,String tokenHash,Instant tokenExpiresAt,String exceptionJson,
                       UUID submittedBy,UUID voucherId,UUID reversalOf,String reversalReason,long version) {}
}
