package com.uten.imp.features.finance.receivables;

import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.util.NativeValueConverters;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.finance.gl.GlPostingService;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.math.RoundingMode;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.time.LocalDate;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.HashMap;
import java.util.HexFormat;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.UUID;

import static com.uten.imp.features.finance.receivables.CustomerPrepaymentContracts.*;

/** Applies customer advances to exact order-source AR rows with immutable dual-rate snapshots. */
@Service
@RequiredArgsConstructor
public class CustomerPrepaymentOffsetService {
    public static final String GL_SOURCE_TYPE = "CUSTOMER_PREPAYMENT_OFFSET";
    private static final int MONEY_SCALE = 4;
    private static final int RATE_SCALE = 6;

    private final EntityManager em;
    private final TxSessionVars tx;
    private final SecurityContextCurrentUser currentUser;
    private final GlPostingService glPosting;

    @Transactional
    public BatchDetail apply(ApplyRequest request) {
        tx.bind();
        validate(request);
        List<Target> targets = request.targets().stream()
                .sorted(Comparator.comparing(Target::receivableLedgerId)
                        .thenComparing(Target::salesOrderId))
                .toList();
        if (targets.stream().map(t -> t.receivableLedgerId() + ":" + t.salesOrderId())
                .distinct().count() != targets.size()) {
            throw validation("同一应收与销售单来源不能在一个转销批次中重复");
        }
        String idempotencyKey = bounded(request.idempotencyKey(), 120, "幂等键");
        String reason = bounded(request.reason(), 2000, "应用原因");
        String requestHash = hash(request.sourceLedgerId(), targets, reason);
        BatchDetail existing = findIdempotent(idempotencyKey, requestHash);
        if (existing != null) return existing;

        LocalDate effectiveDate = BusinessTime.today();
        glPosting.lockAutoProjectionPeriod(effectiveDate);
        List<UUID> ledgerIds = java.util.stream.Stream.concat(
                        java.util.stream.Stream.of(request.sourceLedgerId()),
                        targets.stream().map(Target::receivableLedgerId))
                .distinct().sorted().toList();
        Map<UUID, OpenItem> items = lockOpenItems(ledgerIds);
        OpenItem source = require(items, request.sourceLedgerId());
        if (!"CUSTOMER_PREPAYMENT".equals(source.kind())
                || !"DIRECT_RECEIPT".equals(source.sourceType())
                || source.clientId() == null || source.currencyId() == null
                || source.balanceOriginal() == null || source.balanceOriginal().signum() >= 0
                || source.balanceLocal().signum() >= 0 || source.rate().signum() <= 0) {
            throw conflict("应用来源必须是已审核、同币种且仍有负余额的客户预收款");
        }
        UUID boundOrderId = boundSalesOrder(source.id());
        BigDecimal requested = targets.stream().map(Target::amountOriginal)
                .map(CustomerPrepaymentOffsetService::money)
                .reduce(BigDecimal.ZERO, BigDecimal::add);
        if (requested.signum() <= 0 || requested.compareTo(source.balanceOriginal().abs()) > 0) {
            throw conflict("转销原币合计超过客户预收可用余额");
        }

        UUID actor = currentUser.requireId();
        UUID batchId = UUID.randomUUID();
        int inserted = em.createNativeQuery("""
                INSERT INTO customer_open_item_offset_batches(
                    id,client_id,currency_id,effective_date,status,row_version,
                    idempotency_key,request_hash,reason,applied_by,created_by,updated_by)
                VALUES(:id,:clientId,:currencyId,:effectiveDate,'APPLIED',0,
                       :key,:hash,:reason,:actor,:actor,:actor)
                ON CONFLICT(idempotency_key) DO NOTHING
                """).setParameter("id", batchId)
                .setParameter("clientId", source.clientId())
                .setParameter("currencyId", source.currencyId())
                .setParameter("effectiveDate", effectiveDate)
                .setParameter("key", idempotencyKey)
                .setParameter("hash", requestHash)
                .setParameter("reason", reason)
                .setParameter("actor", actor).executeUpdate();
        if (inserted == 0) {
            BatchDetail raced = findIdempotent(idempotencyKey, requestHash);
            if (raced != null) return raced;
            throw conflict("幂等键已被不同请求使用");
        }

        BigDecimal sourceOriginal = source.balanceOriginal();
        BigDecimal sourceLocal = source.balanceLocal();
        int sequence = 1;
        for (Target input : targets) {
            OpenItem target = require(items, input.receivableLedgerId());
            if (!"RECEIVABLE".equals(target.kind())
                    || !Objects.equals(source.clientId(), target.clientId())
                    || !Objects.equals(source.currencyId(), target.currencyId())
                    || target.balanceOriginal() == null || target.balanceOriginal().signum() <= 0
                    || target.balanceLocal().signum() <= 0 || target.rate().signum() <= 0) {
                throw conflict("转销目标必须是同客户、同币种且仍有正余额的正式应收");
            }
            if (boundOrderId != null && !boundOrderId.equals(input.salesOrderId())) {
                throw conflict("绑定销售单的预收只能转销到同一销售单来源应收");
            }
            SourceRef ref = lockSourceRef(target, input.salesOrderId());
            BigDecimal historicalUnallocated = historicalUnallocatedAppliedOriginal(target.id());
            if (historicalUnallocated.signum() > 0) {
                throw conflict("该应收存在未精确归属销售单的历史到账/冲销，禁止继续转销；请先财务人工来源对账");
            }
            BigDecimal amount = money(input.amountOriginal());
            if (amount.signum() <= 0 || amount.compareTo(target.balanceOriginal()) > 0
                    || amount.compareTo(ref.availableOriginal()) > 0) {
                throw conflict("转销金额超过目标应收或销售单来源可用原币余额：" + target.billNo());
            }
            BigDecimal sourceSlice = amount.compareTo(sourceOriginal.abs()) == 0
                    ? money(sourceLocal.abs())
                    : money(amount.multiply(source.rate()));
            BigDecimal targetSlice = amount.compareTo(ref.availableOriginal()) == 0
                    ? money(ref.availableLocal())
                    : money(amount.multiply(target.rate()));
            if (sourceSlice.compareTo(sourceLocal.abs()) > 0
                    || targetSlice.compareTo(target.balanceLocal()) > 0
                    || targetSlice.compareTo(ref.availableLocal()) > 0) {
                throw conflict("转销账面本币超过预收、应收或销售单来源可用余额");
            }
            BigDecimal sourceAfterOriginal = money(sourceOriginal.add(amount));
            BigDecimal sourceAfterLocal = money(sourceLocal.add(sourceSlice));
            BigDecimal targetAfterOriginal = money(target.balanceOriginal().subtract(amount));
            BigDecimal targetAfterLocal = money(target.balanceLocal().subtract(targetSlice));
            updateOpenItem(source.id(), amount.negate(), sourceSlice.negate(),
                    sourceAfterOriginal, sourceAfterLocal, effectiveDate);
            updateOpenItem(target.id(), amount, targetSlice,
                    targetAfterOriginal, targetAfterLocal, effectiveDate);
            UUID allocationId = UUID.randomUUID();
            em.createNativeQuery("""
                    INSERT INTO customer_open_item_offsets(
                        id,offset_batch_id,line_sequence,client_id,currency_id,
                        source_ledger_id,target_ledger_id,target_source_ref_id,sales_order_id,
                        amount_original,source_amount_local,target_amount_local,exchange_difference,
                        source_rate,target_rate,source_balance_before_original,source_balance_after_original,
                        target_balance_before_original,target_balance_after_original,
                        source_balance_before_local,source_balance_after_local,
                        target_balance_before_local,target_balance_after_local,
                        target_ref_balance_before_original,target_ref_balance_after_original,
                        target_ref_balance_before_local,target_ref_balance_after_local,
                        effective_date,status,row_version,created_by,updated_by)
                    VALUES(:id,:batchId,:sequence,:clientId,:currencyId,
                           :sourceId,:targetId,:sourceRefId,:salesOrderId,
                           :amount,:sourceLocal,:targetLocal,:fx,:sourceRate,:targetRate,
                           :sourceBefore,:sourceAfter,:targetBefore,:targetAfter,
                           :sourceBeforeLocal,:sourceAfterLocal,:targetBeforeLocal,:targetAfterLocal,
                           :targetRefBefore,:targetRefAfter,
                           :targetRefBeforeLocal,:targetRefAfterLocal,
                           :effectiveDate,'APPLIED',0,:actor,:actor)
                    """)
                    .setParameter("id", allocationId).setParameter("batchId", batchId)
                    .setParameter("sequence", sequence++)
                    .setParameter("clientId", source.clientId()).setParameter("currencyId", source.currencyId())
                    .setParameter("sourceId", source.id()).setParameter("targetId", target.id())
                    .setParameter("sourceRefId", ref.id()).setParameter("salesOrderId", input.salesOrderId())
                    .setParameter("amount", amount).setParameter("sourceLocal", sourceSlice)
                    .setParameter("targetLocal", targetSlice)
                    .setParameter("fx", money(sourceSlice.subtract(targetSlice)))
                    .setParameter("sourceRate", source.rate()).setParameter("targetRate", target.rate())
                    .setParameter("sourceBefore", sourceOriginal).setParameter("sourceAfter", sourceAfterOriginal)
                    .setParameter("targetBefore", target.balanceOriginal()).setParameter("targetAfter", targetAfterOriginal)
                    .setParameter("sourceBeforeLocal", sourceLocal).setParameter("sourceAfterLocal", sourceAfterLocal)
                    .setParameter("targetBeforeLocal", target.balanceLocal()).setParameter("targetAfterLocal", targetAfterLocal)
                    .setParameter("targetRefBefore", ref.availableOriginal())
                    .setParameter("targetRefAfter", money(ref.availableOriginal().subtract(amount)))
                    .setParameter("targetRefBeforeLocal", ref.availableLocal())
                    .setParameter("targetRefAfterLocal", money(ref.availableLocal().subtract(targetSlice)))
                    .setParameter("effectiveDate", effectiveDate).setParameter("actor", actor).executeUpdate();
            sourceOriginal = sourceAfterOriginal;
            sourceLocal = sourceAfterLocal;
            items.put(source.id(), source.withBalances(sourceAfterOriginal, sourceAfterLocal));
            items.put(target.id(), target.withBalances(targetAfterOriginal, targetAfterLocal));
        }
        return detail(batchId);
    }

    @Transactional
    public BatchDetail reverse(UUID batchId, ReverseRequest request) {
        tx.bind();
        if (batchId == null || request == null || request.expectedVersion() == null) {
            throw validation("预收转销反转请求不完整");
        }
        String reason = bounded(request.reason(), 2000, "反转原因");
        Object[] batch = lockBatch(batchId);
        if (!"APPLIED".equals(batch[3])) throw conflict("只有已应用批次可反转");
        long version = number(batch[4]).longValue();
        if (version != request.expectedVersion()) throw conflict("批次版本已变化，请刷新后重试");
        LocalDate effectiveDate = NativeValueConverters.toLocalDate(batch[2]);
        glPosting.removeAutoProjection(GL_SOURCE_TYPE, batchId, voucherNo(batchId), effectiveDate);

        @SuppressWarnings("unchecked")
        List<Object[]> rows = em.createNativeQuery("""
                SELECT id,line_sequence,source_ledger_id,target_ledger_id,amount_original,
                       source_amount_local,target_amount_local,
                       source_balance_before_original,source_balance_after_original,
                       target_balance_before_original,target_balance_after_original,
                       source_balance_before_local,source_balance_after_local,
                       target_balance_before_local,target_balance_after_local,
                       target_source_ref_id,sales_order_id,
                       target_ref_balance_before_original,target_ref_balance_after_original,
                       target_ref_balance_before_local,target_ref_balance_after_local
                FROM customer_open_item_offsets
                WHERE offset_batch_id=:batchId AND status='APPLIED'
                ORDER BY line_sequence DESC FOR UPDATE
                """).setParameter("batchId", batchId).getResultList();
        if (rows.isEmpty()) throw conflict("预收转销批次明细缺失或已反转");
        List<UUID> ledgerIds = rows.stream()
                .flatMap(row -> java.util.stream.Stream.of((UUID) row[2], (UUID) row[3]))
                .distinct().sorted().toList();
        Map<UUID, OpenItem> items = lockOpenItems(ledgerIds);
        UUID actor = currentUser.requireId();
        for (Object[] row : rows) {
            OpenItem source = require(items, (UUID) row[2]);
            OpenItem target = require(items, (UUID) row[3]);
            BigDecimal expectedSourceOriginal = decimal(row[8]);
            BigDecimal expectedTargetOriginal = decimal(row[10]);
            BigDecimal expectedSourceLocal = decimal(row[12]);
            BigDecimal expectedTargetLocal = decimal(row[14]);
            SourceRef currentRef = lockSourceRef(target, (UUID) row[16]);
            if (source.balanceOriginal().compareTo(expectedSourceOriginal) != 0
                    || target.balanceOriginal().compareTo(expectedTargetOriginal) != 0
                    || source.balanceLocal().compareTo(expectedSourceLocal) != 0
                    || target.balanceLocal().compareTo(expectedTargetLocal) != 0
                    || currentRef.availableOriginal().compareTo(decimal(row[18])) != 0
                    || currentRef.availableLocal().compareTo(decimal(row[20])) != 0) {
                throw conflict("该转销余额已被后续业务使用，必须按后进先出先反转后续核销");
            }
            BigDecimal amount = decimal(row[4]);
            BigDecimal sourceLocal = decimal(row[5]);
            BigDecimal targetLocal = decimal(row[6]);
            BigDecimal sourceAfterOriginal = decimal(row[7]);
            BigDecimal targetAfterOriginal = decimal(row[9]);
            BigDecimal sourceAfterLocal = decimal(row[11]);
            BigDecimal targetAfterLocal = decimal(row[13]);
            updateOpenItem(source.id(), amount, sourceLocal,
                    sourceAfterOriginal, sourceAfterLocal, null);
            updateOpenItem(target.id(), amount.negate(), targetLocal.negate(),
                    targetAfterOriginal, targetAfterLocal, null);
            em.createNativeQuery("""
                    UPDATE customer_open_item_offsets
                    SET status='REVERSED',row_version=row_version+1,
                        reversed_by=:actor,reversed_at=now(),updated_by=:actor,updated_at=now()
                    WHERE id=:id AND status='APPLIED'
                    """).setParameter("actor", actor).setParameter("id", row[0]).executeUpdate();
            items.put(source.id(), source.withBalances(sourceAfterOriginal, sourceAfterLocal));
            items.put(target.id(), target.withBalances(targetAfterOriginal, targetAfterLocal));
        }
        int updated = em.createNativeQuery("""
                UPDATE customer_open_item_offset_batches
                SET status='REVERSED',row_version=row_version+1,reverse_reason=:reason,
                    reversed_by=:actor,reversed_at=now(),updated_by=:actor,updated_at=now()
                WHERE id=:id AND status='APPLIED' AND row_version=:version
                """).setParameter("reason", reason).setParameter("actor", actor)
                .setParameter("id", batchId).setParameter("version", version).executeUpdate();
        if (updated != 1) throw conflict("批次版本已变化，请刷新后重试");
        return detail(batchId);
    }

    @Transactional(readOnly = true)
    public BatchDetail detail(UUID batchId) {
        @SuppressWarnings("unchecked")
        List<Object[]> batches = em.createNativeQuery("""
                SELECT id,row_version,status,effective_date,client_id,currency_id,reason,applied_at,reversed_at
                FROM customer_open_item_offset_batches WHERE id=:id
                """).setParameter("id", batchId).getResultList();
        if (batches.size() != 1) throw new ApiException(ErrorCode.NOT_FOUND, "预收转销批次不存在");
        Object[] b = batches.getFirst();
        @SuppressWarnings("unchecked")
        List<Object[]> rows = em.createNativeQuery("""
                SELECT id,line_sequence,source_ledger_id,target_ledger_id,target_source_ref_id,sales_order_id,
                       amount_original,source_amount_local,target_amount_local,exchange_difference,
                       source_rate,target_rate,source_balance_before_original,source_balance_after_original,
                       target_balance_before_original,target_balance_after_original,status
                FROM customer_open_item_offsets WHERE offset_batch_id=:id ORDER BY line_sequence
                """).setParameter("id", batchId).getResultList();
        List<Allocation> allocations = rows.stream().map(row -> new Allocation(
                (UUID) row[0], number(row[1]).intValue(), (UUID) row[2], (UUID) row[3],
                (UUID) row[4], (UUID) row[5], text(row[6]), text(row[7]), text(row[8]),
                text(row[9]), text(row[10]), text(row[11]), text(row[12]), text(row[13]),
                text(row[14]), text(row[15]), Objects.toString(row[16], null))).toList();
        return new BatchDetail((UUID) b[0], number(b[1]).longValue(), Objects.toString(b[2], null),
                NativeValueConverters.toLocalDate(b[3]), (UUID) b[4], (UUID) b[5],
                Objects.toString(b[6], null), NativeValueConverters.toOffsetDateTime(b[7]),
                NativeValueConverters.toOffsetDateTime(b[8]), allocations);
    }

    private BatchDetail findIdempotent(String key, String hash) {
        @SuppressWarnings("unchecked")
        List<Object[]> rows = em.createNativeQuery("""
                SELECT id,request_hash FROM customer_open_item_offset_batches
                WHERE idempotency_key=:key
                """).setParameter("key", key).getResultList();
        if (rows.isEmpty()) return null;
        if (rows.size() != 1 || !Objects.equals(hash, rows.getFirst()[1])) {
            throw conflict("幂等键已被不同的预收转销请求使用");
        }
        return detail((UUID) rows.getFirst()[0]);
    }

    @SuppressWarnings("unchecked")
    private Map<UUID, OpenItem> lockOpenItems(List<UUID> ids) {
        List<Object[]> rows = em.createNativeQuery("""
                SELECT id,client_id,currency_id,open_item_kind,source_doc_type,bill_no,
                       amount_balance_original,amount_balance,exchange_rate
                FROM ar_ap_ledger
                WHERE id IN(:ids) AND direction='AR' AND status=1
                  AND COALESCE(is_deleted,FALSE)=FALSE
                ORDER BY id FOR UPDATE
                """).setParameter("ids", ids).getResultList();
        if (rows.size() != ids.size()) throw conflict("预收或应收不存在、已红冲或已删除");
        Map<UUID, OpenItem> result = new HashMap<>();
        for (Object[] row : rows) {
            OpenItem item = new OpenItem((UUID) row[0], (UUID) row[1], (UUID) row[2],
                    Objects.toString(row[3], null), Objects.toString(row[4], null),
                    Objects.toString(row[5], null), nullable(row[6]), decimal(row[7]),
                    positive(decimal(row[8]), "开账汇率"));
            result.put(item.id(), item);
        }
        return result;
    }

    private UUID boundSalesOrder(UUID sourceLedgerId) {
        Object value = em.createNativeQuery("""
                SELECT receipt.sales_order_id
                FROM ar_ap_ledger ledger JOIN finance_receipts receipt ON receipt.id=ledger.source_doc_id
                WHERE ledger.id=:id AND ledger.source_doc_type='DIRECT_RECEIPT'
                  AND receipt.receipt_kind='CUSTOMER_PREPAYMENT' AND receipt.status=1
                  AND COALESCE(receipt.is_deleted,FALSE)=FALSE
                """).setParameter("id", sourceLedgerId).getSingleResult();
        return (UUID) value;
    }

    @SuppressWarnings("unchecked")
    private SourceRef lockSourceRef(OpenItem target, UUID salesOrderId) {
        List<Object[]> rows = em.createNativeQuery("""
                SELECT ref.id,ref.amount_original,ref.amount_local,
                       ref.amount_original
                         - COALESCE((SELECT SUM(a.cash_original+a.write_off_original)
                                     FROM finance_receipt_source_allocations a
                                     WHERE a.source_ref_id=ref.id AND a.status='APPLIED'),0)
                         - COALESCE((SELECT SUM(o.amount_original) FROM customer_open_item_offsets o
                                     WHERE o.target_source_ref_id=ref.id AND o.status='APPLIED'),0),
                       ref.amount_local
                         - COALESCE((SELECT SUM(a.applied_book_local)
                                     FROM finance_receipt_source_allocations a
                                     WHERE a.source_ref_id=ref.id AND a.status='APPLIED'),0)
                         - COALESCE((SELECT SUM(o.target_amount_local) FROM customer_open_item_offsets o
                                     WHERE o.target_source_ref_id=ref.id AND o.status='APPLIED'),0)
                FROM ar_ap_source_refs ref
                JOIN sales_orders sales_order ON sales_order.id=ref.source_id
                WHERE ref.ledger_id=:ledgerId AND ref.source_type='SALES_ORDER'
                  AND ref.source_id=:salesOrderId
                  AND sales_order.client_id=:clientId
                  AND sales_order.currency_id IS NOT DISTINCT FROM :currencyId
                FOR UPDATE
                """).setParameter("ledgerId", target.id()).setParameter("salesOrderId", salesOrderId)
                .setParameter("clientId", target.clientId()).setParameter("currencyId", target.currencyId())
                .getResultList();
        if (rows.size() != 1) throw conflict("目标应收没有唯一、同客户同币种的销售单 UUID 来源");
        Object[] row = rows.getFirst();
        BigDecimal availableOriginal = money(decimal(row[3]));
        BigDecimal availableLocal = money(decimal(row[4]));
        if (availableOriginal.signum() < 0 || availableLocal.signum() < 0) {
            throw conflict("销售单来源已被超额核销，禁止继续转销");
        }
        return new SourceRef((UUID) row[0], availableOriginal, availableLocal);
    }

    private BigDecimal historicalUnallocatedAppliedOriginal(UUID ledgerId) {
        Object[] row = (Object[]) em.createNativeQuery("""
                SELECT COALESCE(ledger.amount_received_original,0)+COALESCE(ledger.amount_write_off_original,0),
                       COALESCE((SELECT SUM(a.cash_original+a.write_off_original)
                                 FROM finance_receipt_source_allocations a
                                 WHERE a.ledger_id=ledger.id AND a.status='APPLIED'),0)
                FROM ar_ap_ledger ledger WHERE ledger.id=:id
                """).setParameter("id", ledgerId).getSingleResult();
        BigDecimal value = money(decimal(row[0]).subtract(decimal(row[1])));
        if (value.signum() < 0) throw conflict("应收来源分配超过台账累计到账/冲销，数据不守恒");
        return value;
    }

    private Object[] lockBatch(UUID id) {
        @SuppressWarnings("unchecked")
        List<Object[]> rows = em.createNativeQuery("""
                SELECT client_id,currency_id,effective_date,status,row_version
                FROM customer_open_item_offset_batches WHERE id=:id FOR UPDATE
                """).setParameter("id", id).getResultList();
        if (rows.size() != 1) throw new ApiException(ErrorCode.NOT_FOUND, "预收转销批次不存在");
        return rows.getFirst();
    }

    private void updateOpenItem(UUID id, BigDecimal offsetOriginalDelta, BigDecimal offsetLocalDelta,
                                BigDecimal balanceOriginal, BigDecimal balanceLocal, LocalDate settledDate) {
        int updated = em.createNativeQuery("""
                UPDATE ar_ap_ledger
                SET amount_offset_original=amount_offset_original+:offsetOriginal,
                    amount_offset_local=amount_offset_local+:offsetLocal,
                    amount_balance_original=:balanceOriginal,amount_balance=:balanceLocal,
                    is_settled=(:balanceOriginal=0 AND :balanceLocal=0),
                    settled_date=CASE WHEN :balanceOriginal=0 AND :balanceLocal=0
                                      THEN COALESCE(CAST(:settledDate AS date),CURRENT_DATE) ELSE NULL END,
                    updated_at=now()
                WHERE id=:id AND direction='AR' AND status=1 AND COALESCE(is_deleted,FALSE)=FALSE
                """).setParameter("offsetOriginal", money(offsetOriginalDelta))
                .setParameter("offsetLocal", money(offsetLocalDelta))
                .setParameter("balanceOriginal", money(balanceOriginal))
                .setParameter("balanceLocal", money(balanceLocal))
                .setParameter("settledDate", settledDate).setParameter("id", id).executeUpdate();
        if (updated != 1) throw conflict("客户预收转销余额更新失败");
    }

    private static void validate(ApplyRequest request) {
        if (request == null || request.sourceLedgerId() == null
                || request.targets() == null || request.targets().isEmpty()) {
            throw validation("客户预收转销请求不完整");
        }
        if (request.targets().stream().anyMatch(t -> t == null || t.receivableLedgerId() == null
                || t.salesOrderId() == null || t.amountOriginal() == null
                || t.amountOriginal().signum() <= 0)) {
            throw validation("转销目标、销售单 UUID 和原币金额必须完整且大于 0");
        }
    }

    static String voucherNo(UUID batchId) {
        return "CPA-" + batchId.toString().replace("-", "");
    }

    private static String hash(UUID source, List<Target> targets, String reason) {
        StringBuilder canonical = new StringBuilder(source.toString()).append('|').append(reason.trim());
        for (Target target : targets) canonical.append('|').append(target.receivableLedgerId())
                .append('|').append(target.salesOrderId()).append('|').append(money(target.amountOriginal()).toPlainString());
        try {
            return HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256")
                    .digest(canonical.toString().getBytes(StandardCharsets.UTF_8)));
        } catch (NoSuchAlgorithmException impossible) {
            throw new IllegalStateException("SHA-256 unavailable", impossible);
        }
    }

    private static String bounded(String value, int max, String label) {
        if (value == null || value.isBlank()) throw validation(label + "不能为空");
        String trimmed = value.trim();
        if (trimmed.length() > max) throw validation(label + "不能超过 " + max + " 个字符");
        return trimmed;
    }

    private static OpenItem require(Map<UUID, OpenItem> map, UUID id) {
        OpenItem value = map.get(id);
        if (value == null) throw conflict("客户预收或应收台账不存在");
        return value;
    }

    private static BigDecimal positive(BigDecimal value, String label) {
        if (value == null || value.signum() <= 0) throw conflict(label + "缺失或无效");
        return value.setScale(RATE_SCALE, RoundingMode.HALF_UP);
    }

    private static BigDecimal money(BigDecimal value) {
        return decimal(value).setScale(MONEY_SCALE, RoundingMode.HALF_UP);
    }

    private static BigDecimal decimal(Object value) {
        return NativeValueConverters.toBigDecimal(value);
    }

    private static BigDecimal nullable(Object value) {
        return value == null ? null : decimal(value);
    }

    private static Number number(Object value) {
        if (value instanceof Number number) return number;
        return new BigDecimal(value.toString());
    }

    private static String text(Object value) {
        return decimal(value).setScale(MONEY_SCALE, RoundingMode.HALF_UP).toPlainString();
    }

    private static ApiException validation(String message) {
        return new ApiException(ErrorCode.VALIDATION_FAILED, message);
    }

    private static ApiException conflict(String message) {
        return new ApiException(ErrorCode.CONFLICT, message);
    }

    private record OpenItem(UUID id, UUID clientId, UUID currencyId, String kind, String sourceType,
                            String billNo, BigDecimal balanceOriginal, BigDecimal balanceLocal, BigDecimal rate) {
        OpenItem withBalances(BigDecimal original, BigDecimal local) {
            return new OpenItem(id, clientId, currencyId, kind, sourceType, billNo, original, local, rate);
        }
    }

    private record SourceRef(UUID id, BigDecimal availableOriginal, BigDecimal availableLocal) {}
}
