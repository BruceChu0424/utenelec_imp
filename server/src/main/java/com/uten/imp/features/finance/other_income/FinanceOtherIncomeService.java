package com.uten.imp.features.finance.other_income;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.common.web.Pageables;
import com.uten.imp.features.finance.other_income.dto.FinanceOtherIncomeDetail;
import com.uten.imp.features.finance.other_income.dto.FinanceOtherIncomeItemDto;
import com.uten.imp.features.finance.other_income.dto.FinanceOtherIncomeItemInput;
import com.uten.imp.features.finance.other_income.dto.FinanceOtherIncomeListItem;
import com.uten.imp.features.finance.other_income.dto.FinanceOtherIncomeQueryFilter;
import com.uten.imp.features.finance.other_income.dto.FinanceOtherIncomeSaveRequest;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import jakarta.persistence.criteria.CriteriaBuilder;
import jakarta.persistence.criteria.Predicate;
import jakarta.persistence.criteria.Root;
import lombok.RequiredArgsConstructor;
import org.springframework.data.domain.Page;
import org.springframework.data.domain.Pageable;
import org.springframework.data.domain.Sort;
import org.springframework.data.jpa.domain.Specification;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.time.OffsetDateTime;
import java.util.ArrayList;
import java.util.List;
import java.util.UUID;

/**
 * 其它收入单服务：CRUD（主 + 明细）+ 审核状态机（仅动账户余额，不涉 AR/AP）。
 *
 * <p>与 {@code FinanceExpenseService} 对称（账户累加方向相反：money-in）。
 * 审核（0→1）：{@code accounts.balance_current += amount_local, receipts_total += amount_local} +
 * 写 finance_reconciliations(source_doc_type=INCOME, in_amount=amount_local)。取代老库 TRI_GetItem。
 */
@Service
@RequiredArgsConstructor
public class FinanceOtherIncomeService {

    private static final short STATUS_DRAFT = 0;
    private static final short STATUS_APPROVED = 1;
    private static final short STATUS_REVERSED = -1;

    public static final String RECON_SOURCE = "INCOME";

    private final FinanceOtherIncomeRepository incomeRepo;
    private final FinanceOtherIncomeItemRepository itemRepo;
    private final TxSessionVars tx;
    private final EntityManager em;

    @Transactional(readOnly = true)
    public PageResponse<FinanceOtherIncomeListItem> list(FinanceOtherIncomeQueryFilter f, int page, int size) {
        Specification<FinanceOtherIncome> spec = (Root<FinanceOtherIncome> root, jakarta.persistence.criteria.CriteriaQuery<?> q,
                                                  CriteriaBuilder cb) -> {
            List<Predicate> ps = new ArrayList<>();
            ps.add(cb.isFalse(root.get("deleted")));
            if (f.keyword() != null && !f.keyword().isBlank()) {
                ps.add(cb.like(cb.lower(root.get("billNo")), "%" + f.keyword().toLowerCase() + "%"));
            }
            if (f.accountId() != null) ps.add(cb.equal(root.get("accountId"), f.accountId()));
            if (f.status() != null) ps.add(cb.equal(root.get("status"), f.status()));
            if (f.dateFrom() != null) ps.add(cb.greaterThanOrEqualTo(root.get("billDate"), f.dateFrom()));
            if (f.dateTo() != null) ps.add(cb.lessThanOrEqualTo(root.get("billDate"), f.dateTo()));
            // departmentId 走明细表，本期略（前端报表侧按部门汇总）。
            return cb.and(ps.toArray(new Predicate[0]));
        };
        Pageable pageable = Pageables.of(page, size, Sort.by(Sort.Direction.DESC, "billDate"));
        Page<FinanceOtherIncome> p = incomeRepo.findAll(spec, pageable);
        return new PageResponse<>(p.map(this::toList).getContent(), page, size, p.getTotalElements(), p.getTotalPages());
    }

    @Transactional(readOnly = true)
    public FinanceOtherIncomeDetail detail(UUID id) {
        FinanceOtherIncome o = require(id);
        List<FinanceOtherIncomeItemDto> items = itemRepo.findByIncomeIdOrderByLineNoAsc(id).stream()
                .map(this::toItemDto).toList();
        return toDetail(o, items);
    }

    @Transactional
    public FinanceOtherIncomeDetail create(FinanceOtherIncomeSaveRequest req) {
        tx.bind();
        assertBillNoFree(req.getBillNo(), null);
        FinanceOtherIncome o = new FinanceOtherIncome();
        applyHeader(req, o);
        o.setStatus(STATUS_DRAFT);
        incomeRepo.save(o);
        List<FinanceOtherIncomeItemDto> items = saveItems(o, req.getItems());
        applyTotals(o, items);
        return toDetail(o, items);
    }

    @Transactional
    public FinanceOtherIncomeDetail update(UUID id, FinanceOtherIncomeSaveRequest req) {
        tx.bind();
        FinanceOtherIncome o = require(id);
        if (o.getStatus() != STATUS_DRAFT) {
            throw new ApiException(ErrorCode.BUSINESS, "仅草稿单据可编辑");
        }
        assertBillNoFree(req.getBillNo(), id);
        applyHeader(req, o);
        itemRepo.deleteByIncomeId(id);
        itemRepo.flush();
        List<FinanceOtherIncomeItemDto> items = saveItems(o, req.getItems());
        applyTotals(o, items);
        return toDetail(o, items);
    }

    @Transactional
    public void delete(UUID id) {
        tx.bind();
        FinanceOtherIncome o = require(id);
        if (o.getStatus() == STATUS_APPROVED) {
            throw new ApiException(ErrorCode.BUSINESS, "已审核单据不可删，请红冲");
        }
        o.setDeleted(true);
        o.setDeletedAt(OffsetDateTime.now());
        incomeRepo.save(o);
    }

    /** 审核：status 0→1，账户累加 + 写流水（不涉 AR/AP）。 */
    @Transactional
    public FinanceOtherIncomeDetail approve(UUID id) {
        tx.bind();
        FinanceOtherIncome o = require(id);
        if (o.getStatus() == null || o.getStatus() != STATUS_DRAFT) {
            throw new ApiException(ErrorCode.BUSINESS, "仅草稿单据可审核");
        }
        if (o.getAccountId() == null) {
            throw new ApiException(ErrorCode.BUSINESS, "收入单需指定收款账户");
        }
        BigDecimal amountLocal = nz(o.getAmountLocal());
        if (amountLocal.signum() != 0) {
            adjustAccount(o.getAccountId(), amountLocal);
        }
        insertReconciliation(o, amountLocal);
        o.setStatus(STATUS_APPROVED);
        incomeRepo.save(o);
        return detail(id);
    }

    /** 红冲：status 1→-1，反向。 */
    @Transactional
    public FinanceOtherIncomeDetail reverse(UUID id) {
        tx.bind();
        FinanceOtherIncome o = require(id);
        if (o.getStatus() == null || o.getStatus() != STATUS_APPROVED) {
            throw new ApiException(ErrorCode.BUSINESS, "仅已审核单据可红冲");
        }
        BigDecimal amountLocal = nz(o.getAmountLocal());
        if (amountLocal.signum() != 0) {
            adjustAccount(o.getAccountId(), amountLocal.negate());
        }
        deleteReconciliation(o.getId());
        o.setStatus(STATUS_REVERSED);
        incomeRepo.save(o);
        return detail(id);
    }

    // ===================== 账户/流水 =====================

    /** 收款账户累加（money-in）：balance_current += delta, receipts_total += delta（delta 已带符号）。 */
    private void adjustAccount(UUID accountId, BigDecimal delta) {
        int rows = em.createNativeQuery("""
                UPDATE accounts
                SET balance_current = COALESCE(balance_current, 0) + :amt,
                    receipts_total  = COALESCE(receipts_total, 0) + :amt,
                    updated_at = now()
                WHERE id = :id
                """)
                .setParameter("amt", delta)
                .setParameter("id", accountId)
                .executeUpdate();
        if (rows == 0) {
            throw new ApiException(ErrorCode.BUSINESS, "账户不存在：" + accountId);
        }
    }

    private void insertReconciliation(FinanceOtherIncome o, BigDecimal amountLocal) {
        em.createNativeQuery("""
                INSERT INTO finance_reconciliations
                  (bill_no, source_doc_type, source_doc_id, account_id, in_amount, out_amount,
                   bill_date, settled_date, source_remark, legacy_bstyle, created_at, updated_at, is_deleted)
                VALUES (:billNo, :src, :sid, :acc, :inAmt, 0, :bd, :sd, :sr, 22, now(), now(), false)
                """)
                .setParameter("billNo", o.getBillNo())
                .setParameter("src", RECON_SOURCE)
                .setParameter("sid", o.getId())
                .setParameter("acc", o.getAccountId())
                .setParameter("inAmt", amountLocal)
                .setParameter("bd", OffsetDateTime.now())
                .setParameter("sd", OffsetDateTime.now())
                .setParameter("sr", o.getRemark())
                .executeUpdate();
    }

    private void deleteReconciliation(UUID incomeId) {
        em.createNativeQuery(
                "DELETE FROM finance_reconciliations WHERE source_doc_id = :sid AND source_doc_type = :src")
                .setParameter("sid", incomeId)
                .setParameter("src", RECON_SOURCE)
                .executeUpdate();
    }

    // ===================== CRUD 辅助 =====================

    private void applyHeader(FinanceOtherIncomeSaveRequest req, FinanceOtherIncome o) {
        o.setBillNo(req.getBillNo());
        o.setBillDate(req.getBillDate());
        o.setAccountId(req.getAccountId());
        o.setCounterpartAccountId(req.getCounterpartAccountId());
        o.setCurrencyId(req.getCurrencyId());
        if (req.getExchangeRate() != null) o.setExchangeRate(req.getExchangeRate());
        if (req.getAmountOriginal() != null) o.setAmountOriginal(req.getAmountOriginal());
        if (req.getAmountLocal() != null) o.setAmountLocal(req.getAmountLocal());
        o.setReceiptMethodId(req.getReceiptMethodId());
        o.setReceiptMethodLegacyId(req.getReceiptMethodLegacyId());
        o.setOperatorId(req.getOperatorId());
        o.setRemark(req.getRemark());
    }

    private List<FinanceOtherIncomeItemDto> saveItems(FinanceOtherIncome o, List<FinanceOtherIncomeItemInput> inputs) {
        if (inputs == null || inputs.isEmpty()) return List.of();
        List<FinanceOtherIncomeItemDto> out = new ArrayList<>(inputs.size());
        int auto = 1;
        for (FinanceOtherIncomeItemInput l : inputs) {
            FinanceOtherIncomeItem it = new FinanceOtherIncomeItem();
            it.setIncomeId(o.getId());
            it.setBillNo(o.getBillNo());
            it.setBillDate(o.getBillDate());
            it.setLineNo(l.getLineNo() != null ? l.getLineNo() : auto);
            it.setIncomeStyleId(l.getIncomeStyleId());
            it.setDepartmentId(l.getDepartmentId());
            it.setCounterpartAccountId(l.getCounterpartAccountId());
            it.setCounterpartName(l.getCounterpartName());
            it.setQty(l.getQty());
            it.setPrice(l.getPrice());
            it.setAmountOriginal(l.getAmountOriginal());
            it.setAmountLocal(l.getAmountLocal());
            it.setSummary(l.getSummary());
            it.setRemark(l.getRemark());
            itemRepo.save(it);
            out.add(toItemDto(it));
            auto++;
        }
        return out;
    }

    private void applyTotals(FinanceOtherIncome o, List<FinanceOtherIncomeItemDto> items) {
        BigDecimal local = items.stream().map(i -> nz(i.getAmountLocal())).reduce(BigDecimal.ZERO, BigDecimal::add);
        BigDecimal original = items.stream().map(i -> nz(i.getAmountOriginal())).reduce(BigDecimal.ZERO, BigDecimal::add);
        o.setAmountLocal(local);
        o.setAmountOriginal(original);
        incomeRepo.save(o);
    }

    private void assertBillNoFree(String billNo, UUID excludeId) {
        if (billNo == null || billNo.isBlank()) return;
        incomeRepo.findByBillNo(billNo).ifPresent(existing -> {
            if (excludeId == null || !existing.getId().equals(excludeId)) {
                throw new ApiException(ErrorCode.CONFLICT, "单号已存在：" + billNo);
            }
        });
    }

    private FinanceOtherIncomeItemDto toItemDto(FinanceOtherIncomeItem it) {
        return new FinanceOtherIncomeItemDto(it.getId(), it.getLineNo(), it.getIncomeStyleId(),
                it.getDepartmentId(), it.getCounterpartAccountId(), it.getCounterpartName(),
                it.getQty(), it.getPrice(), it.getAmountOriginal(), it.getAmountLocal(),
                it.getSummary(), it.getRemark());
    }

    private FinanceOtherIncomeListItem toList(FinanceOtherIncome o) {
        return new FinanceOtherIncomeListItem(o.getId(), o.getBillNo(), o.getBillDate(),
                o.getAccountId(), o.getAmountLocal(), o.getStatus(), o.getLegacyId());
    }

    private FinanceOtherIncomeDetail toDetail(FinanceOtherIncome o, List<FinanceOtherIncomeItemDto> items) {
        return new FinanceOtherIncomeDetail(o.getId(), o.getLegacyId(), o.getBillNo(), o.getBillDate(),
                o.getAccountId(), o.getCounterpartAccountId(), o.getCurrencyId(), o.getExchangeRate(),
                o.getAmountOriginal(), o.getAmountLocal(), o.getReceiptMethodId(), o.getReceiptMethodLegacyId(),
                o.getOperatorId(), o.getMakerId(), o.getApproverId(), o.getRemark(),
                o.getStatus(), o.isClosed(), items);
    }

    private FinanceOtherIncome require(UUID id) {
        return incomeRepo.findById(id).filter(o -> !o.isDeleted())
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "其它收入单不存在"));
    }

    private static BigDecimal nz(BigDecimal x) {
        return x == null ? BigDecimal.ZERO : x;
    }
}
