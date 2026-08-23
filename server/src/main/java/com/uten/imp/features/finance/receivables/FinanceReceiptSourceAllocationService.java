package com.uten.imp.features.finance.receivables;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.finance.receipt.FinanceReceipt;
import com.uten.imp.features.finance.receipt.FinanceReceiptLine;
import com.uten.imp.security.SecurityContextCurrentUser;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.math.RoundingMode;
import java.util.List;
import java.util.UUID;

/**
 * Freezes each approved ordinary receipt line onto immutable SALES_ORDER source refs.
 * New facts use server FIFO; historical multi-source movements are never guessed.
 */
@Service
@RequiredArgsConstructor
public class FinanceReceiptSourceAllocationService {
    private static final int MONEY_SCALE = 4;

    private final EntityManager em;
    private final SecurityContextCurrentUser currentUser;

    @Transactional(propagation = Propagation.MANDATORY)
    public void allocateApprovedReceipt(FinanceReceipt receipt, List<FinanceReceiptLine> lines) {
        if (!"AR_SETTLEMENT".equals(receipt.getReceiptKind()) || lines == null || lines.isEmpty()) {
            throw conflict("普通应收收款必须有明确的核销明细和单据类型");
        }
        List<FinanceReceiptLine> ordered = lines.stream()
                .sorted(java.util.Comparator.comparing(
                        line -> line.getLineNo() == null ? Integer.MAX_VALUE : line.getLineNo()))
                .toList();
        for (FinanceReceiptLine line : ordered) {
            allocateLine(receipt, line);
        }
    }

    @Transactional(propagation = Propagation.MANDATORY)
    public void reverseApprovedReceipt(FinanceReceipt receipt, List<FinanceReceiptLine> lines) {
        if (!"AR_SETTLEMENT".equals(receipt.getReceiptKind())) {
            throw conflict("只有普通应收收款存在销售单来源分配");
        }
        for (FinanceReceiptLine line : lines) {
            long active = number(em.createNativeQuery("""
                    SELECT COUNT(*) FROM finance_receipt_source_allocations
                    WHERE receipt_line_id=:lineId AND status='APPLIED'
                    """).setParameter("lineId", line.getId()).getSingleResult()).longValue();
            if (active == 0) {
                throw conflict("该收款的销售单来源尚未精确分配，禁止红冲；请先由财务完成历史来源对账");
            }
            long later = number(em.createNativeQuery("""
                    SELECT COUNT(*)
                    FROM finance_receipt_source_allocations current_alloc
                    WHERE current_alloc.receipt_line_id=:lineId
                      AND current_alloc.status='APPLIED'
                      AND (
                        EXISTS(SELECT 1 FROM finance_receipt_source_allocations later_alloc
                               WHERE later_alloc.source_ref_id=current_alloc.source_ref_id
                                 AND later_alloc.status='APPLIED'
                                 AND (later_alloc.effective_date,later_alloc.created_at,later_alloc.id)
                                   >(current_alloc.effective_date,current_alloc.created_at,current_alloc.id))
                        OR EXISTS(SELECT 1 FROM customer_open_item_offsets later_offset
                                  WHERE later_offset.target_source_ref_id=current_alloc.source_ref_id
                                    AND later_offset.status='APPLIED'
                                    AND (later_offset.effective_date,later_offset.created_at,later_offset.id)
                                      >(current_alloc.effective_date,current_alloc.created_at,current_alloc.id)))
                    """).setParameter("lineId", line.getId()).getSingleResult()).longValue();
            if (later > 0) {
                throw conflict("该收款来源已有后续收款或预收转销，必须按后进先出先反转后续业务");
            }
        }
        int updated = em.createNativeQuery("""
                UPDATE finance_receipt_source_allocations
                SET status='REVERSED',reversed_at=now(),updated_at=now(),updated_by=:actor
                WHERE receipt_id=:receiptId AND status='APPLIED'
                """).setParameter("actor", currentUser.requireId())
                .setParameter("receiptId", receipt.getId()).executeUpdate();
        if (updated == 0) throw conflict("收款销售单来源分配缺失或已反转");
    }

    @SuppressWarnings("unchecked")
    private void allocateLine(FinanceReceipt receipt, FinanceReceiptLine line) {
        if (line.getAppliedLedgerId() == null || line.getId() == null) {
            throw validation("收款明细必须关联稳定的应收台账 UUID");
        }
        long existing = number(em.createNativeQuery("""
                SELECT COUNT(*) FROM finance_receipt_source_allocations
                WHERE receipt_line_id=:lineId
                """).setParameter("lineId", line.getId()).getSingleResult()).longValue();
        if (existing != 0) throw conflict("收款明细已经生成销售单来源分配，禁止重复审核");

        Object[] ledger = (Object[]) em.createNativeQuery("""
                SELECT amount_received_original,amount_write_off_original,exchange_rate,
                       amount_original,amount_original_local
                FROM ar_ap_ledger
                WHERE id=:ledgerId AND direction='AR' AND open_item_kind='RECEIVABLE'
                  AND status=1 AND COALESCE(is_deleted,FALSE)=FALSE
                FOR UPDATE
                """).setParameter("ledgerId", line.getAppliedLedgerId()).getSingleResult();
        BigDecimal cash = money(line.getAmountOriginal());
        BigDecimal writeOff = money(line.getWriteOffAmount());
        BigDecimal applied = money(cash.add(writeOff));
        BigDecimal ledgerReceived = decimal(ledger[0]);
        BigDecimal ledgerWriteOff = decimal(ledger[1]);
        BigDecimal recognitionRate = positive(decimal(ledger[2]), "应收开账汇率");
        BigDecimal priorMovement = money(ledgerReceived.add(ledgerWriteOff).subtract(applied));
        BigDecimal allocatedPrior = decimal(em.createNativeQuery("""
                SELECT COALESCE(SUM(cash_original+write_off_original),0)
                FROM finance_receipt_source_allocations
                WHERE ledger_id=:ledgerId AND status='APPLIED'
                """).setParameter("ledgerId", line.getAppliedLedgerId()).getSingleResult());
        if (priorMovement.signum() < 0 || priorMovement.compareTo(allocatedPrior) != 0) {
            throw conflict("该应收存在未归属到销售单的历史到账/冲销，禁止继续自动 FIFO；请先财务人工来源对账");
        }

        List<Object[]> refs = em.createNativeQuery("""
                SELECT ref.id,ref.source_id,ref.source_sequence,ref.amount_original,ref.amount_local,
                       COALESCE((SELECT SUM(a.cash_original+a.write_off_original)
                                 FROM finance_receipt_source_allocations a
                                 WHERE a.source_ref_id=ref.id AND a.status='APPLIED'),0)
                         + COALESCE((SELECT SUM(o.amount_original)
                                     FROM customer_open_item_offsets o
                                     WHERE o.target_source_ref_id=ref.id AND o.status='APPLIED'),0) consumed_original,
                       COALESCE((SELECT SUM(a.applied_book_local)
                                 FROM finance_receipt_source_allocations a
                                 WHERE a.source_ref_id=ref.id AND a.status='APPLIED'),0)
                         + COALESCE((SELECT SUM(o.target_amount_local)
                                     FROM customer_open_item_offsets o
                                     WHERE o.target_source_ref_id=ref.id AND o.status='APPLIED'),0) consumed_local
                FROM ar_ap_source_refs ref
                WHERE ref.ledger_id=:ledgerId AND ref.source_type='SALES_ORDER'
                ORDER BY ref.source_sequence,ref.id
                FOR UPDATE
                """).setParameter("ledgerId", line.getAppliedLedgerId()).getResultList();
        if (refs.isEmpty()) {
            throw conflict("该应收没有不可变 SALES_ORDER 来源 UUID，禁止猜测收款归属");
        }
        BigDecimal sourceTotal = refs.stream().map(row -> decimal(row[3]))
                .reduce(BigDecimal.ZERO, BigDecimal::add);
        if (sourceTotal.compareTo(decimal(ledger[3])) != 0) {
            throw conflict("应收原币与销售单来源原币不守恒，禁止自动分配");
        }

        BigDecimal cashRemaining = cash;
        BigDecimal cashLocalRemaining = money(line.getAmountLocal());
        BigDecimal writeOffRemaining = writeOff;
        BigDecimal writeOffLocalRemaining = money(line.getWriteOffLocal());
        BigDecimal appliedRemaining = applied;
        BigDecimal bookLocalRemaining = money(line.getAppliedAmountLocal());
        int lineSequence = 1;
        for (Object[] row : refs) {
            BigDecimal refOriginalRemaining = money(decimal(row[3]).subtract(decimal(row[5])));
            BigDecimal refLocalRemaining = money(decimal(row[4]).subtract(decimal(row[6])));
            if (refOriginalRemaining.signum() < 0 || refLocalRemaining.signum() < 0) {
                throw conflict("销售单来源已被超额核销，禁止继续收款");
            }
            if (appliedRemaining.signum() == 0) break;
            BigDecimal slice = appliedRemaining.min(refOriginalRemaining);
            if (slice.signum() == 0) continue;
            BigDecimal cashSlice = cashRemaining.min(slice);
            BigDecimal writeOffSlice = money(slice.subtract(cashSlice));
            BigDecimal cashLocal = localPart(cashSlice, cashRemaining, cashLocalRemaining,
                    positive(line.getExchangeRate(), "到账汇率"));
            BigDecimal writeOffLocal = localPart(writeOffSlice, writeOffRemaining,
                    writeOffLocalRemaining, positive(line.getExchangeRate(), "到账汇率"));
            BigDecimal bookLocal = appliedRemaining.compareTo(slice) == 0
                    ? bookLocalRemaining
                    : (refOriginalRemaining.compareTo(slice) == 0
                        ? refLocalRemaining : money(slice.multiply(recognitionRate)));
            if (bookLocal.signum() < 0 || bookLocal.compareTo(refLocalRemaining) > 0
                    || bookLocal.compareTo(bookLocalRemaining) > 0) {
                throw conflict("销售单来源账面本币不足或尾差不守恒，禁止自动分配");
            }
            em.createNativeQuery("""
                    INSERT INTO finance_receipt_source_allocations(
                        id,receipt_id,receipt_line_id,ledger_id,source_ref_id,sales_order_id,
                        line_sequence,source_sequence,cash_original,cash_local,
                        write_off_original,write_off_local,applied_book_local,exchange_difference,
                        effective_date,status,created_by,updated_by)
                    VALUES(:id,:receiptId,:lineId,:ledgerId,:sourceRefId,:salesOrderId,
                           :lineSequence,:sourceSequence,:cashOriginal,:cashLocal,
                           :writeOffOriginal,:writeOffLocal,:bookLocal,:exchangeDifference,
                           :effectiveDate,'APPLIED',:actor,:actor)
                    """)
                    .setParameter("id", UUID.randomUUID())
                    .setParameter("receiptId", receipt.getId())
                    .setParameter("lineId", line.getId())
                    .setParameter("ledgerId", line.getAppliedLedgerId())
                    .setParameter("sourceRefId", row[0])
                    .setParameter("salesOrderId", row[1])
                    .setParameter("lineSequence", lineSequence++)
                    .setParameter("sourceSequence", row[2])
                    .setParameter("cashOriginal", cashSlice)
                    .setParameter("cashLocal", cashLocal)
                    .setParameter("writeOffOriginal", writeOffSlice)
                    .setParameter("writeOffLocal", writeOffLocal)
                    .setParameter("bookLocal", bookLocal)
                    .setParameter("exchangeDifference", money(cashLocal.add(writeOffLocal).subtract(bookLocal)))
                    .setParameter("effectiveDate", receipt.getBillDate())
                    .setParameter("actor", currentUser.requireId())
                    .executeUpdate();
            cashRemaining = money(cashRemaining.subtract(cashSlice));
            cashLocalRemaining = money(cashLocalRemaining.subtract(cashLocal));
            writeOffRemaining = money(writeOffRemaining.subtract(writeOffSlice));
            writeOffLocalRemaining = money(writeOffLocalRemaining.subtract(writeOffLocal));
            appliedRemaining = money(appliedRemaining.subtract(slice));
            bookLocalRemaining = money(bookLocalRemaining.subtract(bookLocal));
        }
        if (cashRemaining.signum() != 0 || cashLocalRemaining.signum() != 0
                || writeOffRemaining.signum() != 0 || writeOffLocalRemaining.signum() != 0
                || appliedRemaining.signum() != 0 || bookLocalRemaining.signum() != 0) {
            throw conflict("销售单来源可用余额不足，收款来源分配不守恒");
        }
    }

    private static BigDecimal localPart(
            BigDecimal originalPart, BigDecimal originalRemaining,
            BigDecimal localRemaining, BigDecimal rate) {
        if (originalPart.signum() == 0) return BigDecimal.ZERO.setScale(MONEY_SCALE);
        if (originalPart.compareTo(originalRemaining) == 0) return money(localRemaining);
        BigDecimal value = money(originalPart.multiply(rate));
        if (value.compareTo(localRemaining) > 0) throw conflict("到账本币分配超过剩余快照");
        return value;
    }

    private static BigDecimal positive(BigDecimal value, String label) {
        if (value == null || value.signum() <= 0) throw conflict(label + "缺失或无效");
        return value;
    }

    private static BigDecimal money(BigDecimal value) {
        return decimal(value).setScale(MONEY_SCALE, RoundingMode.HALF_UP);
    }

    private static BigDecimal decimal(Object value) {
        if (value == null) return BigDecimal.ZERO;
        if (value instanceof BigDecimal decimal) return decimal;
        return new BigDecimal(value.toString());
    }

    private static Number number(Object value) {
        if (value instanceof Number number) return number;
        return new BigDecimal(value.toString());
    }

    private static ApiException validation(String message) {
        return new ApiException(ErrorCode.VALIDATION_FAILED, message);
    }

    private static ApiException conflict(String message) {
        return new ApiException(ErrorCode.CONFLICT, message);
    }
}
