package com.uten.imp.features.finance.payables;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.math.RoundingMode;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.time.LocalDate;
import java.time.YearMonth;
import java.util.ArrayList;
import java.util.HexFormat;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Objects;
import java.util.Set;
import java.util.UUID;

import static com.uten.imp.features.finance.payables.SupplierSettlementContracts.*;

/** Frozen, reproducible supplier monthly statement service. */
@Service
@RequiredArgsConstructor
public class SupplierSettlementService {
    private static final int MONEY_SCALE = 4;
    private static final Set<String> FILTER_STATUSES = Set.of(
            "FROZEN", "SUPPLIER_CONFIRMED", "INTERNAL_CONFIRMED", "BOTH_CONFIRMED",
            "DISPUTED", "CLOSED", "REVERSED");

    private final EntityManager em;
    private final TxSessionVars tx;
    private final SecurityContextCurrentUser currentUser;
    private final SupplierPaymentTermService paymentTermService;

    @Transactional
    public BatchDetail freeze(FreezeRequest request) {
        tx.bind();
        if (request == null || request.supplierId() == null || request.currencyId() == null
                || request.periodStart() == null || request.settlementMethodId() == null) {
            throw validation("月结批次必须指定供应商、币种、月份和结算方式");
        }
        YearMonth month = YearMonth.from(request.periodStart());
        LocalDate start = month.atDay(1);
        LocalDate end = month.atEndOfMonth();
        if(!request.periodStart().equals(start)){
            throw validation("月结期间必须使用月份第一天");
        }
        if(end.isAfter(com.uten.imp.common.time.BusinessTime.today())){
            throw conflict("当前月份尚未结束，不能提前冻结月结对账单");
        }
        LocalDate calculatedDue = paymentTermService.resolveDueDate(
                request.supplierId(), request.settlementMethodId(), end);
        if (calculatedDue == null) {
            throw conflict("该结算方式依赖尚未发生的质检、发票或确认事件，不能提前冻结付款到期日");
        }
        if (request.dueDate() != null && !request.dueDate().equals(calculatedDue)) {
            throw conflict("客户端到期日与服务端结算规则不一致，请刷新后重试");
        }
        lockSupplier(request.supplierId());
        validateCurrency(request.currencyId());
        assertNoActiveBatch(request.supplierId(), request.currencyId(), start);
        assertNoUnreplayablePaymentReversals(request.supplierId(), request.currencyId(), end);
        lockLedgers(request.supplierId(), request.currencyId(), end);
        List<SnapshotLine> lines = snapshotLines(
                request.supplierId(), request.currencyId(), start, end);
        assertSettlementMethodConsistency(lines, request.settlementMethodId());
        Totals totals = totals(lines);
        String hash = snapshotHash(lines, request.supplierId(), request.currencyId(),
                request.settlementMethodId(), start, end, calculatedDue);
        UUID batchId = UUID.randomUUID();
        UUID actor = currentUser.requireId();
        em.createNativeQuery("""
                INSERT INTO supplier_settlement_batches(
                    id,supplier_id,currency_id,settlement_method_id,
                    period_start,period_end,due_date,status,
                    opening_balance_original,period_posted_original,period_paid_original,
                    period_offset_original,closing_balance_original,
                    opening_balance_local,period_posted_local,period_paid_local,
                    period_offset_local,closing_balance_local,
                    snapshot_hash,line_count,created_by,updated_by)
                VALUES (
                    :id,:supplierId,:currencyId,:methodId,
                    :periodStart,:periodEnd,:dueDate,'FROZEN',
                    :openingOriginal,:postedOriginal,:paidOriginal,:offsetOriginal,:closingOriginal,
                    :openingLocal,:postedLocal,:paidLocal,:offsetLocal,:closingLocal,
                    :hash,:lineCount,:actor,:actor)
                """)
                .setParameter("id", batchId)
                .setParameter("supplierId", request.supplierId())
                .setParameter("currencyId", request.currencyId())
                .setParameter("methodId", request.settlementMethodId())
                .setParameter("periodStart", start)
                .setParameter("periodEnd", end)
                .setParameter("dueDate", calculatedDue)
                .setParameter("openingOriginal", totals.openingOriginal())
                .setParameter("postedOriginal", totals.postedOriginal())
                .setParameter("paidOriginal", totals.paidOriginal())
                .setParameter("offsetOriginal", totals.offsetOriginal())
                .setParameter("closingOriginal", totals.closingOriginal())
                .setParameter("openingLocal", totals.openingLocal())
                .setParameter("postedLocal", totals.postedLocal())
                .setParameter("paidLocal", totals.paidLocal())
                .setParameter("offsetLocal", totals.offsetLocal())
                .setParameter("closingLocal", totals.closingLocal())
                .setParameter("hash", hash)
                .setParameter("lineCount", lines.size())
                .setParameter("actor", actor)
                .executeUpdate();
        for (SnapshotLine line : lines) insertLine(batchId, line, actor);
        appendEvent(batchId, "FROZEN", "按截止日冻结供应商月结快照");
        return detail(batchId);
    }

    @Transactional(readOnly = true)
    public BatchPage list(UUID supplierId, LocalDate periodStart, String status,
                          String keyword, int page, int size) {
        int safePage = Math.max(1, page);
        int safeSize = Math.min(Math.max(1, size), 200);
        StringBuilder where = new StringBuilder(
                " WHERE COALESCE(batch.is_deleted,FALSE)=FALSE");
        Map<String, Object> params = new LinkedHashMap<>();
        if (supplierId != null) add(where, params, "batch.supplier_id=:supplierId", "supplierId", supplierId);
        if (periodStart != null) {
            LocalDate normalized = YearMonth.from(periodStart).atDay(1);
            add(where, params, "batch.period_start=:periodStart", "periodStart", normalized);
        }
        if (status != null && !status.isBlank()) {
            String normalized = status.trim().toUpperCase(Locale.ROOT);
            if (!FILTER_STATUSES.contains(normalized)) throw validation("无效的月结批次状态");
            add(where, params, "batch.status=:status", "status", normalized);
        }
        if (keyword != null && !keyword.isBlank()) {
            add(where, params,
                    "(LOWER(batch.batch_no) LIKE :keyword OR LOWER(COALESCE(supplier.code,'')) LIKE :keyword"
                            + " OR LOWER(COALESCE(supplier.name,'')) LIKE :keyword)",
                    "keyword", "%" + keyword.trim().toLowerCase(Locale.ROOT) + "%");
        }
        String from = batchFrom();
        Query data = em.createNativeQuery(batchSelect() + from + where
                + " ORDER BY batch.period_start DESC,batch.batch_no DESC LIMIT :limit OFFSET :offset");
        bind(data, params);
        data.setParameter("limit", safeSize);
        data.setParameter("offset", (long) (safePage - 1) * safeSize);
        @SuppressWarnings("unchecked")
        List<Object[]> rows = data.getResultList();
        Query count = em.createNativeQuery("SELECT COUNT(*)" + from + where);
        bind(count, params);
        long total = ((Number) count.getSingleResult()).longValue();
        return new BatchPage(rows.stream().map(this::batchSummary).toList(),
                safePage, safeSize, total, (int) ((total + safeSize - 1) / safeSize));
    }

    @Transactional(readOnly = true)
    public BatchDetail detail(UUID id) {
        BatchSummary summary = requireSummary(id);
        @SuppressWarnings("unchecked")
        List<Object[]> lineRows = em.createNativeQuery("""
                SELECT id,ledger_id,business_type,open_item_kind,source_doc_type,
                       source_doc_id,source_doc_no,bill_date,due_date,booking_rate,
                       opening_balance_original,period_posted_original,period_paid_original,
                       period_offset_original,closing_balance_original,
                       opening_balance_local,period_posted_local,period_paid_local,
                       period_offset_local,closing_balance_local
                FROM supplier_settlement_batch_lines
                WHERE batch_id=:id ORDER BY bill_date,source_doc_no,ledger_id
                """).setParameter("id", id).getResultList();
        List<BatchLine> lines = lineRows.stream().map(row -> new BatchLine(
                uuid(row[0]),uuid(row[1]),text(row[2]),text(row[3]),text(row[4]),
                uuid(row[5]),text(row[6]),date(row[7]),date(row[8]),rate(row[9]),
                money(row[10]),money(row[11]),money(row[12]),money(row[13]),money(row[14]),
                money(row[15]),money(row[16]),money(row[17]),money(row[18]),money(row[19]))).toList();
        @SuppressWarnings("unchecked")
        List<Object[]> eventRows = em.createNativeQuery("""
                SELECT id,event_type,actor_user_id,reason,created_at
                FROM supplier_settlement_batch_events
                WHERE batch_id=:id ORDER BY created_at,id
                """).setParameter("id", id).getResultList();
        List<BatchEvent> events = eventRows.stream().map(row -> new BatchEvent(
                uuid(row[0]),text(row[1]),uuid(row[2]),text(row[3]),text(row[4]))).toList();
        return new BatchDetail(summary, lines, events);
    }

    @Transactional
    public BatchDetail supplierConfirm(UUID id, ConfirmRequest request) {
        tx.bind();
        BatchPeriodIdentity identity=batchPeriodIdentity(id);
        lockSupplier(identity.supplierId());
        LockedBatch batch = lockBatch(id, request == null ? -1 : request.expectedVersion());
        requireBatchPeriodIdentityUnchanged(batch,identity);
        if (!Set.of("FROZEN", "INTERNAL_CONFIRMED", "DISPUTED").contains(batch.status())) {
            throw conflict("当前月结批次不能登记供应商确认");
        }
        String reference = bounded(request.reference(), 500, "供应商确认凭据");
        String next = "INTERNAL_CONFIRMED".equals(batch.status()) ? "BOTH_CONFIRMED" : "SUPPLIER_CONFIRMED";
        updateConfirmation(id, batch.version(), next, true, reference);
        appendEvent(id, "SUPPLIER_CONFIRMED", optional(request.note(), 2000));
        return detail(id);
    }

    @Transactional
    public BatchDetail internalConfirm(UUID id, ConfirmRequest request) {
        tx.bind();
        BatchPeriodIdentity identity=batchPeriodIdentity(id);
        lockSupplier(identity.supplierId());
        LockedBatch batch = lockBatch(id, request == null ? -1 : request.expectedVersion());
        requireBatchPeriodIdentityUnchanged(batch,identity);
        if (!Set.of("FROZEN", "SUPPLIER_CONFIRMED", "DISPUTED").contains(batch.status())) {
            throw conflict("当前月结批次不能执行公司确认");
        }
        String next = "SUPPLIER_CONFIRMED".equals(batch.status()) ? "BOTH_CONFIRMED" : "INTERNAL_CONFIRMED";
        updateConfirmation(id, batch.version(), next, false, null);
        appendEvent(id, "INTERNAL_CONFIRMED", optional(request.note(), 2000));
        return detail(id);
    }

    @Transactional
    public BatchDetail dispute(UUID id, DisputeRequest request) {
        tx.bind();
        BatchPeriodIdentity identity=batchPeriodIdentity(id);
        lockSupplier(identity.supplierId());
        LockedBatch batch = lockBatch(id, request == null ? -1 : request.expectedVersion());
        requireBatchPeriodIdentityUnchanged(batch,identity);
        if (Set.of("CLOSED", "REVERSED").contains(batch.status())) {
            throw conflict("已关闭或已反转批次不能登记争议");
        }
        String reason = bounded(request.reason(), 2000, "争议说明");
        updateStatus(id, batch.version(), "DISPUTED", "dispute_reason", reason);
        appendEvent(id, "DISPUTED", reason);
        return detail(id);
    }

    @Transactional
    public BatchDetail reverse(UUID id, ReverseRequest request) {
        tx.bind();
        BatchPeriodIdentity identity=batchPeriodIdentity(id);
        lockSupplier(identity.supplierId());
        LockedBatch batch = lockBatch(id, request == null ? -1 : request.expectedVersion());
        requireBatchPeriodIdentityUnchanged(batch,identity);
        if ("REVERSED".equals(batch.status())) throw conflict("月结批次已经反转");
        String reason = bounded(request.reason(), 2000, "反转说明");
        int updated = em.createNativeQuery("""
                UPDATE supplier_settlement_batches
                SET status='REVERSED',row_version=row_version+1,
                    reversed_by=:actor,reversed_at=now(),reverse_reason=:reason,
                    updated_by=:actor,updated_at=now()
                WHERE id=:id AND row_version=:version
                """).setParameter("actor", currentUser.requireId())
                .setParameter("reason", reason).setParameter("id", id)
                .setParameter("version", batch.version()).executeUpdate();
        if (updated != 1) throw conflict("月结批次版本已变化，请刷新后重试");
        appendEvent(id, "REVERSED", reason);
        return detail(id);
    }

    private List<SnapshotLine> snapshotLines(UUID supplierId, UUID currencyId,
                                             LocalDate start, LocalDate end) {
        @SuppressWarnings("unchecked")
        List<Object[]> rows = em.createNativeQuery("""
                WITH payment_event AS (
                    SELECT line.applied_ledger_id AS ledger_id,
                           payment.bill_date AS event_date,
                           line.amount_original AS amount_original,
                           COALESCE(line.applied_amount_local,
                                    line.amount_local-COALESCE(line.exchange_diff,0)) AS amount_local
                    FROM finance_payment_lines line
                    JOIN finance_payments payment ON payment.id=line.payment_id
                    WHERE payment.status IN(1,-1) AND COALESCE(payment.is_deleted,FALSE)=FALSE
                      AND COALESCE(line.is_deleted,FALSE)=FALSE
                    UNION ALL
                    SELECT line.applied_ledger_id,
                           (COALESCE(payment.reversed_at, payment.updated_at)
                               AT TIME ZONE 'Asia/Shanghai')::DATE,
                           -line.amount_original,
                           -COALESCE(line.applied_amount_local,
                                     line.amount_local-COALESCE(line.exchange_diff,0))
                    FROM finance_payment_lines line
                    JOIN finance_payments payment ON payment.id=line.payment_id
                    WHERE payment.status=-1 AND COALESCE(payment.is_deleted,FALSE)=FALSE
                      AND COALESCE(line.is_deleted,FALSE)=FALSE
                ), offset_event AS (
                    SELECT target_ledger_id AS ledger_id,effective_date AS event_date,
                           amount_original,target_amount_local AS amount_local
                    FROM supplier_open_item_offsets
                    UNION ALL
                    SELECT source_ledger_id,effective_date,-amount_original,-source_amount_local
                    FROM supplier_open_item_offsets
                    UNION ALL
                    SELECT target_ledger_id,
                           (reversed_at AT TIME ZONE 'Asia/Shanghai')::DATE,
                           -amount_original,-target_amount_local
                    FROM supplier_open_item_offsets WHERE status='REVERSED'
                    UNION ALL
                    SELECT source_ledger_id,
                           (reversed_at AT TIME ZONE 'Asia/Shanghai')::DATE,
                           amount_original,source_amount_local
                    FROM supplier_open_item_offsets WHERE status='REVERSED'
                ), payment_sum AS (
                    SELECT ledger_id,
                           COALESCE(SUM(amount_original) FILTER (WHERE event_date<:start),0) prior_original,
                           COALESCE(SUM(amount_original) FILTER (WHERE event_date BETWEEN :start AND :end),0) period_original,
                           COALESCE(SUM(amount_local) FILTER (WHERE event_date<:start),0) prior_local,
                           COALESCE(SUM(amount_local) FILTER (WHERE event_date BETWEEN :start AND :end),0) period_local
                    FROM payment_event WHERE event_date<=:end GROUP BY ledger_id
                ), offset_sum AS (
                    SELECT ledger_id,
                           COALESCE(SUM(amount_original) FILTER (WHERE event_date<:start),0) prior_original,
                           COALESCE(SUM(amount_original) FILTER (WHERE event_date BETWEEN :start AND :end),0) period_original,
                           COALESCE(SUM(amount_local) FILTER (WHERE event_date<:start),0) prior_local,
                           COALESCE(SUM(amount_local) FILTER (WHERE event_date BETWEEN :start AND :end),0) period_local
                    FROM offset_event WHERE event_date<=:end GROUP BY ledger_id
                ), source AS (
                    SELECT ledger.*,
                           CASE WHEN ledger.open_item_kind='PREPAYMENT'
                                THEN -COALESCE(payment.amount_original,0)
                                ELSE ledger.amount_original END AS posted_original,
                           CASE WHEN ledger.open_item_kind='PREPAYMENT'
                                THEN -COALESCE(payment.amount_local,0)
                                ELSE ledger.amount_original_local END AS posted_local,
                           CASE WHEN ledger.status=-1
                                THEN (ledger.deleted_at AT TIME ZONE 'Asia/Shanghai')::DATE END AS reversal_date
                    FROM ar_ap_ledger ledger
                    LEFT JOIN finance_payments payment
                      ON ledger.source_doc_type='DIRECT_PAYMENT'
                     AND payment.id=ledger.source_doc_id AND payment.status IN(1,-1)
                    WHERE ledger.direction='AP'
                      AND ((ledger.status=1 AND COALESCE(ledger.is_deleted,FALSE)=FALSE)
                        OR (ledger.status=-1 AND COALESCE(ledger.is_deleted,FALSE)=TRUE
                            AND ledger.deleted_at IS NOT NULL))
                      AND ledger.supplier_id=:supplierId AND ledger.currency_id=:currencyId
                      AND ledger.bill_date<=:end
                )
                SELECT source.id,source.business_type,source.open_item_kind,
                       source.source_doc_type,source.source_doc_id,source.source_doc_no,
                       source.bill_date,source.due_date,source.exchange_rate,
                       CASE WHEN source.bill_date<:start THEN source.posted_original ELSE 0 END
                           - CASE WHEN source.reversal_date<:start THEN source.posted_original ELSE 0 END
                           - COALESCE(payment_sum.prior_original,0)-COALESCE(offset_sum.prior_original,0),
                       CASE WHEN source.bill_date BETWEEN :start AND :end THEN source.posted_original ELSE 0 END
                           - CASE WHEN source.reversal_date BETWEEN :start AND :end THEN source.posted_original ELSE 0 END,
                       COALESCE(payment_sum.period_original,0),COALESCE(offset_sum.period_original,0),
                       CASE WHEN source.bill_date<=:end THEN source.posted_original ELSE 0 END
                           - CASE WHEN source.reversal_date<=:end THEN source.posted_original ELSE 0 END
                           - COALESCE(payment_sum.prior_original,0)-COALESCE(payment_sum.period_original,0)
                           - COALESCE(offset_sum.prior_original,0)-COALESCE(offset_sum.period_original,0),
                       CASE WHEN source.bill_date<:start THEN source.posted_local ELSE 0 END
                           - CASE WHEN source.reversal_date<:start THEN source.posted_local ELSE 0 END
                           - COALESCE(payment_sum.prior_local,0)-COALESCE(offset_sum.prior_local,0),
                       CASE WHEN source.bill_date BETWEEN :start AND :end THEN source.posted_local ELSE 0 END
                           - CASE WHEN source.reversal_date BETWEEN :start AND :end THEN source.posted_local ELSE 0 END,
                       COALESCE(payment_sum.period_local,0),COALESCE(offset_sum.period_local,0),
                       CASE WHEN source.bill_date<=:end THEN source.posted_local ELSE 0 END
                           - CASE WHEN source.reversal_date<=:end THEN source.posted_local ELSE 0 END
                           - COALESCE(payment_sum.prior_local,0)-COALESCE(payment_sum.period_local,0)
                           - COALESCE(offset_sum.prior_local,0)-COALESCE(offset_sum.period_local,0),
                       source.settlement_type_id
                FROM source
                LEFT JOIN payment_sum ON payment_sum.ledger_id=source.id
                LEFT JOIN offset_sum ON offset_sum.ledger_id=source.id
                ORDER BY source.bill_date,source.source_doc_no,source.id
                """)
                .setParameter("supplierId", supplierId).setParameter("currencyId", currencyId)
                .setParameter("start", start).setParameter("end", end).getResultList();
        List<SnapshotLine> result = new ArrayList<>();
        for (Object[] row : rows) {
            SnapshotLine line = new SnapshotLine(
                    uuid(row[0]),text(row[1]),text(row[2]),text(row[3]),uuid(row[4]),text(row[5]),
                    LocalDate.parse(row[6].toString()),row[7]==null?null:LocalDate.parse(row[7].toString()),
                    decimal(row[8]),moneyValue(row[9]),moneyValue(row[10]),moneyValue(row[11]),moneyValue(row[12]),
                    moneyValue(row[13]),moneyValue(row[14]),moneyValue(row[15]),moneyValue(row[16]),
                    moneyValue(row[17]),moneyValue(row[18]),uuid(row[19]));
            if (line.hasMovementOrBalance()) result.add(line);
        }
        return result;
    }

    private void insertLine(UUID batchId, SnapshotLine line, UUID actor) {
        em.createNativeQuery("""
                INSERT INTO supplier_settlement_batch_lines(
                    id,batch_id,ledger_id,business_type,open_item_kind,source_doc_type,
                    source_doc_id,source_doc_no,bill_date,due_date,booking_rate,
                    opening_balance_original,period_posted_original,period_paid_original,
                    period_offset_original,closing_balance_original,
                    opening_balance_local,period_posted_local,period_paid_local,
                    period_offset_local,closing_balance_local,created_by)
                VALUES (
                    :id,:batchId,:ledgerId,:businessType,:kind,:sourceType,
                    :sourceId,:sourceNo,:billDate,:dueDate,:rate,
                    :openingOriginal,:postedOriginal,:paidOriginal,:offsetOriginal,:closingOriginal,
                    :openingLocal,:postedLocal,:paidLocal,:offsetLocal,:closingLocal,:actor)
                """)
                .setParameter("id", UUID.randomUUID()).setParameter("batchId", batchId)
                .setParameter("ledgerId", line.ledgerId()).setParameter("businessType", line.businessType())
                .setParameter("kind", line.openItemKind()).setParameter("sourceType", line.sourceDocType())
                .setParameter("sourceId", line.sourceDocId()).setParameter("sourceNo", line.sourceDocNo())
                .setParameter("billDate", line.billDate()).setParameter("dueDate", line.dueDate())
                .setParameter("rate", line.rate()).setParameter("openingOriginal", line.openingOriginal())
                .setParameter("postedOriginal", line.postedOriginal()).setParameter("paidOriginal", line.paidOriginal())
                .setParameter("offsetOriginal", line.offsetOriginal()).setParameter("closingOriginal", line.closingOriginal())
                .setParameter("openingLocal", line.openingLocal()).setParameter("postedLocal", line.postedLocal())
                .setParameter("paidLocal", line.paidLocal()).setParameter("offsetLocal", line.offsetLocal())
                .setParameter("closingLocal", line.closingLocal()).setParameter("actor", actor).executeUpdate();
    }

    private void assertNoUnreplayablePaymentReversals(UUID supplierId, UUID currencyId, LocalDate end) {
        long count = ((Number) em.createNativeQuery("""
                SELECT COUNT(*)
                FROM finance_payments payment
                WHERE payment.status=-1 AND payment.bill_date<=:end
                  AND payment.supplier_id=:supplierId AND payment.currency_id=:currencyId
                  AND NOT EXISTS(SELECT 1 FROM finance_payment_lines line WHERE line.payment_id=payment.id)
                  AND NOT EXISTS(
                      SELECT 1 FROM ar_ap_ledger ledger
                      WHERE ledger.source_doc_type='DIRECT_PAYMENT'
                        AND ledger.source_doc_id=payment.id
                        AND ledger.status=-1 AND COALESCE(ledger.is_deleted,FALSE)=TRUE
                        AND ledger.deleted_at IS NOT NULL)
                """).setParameter("end", end).setParameter("supplierId", supplierId)
                .setParameter("currencyId", currencyId).getSingleResult()).longValue();
        if (count != 0) {
            throw conflict("存在截止日前已红冲付款但缺少独立反转日期事件，禁止事后伪造月结快照；请财务专项核对");
        }
    }

    private void lockLedgers(UUID supplierId, UUID currencyId, LocalDate end) {
        em.createNativeQuery("""
                SELECT id FROM ar_ap_ledger
                WHERE direction='AP' AND status=1 AND COALESCE(is_deleted,FALSE)=FALSE
                  AND supplier_id=:supplierId AND currency_id=:currencyId AND bill_date<=:end
                ORDER BY id FOR UPDATE
                """).setParameter("supplierId", supplierId).setParameter("currencyId", currencyId)
                .setParameter("end", end).getResultList();
    }

    /** A single due date may label only the exact frozen rows that use its method. */
    private static void assertSettlementMethodConsistency(
            List<SnapshotLine> lines, UUID settlementMethodId) {
        boolean mismatched = lines.stream()
                .anyMatch(line -> !Objects.equals(
                        line.settlementMethodId(), settlementMethodId));
        if (mismatched) throw conflict(
                "月结范围包含现金、其他账期或未核验结算方式，禁止用单一到期日混合冻结");
    }

    private void lockSupplier(UUID id) {
        @SuppressWarnings("unchecked")
        List<UUID> rows = em.createNativeQuery("""
                SELECT id FROM suppliers WHERE id=:id AND COALESCE(is_deleted,FALSE)=FALSE FOR UPDATE
                """).setParameter("id", id).getResultList();
        if (rows.size()!=1) throw new ApiException(ErrorCode.NOT_FOUND,"供应商不存在或已删除");
    }

    private void validateCurrency(UUID id) {
        long count=((Number)em.createNativeQuery("""
                SELECT COUNT(*) FROM currencies WHERE id=:id AND status='使用'
                  AND COALESCE(is_deleted,FALSE)=FALSE
                """).setParameter("id",id).getSingleResult()).longValue();
        if(count!=1) throw validation("月结币种不存在或已停用");
    }

    private void assertNoActiveBatch(UUID supplierId,UUID currencyId,LocalDate periodStart){
        long count=((Number)em.createNativeQuery("""
                SELECT COUNT(*) FROM supplier_settlement_batches
                WHERE supplier_id=:supplierId AND currency_id=:currencyId
                  AND period_start=:periodStart AND status<>'REVERSED' AND is_deleted=FALSE
                """).setParameter("supplierId",supplierId).setParameter("currencyId",currencyId)
                .setParameter("periodStart",periodStart).getSingleResult()).longValue();
        if(count!=0) throw conflict("该供应商、币种和月份已经存在有效月结批次");
    }

    private Totals totals(List<SnapshotLine> lines){
        BigDecimal[] v=new BigDecimal[10];java.util.Arrays.fill(v,zero());
        for(SnapshotLine l:lines){v[0]=v[0].add(l.openingOriginal());v[1]=v[1].add(l.postedOriginal());
            v[2]=v[2].add(l.paidOriginal());v[3]=v[3].add(l.offsetOriginal());v[4]=v[4].add(l.closingOriginal());
            v[5]=v[5].add(l.openingLocal());v[6]=v[6].add(l.postedLocal());v[7]=v[7].add(l.paidLocal());
            v[8]=v[8].add(l.offsetLocal());v[9]=v[9].add(l.closingLocal());}
        for(int i=0;i<v.length;i++)v[i]=moneyValue(v[i]);
        return new Totals(v[0],v[1],v[2],v[3],v[4],v[5],v[6],v[7],v[8],v[9]);
    }

    private String snapshotHash(List<SnapshotLine> lines,UUID supplier,UUID currency,
                                UUID settlementMethod,LocalDate start,LocalDate end,LocalDate dueDate){
        StringBuilder canonical=new StringBuilder().append(supplier).append('|').append(currency)
                .append('|').append(settlementMethod).append('|').append(start).append('|').append(end)
                .append('|').append(dueDate).append('\n');
        for(SnapshotLine l:lines)canonical.append(l.canonical()).append('\n');
        try{return HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256")
                .digest(canonical.toString().getBytes(StandardCharsets.UTF_8)));}
        catch(NoSuchAlgorithmException e){throw new IllegalStateException("SHA-256 unavailable",e);}
    }

    private BatchSummary requireSummary(UUID id){
        @SuppressWarnings("unchecked") List<Object[]> rows=em.createNativeQuery(batchSelect()+batchFrom()
                +" WHERE batch.id=:id AND COALESCE(batch.is_deleted,FALSE)=FALSE")
                .setParameter("id",id).getResultList();
        if(rows.size()!=1)throw new ApiException(ErrorCode.NOT_FOUND,"供应商月结批次不存在");
        return batchSummary(rows.getFirst());
    }

    private BatchPeriodIdentity batchPeriodIdentity(UUID id){
        @SuppressWarnings("unchecked")
        List<Object[]> rows=em.createNativeQuery("""
                SELECT supplier_id,currency_id FROM supplier_settlement_batches
                WHERE id=:id AND COALESCE(is_deleted,FALSE)=FALSE
                """).setParameter("id",id).getResultList();
        if(rows.size()!=1)throw new ApiException(ErrorCode.NOT_FOUND,"供应商月结批次不存在");
        return new BatchPeriodIdentity(uuid(rows.getFirst()[0]),uuid(rows.getFirst()[1]));
    }

    private static void requireBatchPeriodIdentityUnchanged(
            LockedBatch batch,BatchPeriodIdentity identity){
        if(!Objects.equals(batch.supplierId(),identity.supplierId())
                ||!Objects.equals(batch.currencyId(),identity.currencyId())){
            throw conflict("月结批次供应商或币种已变化，请刷新后重试");
        }
    }

    private LockedBatch lockBatch(UUID id,long expected){
        @SuppressWarnings("unchecked") List<Object[]> rows=em.createNativeQuery("""
                SELECT id,status,row_version,supplier_id,currency_id FROM supplier_settlement_batches
                WHERE id=:id AND COALESCE(is_deleted,FALSE)=FALSE FOR UPDATE
                """).setParameter("id",id).getResultList();
        if(rows.size()!=1)throw new ApiException(ErrorCode.NOT_FOUND,"供应商月结批次不存在");
        LockedBatch b=new LockedBatch((UUID)rows.getFirst()[0],text(rows.getFirst()[1]),
                ((Number)rows.getFirst()[2]).longValue(),uuid(rows.getFirst()[3]),uuid(rows.getFirst()[4]));
        if(expected<0||b.version()!=expected)throw conflict("月结批次版本已变化，请刷新后重试");
        return b;
    }

    private void updateConfirmation(UUID id,long version,String status,boolean supplier,String reference){
        String columns=supplier
                ?"supplier_confirmation_ref=:reference,supplier_confirmed_by=:actor,supplier_confirmed_at=now(),"
                :"internal_confirmed_by=:actor,internal_confirmed_at=now(),";
        Query q=em.createNativeQuery("UPDATE supplier_settlement_batches SET status=:status,"+columns
                +" row_version=row_version+1,updated_by=:actor,updated_at=now() WHERE id=:id AND row_version=:version")
                .setParameter("status",status).setParameter("actor",currentUser.requireId())
                .setParameter("id",id).setParameter("version",version);
        if(supplier)q.setParameter("reference",reference);
        if(q.executeUpdate()!=1)throw conflict("月结批次版本已变化，请刷新后重试");
    }

    private void updateStatus(UUID id,long version,String status,String field,String value){
        if(!"dispute_reason".equals(field))throw new IllegalArgumentException("unsupported field");
        int n=em.createNativeQuery("""
                UPDATE supplier_settlement_batches SET status=:status,dispute_reason=:value,
                    row_version=row_version+1,updated_by=:actor,updated_at=now()
                WHERE id=:id AND row_version=:version
                """).setParameter("status",status).setParameter("value",value)
                .setParameter("actor",currentUser.requireId()).setParameter("id",id)
                .setParameter("version",version).executeUpdate();
        if(n!=1)throw conflict("月结批次版本已变化，请刷新后重试");
    }

    private void appendEvent(UUID id,String type,String reason){em.createNativeQuery("""
            INSERT INTO supplier_settlement_batch_events(id,batch_id,event_type,actor_user_id,reason)
            VALUES (:eventId,:id,:type,:actor,:reason)
            """).setParameter("eventId",UUID.randomUUID()).setParameter("id",id)
            .setParameter("type",type).setParameter("actor",currentUser.requireId())
            .setParameter("reason",optional(reason,2000)).executeUpdate();}

    private static String batchSelect(){return """
            SELECT batch.id,batch.batch_no,batch.supplier_id,supplier.code,supplier.name,
                   batch.currency_id,currency.code,batch.period_start,batch.period_end,batch.due_date,
                   batch.status,batch.opening_balance_original,batch.period_posted_original,
                   batch.period_paid_original,batch.period_offset_original,batch.closing_balance_original,
                   batch.opening_balance_local,batch.period_posted_local,batch.period_paid_local,
                   batch.period_offset_local,batch.closing_balance_local,batch.line_count,
                   batch.row_version,batch.snapshot_hash,batch.created_at
            """;}
    private static String batchFrom(){return " FROM supplier_settlement_batches batch JOIN suppliers supplier ON supplier.id=batch.supplier_id JOIN currencies currency ON currency.id=batch.currency_id";}
    private BatchSummary batchSummary(Object[]r){return new BatchSummary(uuid(r[0]),text(r[1]),uuid(r[2]),text(r[3]),text(r[4]),uuid(r[5]),text(r[6]),date(r[7]),date(r[8]),date(r[9]),text(r[10]),money(r[11]),money(r[12]),money(r[13]),money(r[14]),money(r[15]),money(r[16]),money(r[17]),money(r[18]),money(r[19]),money(r[20]),((Number)r[21]).intValue(),((Number)r[22]).longValue(),text(r[23]),text(r[24]));}
    private static void add(StringBuilder w,Map<String,Object>p,String q,String n,Object v){w.append(" AND ").append(q);p.put(n,v);} private static void bind(Query q,Map<String,Object>p){p.forEach(q::setParameter);}
    private static String bounded(String v,int m,String l){if(v==null||v.isBlank())throw validation(l+"不能为空");return optional(v,m);} private static String optional(String v,int m){if(v==null)return null;String t=v.trim();if(t.length()>m)throw validation("文本不能超过 "+m+" 个字符");return t.isEmpty()?null:t;}
    private static UUID uuid(Object v){return v instanceof UUID u?u:v==null?null:UUID.fromString(v.toString());} private static String text(Object v){return v==null?null:v.toString();} private static String date(Object v){return v==null?null:v.toString();}
    private static BigDecimal decimal(Object v){return v instanceof BigDecimal b?b:new BigDecimal(v.toString());} private static BigDecimal moneyValue(Object v){return (v==null?BigDecimal.ZERO:decimal(v)).setScale(MONEY_SCALE,RoundingMode.HALF_UP);} private static String money(Object v){return v==null?null:moneyValue(v).toPlainString();} private static String rate(Object v){return v==null?null:decimal(v).setScale(6,RoundingMode.HALF_UP).toPlainString();} private static BigDecimal zero(){return BigDecimal.ZERO.setScale(MONEY_SCALE);}
    private static ApiException validation(String m){return new ApiException(ErrorCode.VALIDATION_FAILED,m);} private static ApiException conflict(String m){return new ApiException(ErrorCode.CONFLICT,m);}

    private record BatchPeriodIdentity(UUID supplierId,UUID currencyId){}
    private record LockedBatch(UUID id,String status,long version,UUID supplierId,UUID currencyId){}
    private record Totals(BigDecimal openingOriginal,BigDecimal postedOriginal,BigDecimal paidOriginal,BigDecimal offsetOriginal,BigDecimal closingOriginal,BigDecimal openingLocal,BigDecimal postedLocal,BigDecimal paidLocal,BigDecimal offsetLocal,BigDecimal closingLocal){}
    private record SnapshotLine(UUID ledgerId,String businessType,String openItemKind,String sourceDocType,UUID sourceDocId,String sourceDocNo,LocalDate billDate,LocalDate dueDate,BigDecimal rate,BigDecimal openingOriginal,BigDecimal postedOriginal,BigDecimal paidOriginal,BigDecimal offsetOriginal,BigDecimal closingOriginal,BigDecimal openingLocal,BigDecimal postedLocal,BigDecimal paidLocal,BigDecimal offsetLocal,BigDecimal closingLocal,UUID settlementMethodId){boolean hasMovementOrBalance(){return openingOriginal.signum()!=0||postedOriginal.signum()!=0||paidOriginal.signum()!=0||offsetOriginal.signum()!=0||closingOriginal.signum()!=0||openingLocal.signum()!=0||postedLocal.signum()!=0||paidLocal.signum()!=0||offsetLocal.signum()!=0||closingLocal.signum()!=0;}String canonical(){return String.join("|",ledgerId.toString(),Objects.toString(businessType,""),Objects.toString(openItemKind,""),Objects.toString(sourceDocType,""),Objects.toString(sourceDocId,""),Objects.toString(sourceDocNo,""),billDate.toString(),Objects.toString(dueDate,""),rate.toPlainString(),openingOriginal.toPlainString(),postedOriginal.toPlainString(),paidOriginal.toPlainString(),offsetOriginal.toPlainString(),closingOriginal.toPlainString(),openingLocal.toPlainString(),postedLocal.toPlainString(),paidLocal.toPlainString(),offsetLocal.toPlainString(),closingLocal.toPlainString());}}
}
