package com.uten.imp.features.finance.bank_transfer;

import com.uten.imp.common.util.NameRefKeyword;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.common.web.Pageables;
import com.uten.imp.common.web.TableSort;
import com.uten.imp.common.docnumber.DocNumberPrefix;
import com.uten.imp.common.docnumber.DocNumberService;
import com.uten.imp.common.util.NativeQueryResults;
import com.uten.imp.features.finance.FinanceDocumentAccessPolicy;
import com.uten.imp.features.finance.accountflow.AccountFlowLedgerService;
import com.uten.imp.features.finance.accountflow.AccountPosting;
import com.uten.imp.features.finance.gl.GlPostingService;
import com.uten.imp.features.finance.bank_transfer.dto.FinanceBankTransferDetail;
import com.uten.imp.features.finance.bank_transfer.dto.FinanceBankTransferLineDto;
import com.uten.imp.features.finance.bank_transfer.dto.FinanceBankTransferLineInput;
import com.uten.imp.features.finance.bank_transfer.dto.FinanceBankTransferListItem;
import com.uten.imp.features.finance.bank_transfer.dto.FinanceBankTransferQueryFilter;
import com.uten.imp.features.finance.bank_transfer.dto.FinanceBankTransferSaveRequest;
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
import java.util.HashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.UUID;

/**
 * 银行存取款单服务：CRUD + 本位币账户间原子过账。
 *
 * <p>当前审核仅允许启用的本位币账户之间转账。跨币种与外币账户需要双边汇率、
 * 来源/时点及本位币金额快照，在这些权威字段上线前一律 fail closed。红冲仍可按
 * 已冻结原生金额撤销历史单据。
 *
 * <p>审核/红冲实现老库 TRI_BankItem 的对称语义：
 * <ul>
 *   <li>每个 line（in_account）：{@code in_account.receipts_total += amount_local}（本位币身份换算 1:1）；</li>
 *   <li>{@code out_account.payments_total += amount_local}；</li>
 *   <li>每账户写一行 {@code finance_reconciliations(source='BANK_TRANSFER')}。</li>
 * </ul>
 *
 * <p>所有涉及账户先按 UUID 稳定顺序加行锁，账户余额、累计额和
 * finance_reconciliations 在同一事务提交。详见 design doc 26 §4.7、§5.3。
 */
@Service
@RequiredArgsConstructor
public class FinanceBankTransferService {
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

    private final FinanceBankTransferRepository transferRepo;
    private final FinanceBankTransferLineRepository lineRepo;
    private final TxSessionVars tx;
    private final SecurityContextCurrentUser currentUser;
    private final com.uten.imp.common.util.EmployeeNameResolver nameResolver;
    private final DocNumberService docNumberService;
    private final EntityManager em;
    private final FinanceDocumentAccessPolicy access;
    private final GlPostingService glPosting;
    private final AccountFlowLedgerService accountFlowLedger;

    @Transactional(readOnly = true)
    public PageResponse<FinanceBankTransferListItem> list(FinanceBankTransferQueryFilter f, int page, int size, String sort, String order) {
        Specification<FinanceBankTransfer> spec = transferSpec(f);
        Pageable pageable = Pageables.of(page, size,
                TableSort.resolve(sort, order, Sort.by(Sort.Direction.DESC, "billDate"), ALLOWED_SORT));
        Page<FinanceBankTransfer> p = transferRepo.findAll(spec, pageable);
        PageResponse<FinanceBankTransferListItem> result = new PageResponse<>(p.map(this::toList).getContent(), p);
        return p.stream().noneMatch(FinanceBankTransfer::isDeleted) ? result
                : retainedRecords.page(result, "finance_bank_transfers", p.getContent());
    }

    /** 单据号列值筛选桶（2026-09-25 单号列统一）：与列表同一份谓词分组计数。 */
    @Transactional(readOnly = true)
    public java.util.Map<String, java.util.List<java.util.Map<String, Object>>> facets(FinanceBankTransferQueryFilter f) {
        return java.util.Map.of("billNo",
                com.uten.imp.common.web.TableFacets.groupCount(em, FinanceBankTransfer.class, transferSpec(f), "billNo"));
    }

    /** 列表谓词（list 与 facets 共用，2026-09-25 单号列统一抽出；billNo=表头单据号精确匹配）。 */
    private Specification<FinanceBankTransfer> transferSpec(FinanceBankTransferQueryFilter f) {
        var readScope = access.scope();
        return (Root<FinanceBankTransfer> root,
                jakarta.persistence.criteria.CriteriaQuery<?> q,
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
                NameRefKeyword.byName(kws, q, cb, root.get("outAccountId"),
                        com.uten.imp.features.master.account.Account.class, "name", kw);
                NameRefKeyword.byName(kws, q, cb, root.get("outAccountId"),
                        com.uten.imp.features.master.account.Account.class, "code", kw);
                // 存款账户在行上（一单多行 FinanceBankTransferLine.inAccountId），表头没有
                // inAccountId 列——按行 EXISTS 子查询搜，口径同 SubcontractGoodsKeyword。
                jakarta.persistence.criteria.Subquery<UUID> inAccounts = q.subquery(UUID.class);
                jakarta.persistence.criteria.Root<com.uten.imp.features.master.account.Account> account =
                        inAccounts.from(com.uten.imp.features.master.account.Account.class);
                inAccounts.select(account.get("id")).where(
                        cb.isFalse(account.get("deleted")),
                        cb.or(cb.like(cb.lower(account.get("name")), kw),
                                cb.like(cb.lower(account.get("code")), kw)));
                jakarta.persistence.criteria.Subquery<UUID> lineHit = q.subquery(UUID.class);
                jakarta.persistence.criteria.Root<FinanceBankTransferLine> line =
                        lineHit.from(FinanceBankTransferLine.class);
                lineHit.select(line.get("id")).where(
                        cb.equal(line.get("transferId"), root.get("id")),
                        line.get("inAccountId").in(inAccounts));
                kws.add(cb.exists(lineHit));
                ps.add(cb.or(kws.toArray(new Predicate[0])));
            }
            if (f.outAccountId() != null) ps.add(cb.equal(root.get("outAccountId"), f.outAccountId()));
            if (f.status() != null) ps.add(cb.equal(root.get("status"), f.status()));
            if (f.dateFrom() != null) ps.add(cb.greaterThanOrEqualTo(root.get("billDate"), f.dateFrom()));
            if (f.dateTo() != null) ps.add(cb.lessThanOrEqualTo(root.get("billDate"), f.dateTo()));
            // 单据号表头值筛选（2026-09-25 单号列统一）：精确匹配。
            if (f.billNo() != null && !f.billNo().isBlank()) {
                ps.add(cb.equal(root.get("billNo"), f.billNo().trim()));
            }
            f.headerFilters().apply(root, cb, ps, "amountLocal", true, null, false, null, true);
            return cb.and(ps.toArray(new Predicate[0]));
        };
    }

    @Transactional(readOnly = true)
    public FinanceBankTransferDetail detail(UUID id) { return readDetail(id, false); }


    @Transactional(readOnly = true)
    public FinanceBankTransferDetail detailHistory(UUID id) { return readDetail(id, true); }

    private FinanceBankTransferDetail readDetail(UUID id, boolean historyRead) {
        FinanceBankTransfer t = require(id, historyRead);
        access.requireReadable(t.getMakerId(), "银行存取款单不存在");
        List<FinanceBankTransferLineDto> items = lineRepo.findByTransferIdOrderByLineNoAsc(id).stream()
                .map(this::toLineDto).toList();
        return finishHistory(toDetail(t, items), t, historyRead);
    }

    @Transactional
    @PreAuthorize("hasAuthority('finance_bank_transfer:create')")
    @com.uten.imp.common.platformcolumns.PlatformColumnDocumentSave(scope="finance_bank_transfer_item")
    public FinanceBankTransferDetail create(FinanceBankTransferSaveRequest req) {
        tx.bind();
        assertBillNoFree(req.getBillNo(), null);
        FinanceBankTransfer t = new FinanceBankTransfer();
        applyHeader(req, t);
        t.setStatus(STATUS_DRAFT);
        t.setMakerId(currentUser.requireEmployeeId());   // 制单=当前登录用户（报表按 maker_id 解析制单员）
        transferRepo.save(t);
        List<FinanceBankTransferLineDto> items = saveLines(t, req.getItems());
        applyTotals(t, items);
        return toDetail(t, items);
    }

    @Transactional
    @PreAuthorize("hasAuthority('finance_bank_transfer:edit')")
    @com.uten.imp.common.platformcolumns.PlatformColumnDocumentSave(scope="finance_bank_transfer_item", requestArgument=1, documentIdArgument=0)
    public FinanceBankTransferDetail update(UUID id, FinanceBankTransferSaveRequest req) {
        tx.bind();
        FinanceBankTransfer t = lockActive(id);
        access.requireWritable(t.getMakerId(), "只能操作本人负责或已授权的银行存取款单");
        com.uten.imp.features.finance.FinanceLegacyRecordGuard.requireMutable(t.getLegacyId());
        if (t.getStatus() != STATUS_DRAFT) {
            throw new ApiException(ErrorCode.BUSINESS, "仅草稿单据可编辑");
        }
        assertBillNoFree(req.getBillNo(), id);
        applyHeader(req, t);
        lineRepo.deleteByTransferId(id);
        lineRepo.flush();
        List<FinanceBankTransferLineDto> items = saveLines(t, req.getItems());
        applyTotals(t, items);
        return toDetail(t, items);
    }

    @Transactional
    @PreAuthorize("hasAuthority('finance_bank_transfer:delete')")
    public void delete(UUID id) {
        tx.bind();
        FinanceBankTransfer t = lockActive(id);
        access.requireWritable(t.getMakerId(), "只能操作本人负责或已授权的银行存取款单");
        com.uten.imp.features.finance.FinanceLegacyRecordGuard.requireMutable(t.getLegacyId());
        if (t.getStatus() == null || t.getStatus() != STATUS_DRAFT) {
            throw new ApiException(ErrorCode.BUSINESS, "仅草稿单据可删除；已审核单据请红冲");
        }
        t.setDeleted(true);
        t.setDeletedAt(OffsetDateTime.now());
        transferRepo.save(t);
    }

    /** 审核：转出账户扣减、逐转入本位币账户 1:1 入账，并写对称账户流水。 */
    @Transactional
    @PreAuthorize("hasAuthority('finance_bank_transfer:approve')")
    public FinanceBankTransferDetail approve(UUID id) {
        tx.bind();
        FinanceBankTransfer t = lockActive(id);
        access.requireScopedOperationWritable(t.getMakerId(), "只能操作本人负责或已交接的银行存取款单",
                "finance_bank_transfer:approve");
        com.uten.imp.features.finance.FinanceLegacyRecordGuard.requireMutable(t.getLegacyId());
        if (t.getStatus() == null || t.getStatus() != STATUS_DRAFT) {
            throw new ApiException(ErrorCode.BUSINESS, "仅草稿单据可审核");
        }
        UUID approver = currentUser.requireEmployeeId(); // 审核=当前登录用户（报表按 approver_id 解析审核员）
        if (t.getMakerId() != null && t.getMakerId().equals(approver)) {
            throw new ApiException(ErrorCode.BUSINESS, "制单人与审核人不可相同(职责分离)");
        }
        glPosting.lockAutoProjectionPeriod(t.getBillDate());
        List<FinanceBankTransferLine> lines = lineRepo.findByTransferIdOrderByLineNoAsc(id);
        TransferPosting posting = preparePosting(t, lines, true);
        assertNoExistingPosting(t.getId());
        postTransfer(t, posting);
        t.setApproverId(approver);
        t.setStatus(STATUS_APPROVED);
        transferRepo.save(t);
        return detail(id);
    }

    /** 红冲：严格使用审核时固化的两侧账户原生金额做反向账户/流水冲销。 */
    @Transactional
    @PreAuthorize("hasAuthority('finance_bank_transfer:reverse')")
    public FinanceBankTransferDetail reverse(UUID id) {
        tx.bind();
        FinanceBankTransfer t = lockActive(id);
        access.requireScopedOperationWritable(t.getMakerId(), "只能操作本人负责或已交接的银行存取款单",
                "finance_bank_transfer:reverse");
        com.uten.imp.features.finance.FinanceLegacyRecordGuard.requireMutable(t.getLegacyId());
        if (t.getStatus() == null || t.getStatus() != STATUS_APPROVED) {
            throw new ApiException(ErrorCode.BUSINESS, "仅已审核单据可红冲");
        }
        glPosting.removeAutoProjection("BANK_TRANSFER", t.getId(), t.getBillNo(), t.getBillDate());
        List<FinanceBankTransferLine> lines = lineRepo.findByTransferIdOrderByLineNoAsc(id);
        TransferPosting posting = preparePosting(t, lines, false);
        assertCompletePosting(t.getId(), posting.incomingByAccount().size() + 1L);
        // 两侧账户余额与流水由账本按审核时的原始流水一并冲回。
        reverseReconciliations(t.getId());
        t.setStatus(STATUS_REVERSED);
        transferRepo.save(t);
        return detail(id);
    }

    private TransferPosting preparePosting(
            FinanceBankTransfer transfer,
            List<FinanceBankTransferLine> lines,
            boolean approval) {
        if (transfer.getOutAccountId() == null) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "银行存取款单必须指定转出账户");
        }
        if (lines == null || lines.isEmpty()) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "银行存取款单至少需要一个转入账户");
        }

        LinkedHashSet<UUID> accountIds = new LinkedHashSet<>();
        accountIds.add(transfer.getOutAccountId());
        for (FinanceBankTransferLine line : lines) {
            if (line.getInAccountId() == null) {
                throw new ApiException(ErrorCode.VALIDATION_FAILED, "转入账户不能为空");
            }
            if (line.getInAccountId().equals(transfer.getOutAccountId())) {
                throw new ApiException(ErrorCode.VALIDATION_FAILED, "转出账户与转入账户不能相同");
            }
            if (line.getAmountLocal() == null || line.getAmountLocal().signum() <= 0) {
                throw new ApiException(ErrorCode.VALIDATION_FAILED, "每笔转账金额必须大于 0");
            }
            accountIds.add(line.getInAccountId());
        }

        // 审核: 账本按主键顺序锁住转出与全部转入账户(须启用); 红冲: 余额由账本按原始流水冲回, 这里只核对单据。
        Map<UUID, AccountFlowLedgerService.LockedAccount> accounts = approval
                ? accountFlowLedger.lockActive(accountIds, "转账账户") : Map.of();
        AccountFlowLedgerService.LockedAccount out = accounts.get(transfer.getOutAccountId());
        if (approval) {
            requireBaseCurrencyTransferAccounts(accounts.values(), out.currencyId());
            if (transfer.getCurrencyId() == null) {
                transfer.setCurrencyId(out.currencyId());
            } else if (out.currencyId() != null
                    && !transfer.getCurrencyId().equals(out.currencyId())) {
                throw new ApiException(ErrorCode.CONFLICT, "单据币种与转出账户币种不一致");
            }
        }

        BigDecimal outRate = null;
        if (approval) {
            // 本位币身份汇率只能为 1；不读取可变币种主档参考汇率做换汇。
            outRate = BigDecimal.ONE.setScale(6);
            BigDecimal clientRate = positiveRate(transfer.getExchangeRate());
            if (clientRate != null && clientRate.compareTo(outRate) != 0) {
                throw new ApiException(
                        ErrorCode.CONFLICT,
                        "本位币账户间转账汇率必须为 1；跨币种需先建立双边币种、汇率和本位币金额快照");
            }
        }

        BigDecimal outgoing = BigDecimal.ZERO;
        BigDecimal incomingTotal = BigDecimal.ZERO;
        Map<UUID, BigDecimal> incoming = new HashMap<>();
        // M10：一张单的转入账户必须同币种；否则各 converted 是不同货币却相加成头表 amountOriginal，语义错。
        LinkedHashSet<UUID> distinctInCurrencies = approval ? new LinkedHashSet<>() : null;
        for (FinanceBankTransferLine line : lines) {
            AccountFlowLedgerService.LockedAccount in = accounts.get(line.getInAccountId());
            BigDecimal sourceAmount = line.getAmountLocal();
            BigDecimal converted;
            if (approval) {
                distinctInCurrencies.add(in.currencyId());
                if (!Objects.equals(out.currencyId(), in.currencyId())) {
                    throw new ApiException(
                            ErrorCode.CONFLICT,
                            "当前仅允许同一本位币账户间转账；跨币种需先建立双边币种、汇率和本位币金额快照");
                }
                converted = sourceAmount;
                if (converted.signum() <= 0) {
                    throw new ApiException(ErrorCode.BUSINESS, "审核转入金额必须大于 0");
                }
                // Persist the authoritative target-account native amount.
                // Reversal uses this snapshot and never recomputes from master data.
                line.setAmountOriginal(converted);
                lineRepo.save(line);
            } else {
                converted = line.getAmountOriginal();
                if (converted == null || converted.signum() <= 0) {
                    throw new ApiException(ErrorCode.CONFLICT, "原审核转入账户金额缺失，禁止红冲");
                }
            }
            outgoing = outgoing.add(sourceAmount);
            incomingTotal = incomingTotal.add(converted);
            incoming.merge(line.getInAccountId(), converted, BigDecimal::add);
        }
        if (approval) {
            if (distinctInCurrencies.size() > 1) {
                throw new ApiException(
                        ErrorCode.BUSINESS,
                        "一张银行存取款单的转入账户必须为同一币种；请拆分成多张单据");
            }
            transfer.setExchangeRate(outRate);
            transfer.setAmountLocal(outgoing);
            transfer.setAmountOriginal(incomingTotal);
            transferRepo.save(transfer);
        } else if (nz(transfer.getAmountLocal()).compareTo(outgoing) != 0
                || nz(transfer.getAmountOriginal()).compareTo(incomingTotal) != 0) {
            throw new ApiException(ErrorCode.CONFLICT, "银行存取款表头与已审核明细金额不一致");
        }
        return new TransferPosting(outgoing, incoming, accounts);
    }

    private static void requireBaseCurrencyTransferAccounts(
            java.util.Collection<AccountFlowLedgerService.LockedAccount> accounts,
            UUID expectedCurrencyId) {
        boolean invalid = expectedCurrencyId == null || accounts.stream().anyMatch(account ->
                !Objects.equals(account.currencyId(), expectedCurrencyId)
                        || !account.baseCurrency());
        if (invalid) {
            throw new ApiException(
                    ErrorCode.CONFLICT,
                    "当前银行转账仅允许转出和全部转入均为同一启用本位币账户；外币或跨币种需先建立双边币种、汇率和本位币金额快照");
        }
    }

    /** 转出账户扣减、逐转入账户入账, 各写一条流水; 全部经账本(ADR-112)。 */
    private void postTransfer(FinanceBankTransfer transfer, TransferPosting posting) {
        java.time.OffsetDateTime bookedAt = transfer.getBillDate()
                .atStartOfDay(java.time.ZoneOffset.UTC).toOffsetDateTime();
        accountFlowLedger.post(posting.accounts().get(transfer.getOutAccountId()),
                AccountPosting.out("BANK_TRANSFER", transfer.getId(), transfer.getBillNo(),
                                transfer.getOutAccountId())
                        .rule(AccountPosting.CurrencyRule.BASE_ONLY, transfer.getCurrencyId())
                        .amounts(posting.outgoing(), posting.outgoing())
                        .bookedAt(bookedAt)
                        .settledAt(OffsetDateTime.now())
                        .checkNo(transfer.getInvoiceNo())
                        .sourceRemark(transfer.getRemark())
                        .legacyBstyle(27)
                        .label("转出账户"));
        for (Map.Entry<UUID, BigDecimal> entry : posting.incomingByAccount()
                .entrySet().stream().sorted(Map.Entry.comparingByKey()).toList()) {
            accountFlowLedger.post(posting.accounts().get(entry.getKey()),
                    AccountPosting.in("BANK_TRANSFER", transfer.getId(), transfer.getBillNo(), entry.getKey())
                            .rule(AccountPosting.CurrencyRule.BASE_ONLY, transfer.getCurrencyId())
                            .amounts(entry.getValue(), entry.getValue())
                            .bookedAt(bookedAt)
                            .settledAt(OffsetDateTime.now())
                            .checkNo(transfer.getInvoiceNo())
                            .sourceRemark("银行存取款转入")
                            .legacyBstyle(27)
                            .label("转入账户"));
        }
    }

    private void assertNoExistingPosting(UUID transferId) {
        if (postingCount(transferId) != 0) {
            throw new ApiException(ErrorCode.CONFLICT, "银行存取款单已存在账户流水，禁止重复审核");
        }
    }

    private void assertCompletePosting(UUID transferId, long expectedRows) {
        long actual = postingCount(transferId);
        if (actual != expectedRows) {
            throw new ApiException(
                    ErrorCode.CONFLICT,
                    "银行存取款流水不完整，禁止红冲(期望 " + expectedRows + "，实际 " + actual + ")");
        }
    }

    private long postingCount(UUID transferId) {
        return ((Number) em.createNativeQuery("""
                        SELECT COUNT(*)
                        FROM finance_reconciliations
                        WHERE source_doc_type = 'BANK_TRANSFER'
                          AND source_doc_id = :id
                          AND COALESCE(is_deleted, false) = false
                        """)
                .setParameter("id", transferId)
                .getSingleResult()).longValue();
    }

    private void reverseReconciliations(UUID transferId) {
        accountFlowLedger.reverse(
                "BANK_TRANSFER", transferId, OffsetDateTime.now(), "银行存取款红冲");
    }

    private static BigDecimal positiveRate(BigDecimal value) {
        return value != null && value.signum() > 0 ? value : null;
    }

    private static BigDecimal nz(BigDecimal value) {
        return value == null ? BigDecimal.ZERO : value;
    }

    private record TransferPosting(
            BigDecimal outgoing,
            Map<UUID, BigDecimal> incomingByAccount,
            Map<UUID, AccountFlowLedgerService.LockedAccount> accounts) {}

    // ===================== CRUD 辅助 =====================

    private void applyHeader(FinanceBankTransferSaveRequest req, FinanceBankTransfer t) {
        // 单据号系统自动生成（服务端权威）：仅新建（billNo 空）时取号；更新保留既有号，忽略客户端值。
        if (t.getBillNo() == null || t.getBillNo().isBlank()) {
            t.setBillNo(docNumberService.nextNumber(DocNumberPrefix.FIN_BANK_TRANSFER));
        }
        t.setBillDate(req.getBillDate());
        t.setOutAccountId(req.getOutAccountId());
        t.setCurrencyId(req.getCurrencyId());
        if (req.getExchangeRate() != null) t.setExchangeRate(req.getExchangeRate());
        t.setInvoiceNo(req.getInvoiceNo());
        t.setOperatorId(req.getOperatorId());
        t.setRemark(req.getRemark());
    }

    private List<FinanceBankTransferLineDto> saveLines(FinanceBankTransfer t, List<FinanceBankTransferLineInput> inputs) {
        if (inputs == null || inputs.isEmpty()) return List.of();
        List<FinanceBankTransferLineDto> out = new ArrayList<>(inputs.size());
        int auto = 1;
        for (FinanceBankTransferLineInput l : inputs) {
            FinanceBankTransferLine ln = new FinanceBankTransferLine();
            ln.setTransferId(t.getId());
            ln.setBillNo(t.getBillNo());
            ln.setBillDate(t.getBillDate());
            ln.setLineNo(l.getLineNo() != null ? l.getLineNo() : auto);
            ln.setInAccountId(l.getInAccountId());
            ln.setOccurDate(l.getOccurDate());
            // 实际转账金额只录一次: 仅支持本位币账户间转账(审核时校验), 转出本币额 = 转入原币额。
            BigDecimal amount = com.uten.imp.common.util.FinancialExactAmount.optional(
                    l.getAmountOriginal(), "转账金额");
            ln.setAmountOriginal(amount);
            ln.setAmountLocal(amount);
            ln.setSummary(l.getSummary());
            lineRepo.save(ln);
            out.add(toLineDto(ln));
            auto++;
        }
        return out;
    }

    private void applyTotals(FinanceBankTransfer t, List<FinanceBankTransferLineDto> items) {
        BigDecimal local = items.stream().map(i -> i.getAmountLocal() == null ? BigDecimal.ZERO : i.getAmountLocal())
                .reduce(BigDecimal.ZERO, BigDecimal::add);
        BigDecimal original = items.stream().map(i -> i.getAmountOriginal() == null ? BigDecimal.ZERO : i.getAmountOriginal())
                .reduce(BigDecimal.ZERO, BigDecimal::add);
        t.setAmountLocal(local);
        t.setAmountOriginal(original);
        transferRepo.save(t);
    }

    private void assertBillNoFree(String billNo, UUID excludeId) {
        if (billNo == null || billNo.isBlank()) return;
        transferRepo.findByBillNo(billNo).ifPresent(existing -> {
            if (excludeId == null || !existing.getId().equals(excludeId)) {
                throw new ApiException(ErrorCode.CONFLICT, "单号已存在：" + billNo);
            }
        });
    }

    private FinanceBankTransferLineDto toLineDto(FinanceBankTransferLine ln) {
        return new FinanceBankTransferLineDto(ln.getId(), ln.getLineNo(), ln.getInAccountId(),
                ln.getOccurDate(), ln.getAmountOriginal(), ln.getAmountLocal(), ln.getSummary());
    }

    private FinanceBankTransferListItem toList(FinanceBankTransfer t) {
        return new FinanceBankTransferListItem(t.getId(), t.getBillNo(), t.getBillDate(),
                t.getOutAccountId(), t.getAmountLocal(), t.getStatus(), t.getLegacyId());
    }

    private FinanceBankTransferDetail toDetail(FinanceBankTransfer t, List<FinanceBankTransferLineDto> items) {
        return new FinanceBankTransferDetail(t.getId(), t.getLegacyId(), t.getBillNo(), t.getBillDate(),
                t.getOutAccountId(), t.getCurrencyId(), t.getExchangeRate(),
                t.getAmountOriginal(), t.getAmountLocal(), t.getInvoiceNo(),
                t.getOperatorId(), t.getMakerId(), t.getApproverId(), t.getRemark(),
                t.getStatus(), t.isClosed(), items,
                nameResolver.nameOf(t.getMakerId()), t.getCreatedAt());
    }

    private FinanceBankTransfer require(UUID id) { return require(id, false); }

    private FinanceBankTransfer require(UUID id, boolean includeDeleted) {
        return transferRepo.findById(id).filter(t -> includeDeleted || !t.isDeleted())
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "银行存取款单不存在"));
    }

    private FinanceBankTransfer lockActive(UUID id) {
        FinanceBankTransfer transfer = require(id);
        em.refresh(transfer, jakarta.persistence.LockModeType.PESSIMISTIC_WRITE);
        if (transfer.isDeleted()) {
            throw new ApiException(ErrorCode.NOT_FOUND, "银行存取款单不存在");
        }
        return transfer;
    }

    private FinanceBankTransferDetail finishHistory(FinanceBankTransferDetail view, FinanceBankTransfer entity, boolean historyRead) {
        if (!historyRead && !entity.isDeleted()) return view;
        return retainedRecords.detail(view, "finance_bank_transfers", entity.getId(), entity.isDeleted(), entity.getDeletedAt(), historyRead);
    }

    @Transactional(readOnly = true)
    public java.util.List<com.uten.imp.common.history.RetainedRecordReader.RetainedRow> historyRows(UUID id, Long beforeId, int size) {
        var document=detailHistory(id);
        return retainedRecords.children("finance_bank_transfers",id,beforeId,size);
    }
}
