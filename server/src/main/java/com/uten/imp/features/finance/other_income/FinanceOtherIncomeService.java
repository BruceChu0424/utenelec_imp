package com.uten.imp.features.finance.other_income;

import com.uten.imp.common.finance.MoneyPolicy;
import com.uten.imp.common.util.NameRefKeyword;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.common.web.Pageables;
import com.uten.imp.common.web.TableSort;
import com.uten.imp.common.docnumber.DocNumberPrefix;
import com.uten.imp.common.docnumber.DocNumberService;
import com.uten.imp.common.util.EmployeeNameResolver.EmployeeReference;
import com.uten.imp.common.util.PaymentMethodReferenceResolver;
import com.uten.imp.features.finance.FinanceDocumentAccessPolicy;
import com.uten.imp.features.finance.accountflow.AccountFlowLedgerService;
import com.uten.imp.features.finance.accountflow.AccountPosting;
import com.uten.imp.features.finance.gl.GlPostingService;
import com.uten.imp.features.finance.other_income.dto.FinanceOtherIncomeDetail;
import com.uten.imp.features.finance.other_income.dto.FinanceOtherIncomeItemDto;
import com.uten.imp.features.finance.other_income.dto.FinanceOtherIncomeItemInput;
import com.uten.imp.features.finance.other_income.dto.FinanceOtherIncomeListItem;
import com.uten.imp.features.finance.other_income.dto.FinanceOtherIncomeQueryFilter;
import com.uten.imp.features.finance.other_income.dto.FinanceOtherIncomeSaveRequest;
import com.uten.imp.application.concurrency.PaymentStyleHierarchyLock;
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
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.time.OffsetDateTime;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.UUID;

/**
 * 其它收入单服务：CRUD（主 + 明细）+ 审核状态机（仅动账户余额，不涉 AR/AP）。
 *
 * <p>与 {@code FinanceExpenseService} 对称（账户累加方向相反：money-in）。
 * 审核（0→1）：{@code accounts.balance_current += amount_local, receipts_total += amount_local} +
 * 写 finance_reconciliations(source_doc_type=INCOME, in_amount=amount_local)。
 */
@Service
@RequiredArgsConstructor
public class FinanceOtherIncomeService {
    private com.uten.imp.common.history.RetainedRecordReader retainedRecords;
    @org.springframework.beans.factory.annotation.Autowired
    public void setRetainedRecords(com.uten.imp.common.history.RetainedRecordReader reader) { retainedRecords = reader; }


    private static final short STATUS_DRAFT = 0;
    private static final short STATUS_APPROVED = 1;
    private static final short STATUS_REVERSED = -1;

    /** 列排序白名单：前端列 key → JPA 实体属性名（日期/金额/单据号可排序；命中才排序，否则默认 billDate DESC）。 */
    private static final Map<String, String> ALLOWED_SORT = Map.of(
            "billDate", "billDate", "amountLocal", "amountLocal",
            "billNo", "billNo"); // 2026-09-25 单号列统一

    public static final String RECON_SOURCE = "INCOME";

    private final FinanceOtherIncomeRepository incomeRepo;
    private final FinanceOtherIncomeItemRepository itemRepo;
    private final TxSessionVars tx;
    private final SecurityContextCurrentUser currentUser;
    private final com.uten.imp.common.util.EmployeeNameResolver nameResolver;
    private final EntityManager em;
    private final DocNumberService docNumberService;
    private final FinanceDocumentAccessPolicy access;
    private final GlPostingService glPosting;
    private final AccountFlowLedgerService accountFlowLedger;

    @Transactional(readOnly = true)
    public PageResponse<FinanceOtherIncomeListItem> list(FinanceOtherIncomeQueryFilter f, int page, int size, String sort, String order) {
        Specification<FinanceOtherIncome> spec = incomeSpec(f);
        Pageable pageable = Pageables.of(page, size,
                TableSort.resolve(sort, order, Sort.by(Sort.Direction.DESC, "billDate"), ALLOWED_SORT));
        Page<FinanceOtherIncome> p = incomeRepo.findAll(spec, pageable);
        PageResponse<FinanceOtherIncomeListItem> result = new PageResponse<>(p.map(this::toList).getContent(), p);
        return p.stream().noneMatch(FinanceOtherIncome::isDeleted) ? result
                : retainedRecords.page(result, "finance_other_incomes", p.getContent());
    }

    /** 单据号列值筛选桶（2026-09-25 单号列统一）：与列表同一份谓词分组计数。 */
    @Transactional(readOnly = true)
    public java.util.Map<String, java.util.List<java.util.Map<String, Object>>> facets(FinanceOtherIncomeQueryFilter f) {
        return java.util.Map.of("billNo",
                com.uten.imp.common.web.TableFacets.groupCount(em, FinanceOtherIncome.class, incomeSpec(f), "billNo"));
    }

    /** 列表谓词（list 与 facets 共用，2026-09-25 单号列统一抽出；billNo=表头单据号精确匹配）。 */
    private Specification<FinanceOtherIncome> incomeSpec(FinanceOtherIncomeQueryFilter f) {
        var readScope = access.scope();
        return (Root<FinanceOtherIncome> root, jakarta.persistence.criteria.CriteriaQuery<?> q,
                CriteriaBuilder cb) -> {
            List<Predicate> ps = new ArrayList<>();
            if (f.onlyDeleted()) ps.add(cb.isTrue(root.get("deleted")));
            else if (!f.includeDeleted()) ps.add(cb.isFalse(root.get("deleted")));
            ps.add(access.readablePredicate(root, cb, "makerId", readScope));
            if (f.keyword() != null && !f.keyword().isBlank()) {
                // 全行可搜（2026-10-09「行里显示什么就能按什么搜」）：单据号 + 引用主档名称
                //（经 NameRefKeyword 转外键 IN 子查询，count 同谓词派生）。
                String kw = NameRefKeyword.like(f.keyword());
                var kws = NameRefKeyword.keywords();
                kws.add(cb.like(cb.lower(root.get("billNo")), kw));
                NameRefKeyword.byName(kws, q, cb, root.get("accountId"),
                        com.uten.imp.features.master.account.Account.class, "name", kw);
                NameRefKeyword.byName(kws, q, cb, root.get("accountId"),
                        com.uten.imp.features.master.account.Account.class, "code", kw);
                ps.add(cb.or(kws.toArray(new Predicate[0])));
            }
            if (f.accountId() != null) ps.add(cb.equal(root.get("accountId"), f.accountId()));
            if (f.status() != null) ps.add(cb.equal(root.get("status"), f.status()));
            if (f.dateFrom() != null) ps.add(cb.greaterThanOrEqualTo(root.get("billDate"), f.dateFrom()));
            if (f.dateTo() != null) ps.add(cb.lessThanOrEqualTo(root.get("billDate"), f.dateTo()));
            // departmentId 走明细表，本期略（前端报表侧按部门汇总）。
            // 单据号表头值筛选（2026-09-25 单号列统一）：精确匹配。
            if (f.billNo() != null && !f.billNo().isBlank()) {
                ps.add(cb.equal(root.get("billNo"), f.billNo().trim()));
            }
            f.headerFilters().apply(root, cb, ps, "amountLocal", true, null, false, null, true);
            return cb.and(ps.toArray(new Predicate[0]));
        };
    }

    @Transactional(readOnly = true)
    public FinanceOtherIncomeDetail detail(UUID id) { return readDetail(id, false); }


    @Transactional(readOnly = true)
    public FinanceOtherIncomeDetail detailHistory(UUID id) { return readDetail(id, true); }

    private FinanceOtherIncomeDetail readDetail(UUID id, boolean historyRead) {
        FinanceOtherIncome o = require(id, historyRead);
        access.requireReadable(o.getMakerId(), "其它收入单不存在");
        List<FinanceOtherIncomeItemDto> items = itemRepo.findByIncomeIdOrderByLineNoAsc(id).stream()
                .map(this::toItemDto).toList();
        return finishHistory(toDetail(o, items), o, historyRead);
    }

    @Transactional
    @PreAuthorize("hasAuthority('finance_other_income:create')")
    @com.uten.imp.common.platformcolumns.PlatformColumnDocumentSave(scope="finance_other_income_item")
    public FinanceOtherIncomeDetail create(FinanceOtherIncomeSaveRequest req) {
        tx.bind();
        if ((req.getItems() != null && !req.getItems().isEmpty())
                || req.getReceiptMethodId() != null
                || req.getReceiptMethodLegacyId() != null) {
            PaymentStyleHierarchyLock.lock(em);
        }
        assertBillNoFree(req.getBillNo(), null);
        FinanceOtherIncome o = new FinanceOtherIncome();
        applyHeader(req, o);
        o.setStatus(STATUS_DRAFT);
        o.setMakerId(currentUser.requireEmployeeId());   // 制单=当前登录用户（报表按 maker_id 解析制单员）
        applyMakerIdentity(o);
        incomeRepo.save(o);
        List<FinanceOtherIncomeItemDto> items = saveItems(o, req.getItems());
        applyTotals(o, items);
        return toDetail(o, items);
    }

    @Transactional
    @PreAuthorize("hasAuthority('finance_other_income:edit')")
    @com.uten.imp.common.platformcolumns.PlatformColumnDocumentSave(scope="finance_other_income_item", requestArgument=1, documentIdArgument=0)
    public FinanceOtherIncomeDetail update(UUID id, FinanceOtherIncomeSaveRequest req) {
        tx.bind();
        if ((req.getItems() != null && !req.getItems().isEmpty())
                || req.getReceiptMethodId() != null
                || req.getReceiptMethodLegacyId() != null) {
            PaymentStyleHierarchyLock.lock(em);
        }
        FinanceOtherIncome o = lockActive(id);
        access.requireWritable(o.getMakerId(), "只能操作本人负责或已授权的其它收入单");
        com.uten.imp.features.finance.FinanceLegacyRecordGuard.requireMutable(o.getLegacyId());
        if (o.getStatus() != STATUS_DRAFT) {
            throw new ApiException(ErrorCode.BUSINESS, "仅草稿单据可编辑");
        }
        assertBillNoFree(req.getBillNo(), id);
        applyHeader(req, o);
        applyMakerIdentity(o);
        itemRepo.deleteByIncomeId(id);
        itemRepo.flush();
        List<FinanceOtherIncomeItemDto> items = saveItems(o, req.getItems());
        applyTotals(o, items);
        return toDetail(o, items);
    }

    @Transactional
    @PreAuthorize("hasAuthority('finance_other_income:delete')")
    public void delete(UUID id) {
        tx.bind();
        FinanceOtherIncome o = lockActive(id);
        access.requireWritable(o.getMakerId(), "只能操作本人负责或已授权的其它收入单");
        com.uten.imp.features.finance.FinanceLegacyRecordGuard.requireMutable(o.getLegacyId());
        if (o.getStatus() == null || o.getStatus() != STATUS_DRAFT) {
            throw new ApiException(ErrorCode.BUSINESS, "仅草稿单据可删除；已审核单据请红冲");
        }
        o.setDeleted(true);
        o.setDeletedAt(OffsetDateTime.now());
        incomeRepo.save(o);
    }

    /** 审核：status 0→1，账户累加 + 写流水（不涉 AR/AP）。 */
    @Transactional
    @PreAuthorize("hasAuthority('finance_other_income:approve')")
    public FinanceOtherIncomeDetail approve(UUID id) {
        tx.bind();
        FinanceOtherIncome o = lockActive(id);
        access.requireScopedOperationWritable(o.getMakerId(), "只能操作本人负责或已交接的其它收入单",
                "finance_other_income:approve");
        com.uten.imp.features.finance.FinanceLegacyRecordGuard.requireMutable(o.getLegacyId());
        if (o.getStatus() == null || o.getStatus() != STATUS_DRAFT) {
            throw new ApiException(ErrorCode.BUSINESS, "仅草稿单据可审核");
        }
        if (o.getAccountId() == null) {
            throw new ApiException(ErrorCode.BUSINESS, "收入单需指定收款账户");
        }
        UUID approver = currentUser.requireEmployeeId(); // 审核=当前登录用户（报表按 approver_id 解析审核员）
        if (o.getMakerId() != null && o.getMakerId().equals(approver)) {
            throw new ApiException(ErrorCode.BUSINESS, "制单人与审核人不可相同(职责分离)");
        }
        glPosting.lockAutoProjectionPeriod(o.getBillDate());
        o.setApproverId(approver);
        o.setApproverLegacyId(null);
        o.setApproverName(nameResolver.nameOf(approver));
        BigDecimal amountLocal = nz(o.getAmountLocal());
        if (amountLocal.signum() <= 0) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "其它收入本位币总额必须大于 0");
        }
        if (o.getCurrencyId() == null || o.getExchangeRate() == null
                || o.getExchangeRate().compareTo(BigDecimal.ONE) != 0) {
            throw new ApiException(
                    ErrorCode.CONFLICT,
                    "其它收入仅支持本位币：单头币种必须等于真实收款账户币种，汇率必须为 1");
        }
        accountFlowLedger.post(AccountPosting.in(RECON_SOURCE, o.getId(), o.getBillNo(), o.getAccountId())
                .rule(AccountPosting.CurrencyRule.BASE_ONLY, o.getCurrencyId())
                .amounts(amountLocal, amountLocal)
                .bookedAt(o.getBillDate().atStartOfDay(java.time.ZoneOffset.UTC).toOffsetDateTime())
                .settledAt(OffsetDateTime.now())
                .sourceRemark(o.getRemark())
                .legacyBstyle(22)
                .label("其它收入收款账户"));
        o.setStatus(STATUS_APPROVED);
        incomeRepo.save(o);
        return detail(id);
    }

    /** 红冲：status 1→-1，反向。 */
    @Transactional
    @PreAuthorize("hasAuthority('finance_other_income:reverse')")
    public FinanceOtherIncomeDetail reverse(UUID id) {
        tx.bind();
        FinanceOtherIncome o = lockActive(id);
        access.requireScopedOperationWritable(o.getMakerId(), "只能操作本人负责或已交接的其它收入单",
                "finance_other_income:reverse");
        com.uten.imp.features.finance.FinanceLegacyRecordGuard.requireMutable(o.getLegacyId());
        if (o.getStatus() == null || o.getStatus() != STATUS_APPROVED) {
            throw new ApiException(ErrorCode.BUSINESS, "仅已审核单据可红冲");
        }
        glPosting.removeAutoProjection(RECON_SOURCE, o.getId(), o.getBillNo(), o.getBillDate());
        // 账户余额与流水由账本按原始流水一并冲回。
        reverseReconciliation(o.getId());
        o.setStatus(STATUS_REVERSED);
        incomeRepo.save(o);
        return detail(id);
    }

    // ===================== 账户/流水 =====================

    private void reverseReconciliation(UUID incomeId) {
        accountFlowLedger.reverse(
                RECON_SOURCE, incomeId, OffsetDateTime.now(), "其它收入红冲");
    }

    // ===================== CRUD 辅助 =====================

    private void applyHeader(FinanceOtherIncomeSaveRequest req, FinanceOtherIncome o) {
        // 单据号系统自动生成（服务端权威）：仅新建（billNo 空）时取号；更新保留既有号，忽略客户端值。
        if (o.getBillNo() == null || o.getBillNo().isBlank()) {
            o.setBillNo(docNumberService.nextNumber(DocNumberPrefix.FIN_OTHER_INCOME));
        }
        o.setBillDate(req.getBillDate());
        o.setAccountId(req.getAccountId());
        o.setCounterpartAccountId(req.getCounterpartAccountId());
        o.setCurrencyId(req.getCurrencyId());
        if (req.getExchangeRate() != null) o.setExchangeRate(com.uten.imp.common.util.FinancialExactAmount.rate(req.getExchangeRate(),"汇率"));
        applyReceiptMethod(req, o);
        applyOperator(req.getOperatorId(), o);
        o.setRemark(req.getRemark());
    }

    private void applyReceiptMethod(FinanceOtherIncomeSaveRequest req, FinanceOtherIncome income) {
        if (req.getReceiptMethodId() == null && req.getReceiptMethodLegacyId() == null
                && income.getLegacyId() != null && income.getReceiptMethodId() == null) {
            return; // imported RecStyle snapshot has no safe master mapping; keep it historical
        }
        var method = PaymentMethodReferenceResolver.resolve(
                em, req.getReceiptMethodId(), req.getReceiptMethodLegacyId(), "收款方式",
                PaymentMethodReferenceResolver.Direction.RECEIPT);
        income.setReceiptMethodId(method == null ? null : method.id());
        income.setReceiptMethodLegacyId(method == null ? null : method.legacyId());
    }

    private void applyOperator(UUID requestedId, FinanceOtherIncome income) {
        EmployeeReference operator = nameResolver.resolveForWrite(requestedId, null, null, "经手人");
        if (operator == null && income.getLegacyId() != null && income.getOperatorId() == null) {
            return;
        }
        income.setOperatorId(operator == null ? null : operator.id());
        income.setOperatorLegacyId(operator == null ? null : operator.legacyId());
        income.setOperatorName(operator == null ? null : operator.name());
    }

    private void applyMakerIdentity(FinanceOtherIncome income) {
        if (income.getMakerId() == null) return;
        income.setMakerLegacyId(null); // Sys_Operator ids are not employees.legacy_id
        income.setMakerName(nameResolver.nameOf(income.getMakerId()));
    }

    private List<FinanceOtherIncomeItemDto> saveItems(FinanceOtherIncome o, List<FinanceOtherIncomeItemInput> inputs) {
        if (inputs == null || inputs.isEmpty()) return List.of();
        List<FinanceOtherIncomeItemDto> out = new ArrayList<>(inputs.size());
        int auto = 1;
        for (FinanceOtherIncomeItemInput l : inputs) {
            // 总账贷方按行 income_style_id 过账，落库前强校验非空（空则借贷不平衡）
            if (l.getIncomeStyleId() == null) {
                throw new ApiException(ErrorCode.VALIDATION_FAILED, "收入明细必须指定收入类别(income_style_id)");
            }
            requirePostableStyle(l.getIncomeStyleId());
            FinanceOtherIncomeItem it = new FinanceOtherIncomeItem();
            it.setIncomeId(o.getId());
            it.setBillNo(o.getBillNo());
            it.setBillDate(o.getBillDate());
            it.setLineNo(l.getLineNo() != null ? l.getLineNo() : auto);
            it.setIncomeStyleId(l.getIncomeStyleId());
            it.setDepartmentId(l.getDepartmentId());
            it.setCounterpartAccountId(l.getCounterpartAccountId());
            it.setCounterpartName(l.getCounterpartName());
            it.setQty(l.getQty()==null?null:com.uten.imp.common.util.FinancialExactAmount.quantity(l.getQty(),"数量"));
            it.setPrice(l.getPrice()==null?null:com.uten.imp.common.util.FinancialExactAmount.unitPrice(l.getPrice(),"单价"));
            it.setAmountOriginal(com.uten.imp.common.util.FinancialExactAmount.optional(l.getAmountOriginal(),"实际原币金额"));
            // 本币 = 实际原币 × 表头汇率(ADR-112), 不接受客户端另报本币。
            it.setAmountLocal(it.getAmountOriginal()==null||o.getExchangeRate()==null?null
                    :MoneyPolicy.local(it.getAmountOriginal(),o.getExchangeRate()));
            it.setSummary(l.getSummary());
            it.setRemark(l.getRemark());
            itemRepo.save(it);
            out.add(toItemDto(it));
            auto++;
        }
        return out;
    }

    /** 其它收入明细只能引用启用的 INCOME 叶子类别。 */
    private void requirePostableStyle(UUID styleId) {
        Number matches = (Number) em.createNativeQuery("""
                        SELECT COUNT(*)
                        FROM payment_styles ps
                        WHERE ps.id = :id
                          AND COALESCE(ps.is_deleted, false) = false
                          AND ps.status = '使用'
                          AND ps.category = 'INCOME'
                          AND NOT EXISTS (
                              SELECT 1
                              FROM payment_styles child
                              WHERE child.parent_id = ps.id
                                AND COALESCE(child.is_deleted, false) = false
                          )
                        """)
                .setParameter("id", styleId)
                .getSingleResult();
        if (matches.longValue() != 1L) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "收入类别不存在、已禁用、大类不匹配或不是末级类别");
        }
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
                it.getSummary(), it.getRemark(), null);
    }

    private FinanceOtherIncomeListItem toList(FinanceOtherIncome o) {
        return new FinanceOtherIncomeListItem(o.getId(), o.getBillNo(), o.getBillDate(),
                o.getAccountId(), o.getAmountLocal(), o.getStatus(), o.getLegacyId());
    }

    private FinanceOtherIncomeDetail toDetail(FinanceOtherIncome o, List<FinanceOtherIncomeItemDto> items) {
        var departments = com.uten.imp.features.finance.FinanceDepartmentNames.referenced(
                em, items.stream().map(FinanceOtherIncomeItemDto::getDepartmentId).toList());
        items.forEach(item -> item.setDepartmentName(item.getDepartmentId() == null
                ? null : departments.get(item.getDepartmentId())));
        return new FinanceOtherIncomeDetail(o.getId(), o.getLegacyId(), o.getBillNo(), o.getBillDate(),
                o.getAccountId(), o.getCounterpartAccountId(), o.getCurrencyId(), o.getExchangeRate(),
                o.getAmountOriginal(), o.getAmountLocal(), o.getReceiptMethodId(), o.getReceiptMethodLegacyId(),
                o.getOperatorId(), o.getMakerId(), o.getApproverId(), o.getRemark(),
                o.getStatus(), o.isClosed(), items,
                nameResolver.nameOf(o.getMakerId()), o.getCreatedAt());
    }

    private FinanceOtherIncome require(UUID id) { return require(id, false); }

    private FinanceOtherIncome require(UUID id, boolean includeDeleted) {
        return incomeRepo.findById(id).filter(o -> includeDeleted || !o.isDeleted())
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "其它收入单不存在"));
    }

    private FinanceOtherIncome lockActive(UUID id) {
        FinanceOtherIncome income = require(id);
        em.refresh(income, jakarta.persistence.LockModeType.PESSIMISTIC_WRITE);
        if (income.isDeleted()) {
            throw new ApiException(ErrorCode.NOT_FOUND, "其它收入单不存在");
        }
        return income;
    }

    private static BigDecimal nz(BigDecimal x) {
        return x == null ? BigDecimal.ZERO : x;
    }

    private FinanceOtherIncomeDetail finishHistory(FinanceOtherIncomeDetail view, FinanceOtherIncome entity, boolean historyRead) {
        if (!historyRead && !entity.isDeleted()) return view;
        return retainedRecords.detail(view, "finance_other_incomes", entity.getId(), entity.isDeleted(), entity.getDeletedAt(), historyRead);
    }

    @Transactional(readOnly = true)
    public java.util.List<com.uten.imp.common.history.RetainedRecordReader.RetainedRow> historyRows(UUID id, Long beforeId, int size) {
        var document=detailHistory(id);
        return retainedRecords.children("finance_other_incomes",id,beforeId,size);
    }
}
