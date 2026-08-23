package com.uten.imp.features.finance.payables;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.finance.gl.GlPostingService;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.math.RoundingMode;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.UUID;

/** Applies an accepted supplier credit/claim/prepayment to positive AP with exact snapshots. */
@Service
@RequiredArgsConstructor
public class SupplierOpenItemOffsetService {
    private static final int MONEY_SCALE = 4;

    private final EntityManager em;
    private final TxSessionVars tx;
    private final SecurityContextCurrentUser currentUser;
    private final GlPostingService glPosting;
    private final SupplierClosedPeriodGuard closedPeriodGuard;

    @Transactional(propagation = Propagation.MANDATORY)
    public void apply(
            UUID resolutionId,
            UUID sourceLedgerId,
            UUID supplierId,
            UUID currencyId,
            LocalDate effectiveDate,
            List<Target> targets,
            String reason) {
        applyBatch(resolutionId,resolutionId,sourceLedgerId,supplierId,currencyId,
                effectiveDate,targets,reason);
    }

    @Transactional(propagation = Propagation.MANDATORY)
    public void applyBatch(
            UUID offsetBatchId,
            UUID resolutionId,
            UUID sourceLedgerId,
            UUID supplierId,
            UUID currencyId,
            LocalDate effectiveDate,
            List<Target> targets,
            String reason) {
        tx.bind();
        if(offsetBatchId==null)throw validation("抵销批次 UUID 不能为空");
        closedPeriodGuard.requireOpen(
                supplierId, currencyId, effectiveDate, "供应商贷项或索赔抵销");
        if (targets == null || targets.isEmpty()) {
            throw validation("应付抵销必须选择至少一笔正应付");
        }
        if (targets.stream().anyMatch(target -> target == null || target.payableId() == null
                || target.amountOriginal() == null || target.amountOriginal().signum() <= 0)) {
            throw validation("应付抵销目标和原币金额必须完整且大于 0");
        }
        if (targets.stream().map(Target::payableId).distinct().count() != targets.size()) {
            throw validation("同一笔正应付不能在一次抵销中重复选择");
        }
        List<UUID> ids = java.util.stream.Stream.concat(
                        java.util.stream.Stream.of(sourceLedgerId),
                        targets.stream().map(Target::payableId))
                .distinct().sorted().toList();
        Map<UUID, OpenItem> locked = lock(ids);
        OpenItem source = require(locked, sourceLedgerId);
        if (!Objects.equals(source.supplierId(), supplierId)
                || !Objects.equals(source.currencyId(), currencyId)
                || !(source.kind().equals("CREDIT") || source.kind().equals("CLAIM_CREDIT")
                || source.kind().equals("PREPAYMENT"))
                || source.balanceOriginal() == null || source.balanceOriginal().signum() >= 0
                || source.balanceLocal().signum() >= 0) {
            throw conflict("抵销来源必须是同供应商、同币种且仍有负余额的贷项/索赔/预付款");
        }
        BigDecimal requested = targets.stream().map(Target::amountOriginal)
                .map(SupplierOpenItemOffsetService::money).reduce(BigDecimal.ZERO, BigDecimal::add);
        if (requested.compareTo(source.balanceOriginal().abs()) > 0) {
            throw conflict("抵销金额超过贷项/索赔/预付款可用余额");
        }

        BigDecimal sourceOriginalRemaining = source.balanceOriginal();
        BigDecimal sourceLocalRemaining = source.balanceLocal();
        int lineSequence=1;
        for (Target input : targets) {
            OpenItem target = require(locked, input.payableId());
            BigDecimal amount = money(input.amountOriginal());
            if (!"PAYABLE".equals(target.kind())
                    || !Objects.equals(target.supplierId(), supplierId)
                    || !Objects.equals(target.currencyId(), currencyId)
                    || target.balanceOriginal() == null || target.balanceOriginal().signum() <= 0
                    || target.balanceLocal().signum() <= 0) {
                throw conflict("抵销目标必须是同供应商、同币种且仍有正余额的应付");
            }
            if (source.rate() == null || target.rate() == null
                    || source.rate().compareTo(target.rate()) != 0) {
                throw conflict("不同开账汇率的贷项/预付款抵销会产生汇兑差额；专用汇兑过账未完成前禁止自动抵销");
            }
            if (amount.compareTo(target.balanceOriginal()) > 0) {
                throw conflict("抵销金额超过目标应付未付原币余额：" + target.billNo());
            }
            BigDecimal sourceLocal = localSlice(
                    amount, sourceOriginalRemaining.abs(), sourceLocalRemaining.abs(), source.rate());
            BigDecimal targetLocal = localSlice(
                    amount, target.balanceOriginal(), target.balanceLocal(), target.rate());
            BigDecimal sourceAfterOriginal = money(sourceOriginalRemaining.add(amount));
            BigDecimal sourceAfterLocal = money(sourceLocalRemaining.add(sourceLocal));
            BigDecimal targetAfterOriginal = money(target.balanceOriginal().subtract(amount));
            BigDecimal targetAfterLocal = money(target.balanceLocal().subtract(targetLocal));

            updateOpenItem(source.id(), amount.negate(), sourceLocal.negate(),
                    sourceAfterOriginal, sourceAfterLocal, effectiveDate);
            updateOpenItem(target.id(), amount, targetLocal,
                    targetAfterOriginal, targetAfterLocal, effectiveDate);
            UUID allocationId = UUID.randomUUID();
            em.createNativeQuery("""
                    INSERT INTO supplier_open_item_offsets(
                        id, supplier_id, currency_id, source_ledger_id, target_ledger_id,
                        offset_batch_id,line_sequence,resolution_id,
                        amount_original, source_amount_local, target_amount_local,
                        source_balance_before_original, source_balance_after_original,
                        target_balance_before_original, target_balance_after_original,
                        effective_date, status, reason, applied_by,
                        source_rate,target_rate,created_by, updated_by)
                    VALUES (
                        :id, :supplierId, :currencyId, :sourceId, :targetId,
                        :batchId,:lineSequence,:resolutionId,:amountOriginal,:sourceLocal,:targetLocal,
                        :sourceBefore, :sourceAfter, :targetBefore, :targetAfter,
                        :effectiveDate,'APPLIED',:reason,:actor,:sourceRate,:targetRate,:actor,:actor)
                    """)
                    .setParameter("id", allocationId)
                    .setParameter("supplierId", supplierId)
                    .setParameter("currencyId", currencyId)
                    .setParameter("sourceId", source.id())
                    .setParameter("targetId", target.id())
                    .setParameter("batchId",offsetBatchId)
                    .setParameter("lineSequence",lineSequence)
                    .setParameter("resolutionId", resolutionId)
                    .setParameter("amountOriginal", amount)
                    .setParameter("sourceLocal", sourceLocal)
                    .setParameter("targetLocal", targetLocal)
                    .setParameter("sourceBefore", sourceOriginalRemaining)
                    .setParameter("sourceAfter", sourceAfterOriginal)
                    .setParameter("sourceRate",source.rate())
                    .setParameter("targetRate",target.rate())
                    .setParameter("targetBefore", target.balanceOriginal())
                    .setParameter("targetAfter", targetAfterOriginal)
                    .setParameter("effectiveDate", effectiveDate)
                    .setParameter("reason", bounded(reason, 2000, "抵销原因"))
                    .setParameter("actor", currentUser.requireId())
                    .executeUpdate();

            sourceOriginalRemaining = sourceAfterOriginal;
            sourceLocalRemaining = sourceAfterLocal;
            locked.put(source.id(), source.withBalances(sourceAfterOriginal, sourceAfterLocal));
            locked.put(target.id(), target.withBalances(targetAfterOriginal, targetAfterLocal));
            lineSequence++;
        }
    }

    @Transactional(propagation = Propagation.MANDATORY)
    public void reverseForResolution(UUID resolutionId, String reason) {
        reverseBatch(resolutionId,reason);
    }

    @Transactional(propagation = Propagation.MANDATORY)
    public void reverseBatch(UUID offsetBatchId,String reason) {
        tx.bind();
        @SuppressWarnings("unchecked")
        List<Object[]> identities=em.createNativeQuery("""
                SELECT DISTINCT supplier_id,currency_id
                FROM supplier_open_item_offsets
                WHERE offset_batch_id=:batchId AND status='APPLIED'
                """).setParameter("batchId",offsetBatchId).getResultList();
        if(identities.isEmpty())return;
        if(identities.size()!=1)throw conflict("抵销批次的供应商或币种不一致");
        UUID guardedSupplierId=(UUID)identities.getFirst()[0];
        UUID guardedCurrencyId=(UUID)identities.getFirst()[1];
        closedPeriodGuard.requireOpen(
                guardedSupplierId,guardedCurrencyId,BusinessTime.today(),"供应商抵销反转");

        @SuppressWarnings("unchecked")
        List<Object[]> rows = em.createNativeQuery("""
                SELECT id, source_ledger_id, target_ledger_id, amount_original,
                       source_amount_local, target_amount_local,
                       source_balance_before_original, source_balance_after_original,
                       target_balance_before_original, target_balance_after_original,
                       effective_date,resolution_id,supplier_id,currency_id
                FROM supplier_open_item_offsets
                WHERE offset_batch_id = :batchId AND status = 'APPLIED'
                ORDER BY line_sequence DESC
                FOR UPDATE
                """).setParameter("batchId",offsetBatchId).getResultList();
        if (rows.isEmpty()) return;
        List<UUID> ledgerIds = rows.stream()
                .flatMap(row -> java.util.stream.Stream.of((UUID) row[1], (UUID) row[2]))
                .distinct().sorted().toList();
        Map<UUID, OpenItem> locked = lock(ledgerIds);
        LocalDate effectiveDate=(LocalDate)rows.getFirst()[10];
        UUID resolutionId=(UUID)rows.getFirst()[11];
        UUID supplierId=(UUID)rows.getFirst()[12];
        UUID currencyId=(UUID)rows.getFirst()[13];
        for(Object[] row:rows){
            if(!Objects.equals(effectiveDate,row[10])||!Objects.equals(resolutionId,row[11])
                    ||!Objects.equals(supplierId,row[12])
                    ||!Objects.equals(currencyId,row[13])){
                throw conflict("抵销批次的生效日或索赔方案不一致");
            }
        }
        if(!Objects.equals(supplierId,guardedSupplierId)
                ||!Objects.equals(currencyId,guardedCurrencyId)){
            throw conflict("抵销批次身份已变化，请刷新后重试");
        }
        if(resolutionId!=null){
            glPosting.removeSupplierClaimOffsetBatch(offsetBatchId,effectiveDate);
        }
        for (Object[] row : rows) {
            UUID allocationId = (UUID) row[0];
            UUID sourceId = (UUID) row[1];
            UUID targetId = (UUID) row[2];
            BigDecimal amount = decimal(row[3]);
            BigDecimal sourceLocal = decimal(row[4]);
            BigDecimal targetLocal = decimal(row[5]);
            BigDecimal expectedSourceAfter = decimal(row[7]);
            BigDecimal expectedTargetAfter = decimal(row[9]);
            OpenItem source = require(locked, sourceId);
            OpenItem target = require(locked, targetId);
            if (source.balanceOriginal().compareTo(expectedSourceAfter) != 0
                    || target.balanceOriginal().compareTo(expectedTargetAfter) != 0) {
                throw conflict("抵销后余额已被后续业务使用，必须先反转后续核销");
            }
            BigDecimal sourceAfterOriginal = money(source.balanceOriginal().subtract(amount));
            BigDecimal sourceAfterLocal = money(source.balanceLocal().subtract(sourceLocal));
            BigDecimal targetAfterOriginal = money(target.balanceOriginal().add(amount));
            BigDecimal targetAfterLocal = money(target.balanceLocal().add(targetLocal));
            updateOpenItem(sourceId, amount, sourceLocal,
                    sourceAfterOriginal, sourceAfterLocal, null);
            updateOpenItem(targetId, amount.negate(), targetLocal.negate(),
                    targetAfterOriginal, targetAfterLocal, null);
            em.createNativeQuery("""
                    UPDATE supplier_open_item_offsets
                    SET status = 'REVERSED', row_version = row_version + 1,
                        reversed_by = :actor, reversed_at = now(), reverse_reason = :reason,
                        updated_by = :actor, updated_at = now()
                    WHERE id = :id AND status = 'APPLIED'
                    """)
                    .setParameter("actor", currentUser.requireId())
                    .setParameter("reason", bounded(reason, 2000, "反转原因"))
                    .setParameter("id", allocationId)
                    .executeUpdate();
            locked.put(sourceId, source.withBalances(sourceAfterOriginal, sourceAfterLocal));
            locked.put(targetId, target.withBalances(targetAfterOriginal, targetAfterLocal));
        }
    }

    private Map<UUID, OpenItem> lock(List<UUID> ids) {
        if (ids == null || ids.isEmpty()) return Map.of();
        @SuppressWarnings("unchecked")
        List<Object[]> rows = em.createNativeQuery("""
                SELECT id, supplier_id, currency_id, open_item_kind, bill_no,
                       amount_balance_original, amount_balance, exchange_rate
                FROM ar_ap_ledger
                WHERE id IN (:ids) AND direction = 'AP' AND status = 1
                  AND COALESCE(is_deleted, FALSE) = FALSE
                ORDER BY id
                FOR UPDATE
                """).setParameter("ids", ids).getResultList();
        if (rows.size() != ids.size()) {
            throw conflict("抵销涉及的应付、贷项或预付款不存在或已失效");
        }
        Map<UUID, OpenItem> result = new HashMap<>();
        for (Object[] row : rows) {
            OpenItem item = new OpenItem((UUID) row[0], (UUID) row[1], (UUID) row[2],
                    Objects.toString(row[3], null), Objects.toString(row[4], null),
                    nullableDecimal(row[5]), decimal(row[6]), nullableDecimal(row[7]));
            result.put(item.id(), item);
        }
        return result;
    }

    private void updateOpenItem(
            UUID id,
            BigDecimal offsetOriginalDelta,
            BigDecimal offsetLocalDelta,
            BigDecimal balanceOriginal,
            BigDecimal balanceLocal,
            LocalDate settledDate) {
        int updated = em.createNativeQuery("""
                UPDATE ar_ap_ledger
                SET amount_offset_original = amount_offset_original + :offsetOriginal,
                    amount_offset_local = amount_offset_local + :offsetLocal,
                    amount_balance_original = :balanceOriginal,
                    amount_balance = :balanceLocal,
                    is_settled = (:balanceLocal = 0),
                    settled_date = CASE WHEN :balanceLocal = 0 THEN COALESCE(CAST(:settledDate AS date), CURRENT_DATE) ELSE NULL END,
                    updated_at = now()
                WHERE id = :id
                """)
                .setParameter("offsetOriginal", money(offsetOriginalDelta))
                .setParameter("offsetLocal", money(offsetLocalDelta))
                .setParameter("balanceOriginal", money(balanceOriginal))
                .setParameter("balanceLocal", money(balanceLocal))
                .setParameter("settledDate", settledDate)
                .setParameter("id", id)
                .executeUpdate();
        if (updated != 1) throw conflict("应付抵销余额更新失败");
    }

    private static BigDecimal localSlice(
            BigDecimal amountOriginal,
            BigDecimal availableOriginal,
            BigDecimal availableLocal,
            BigDecimal rate) {
        if (amountOriginal.compareTo(availableOriginal) == 0) {
            return money(availableLocal); // final slice absorbs historical rounding tail
        }
        if (rate == null || rate.signum() <= 0) {
            throw conflict("抵销项目开账汇率缺失或无效，不能自动换算");
        }
        BigDecimal calculated = money(amountOriginal.multiply(rate));
        if (calculated.compareTo(availableLocal) > 0) {
            throw conflict("抵销账面本币超过可用余额");
        }
        return calculated;
    }

    private static OpenItem require(Map<UUID, OpenItem> items, UUID id) {
        OpenItem value = items.get(id);
        if (value == null) throw conflict("应付抵销项目不存在");
        return value;
    }

    private static BigDecimal money(BigDecimal value) {
        return value.setScale(MONEY_SCALE, RoundingMode.HALF_UP);
    }

    private static BigDecimal decimal(Object value) {
        if (value instanceof BigDecimal decimal) return decimal;
        return new BigDecimal(value.toString());
    }

    private static BigDecimal nullableDecimal(Object value) {
        return value == null ? null : decimal(value);
    }

    private static String bounded(String value, int max, String label) {
        if (value == null || value.isBlank()) throw validation(label + "不能为空");
        String trimmed = value.trim();
        if (trimmed.length() > max) throw validation(label + "不能超过 " + max + " 个字符");
        return trimmed;
    }

    private static ApiException validation(String message) {
        return new ApiException(ErrorCode.VALIDATION_FAILED, message);
    }

    private static ApiException conflict(String message) {
        return new ApiException(ErrorCode.CONFLICT, message);
    }

    public record Target(UUID payableId, BigDecimal amountOriginal) {}

    private record OpenItem(
            UUID id,
            UUID supplierId,
            UUID currencyId,
            String kind,
            String billNo,
            BigDecimal balanceOriginal,
            BigDecimal balanceLocal,
            BigDecimal rate) {
        private OpenItem withBalances(BigDecimal original, BigDecimal local) {
            return new OpenItem(id, supplierId, currencyId, kind, billNo, original, local, rate);
        }
    }
}
