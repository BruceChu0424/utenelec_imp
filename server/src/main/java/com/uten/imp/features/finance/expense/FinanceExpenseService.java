package com.uten.imp.features.finance.expense;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.common.web.Pageables;
import com.uten.imp.common.web.TableSort;
import com.uten.imp.features.finance.expense.dto.FinanceExpenseDetail;
import com.uten.imp.features.finance.expense.dto.FinanceExpenseItemDto;
import com.uten.imp.features.finance.expense.dto.FinanceExpenseItemInput;
import com.uten.imp.features.finance.expense.dto.FinanceExpenseListItem;
import com.uten.imp.features.finance.expense.dto.FinanceExpenseQueryFilter;
import com.uten.imp.features.finance.expense.dto.FinanceExpenseSaveRequest;
import com.uten.imp.security.SecurityContextCurrentUser;
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
import java.util.Map;
import java.util.UUID;

/**
 * 一般费用单服务：CRUD（主 + 明细）+ 审核状态机（仅动账户余额，不涉 AR/AP）。
 *
 * <p>审核（0→1）：{@code accounts.balance_current -= amount_local, payments_total += amount_local} +
 * 写 finance_reconciliations(source_doc_type=EXPENSE, out_amount=amount_local)。取代老库 TRI_PaidItem。
 *
 * <p>红冲（1→-1）反向。total 由明细 amount_local 求和。
 */
@Service
@RequiredArgsConstructor
public class FinanceExpenseService {

    private static final short STATUS_DRAFT = 0;
    private static final short STATUS_APPROVED = 1;
    private static final short STATUS_REVERSED = -1;

    /** 列排序白名单：前端列 key → JPA 实体属性名（日期/金额可排序；命中才排序，否则默认 billDate DESC）。 */
    private static final Map<String, String> ALLOWED_SORT = Map.of("billDate", "billDate", "amountLocal", "amountLocal");

    public static final String RECON_SOURCE = "EXPENSE";

    private final FinanceExpenseRepository expenseRepo;
    private final FinanceExpenseItemRepository itemRepo;
    private final TxSessionVars tx;
    private final SecurityContextCurrentUser currentUser;
    private final EntityManager em;

    @Transactional(readOnly = true)
    public PageResponse<FinanceExpenseListItem> list(FinanceExpenseQueryFilter f, int page, int size, String sort, String order) {
        Specification<FinanceExpense> spec = (Root<FinanceExpense> root, jakarta.persistence.criteria.CriteriaQuery<?> q,
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
            // departmentId 走明细表（多对一），主表过滤需 EXISTS；本期略，前端报表侧按部门汇总。
            return cb.and(ps.toArray(new Predicate[0]));
        };
        Pageable pageable = Pageables.of(page, size,
                TableSort.resolve(sort, order, Sort.by(Sort.Direction.DESC, "billDate"), ALLOWED_SORT));
        Page<FinanceExpense> p = expenseRepo.findAll(spec, pageable);
        return new PageResponse<>(p.map(this::toList).getContent(), page, size, p.getTotalElements(), p.getTotalPages());
    }

    @Transactional(readOnly = true)
    public FinanceExpenseDetail detail(UUID id) {
        FinanceExpense e = require(id);
        List<FinanceExpenseItemDto> items = itemRepo.findByExpenseIdOrderByLineNoAsc(id).stream()
                .map(this::toItemDto).toList();
        return toDetail(e, items);
    }

    @Transactional
    public FinanceExpenseDetail create(FinanceExpenseSaveRequest req) {
        tx.bind();
        assertBillNoFree(req.getBillNo(), null);
        FinanceExpense e = new FinanceExpense();
        applyHeader(req, e);
        e.setStatus(STATUS_DRAFT);
        e.setMakerId(currentUser.requireId());   // 制单=当前登录用户（报表按 maker_id 解析制单员）
        expenseRepo.save(e);
        List<FinanceExpenseItemDto> items = saveItems(e, req.getItems());
        applyTotals(e, items);
        return toDetail(e, items);
    }

    @Transactional
    public FinanceExpenseDetail update(UUID id, FinanceExpenseSaveRequest req) {
        tx.bind();
        FinanceExpense e = require(id);
        if (e.getStatus() != STATUS_DRAFT) {
            throw new ApiException(ErrorCode.BUSINESS, "仅草稿单据可编辑");
        }
        assertBillNoFree(req.getBillNo(), id);
        applyHeader(req, e);
        itemRepo.deleteByExpenseId(id);
        itemRepo.flush();
        List<FinanceExpenseItemDto> items = saveItems(e, req.getItems());
        applyTotals(e, items);
        return toDetail(e, items);
    }

    @Transactional
    public void delete(UUID id) {
        tx.bind();
        FinanceExpense e = require(id);
        if (e.getStatus() == STATUS_APPROVED) {
            throw new ApiException(ErrorCode.BUSINESS, "已审核单据不可删，请红冲");
        }
        e.setDeleted(true);
        e.setDeletedAt(OffsetDateTime.now());
        expenseRepo.save(e);
    }

    /** 审核：status 0→1，账户扣减 + 写流水（不涉 AR/AP）。 */
    @Transactional
    public FinanceExpenseDetail approve(UUID id) {
        tx.bind();
        FinanceExpense e = require(id);
        if (e.getStatus() == null || e.getStatus() != STATUS_DRAFT) {
            throw new ApiException(ErrorCode.BUSINESS, "仅草稿单据可审核");
        }
        if (e.getAccountId() == null) {
            throw new ApiException(ErrorCode.BUSINESS, "费用单需指定付款账户");
        }
        e.setApproverId(currentUser.requireId()); // 审核=当前登录用户（报表按 approver_id 解析审核员）
        BigDecimal amountLocal = nz(e.getAmountLocal());
        if (amountLocal.signum() != 0) {
            adjustAccount(e.getAccountId(), amountLocal);
        }
        insertReconciliation(e, amountLocal);
        e.setStatus(STATUS_APPROVED);
        expenseRepo.save(e);
        return detail(id);
    }

    /** 红冲：status 1→-1，反向。 */
    @Transactional
    public FinanceExpenseDetail reverse(UUID id) {
        tx.bind();
        FinanceExpense e = require(id);
        if (e.getStatus() == null || e.getStatus() != STATUS_APPROVED) {
            throw new ApiException(ErrorCode.BUSINESS, "仅已审核单据可红冲");
        }
        BigDecimal amountLocal = nz(e.getAmountLocal());
        if (amountLocal.signum() != 0) {
            adjustAccount(e.getAccountId(), amountLocal.negate());
        }
        deleteReconciliation(e.getId());
        e.setStatus(STATUS_REVERSED);
        expenseRepo.save(e);
        return detail(id);
    }

    // ===================== 账户/流水 =====================

    /** 付款账户扣减（money-out）：balance_current -= delta, payments_total += delta（delta 已带符号）。 */
    private void adjustAccount(UUID accountId, BigDecimal delta) {
        int rows = em.createNativeQuery("""
                UPDATE accounts
                SET balance_current = COALESCE(balance_current, 0) - :amt,
                    payments_total  = COALESCE(payments_total, 0) + :amt,
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

    private void insertReconciliation(FinanceExpense e, BigDecimal amountLocal) {
        em.createNativeQuery("""
                INSERT INTO finance_reconciliations
                  (bill_no, source_doc_type, source_doc_id, account_id, in_amount, out_amount,
                   bill_date, settled_date, source_remark, legacy_bstyle, created_at, updated_at, is_deleted)
                VALUES (:billNo, :src, :sid, :acc, 0, :outAmt, :bd, :sd, :sr, 23, now(), now(), false)
                """)
                .setParameter("billNo", e.getBillNo())
                .setParameter("src", RECON_SOURCE)
                .setParameter("sid", e.getId())
                .setParameter("acc", e.getAccountId())
                .setParameter("outAmt", amountLocal)
                .setParameter("bd", OffsetDateTime.now())
                .setParameter("sd", OffsetDateTime.now())
                .setParameter("sr", e.getRemark())
                .executeUpdate();
    }

    private void deleteReconciliation(UUID expenseId) {
        em.createNativeQuery(
                "DELETE FROM finance_reconciliations WHERE source_doc_id = :sid AND source_doc_type = :src")
                .setParameter("sid", expenseId)
                .setParameter("src", RECON_SOURCE)
                .executeUpdate();
    }

    // ===================== CRUD 辅助 =====================

    private void applyHeader(FinanceExpenseSaveRequest req, FinanceExpense e) {
        e.setBillNo(req.getBillNo());
        e.setBillDate(req.getBillDate());
        e.setAccountId(req.getAccountId());
        e.setCounterpartAccountId(req.getCounterpartAccountId());
        e.setCurrencyId(req.getCurrencyId());
        if (req.getExchangeRate() != null) e.setExchangeRate(req.getExchangeRate());
        if (req.getAmountOriginal() != null) e.setAmountOriginal(req.getAmountOriginal());
        if (req.getAmountLocal() != null) e.setAmountLocal(req.getAmountLocal());
        e.setOperatorId(req.getOperatorId());
        e.setRemark(req.getRemark());
    }

    private List<FinanceExpenseItemDto> saveItems(FinanceExpense e, List<FinanceExpenseItemInput> inputs) {
        if (inputs == null || inputs.isEmpty()) return List.of();
        List<FinanceExpenseItemDto> out = new ArrayList<>(inputs.size());
        int auto = 1;
        for (FinanceExpenseItemInput l : inputs) {
            FinanceExpenseItem it = new FinanceExpenseItem();
            it.setExpenseId(e.getId());
            it.setBillNo(e.getBillNo());
            it.setBillDate(e.getBillDate());
            it.setLineNo(l.getLineNo() != null ? l.getLineNo() : auto);
            it.setExpenseStyleId(l.getExpenseStyleId());
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

    private void applyTotals(FinanceExpense e, List<FinanceExpenseItemDto> items) {
        BigDecimal local = items.stream().map(i -> nz(i.getAmountLocal())).reduce(BigDecimal.ZERO, BigDecimal::add);
        BigDecimal original = items.stream().map(i -> nz(i.getAmountOriginal())).reduce(BigDecimal.ZERO, BigDecimal::add);
        e.setAmountLocal(local);
        e.setAmountOriginal(original);
        expenseRepo.save(e);
    }

    private void assertBillNoFree(String billNo, UUID excludeId) {
        if (billNo == null || billNo.isBlank()) return;
        expenseRepo.findByBillNo(billNo).ifPresent(existing -> {
            if (excludeId == null || !existing.getId().equals(excludeId)) {
                throw new ApiException(ErrorCode.CONFLICT, "单号已存在：" + billNo);
            }
        });
    }

    private FinanceExpenseItemDto toItemDto(FinanceExpenseItem it) {
        return new FinanceExpenseItemDto(it.getId(), it.getLineNo(), it.getExpenseStyleId(),
                it.getDepartmentId(), it.getCounterpartAccountId(), it.getCounterpartName(),
                it.getQty(), it.getPrice(), it.getAmountOriginal(), it.getAmountLocal(),
                it.getSummary(), it.getRemark());
    }

    private FinanceExpenseListItem toList(FinanceExpense e) {
        return new FinanceExpenseListItem(e.getId(), e.getBillNo(), e.getBillDate(),
                e.getAccountId(), e.getAmountLocal(), e.getStatus(), e.getLegacyId());
    }

    private FinanceExpenseDetail toDetail(FinanceExpense e, List<FinanceExpenseItemDto> items) {
        return new FinanceExpenseDetail(e.getId(), e.getLegacyId(), e.getBillNo(), e.getBillDate(),
                e.getAccountId(), e.getCounterpartAccountId(), e.getCurrencyId(), e.getExchangeRate(),
                e.getAmountOriginal(), e.getAmountLocal(), e.getOperatorId(), e.getMakerId(), e.getApproverId(),
                e.getRemark(), e.getStatus(), e.isClosed(), items);
    }

    private FinanceExpense require(UUID id) {
        return expenseRepo.findById(id).filter(e -> !e.isDeleted())
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "一般费用单不存在"));
    }

    private static BigDecimal nz(BigDecimal x) {
        return x == null ? BigDecimal.ZERO : x;
    }
}
