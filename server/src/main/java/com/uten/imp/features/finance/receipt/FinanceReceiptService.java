package com.uten.imp.features.finance.receipt;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.common.web.Pageables;
import com.uten.imp.common.web.TableSort;
import com.uten.imp.common.docnumber.DocNumberPrefix;
import com.uten.imp.common.docnumber.DocNumberService;
import com.uten.imp.common.util.EmployeeNameResolver.EmployeeReference;
import com.uten.imp.common.util.NativeQueryResults;
import com.uten.imp.common.util.PaymentMethodReferenceResolver;
import com.uten.imp.features.finance.FinanceDocumentAccessPolicy;
import com.uten.imp.features.finance.accountflow.AccountFlowLedgerService;
import com.uten.imp.features.finance.arap.ArApLedger;
import com.uten.imp.features.finance.arap.ArApLedgerRepository;
import com.uten.imp.features.finance.arap.ArApLedgerService;
import com.uten.imp.features.finance.gl.GlPostingService;
import com.uten.imp.features.finance.receivables.FinanceReceiptSourceAllocationService;
import com.uten.imp.features.finance.receipt.dto.FinanceReceiptDetail;
import com.uten.imp.features.finance.receipt.dto.FinanceReceiptLineDto;
import com.uten.imp.features.finance.receipt.dto.FinanceReceiptLineInput;
import com.uten.imp.features.finance.receipt.dto.FinanceReceiptListItem;
import com.uten.imp.features.finance.receipt.dto.FinanceReceiptQueryFilter;
import com.uten.imp.features.finance.receipt.dto.FinanceReceiptSaveRequest;
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
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.HashSet;
import java.util.HexFormat;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.Set;
import java.util.UUID;

/**
 * 销售收款单服务：CRUD（主 + 明细）+ 审核状态机（核销 AR / 直接收款 / 账户累加 / 写流水）。
 *
 * <p>审核（status 0→1）调用 {@link #settleReceipt}。
 * <ul>
 *   <li>明细非空（指定核销 AR）：每行 {@code applied_ledger_id} 回写 ar_ap_ledger.amount_settled += line.amount_local
 *       + amount_balance 重算 + balance = 0 自动 is_settled=true。</li>
 *   <li>明细为空（直接收款 / 客户预付）：调 {@link ArApLedgerService#postArAp} 建 DIRECT_RECEIPT 立帐行
 *       （amount_original_local=0），再置 settled=amount_local、balance=-amount_local（负值 = 客户预付）。</li>
 *   <li>人民币账户增加本批 {@code amount_local}；同币种外币账户增加本批
 *       {@code amount_original}。</li>
 *   <li>账户流水使用账户自身币种，与 {@code balance_current} 保持同一单位。</li>
 * </ul>
 *
 * <p>红冲（1→-1）反向：回减核销 / 保留预收历史 / 回滚账户 /
 * 追加账户与总账反向事实；原始流水和凭证均不删除。
 */
@Service
@RequiredArgsConstructor
public class FinanceReceiptService {

    private static final short STATUS_DRAFT = 0;
    private static final short STATUS_APPROVED = 1;
    private static final short STATUS_REVERSED = -1;
    private static final int MONEY_SCALE = 4;
    private static final int RATE_SCALE = 6;
    private static final short SETTLEMENT_AUTHORITY_V1 = 1;
    private static final short SETTLEMENT_AUTHORITY_V2 = 2;
    private static final String FEE_NONE = "NONE";
    private static final String FEE_DEDUCTED = "DEDUCTED_FROM_PROCEEDS";
    private static final String FEE_SEPARATE = "PAID_SEPARATELY";
    private static final String FEE_BEARER_NONE = "NONE";
    private static final String FEE_BEARER_COMPANY = "COMPANY";
    private static final String RECON_FEE_SOURCE = "RECEIPT_FEE";

    /** 列排序白名单：前端列 key → JPA 实体属性名（日期/金额可排序；命中才排序，否则默认 billDate DESC）。 */
    private static final Map<String, String> ALLOWED_SORT = Map.of("billDate", "billDate", "amountLocal", "amountLocal");

    /** ar_ap_ledger.source_doc_type 直接收款枚举（{@link ArApLedgerService#postArAp}）。 */
    public static final String SRC_DIRECT_RECEIPT = "DIRECT_RECEIPT";

    /** finance_reconciliations.source_doc_type 枚举（替代老库 BStyle=20）。 */
    public static final String RECON_SOURCE = "RECEIPT";

    private final FinanceReceiptRepository receiptRepo;
    private final FinanceReceiptLineRepository lineRepo;
    private final ArApLedgerRepository ledgerRepo;
    private final ArApLedgerService arApService;
    private final TxSessionVars tx;
    private final SecurityContextCurrentUser currentUser;
    private final com.uten.imp.common.util.EmployeeNameResolver nameResolver;
    private final EntityManager em;
    private final DocNumberService docNumberService;
    private final FinanceDocumentAccessPolicy access;
    private final GlPostingService glPosting;
    private final FinanceReceiptSourceAllocationService sourceAllocation;
    private final AccountFlowLedgerService accountFlowLedger;

    @Transactional(readOnly = true)
    public PageResponse<FinanceReceiptListItem> list(FinanceReceiptQueryFilter f, int page, int size, String sort, String order) {
        var readScope = access.scope();
        Specification<FinanceReceipt> spec = (Root<FinanceReceipt> root, jakarta.persistence.criteria.CriteriaQuery<?> q,
                                              CriteriaBuilder cb) -> {
            List<Predicate> ps = new ArrayList<>();
            ps.add(cb.isFalse(root.get("deleted")));
            ps.add(access.readablePredicate(root, cb, "makerId", readScope));
            if (!canViewCustomerPrepayment()) {
                ps.add(cb.notEqual(root.get("receiptKind"), "CUSTOMER_PREPAYMENT"));
            }
            if (f.keyword() != null && !f.keyword().isBlank()) {
                ps.add(cb.like(cb.lower(root.get("billNo")), "%" + f.keyword().toLowerCase() + "%"));
            }
            if (f.clientId() != null) ps.add(cb.equal(root.get("clientId"), f.clientId()));
            if (f.accountId() != null) ps.add(cb.equal(root.get("accountId"), f.accountId()));
            if (f.status() != null) ps.add(cb.equal(root.get("status"), f.status()));
            if (f.dateFrom() != null) ps.add(cb.greaterThanOrEqualTo(root.get("billDate"), f.dateFrom()));
            if (f.dateTo() != null) ps.add(cb.lessThanOrEqualTo(root.get("billDate"), f.dateTo()));
            return cb.and(ps.toArray(new Predicate[0]));
        };
        Pageable pageable = Pageables.of(page, size,
                TableSort.resolve(sort, order, Sort.by(Sort.Direction.DESC, "billDate"), ALLOWED_SORT));
        Page<FinanceReceipt> p = receiptRepo.findAll(spec, pageable);
        return new PageResponse<>(p.map(this::toList).getContent(), p);
    }

    @Transactional(readOnly = true)
    public FinanceReceiptDetail detail(UUID id) {
        FinanceReceipt r = require(id);
        access.requireReadable(r.getMakerId(), "销售收款单不存在");
        requirePrepaymentView(r);
        List<FinanceReceiptLineDto> items = lineRepo.findByReceiptIdOrderByLineNoAsc(id).stream()
                .map(this::toLineDto).toList();
        return toDetail(r, lineRepo.findByReceiptIdOrderByLineNoAsc(r.getId()).stream().map(this::toLineDto).toList());
    }

    @Transactional
    @PreAuthorize("hasAuthority('finance_receipt:create') and "
            + "(#req.receiptKind == null or !#req.receiptKind.equalsIgnoreCase('CUSTOMER_PREPAYMENT') "
            + "or (hasAuthority('customer_prepayment:view') and hasAuthority('finance:view:all')))")
    public FinanceReceiptDetail create(FinanceReceiptSaveRequest req) {
        tx.bind();
        requirePrepaymentView(req.getReceiptKind());
        UUID makerId = currentUser.requireEmployeeId();
        String idempotencyKey = normalizeIdempotencyKey(req.getCreateIdempotencyKey());
        String requestHash = requestHash(req);
        lockCreateIdempotency(makerId, idempotencyKey);
        FinanceReceipt replay = findCreateReplay(makerId, idempotencyKey);
        if (replay != null) {
            if (!Objects.equals(replay.getCreateRequestHash(), requestHash)) {
                throw new ApiException(ErrorCode.CONFLICT,
                        "收款创建幂等键已用于不同内容，请刷新后重新提交");
            }
            return detail(replay.getId());
        }
        PaymentStyleHierarchyLock.lock(em);
        assertBillNoFree(req.getBillNo(), null);
        FinanceReceipt r = new FinanceReceipt();
        r.setMakerId(makerId);
        r.setCreateIdempotencyKey(idempotencyKey);
        r.setCreateRequestHash(requestHash);
        applyHeader(req, r);
        r.setStatus(STATUS_DRAFT);
        applyMakerIdentity(r);
        receiptRepo.save(r);
        List<FinanceReceiptLineDto> items = saveLines(r, req.getItems());
        applyLineTotals(r, items);
        finalizeSettlementAuthority(r, req.getAccountCurrencyId(),
                req.getAccountAmount(), false);
        validateReceiptShape(r, items, false);
        receiptRepo.flush();
        return toDetail(r, lineRepo.findByReceiptIdOrderByLineNoAsc(r.getId()).stream().map(this::toLineDto).toList());
    }

    @Transactional
    @PreAuthorize("hasAuthority('finance_receipt:edit') and "
            + "(#req.receiptKind == null or !#req.receiptKind.equalsIgnoreCase('CUSTOMER_PREPAYMENT') "
            + "or (hasAuthority('customer_prepayment:view') and hasAuthority('finance:view:all')))")
    public FinanceReceiptDetail update(UUID id, FinanceReceiptSaveRequest req) {
        tx.bind();
        PaymentStyleHierarchyLock.lock(em);
        FinanceReceipt r = lockActive(id);
        access.requireWritable(r.getMakerId(), "只能操作本人负责或已授权的销售收款单");
        requirePrepaymentView(r);
        requirePrepaymentView(req.getReceiptKind());
        if (r.getStatus() != STATUS_DRAFT) {
            throw new ApiException(ErrorCode.BUSINESS, "仅草稿单据可编辑");
        }
        if (req.getExpectedVersion() == null
                || r.getVersion() == null
                || req.getExpectedVersion().longValue() != r.getVersion().longValue()) {
            throw new ApiException(ErrorCode.CONFLICT,
                    "收款草稿已被其他操作更新，请刷新后重试");
        }
        assertBillNoFree(req.getBillNo(), id);
        applyHeader(req, r);
        applyMakerIdentity(r);
        lineRepo.deleteByReceiptId(id);
        lineRepo.flush();
        List<FinanceReceiptLineDto> items = saveLines(r, req.getItems());
        applyLineTotals(r, items);
        finalizeSettlementAuthority(r, req.getAccountCurrencyId(),
                req.getAccountAmount(), false);
        validateReceiptShape(r, items, false);
        receiptRepo.flush();
        return toDetail(r, lineRepo.findByReceiptIdOrderByLineNoAsc(r.getId()).stream().map(this::toLineDto).toList());
    }

    @Transactional
    @PreAuthorize("hasAuthority('finance_receipt:delete')")
    public void delete(UUID id) {
        tx.bind();
        FinanceReceipt r = lockActive(id);
        access.requireWritable(r.getMakerId(), "只能操作本人负责或已授权的销售收款单");
        requirePrepaymentView(r);
        if (r.getStatus() == null || r.getStatus() != STATUS_DRAFT) {
            throw new ApiException(ErrorCode.BUSINESS, "仅草稿单据可删除；已审核单据请红冲");
        }
        r.setDeleted(true);
        r.setDeletedAt(OffsetDateTime.now());
        receiptRepo.save(r);
    }

    /** 审核：status 0→1，核销 AR / 直接收款 / 账户累加 / 写流水。 */
    @Transactional
    @PreAuthorize("hasAuthority('finance_receipt:approve')")
    public FinanceReceiptDetail approve(UUID id) {
        tx.bind();
        // 审核会校验并消费 other_fee_style_id。先取类别锁，再取单据行锁，
        // 与草稿编辑保持固定锁顺序，避免并发停用/增加子类造成 TOCTOU。
        PaymentStyleHierarchyLock.lock(em);
        FinanceReceipt r = lockActive(id);
        access.requireScopedOperationWritable(r.getMakerId(), "只能操作本人负责或已交接的销售收款单",
                "finance_receipt:approve");
        requirePrepaymentView(r);
        if (r.getStatus() == null || r.getStatus() != STATUS_DRAFT) {
            throw new ApiException(ErrorCode.BUSINESS, "仅草稿单据可审核");
        }
        if (r.getAccountId() == null) {
            throw new ApiException(ErrorCode.BUSINESS, "收款单需指定收款账户");
        }
        if (r.getClientId() == null) {
            throw new ApiException(ErrorCode.BUSINESS, "收款单需指定客户");
        }
        // Global money lock order is period -> accounts -> AR/open items.
        // Account-balance adjustment already uses this order; taking account
        // locks first here would create a real deadlock cycle.
        glPosting.lockAutoProjectionPeriod(r.getBillDate());
        validateReceiptShape(r, lineRepo.findByReceiptIdOrderByLineNoAsc(r.getId()), true);
        finalizeSettlementAuthority(r, r.getAccountCurrencyId(),
                r.getAccountAmount(), true);
        assertNoExistingPosting(r.getId()); // M19：幂等护栏，finance_reconciliations 已存在该单流水则禁止重复审核
        UUID approver = currentUser.requireEmployeeId(); // 审核=当前登录用户（报表按 approver_id 解析审核员）
        if (r.getMakerId() != null && r.getMakerId().equals(approver)) {
            throw new ApiException(ErrorCode.BUSINESS, "制单人与审核人不可相同(职责分离)");
        }
        r.setApproverId(approver);
        r.setApproverLegacyId(null);
        r.setApproverName(nameResolver.nameOf(approver));
        settleReceipt(r);
        r.setStatus(STATUS_APPROVED);
        r.setCancelDate(OffsetDateTime.now());
        receiptRepo.saveAndFlush(r);
        glPosting.postReceiptDoc(r.getId());
        assertV1ProjectionIntegrity(r.getId());
        return detail(id);
    }

    /** 红冲：status 1→-1，AR、真实账户、账户流水和 GL 在同一事务追加反向事实。 */
    @Transactional
    @PreAuthorize("hasAuthority('finance_receipt:reverse')")
    public FinanceReceiptDetail reverse(UUID id) {
        tx.bind();
        PaymentStyleHierarchyLock.lock(em);
        FinanceReceipt r = lockActive(id);
        access.requireScopedOperationWritable(r.getMakerId(), "只能操作本人负责或已交接的销售收款单",
                "finance_receipt:reverse");
        requirePrepaymentView(r);
        if (r.getStatus() == null || r.getStatus() != STATUS_APPROVED) {
            throw new ApiException(ErrorCode.BUSINESS, "仅已审核单据可红冲");
        }
        assertCompletePosting(r); // 红冲前确认收款与另付费用流水完整
        OffsetDateTime reversedAt = OffsetDateTime.now();
        glPosting.reverseReceiptDoc(r.getId(), reversedAt);
        // Allocation reversal is database-guarded against a reversed receipt header.
        r.setStatus(STATUS_REVERSED);
        r.setReversedAt(reversedAt); // V390：一次写入，数据库触发器锁定
        receiptRepo.saveAndFlush(r);
        reverseSettlement(r);
        if (r.getSettlementAuthorityVersion()>=SETTLEMENT_AUTHORITY_V1) {
            assertV1ProjectionIntegrity(r.getId());
        }
        return detail(id);
    }

    // ===================== 核销逻辑 =====================

    /** 审核核销：lines 非空 → 累加 AR 核销；lines 空 → postArAp 建 DIRECT_RECEIPT 行。 */
    private void settleReceipt(FinanceReceipt r) {
        List<FinanceReceiptLine> lines = lineRepo.findByReceiptIdOrderByLineNoAsc(r.getId());
        Map<UUID, ArApLedger> lockedLedgers = lines.isEmpty()
                ? Map.of()
                : lockAppliedLedgers(lines);
        if (!lines.isEmpty() && r.getSettlementAuthorityVersion()<SETTLEMENT_AUTHORITY_V2) {
            applyLineTotals(r, lines.stream().map(this::toLineDto).toList());
        }
        BigDecimal amountLocal = nz(r.getAmountLocal());
        if (!lines.isEmpty()) {
            settleAppliedLines(r, lines, lockedLedgers);
            refreshGlFxStyleSnapshot(r, lines);
            // Freeze every authoritative line snapshot while the header is
            // still DRAFT. V407 correctly forbids monetary line changes once
            // the parent status advances to APPROVED.
            lineRepo.flush();
            // Freeze exact receipt-to-order allocations only after authoritative line snapshots exist.
            r.setStatus(STATUS_APPROVED);
            receiptRepo.saveAndFlush(r);
            sourceAllocation.allocateApprovedReceipt(r, lines);
            amountLocal = nz(r.getAmountLocal());
            applyAccountPosting(r, 1);
            return;
        }
        if (r.getCurrencyId() == null) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "直接预收款必须指定币别");
        }
        BigDecimal directRate = positiveRate(r.getExchangeRate());
        BigDecimal directOriginal = positiveMoney(r.getAmountOriginal(), "直接收款原币金额");
        amountLocal = r.getSettlementAuthorityVersion()>=SETTLEMENT_AUTHORITY_V2
                ? money(r.getAmountLocal()) : money(directOriginal.multiply(directRate));
        r.setExchangeRate(directRate);
        r.setAmountOriginal(directOriginal);
        r.setAmountLocal(amountLocal);
        if (r.getSettlementAuthorityVersion() == 0
                && (nz(r.getBankFee()).signum() != 0
                    || nz(r.getOtherFee()).signum() != 0)) {
            throw new ApiException(ErrorCode.BUSINESS, "客户预收款暂不支持费用冲销；费用必须分配到引用的应收明细");
        }
        // 直接收款 / 客户预付：建 DIRECT_RECEIPT 立帐行（amount=0），到账与负余额随 INSERT
        // 一步写入终态——V379 预收 shape 是立即 CHECK，两步写会在中间态被数据库拒绝。
        arApService.postArAp(new ArApLedgerService.ArApPostingRequest(
                "AR", SRC_DIRECT_RECEIPT, r.getId(), r.getBillNo(), r.getBillDate(),
                r.getClientId(), null, r.getCurrencyId(), r.getExchangeRate(),
                BigDecimal.ZERO, (short) 20, "直接收款"),
                money(nz(r.getAmountOriginal())), money(amountLocal));
        List<ArApLedger> created = ledgerRepo.findBySourceForUpdate(
                r.getId(), SRC_DIRECT_RECEIPT);
        if (created.size() != 1) {
            throw new ApiException(ErrorCode.CONFLICT, "直接收款立账结果不唯一");
        }
        ArApLedger led = created.getFirst();
        led.setAmountWriteOffOriginal(BigDecimal.ZERO.setScale(MONEY_SCALE));
        led.setAmountWriteOffLocal(BigDecimal.ZERO.setScale(MONEY_SCALE));
        led.setAmountSettled(amountLocal);
        refreshBalancesAndSettlement(led, r.getBillDate());
        ledgerRepo.save(led);
        // 账户累加 + 写流水
        applyAccountPosting(r, 1);
    }

    /** 红冲反向：lines 非空 → 回减 AR 核销；lines 空 → 删 DIRECT_RECEIPT 立帐行。 */
    private void settleAppliedLines(
            FinanceReceipt receipt,
            List<FinanceReceiptLine> lines,
            Map<UUID, ArApLedger> lockedLedgers) {
        BigDecimal cashLocalTotal = BigDecimal.ZERO;
        BigDecimal cashOriginalTotal = BigDecimal.ZERO;
        BigDecimal writeOffLocalTotal = BigDecimal.ZERO;

        for (FinanceReceiptLine line : lines) {
            ArApLedger ledger = lockedLedgers.get(line.getAppliedLedgerId());
            if (!"AR".equals(ledger.getDirection())) {
                throw new ApiException(ErrorCode.BUSINESS, "销售收款只能引用应收记录");
            }
            if (receipt.getClientId() == null
                    || !Objects.equals(receipt.getClientId(), ledger.getClientId())
                    || (line.getClientId() != null
                    && !Objects.equals(receipt.getClientId(), line.getClientId()))) {
                throw new ApiException(ErrorCode.CONFLICT, "收款客户与引用应收客户不一致");
            }
            if (SRC_DIRECT_RECEIPT.equals(ledger.getSourceDocType())) {
                throw new ApiException(ErrorCode.CONFLICT, "客户预收款不能作为普通应收引用");
            }
            if (ledger.isSettled()) {
                throw new ApiException(ErrorCode.CONFLICT, "引用的应收已经结清");
            }
            if (ledger.getCurrencyId() == null) {
                throw new ApiException(ErrorCode.CONFLICT,
                        "该历史应收的币别尚未核验，不能自动核销；请先由财务完成历史币别确认");
            }
            if (line.getCurrencyId() == null
                    || !Objects.equals(ledger.getCurrencyId(), line.getCurrencyId())) {
                throw new ApiException(ErrorCode.BUSINESS,
                        "核销原币必须与应收币种一致；美元应收可按本批实际到账汇率"
                                + "结汇进入人民币账户，不能以第三币种金额直接改写应收原币");
            }

            BigDecimal receiptRate = positiveRate(line.getExchangeRate());
            BigDecimal recognitionRate = positiveRate(ledger.getExchangeRate());
            BigDecimal cashOriginal = positiveMoney(line.getAmountOriginal(), "本次收款金额");
            BigDecimal writeOffOriginal = nonNegativeMoney(line.getWriteOffAmount(), "冲销金额");
            BigDecimal appliedOriginal = money(cashOriginal.add(writeOffOriginal));
            if (ledger.getAmountBalanceOriginal() == null) {
                throw new ApiException(ErrorCode.CONFLICT,
                        "该历史应收的原币余额或汇率尚未核验，不能自动核销；请先由财务完成历史金额确认");
            }
            BigDecimal beforeOriginal = nz(ledger.getAmountBalanceOriginal());
            if (beforeOriginal.signum() <= 0) {
                throw new ApiException(ErrorCode.CONFLICT, "引用的应收没有可收余额");
            }
            if (appliedOriginal.compareTo(beforeOriginal) > 0) {
                throw new ApiException(ErrorCode.BUSINESS, "本次到账与费用冲销合计超过应收未收金额");
            }

            BigDecimal afterOriginal = money(beforeOriginal.subtract(appliedOriginal));
            BigDecimal cashLocal = receipt.getSettlementAuthorityVersion()>=SETTLEMENT_AUTHORITY_V2
                    ? money(line.getAmountLocal()) : money(cashOriginal.multiply(receiptRate));
            BigDecimal writeOffLocal = money(writeOffOriginal.multiply(receiptRate));
            BigDecimal originalLocal = nz(ledger.getAmountOriginalLocal());
            BigDecimal oldSettledLocal = nz(ledger.getAmountSettled());
            BigDecimal beforeBookLocal=nz(ledger.getAmountBalance());
            BigDecimal newSettledLocal = oldSettledLocal.add(
                    receipt.getSettlementAuthorityVersion()>=SETTLEMENT_AUTHORITY_V2
                    ? sourceAllocation.plannedBookAmount(ledger,appliedOriginal)
                    : money(appliedOriginal.multiply(recognitionRate)));
            if (afterOriginal.signum() == 0) {
                newSettledLocal = originalLocal.subtract(nz(ledger.getAmountOffsetLocal()));
            }
            BigDecimal appliedLocal = money(newSettledLocal.subtract(oldSettledLocal));
            BigDecimal exchangeDiff = money(cashLocal.add(writeOffLocal).subtract(appliedLocal));

            line.setAmountLocal(cashLocal);
            line.setWriteOffLocal(writeOffLocal);
            line.setAppliedAmountLocal(appliedLocal);
            line.setExchangeDiff(exchangeDiff);
            line.setBalanceBeforeOriginal(beforeOriginal);
            line.setBalanceAfterOriginal(afterOriginal);
            if(receipt.getSettlementAuthorityVersion()>=SETTLEMENT_AUTHORITY_V2) {
                line.setBookBalanceBeforeLocal(beforeBookLocal);
                line.setBookBalanceAfterLocal(money(beforeBookLocal.subtract(appliedLocal)));
            }
            lineRepo.save(line);

            ledger.setAmountReceivedOriginal(money(nz(ledger.getAmountReceivedOriginal()).add(cashOriginal)));
            ledger.setAmountReceivedLocal(money(nz(ledger.getAmountReceivedLocal()).add(cashLocal)));
            ledger.setAmountWriteOffOriginal(money(nz(ledger.getAmountWriteOffOriginal()).add(writeOffOriginal)));
            ledger.setAmountWriteOffLocal(money(nz(ledger.getAmountWriteOffLocal()).add(writeOffLocal)));
            ledger.setAmountSettled(money(newSettledLocal));
            refreshBalancesAndSettlement(ledger, receipt.getBillDate());
            ledgerRepo.save(ledger);

            cashOriginalTotal = cashOriginalTotal.add(cashOriginal);
            cashLocalTotal = cashLocalTotal.add(cashLocal);
            writeOffLocalTotal = writeOffLocalTotal.add(writeOffLocal);
        }

        BigDecimal headerFees = money(nz(receipt.getBankFee()).add(nz(receipt.getOtherFee())));
        if (nz(receipt.getOtherFee()).signum() > 0 && receipt.getOtherFeeStyleId() == null) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "填写其它费用时必须选择费用项目");
        }
        if (nz(receipt.getOtherFee()).signum() > 0) {
            assertExpenseStyleActive(receipt.getOtherFeeStyleId());
        }
        if (receipt.getSettlementAuthorityVersion() >= SETTLEMENT_AUTHORITY_V1
                && money(writeOffLocalTotal).signum() != 0) {
            throw new ApiException(ErrorCode.BUSINESS,
                    "新收款的AR商业冲销必须为0，手续费由独立费用快照承担");
        }
        if (receipt.getSettlementAuthorityVersion() == 0
                && money(writeOffLocalTotal).compareTo(headerFees) != 0) {
            throw new ApiException(ErrorCode.BUSINESS,
                    "明细冲销人民币合计必须等于手续费与其它费用合计");
        }
        receipt.setAmountOriginal(money(cashOriginalTotal));
        receipt.setAmountLocal(money(cashLocalTotal));
        receiptRepo.save(receipt);
    }

    private void reverseSettlement(FinanceReceipt r) {
        List<FinanceReceiptLine> lines = lineRepo.findByReceiptIdOrderByLineNoAsc(r.getId());
        BigDecimal amountLocal = nz(r.getAmountLocal());
        if (!lines.isEmpty()) {
            sourceAllocation.reverseApprovedReceipt(r, lines);
            reverseAppliedLines(r, lines, lockAppliedLedgers(lines));
            applyAccountPosting(r, -1);
            return;
        }
        // Direct prepayment reversal retains the AR history row. Any applications
        // must be reversed first; physical delete would drift history and break FK audit.
        List<ArApLedger> rows = ledgerRepo.findBySourceForUpdate(r.getId(), SRC_DIRECT_RECEIPT);
        if (rows.size() != 1) {
            throw new ApiException(ErrorCode.CONFLICT, "直接预收反立账来源缺失或重复");
        }
        ArApLedger led = rows.getFirst();
        long activeOffsets = ((Number) em.createNativeQuery("""
                SELECT COUNT(*) FROM customer_open_item_offsets
                WHERE source_ledger_id=:ledgerId AND status='APPLIED'
                """).setParameter("ledgerId", led.getId()).getSingleResult()).longValue();
        if (activeOffsets != 0 || nz(led.getAmountOffsetOriginal()).signum() != 0
                || nz(led.getAmountOffsetLocal()).signum() != 0) {
            throw new ApiException(ErrorCode.CONFLICT,
                    "客户预收已有转销，必须先按后进先出反转全部预收应用后再红冲收款");
        }
        led.setStatus(STATUS_REVERSED);
        led.setDeleted(true);
        led.setDeletedAt(OffsetDateTime.now());
        ledgerRepo.save(led);
        if (amountLocal.signum() != 0) {
            applyAccountPosting(r, -1);
        }
    }

    private void reverseAppliedLines(
            FinanceReceipt receipt,
            List<FinanceReceiptLine> lines,
            Map<UUID, ArApLedger> lockedLedgers) {
        for (FinanceReceiptLine line : lines) {
            ArApLedger ledger = lockedLedgers.get(line.getAppliedLedgerId());
            if (!"AR".equals(ledger.getDirection())
                    || !Objects.equals(receipt.getClientId(), ledger.getClientId())) {
                throw new ApiException(ErrorCode.CONFLICT, "收款红冲来源与当前应收不一致");
            }
            BigDecimal cashOriginal = positiveMoney(line.getAmountOriginal(), "本次收款金额");
            BigDecimal writeOffOriginal = nonNegativeMoney(line.getWriteOffAmount(), "冲销金额");
            BigDecimal newReceivedOriginal = money(nz(ledger.getAmountReceivedOriginal()).subtract(cashOriginal));
            BigDecimal newReceivedLocal = money(nz(ledger.getAmountReceivedLocal()).subtract(nz(line.getAmountLocal())));
            BigDecimal newWriteOffOriginal = money(nz(ledger.getAmountWriteOffOriginal()).subtract(writeOffOriginal));
            BigDecimal newWriteOffLocal = money(nz(ledger.getAmountWriteOffLocal()).subtract(nz(line.getWriteOffLocal())));
            BigDecimal newSettledLocal = money(nz(ledger.getAmountSettled()).subtract(nz(line.getAppliedAmountLocal())));
            if (newReceivedOriginal.signum() < 0 || newReceivedLocal.signum() < 0
                    || newWriteOffOriginal.signum() < 0 || newWriteOffLocal.signum() < 0
                    || newSettledLocal.signum() < 0) {
                throw new ApiException(ErrorCode.CONFLICT, "应收累计值不足，禁止红冲该收款单");
            }
            ledger.setAmountReceivedOriginal(newReceivedOriginal);
            ledger.setAmountReceivedLocal(newReceivedLocal);
            ledger.setAmountWriteOffOriginal(newWriteOffOriginal);
            ledger.setAmountWriteOffLocal(newWriteOffLocal);
            ledger.setAmountSettled(newSettledLocal);
            refreshBalancesAndSettlement(ledger, receipt.getBillDate());
            ledgerRepo.save(ledger);
        }
    }

    /**
     * 自动结清维护（对齐 数据库约束）：仅 balance = 0 时
     * {@code is_settled=true}。DIRECT_RECEIPT 的负余额表示仍可使用的客户预收款，
     * 必须保持未结清，不能混同为普通应收已核销。
     */
    private void refreshBalancesAndSettlement(ArApLedger led, LocalDate settlementDate) {
        BigDecimal original = money(nz(led.getAmountOriginal())
                .subtract(nz(led.getAmountReceivedOriginal()))
                .subtract(nz(led.getAmountWriteOffOriginal()))
                .subtract(nz(led.getAmountOffsetOriginal())));
        BigDecimal bal = money(nz(led.getAmountOriginalLocal())
                .subtract(nz(led.getAmountSettled())).subtract(nz(led.getAmountOffsetLocal())));
        if (!SRC_DIRECT_RECEIPT.equals(led.getSourceDocType()) && (original.signum()<0 || bal.signum()<0)) {
            throw new ApiException(ErrorCode.CONFLICT, "应收余额不足以覆盖收款、冲销与已转销预收，请核对来源");
        }
        led.setAmountBalanceOriginal(original);
        led.setAmountBalance(bal);
        boolean settled = com.uten.imp.features.finance.arap.ArApSettlementPolicy.isSettled(original,bal);
        led.setSettled(settled);
        led.setSettledDate(settled ? settlementDate : null);
    }

    private Map<UUID, ArApLedger> lockAppliedLedgers(List<FinanceReceiptLine> lines) {
        List<UUID> ids = lines.stream()
                .map(FinanceReceiptLine::getAppliedLedgerId)
                .toList();
        if (ids.stream().anyMatch(Objects::isNull)) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "收款核销明细必须关联应收台账");
        }
        if (new HashSet<>(ids).size() != ids.size()) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "同一应收台账不能在一张收款单中重复核销");
        }
        List<ArApLedger> locked = ledgerRepo.findAllByIdInForUpdate(
                ids.stream().sorted().toList());
        if (locked.size() != ids.size()) {
            throw new ApiException(ErrorCode.BUSINESS, "核销的应收记录不存在或已删除");
        }
        Map<UUID, ArApLedger> byId = new HashMap<>();
        for (ArApLedger ledger : locked) {
            byId.put(ledger.getId(), ledger);
        }
        return byId;
    }

    private void applyLineTotals(FinanceReceipt receipt, List<FinanceReceiptLineDto> lines) {
        if (lines == null || lines.isEmpty()) {
            return;
        }
        UUID currencyId = null;
        BigDecimal commonRate = null;
        for (FinanceReceiptLineDto line : lines) {
            if (line.getCurrencyId() == null) {
                throw new ApiException(ErrorCode.VALIDATION_FAILED, "收款明细必须填写币别");
            }
            if (currencyId == null) {
                currencyId = line.getCurrencyId();
            } else if (!currencyId.equals(line.getCurrencyId())) {
                throw new ApiException(ErrorCode.BUSINESS, "同一张收款单的明细必须使用同一到账币别");
            }
            BigDecimal rate = positiveRate(line.getExchangeRate());
            if (commonRate == null) {
                commonRate = rate;
            } else if (commonRate.compareTo(rate) != 0) {
                throw new ApiException(ErrorCode.BUSINESS, "同一张收款单的明细必须使用同一到账汇率");
            }
        }
        BigDecimal local = lines.stream()
                .map(line -> nz(line.getAmountLocal()))
                .reduce(BigDecimal.ZERO, BigDecimal::add);
        BigDecimal original = lines.stream()
                .map(line -> line.getAmountOriginal() == null
                        ? nz(line.getAmountLocal())
                        : line.getAmountOriginal())
                .reduce(BigDecimal.ZERO, BigDecimal::add);
        receipt.setAmountLocal(local);
        receipt.setAmountOriginal(original);
        receipt.setCurrencyId(currencyId);
        receipt.setExchangeRate(commonRate);
        receiptRepo.save(receipt);
    }

    /**
     * 累加账户余额 + receipts_total，并返回应写入账户流水的同口径金额。
     *
     * <p>人民币账户记本币；与到账币种相同的外币账户记原币。审核为正、红冲为负，
     * 账户余额与 finance_reconciliations 始终保持同一账户币种口径。
     */
    private void applyAccountPosting(FinanceReceipt receipt, int sign) {
        if (receipt.getSettlementAuthorityVersion() < SETTLEMENT_AUTHORITY_V1) {
            BigDecimal accountAmount = adjustAccount(
                    receipt.getAccountId(),
                    receipt.getCurrencyId(),
                    nz(receipt.getAmountOriginal()).multiply(BigDecimal.valueOf(sign)),
                    nz(receipt.getAmountLocal()).multiply(BigDecimal.valueOf(sign)));
            if (sign > 0) {
                insertReconciliation(receipt, accountAmount);
            } else {
                accountFlowLedger.reverse(
                        RECON_SOURCE, receipt.getId(), receipt.getReversedAt(), "销售收款红冲");
            }
            return;
        }

        List<UUID> ids = new ArrayList<>();
        ids.add(receipt.getAccountId());
        if (FEE_SEPARATE.equals(receipt.getFeeSettlementMode())
                && receipt.getFeePaymentAccountId() != null
                && !receipt.getFeePaymentAccountId().equals(receipt.getAccountId())) {
            ids.add(receipt.getFeePaymentAccountId());
        }
        Map<UUID, AccountCurrencySnapshot> accounts =
                loadAccountCurrencySnapshots(ids, true);
        AccountCurrencySnapshot receiving = accounts.get(receipt.getAccountId());
        if (receiving == null
                || !Objects.equals(receiving.currencyId(), receipt.getAccountCurrencyId())) {
            throw new ApiException(ErrorCode.CONFLICT,
                    "收款账户或币种已变化，禁止继续过账");
        }
        BigDecimal incoming = money(receipt.getAccountAmount())
                .multiply(BigDecimal.valueOf(sign));
        updateIncomingAccount(receipt.getAccountId(), incoming);

        if (FEE_SEPARATE.equals(receipt.getFeeSettlementMode())) {
            AccountCurrencySnapshot feeAccount =
                    accounts.get(receipt.getFeePaymentAccountId());
            if (feeAccount == null
                    || !Objects.equals(
                            feeAccount.currencyId(), receipt.getFeeAccountCurrencyId())) {
                throw new ApiException(ErrorCode.CONFLICT,
                        "手续费付款账户或币种已变化，禁止继续过账");
            }
            BigDecimal feeAmount = money(nz(receipt.getBankFeeAccountAmount())
                    .add(nz(receipt.getOtherFeeAccountAmount())))
                    .multiply(BigDecimal.valueOf(sign));
            updateOutgoingAccount(receipt.getFeePaymentAccountId(), feeAmount);
        }

        if (sign > 0) {
            insertV1Reconciliations(receipt);
        } else {
            accountFlowLedger.reverse(
                    RECON_SOURCE, receipt.getId(), receipt.getReversedAt(), "销售收款红冲");
            if (FEE_SEPARATE.equals(receipt.getFeeSettlementMode())) {
                accountFlowLedger.reverse(
                        RECON_FEE_SOURCE, receipt.getId(), receipt.getReversedAt(),
                        "销售收款另付费用红冲");
            }
        }
    }

    private void updateIncomingAccount(UUID accountId, BigDecimal delta) {
        int updated = em.createNativeQuery("""
                        UPDATE accounts
                        SET balance_current=balance_current+:amount,
                            receipts_total=receipts_total+:amount,
                            updated_at=now()
                        WHERE id=:id
                        """)
                .setParameter("amount", delta)
                .setParameter("id", accountId)
                .executeUpdate();
        if (updated != 1) {
            throw new ApiException(ErrorCode.CONFLICT,
                    "收款账户余额更新失败：" + accountId);
        }
    }

    private void updateOutgoingAccount(UUID accountId, BigDecimal delta) {
        int updated = em.createNativeQuery("""
                        UPDATE accounts
                        SET balance_current=balance_current-:amount,
                            payments_total=payments_total+:amount,
                            updated_at=now()
                        WHERE id=:id
                        """)
                .setParameter("amount", delta)
                .setParameter("id", accountId)
                .executeUpdate();
        if (updated != 1) {
            throw new ApiException(ErrorCode.CONFLICT,
                    "手续费付款账户余额更新失败：" + accountId);
        }
    }

    private BigDecimal adjustAccount(
            UUID accountId,
            UUID receiptCurrencyId,
            BigDecimal originalDelta,
            BigDecimal localDelta) {
        @SuppressWarnings("unchecked")
        List<Object[]> rows = em.createNativeQuery("""
                        SELECT account.currency_id, currency.code, currency.name,
                               currency.is_base_currency
                        FROM accounts account
                        LEFT JOIN currencies currency
                          ON currency.id=account.currency_id
                         AND COALESCE(currency.is_deleted,false)=false
                         AND currency.status='使用'
                        WHERE account.id=:id
                          AND COALESCE(account.is_deleted,false)=false
                          AND account.status='使用'
                        FOR UPDATE OF account
                        """)
                .setParameter("id", accountId)
                .getResultList();
        if (rows.size() != 1) {
            throw new ApiException(ErrorCode.BUSINESS,
                    "收款账户不存在或已停用：" + accountId);
        }
        Object[] row = rows.getFirst();
        UUID accountCurrencyId = (UUID) row[0];
        String currencyCode = row[1] == null ? null : row[1].toString();
        String currencyName = row[2] == null ? null : row[2].toString();
        boolean baseCurrency = Boolean.TRUE.equals(row[3]);
        if (accountCurrencyId == null) {
            throw new ApiException(ErrorCode.BUSINESS, "收款账户未设置币种");
        }
        if (currencyCode == null && currencyName == null) {
            throw new ApiException(ErrorCode.BUSINESS, "收款账户币种不存在或已停用");
        }
        BigDecimal accountDelta;
        if (baseCurrency) {
            accountDelta = money(localDelta);
        } else if (Objects.equals(accountCurrencyId, receiptCurrencyId)) {
            accountDelta = money(originalDelta);
        } else {
            throw new ApiException(ErrorCode.BUSINESS,
                    "收款账户必须为人民币账户或与应收原币相同的账户；"
                            + "美元应收可结汇进入人民币账户，不能直接进入第三币种账户："
                            + accountId);
        }
        int updated = em.createNativeQuery("""
                        UPDATE accounts
                        SET balance_current=COALESCE(balance_current,0)+:amount,
                            receipts_total=COALESCE(receipts_total,0)+:amount,
                            updated_at=now()
                        WHERE id=:id
                        """)
                .setParameter("amount", accountDelta)
                .setParameter("id", accountId)
                .executeUpdate();
        if (updated != 1) {
            throw new ApiException(ErrorCode.CONFLICT, "收款账户余额更新失败：" + accountId);
        }
        return accountDelta;
    }

    private void insertReconciliation(FinanceReceipt r, BigDecimal accountAmount) {
        String counterpart = r.getClientId() == null ? null : lookupClientName(r.getClientId());
        em.createNativeQuery("""
                INSERT INTO finance_reconciliations
                  (bill_no, source_doc_type, source_doc_id, account_id, check_no, counterpart_name,
                   in_amount, out_amount, bill_date, settled_date, source_remark, legacy_bstyle, created_at, updated_at, is_deleted)
                VALUES (:billNo, :src, :sid, :acc, :chk, :cpn, :inAmt, 0, :bd, :sd, :sr, 20, now(), now(), false)
                """)
                .setParameter("billNo", r.getBillNo())
                .setParameter("src", RECON_SOURCE)
                .setParameter("sid", r.getId())
                .setParameter("acc", r.getAccountId())
                .setParameter("chk", r.getInvoiceNo())
                .setParameter("cpn", counterpart)
                .setParameter("inAmt", accountAmount)
                .setParameter("bd", r.getBillDate().atStartOfDay(java.time.ZoneOffset.UTC).toOffsetDateTime()) // M17：bill_date 用单据日期，settled_date 保持审核时刻
                .setParameter("sd", OffsetDateTime.now())
                .setParameter("sr", r.getSourceRemark())
                .executeUpdate();
    }

    private void insertV1Reconciliations(FinanceReceipt receipt) {
        String counterpart = receipt.getClientId() == null
                ? null : lookupClientName(receipt.getClientId());
        em.createNativeQuery("""
                        INSERT INTO finance_reconciliations(
                            bill_no,source_doc_type,source_doc_id,account_id,
                            account_currency_id,in_amount,out_amount,amount_local,
                            bill_date,settled_date,source_remark,remark,
                            entry_kind,created_at,updated_at,is_deleted)
                        VALUES(
                            :billNo,:source,:sourceId,:account,:currency,
                            :amount,0,:local,:bookedAt,now(),:sourceRemark,:remark,
                            'POSTING',now(),now(),FALSE)
                        """)
                .setParameter("billNo", receipt.getBillNo())
                .setParameter("source", RECON_SOURCE)
                .setParameter("sourceId", receipt.getId())
                .setParameter("account", receipt.getAccountId())
                .setParameter("currency", receipt.getAccountCurrencyId())
                .setParameter("amount", receipt.getAccountAmount())
                .setParameter("local", receipt.getAccountAmountLocal())
                .setParameter("bookedAt", receipt.getBankBookedAt())
                .setParameter("sourceRemark", receipt.getSettlementChannel())
                .setParameter("remark", counterpart == null
                        ? receipt.getRemark() : counterpart + " " + Objects.toString(receipt.getRemark(), ""))
                .executeUpdate();

        if (!FEE_SEPARATE.equals(receipt.getFeeSettlementMode())) return;
        BigDecimal feeAmount = money(nz(receipt.getBankFeeAccountAmount())
                .add(nz(receipt.getOtherFeeAccountAmount())));
        BigDecimal feeLocal = money(nz(receipt.getBankFee())
                .add(nz(receipt.getOtherFee())));
        em.createNativeQuery("""
                        INSERT INTO finance_reconciliations(
                            bill_no,source_doc_type,source_doc_id,account_id,
                            account_currency_id,in_amount,out_amount,amount_local,
                            bill_date,settled_date,source_remark,remark,
                            entry_kind,created_at,updated_at,is_deleted)
                        VALUES(
                            :billNo,:source,:sourceId,:account,:currency,
                            0,:amount,:local,:bookedAt,now(),'收款费用另付',:remark,
                            'POSTING',now(),now(),FALSE)
                        """)
                .setParameter("billNo", receipt.getBillNo())
                .setParameter("source", RECON_FEE_SOURCE)
                .setParameter("sourceId", receipt.getId())
                .setParameter("account", receipt.getFeePaymentAccountId())
                .setParameter("currency", receipt.getFeeAccountCurrencyId())
                .setParameter("amount", feeAmount)
                .setParameter("local", feeLocal)
                .setParameter("bookedAt", receipt.getBankBookedAt())
                .setParameter("remark", "银行手续费/外贸代理费")
                .executeUpdate();
    }

    private void assertNoExistingPosting(UUID receiptId) {
        if (postingCount(receiptId, RECON_SOURCE) != 0
                || postingCount(receiptId, RECON_FEE_SOURCE) != 0) {
            throw new ApiException(ErrorCode.CONFLICT, "该单据已存在账户流水，禁止重复审核");
        }
    }

    private void assertCompletePosting(FinanceReceipt receipt) {
        if(receipt.getSettlementAuthorityVersion()>=SETTLEMENT_AUTHORITY_V1){
            long integrity=((Number)em.createNativeQuery("""
                    SELECT COUNT(*) FROM v_receipt_flow_integrity
                    WHERE receipt_id=:id AND is_consistent
                    """).setParameter("id",receipt.getId()).getSingleResult()).longValue();
            if(integrity!=1L){
                throw new ApiException(ErrorCode.CONFLICT,
                        "收款账户流水与冻结的账户、币种、原币/本位币或反向引用不一致，禁止红冲");
            }
        }else{
            long legacyGl=((Number)em.createNativeQuery("""
                    SELECT COUNT(*) FROM v_receipt_v0_gl_reconciliation
                    WHERE receipt_id=:id AND reconciliation_state='OK'
                    """).setParameter("id",receipt.getId()).getSingleResult()).longValue();
            if(legacyGl!=1L){
                throw new ApiException(ErrorCode.CONFLICT,
                        "历史 V0 收款总账凭证缺失、歧义或不平，禁止自动红冲");
            }
        }
        long actual = postingCount(receipt.getId(), RECON_SOURCE);
        long feeActual = postingCount(receipt.getId(), RECON_FEE_SOURCE);
        long expectedFee = receipt.getSettlementAuthorityVersion() >= SETTLEMENT_AUTHORITY_V1
                && FEE_SEPARATE.equals(receipt.getFeeSettlementMode()) ? 1L : 0L;
        if (actual != 1L || feeActual != expectedFee) {
            throw new ApiException(ErrorCode.CONFLICT,
                    "收款流水不完整，禁止红冲(收款 " + actual
                            + "，另付费用 " + feeActual + ")");
        }
    }

    private void assertV1ProjectionIntegrity(UUID receiptId){
        Object[] proof=NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT
                  (SELECT COUNT(*) FROM v_receipt_flow_integrity
                   WHERE receipt_id=:id AND is_consistent),
                  (SELECT COUNT(*) FROM v_receipt_gl_integrity
                   WHERE receipt_id=:id AND is_consistent)
                """).setParameter("id",receiptId)).getFirst();
        if(((Number)proof[0]).longValue()!=1L || ((Number)proof[1]).longValue()!=1L){
            throw new ApiException(ErrorCode.CONFLICT,
                    "收款账户流水或总账投影未通过事务内完整性校验");
        }
    }

    private long postingCount(UUID receiptId, String sourceType) {
        return ((Number) em.createNativeQuery("""
                        SELECT COUNT(*)
                        FROM finance_reconciliations
                        WHERE source_doc_type = :src
                          AND source_doc_id = :id
                          AND entry_kind IN ('POSTING','ADJUSTMENT')
                          AND COALESCE(is_deleted, false) = false
                        """)
                .setParameter("src", sourceType)
                .setParameter("id", receiptId)
                .getSingleResult()).longValue();
    }

    private String lookupClientName(UUID clientId) {
        try {
            Object r = em.createNativeQuery("SELECT name FROM clients WHERE id = :id AND COALESCE(is_deleted, false) = false")
                    .setParameter("id", clientId).getSingleResult();
            return r == null ? null : r.toString();
        } catch (jakarta.persistence.NoResultException e) {
            return null;
        } catch (jakarta.persistence.NonUniqueResultException e) {
            throw new ApiException(ErrorCode.CONFLICT, "客户主档存在重复：" + clientId);
        }
    }

    private void assertExpenseStyleActive(UUID styleId) {
        long count = ((Number) em.createNativeQuery("""
                        SELECT COUNT(*)
                        FROM payment_styles
                        WHERE id=:id
                          AND category='EXPENSE'
                          AND status='使用'
                          AND COALESCE(is_deleted,false)=false
                        """)
                .setParameter("id", styleId)
                .getSingleResult()).longValue();
        if (count != 1) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "其它费用项目不存在、已停用或不是费用类");
        }
    }

    // ===================== CRUD 辅助 =====================

    private void requirePrepaymentView(FinanceReceipt receipt) {
        requirePrepaymentView(receipt == null ? null : receipt.getReceiptKind());
    }

    private void requirePrepaymentView(String receiptKind) {
        if (receiptKind != null && "CUSTOMER_PREPAYMENT".equalsIgnoreCase(receiptKind.trim())
                && !canViewCustomerPrepayment()) {
            throw new ApiException(ErrorCode.FORBIDDEN, "客户预收资金要求 customer_prepayment:view 与 finance:view:all 权限");
        }
    }

    private boolean canViewCustomerPrepayment() {
        return access.hasAuthority("customer_prepayment:view")
                && access.hasAuthority("finance:view:all");
    }

    private void validateReceiptShape(FinanceReceipt receipt, List<?> lines, boolean lockOrder) {
        String kind = receipt.getReceiptKind();
        boolean hasLines = lines != null && !lines.isEmpty();
        if ("AR_SETTLEMENT".equals(kind)) {
            if (!hasLines) {
                throw new ApiException(ErrorCode.VALIDATION_FAILED, "普通应收收款必须至少选择一笔正式应收");
            }
            if (receipt.getSalesOrderId() != null) {
                throw new ApiException(ErrorCode.VALIDATION_FAILED,
                        "普通应收收款按明细来源分配，单头不得绑定销售单");
            }
            return;
        }
        if (!"CUSTOMER_PREPAYMENT".equals(kind)) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED,
                    "收款业务类型必须是 AR_SETTLEMENT 或 CUSTOMER_PREPAYMENT");
        }
        if (hasLines) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "客户预收款不能包含普通应收核销明细");
        }
        if (receipt.getClientId() == null || receipt.getCurrencyId() == null) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "客户预收款必须指定客户和币别");
        }
        if (receipt.getExchangeRate() == null || receipt.getExchangeRate().signum() <= 0) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "客户预收款汇率必须大于 0");
        }
        if (receipt.getAmountOriginal() == null || receipt.getAmountOriginal().signum() <= 0) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "客户预收款原币金额必须大于 0");
        }
        if (receipt.getSalesOrderId() == null) return;
        String sql = """
                SELECT client_id,currency_id,status,is_deleted,is_stopped,is_closed
                FROM sales_orders WHERE id=:id
                """ + (lockOrder ? " FOR UPDATE" : "");
        @SuppressWarnings("unchecked")
        List<Object[]> rows = em.createNativeQuery(sql)
                .setParameter("id", receipt.getSalesOrderId()).getResultList();
        if (rows.size() != 1 || ((Number) rows.getFirst()[2]).intValue() != STATUS_APPROVED
                || Boolean.TRUE.equals(rows.getFirst()[3])
                || Boolean.TRUE.equals(rows.getFirst()[4])
                || Boolean.TRUE.equals(rows.getFirst()[5])
                || !Objects.equals(receipt.getClientId(), rows.getFirst()[0])
                || !Objects.equals(receipt.getCurrencyId(), rows.getFirst()[1])) {
            throw new ApiException(ErrorCode.CONFLICT,
                    "绑定预收要求销售单已审核、未中止、未结案且客户、币别与收款完全一致");
        }
    }

    private void applyHeader(FinanceReceiptSaveRequest req, FinanceReceipt r) {
        // 单据号系统自动生成（服务端权威）：仅新建（billNo 空）时取号；更新保留既有号，忽略客户端值。
        if (r.getBillNo() == null || r.getBillNo().isBlank()) {
            r.setBillNo(docNumberService.nextNumber(DocNumberPrefix.FIN_RECEIPT));
        }
        r.setBillDate(req.getBillDate());
        r.setReceiptKind(req.getReceiptKind() == null
                ? null : req.getReceiptKind().trim().toUpperCase(java.util.Locale.ROOT));
        r.setSalesOrderId(req.getSalesOrderId());
        r.setClientId(req.getClientId());
        r.setAccountId(req.getAccountId());
        r.setCounterpartAccountId(req.getCounterpartAccountId());
        // AR validation queries may auto-flush this draft. Keep the first write
        // legacy-compatible; finalizeSettlementAuthority upgrades it to V2 only
        // after every account/fee snapshot has been derived in this transaction.
        r.setSettlementAuthorityVersion((short) 0);
        r.setCurrencyId(req.getCurrencyId());
        // null 必须清掉实体默认值/旧草稿值；直收与预收也只能使用财务显式填写的到账汇率。
        r.setExchangeRate(req.getExchangeRate()==null?null:positiveRate(req.getExchangeRate()));
        r.setAmountOriginal(com.uten.imp.common.util.FinancialExactAmount.optional(req.getAmountOriginal(),"收款原币"));
        // Initial quote projection only; V2 replaces it with the actual bank basis below.
        java.math.BigDecimal rate = r.getExchangeRate();
        r.setAmountLocal(req.getAmountOriginal() == null || rate == null
                ? null
                : money(req.getAmountOriginal().multiply(rate)));
        r.setBankFee(BigDecimal.ZERO.setScale(MONEY_SCALE));
        r.setOtherFee(BigDecimal.ZERO.setScale(MONEY_SCALE));
        r.setBankFeeAccountAmount(money(req.getBankFeeAccountAmount() != null
                ? req.getBankFeeAccountAmount() : req.getBankFee()));
        r.setOtherFeeAccountAmount(money(req.getOtherFeeAccountAmount() != null
                ? req.getOtherFeeAccountAmount() : req.getOtherFee()));
        r.setOtherFeeStyleId(req.getOtherFeeStyleId());
        r.setSettlementChannel(upper(req.getSettlementChannel()));
        r.setSettlementAgentSupplierId(req.getSettlementAgentSupplierId());
        r.setSettlementAgentNameSnapshot(null);
        r.setSettlementRateQuoteDirection("BASE_PER_SETTLEMENT");
        r.setExchangeRateSource(upper(req.getExchangeRateSource()));
        r.setExchangeRateEffectiveAt(req.getExchangeRateEffectiveAt());
        r.setBankBookedAt(req.getBankBookedAt());
        r.setBankReference(trimToNull(req.getBankReference()));
        r.setAgentStatementNo(trimToNull(req.getAgentStatementNo()));
        r.setAccountCurrencyId(req.getAccountCurrencyId());
        r.setAccountAmount(req.getAccountAmount() == null
                ? null : money(req.getAccountAmount()));
        r.setAccountAmountLocal(null);
        r.setAccountExchangeRate(null);
        r.setAccountExchangeRateSource(null);
        r.setFeeSettlementMode(upper(req.getFeeSettlementMode()));
        r.setFeeBearer(upper(req.getFeeBearer()));
        r.setFeePaymentAccountId(req.getFeePaymentAccountId());
        r.setFeeAccountCurrencyId(null);
        r.setFeeAccountExchangeRate(null);
        applyReceiptMethod(req, r);
        r.setInvoiceNo(trimToNull(req.getInvoiceNo()));
        applyOperator(req.getOperatorId(), r);
        r.setSourceRemark(trimToNull(req.getSourceRemark()));
        r.setRemark(trimToNull(req.getRemark()));
    }

    /**
     * Freeze actual bank amounts and complete fee products against the account currency.
     * The reference quote remains evidence; it does not replace an actual base-currency bank receipt.
     */
    private void finalizeSettlementAuthority(
            FinanceReceipt receipt,
            UUID expectedAccountCurrencyId,
            BigDecimal actualAccountAmount,
            boolean lockAccounts) {
        if (receipt.getAccountId() == null || receipt.getCurrencyId() == null
                || receipt.getAmountOriginal() == null
                || receipt.getAmountOriginal().signum() <= 0
                || receipt.getAmountLocal() == null
                || receipt.getAmountLocal().signum() <= 0
                || receipt.getExchangeRate() == null
                || receipt.getExchangeRate().signum() <= 0) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED,
                    "收款账户、结算原币、原币毛额和实际结算汇率必须完整");
        }
        String channel = upper(receipt.getSettlementChannel());
        String rateSource = upper(receipt.getExchangeRateSource());
        if (channel == null
                || !Set.of("DIRECT_ACCOUNT", "TRADE_AGENT_CONVERSION").contains(channel)) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED,
                    "收款渠道只能是公司账户直收或外贸公司代收结汇");
        }
        if (receipt.getExchangeRateEffectiveAt() == null
                || receipt.getBankBookedAt() == null) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED,
                    "必须填写汇率生效时间和银行实际入账时间");
        }
        if (trimToNull(receipt.getBankReference()) == null) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED,
                    "必须填写真实银行入账流水号");
        }
        if ("TRADE_AGENT_CONVERSION".equals(channel)
                && !"TRADE_AGENT_STATEMENT".equals(rateSource)) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED,
                    "外贸公司代收结汇必须使用外贸公司结汇单作为汇率来源");
        }
        if ("DIRECT_ACCOUNT".equals(channel)
                && !"BANK_STATEMENT".equals(rateSource)) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED,
                    "公司账户直收必须使用银行回单作为汇率来源");
        }

        BigDecimal bankFeeAccount = nonNegativeMoney(
                receipt.getBankFeeAccountAmount(), "银行手续费");
        BigDecimal otherFeeAccount = nonNegativeMoney(
                receipt.getOtherFeeAccountAmount(), "外贸代理费或其它费用");
        BigDecimal feeAccountTotal = money(bankFeeAccount.add(otherFeeAccount));
        String feeMode = upper(receipt.getFeeSettlementMode());
        String feeBearer = upper(receipt.getFeeBearer());
        if (feeAccountTotal.signum() == 0) {
            feeMode = FEE_NONE;
            feeBearer = FEE_BEARER_NONE;
        } else if (feeMode == null
                || !Set.of(FEE_DEDUCTED, FEE_SEPARATE).contains(feeMode)) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED,
                    "有手续费时必须选择从到账扣除或另行支付");
        }
        if (feeAccountTotal.signum() > 0
                && !FEE_BEARER_COMPANY.equals(feeBearer)) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED,
                    "有费用时必须明确由本公司承担；客户或外贸公司承担会形成新的应收/索赔，"
                            + "不能直接记为本公司费用");
        }
        UUID feePaymentAccountId = FEE_SEPARATE.equals(feeMode)
                ? receipt.getFeePaymentAccountId() : null;
        if (FEE_SEPARATE.equals(feeMode) && feePaymentAccountId == null) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED,
                    "手续费另行支付时必须选择真实付款账户");
        }

        List<UUID> accountIds = new ArrayList<>();
        accountIds.add(receipt.getAccountId());
        if (feePaymentAccountId != null
                && !feePaymentAccountId.equals(receipt.getAccountId())) {
            accountIds.add(feePaymentAccountId);
        }
        Map<UUID, AccountCurrencySnapshot> accounts =
                loadAccountCurrencySnapshots(accountIds, lockAccounts);
        AccountCurrencySnapshot receiving = accounts.get(receipt.getAccountId());
        if (receiving == null) {
            throw new ApiException(ErrorCode.BUSINESS, "收款账户不存在、已停用或币种不可用");
        }
        if (expectedAccountCurrencyId != null
                && !expectedAccountCurrencyId.equals(receiving.currencyId())) {
            throw new ApiException(ErrorCode.CONFLICT,
                    "收款账户币种已变化，请刷新账户资料后重新保存");
        }

        BigDecimal settlementRate = positiveRate(receipt.getExchangeRate());
        BigDecimal receivingRate;
        String receivingRateSource;
        if (receiving.baseCurrency()) {
            receivingRate = BigDecimal.ONE.setScale(RATE_SCALE);
            receivingRateSource = "BASE_CURRENCY_IDENTITY";
        } else if (receiving.currencyId().equals(receipt.getCurrencyId())) {
            receivingRate = settlementRate;
            receivingRateSource = "SETTLEMENT_RATE";
        } else {
            throw new ApiException(ErrorCode.BUSINESS,
                    "收款账户必须是本位币账户或与应收原币相同的真实外币账户；第三币种暂不支持");
        }
        if ("TRADE_AGENT_CONVERSION".equals(channel)) {
            if (!receiving.baseCurrency()) {
                throw new ApiException(ErrorCode.BUSINESS,
                        "外贸公司代收结汇只能进入本位币账户；真实外币保留请使用公司账户直收");
            }
            if (receipt.getSettlementAgentSupplierId() == null) {
                throw new ApiException(ErrorCode.VALIDATION_FAILED,
                        "外贸公司代收结汇必须选择合作外贸公司");
            }
            if (trimToNull(receipt.getAgentStatementNo()) == null) {
                throw new ApiException(ErrorCode.VALIDATION_FAILED,
                        "外贸公司代收结汇必须填写代理结算单号");
            }
            receipt.setSettlementAgentNameSnapshot(activeSupplierName(
                    receipt.getSettlementAgentSupplierId(), lockAccounts));
        } else {
            if (receipt.getSettlementAgentSupplierId() != null) {
                throw new ApiException(ErrorCode.VALIDATION_FAILED,
                        "公司账户直收不能同时填写外贸代理公司");
            }
            if (trimToNull(receipt.getAgentStatementNo()) != null) {
                throw new ApiException(ErrorCode.VALIDATION_FAILED,
                        "公司账户直收不能填写外贸代理结算单号");
            }
            receipt.setSettlementAgentNameSnapshot(null);
        }

        AccountCurrencySnapshot feeAccount = FEE_SEPARATE.equals(feeMode)
                ? accounts.get(feePaymentAccountId) : receiving;
        if (feeAccount == null) {
            throw new ApiException(ErrorCode.BUSINESS, "手续费付款账户不存在、已停用或币种不可用");
        }
        BigDecimal feeRate;
        if (feeAccount.baseCurrency()) {
            feeRate = BigDecimal.ONE.setScale(RATE_SCALE);
        } else if (feeAccount.currencyId().equals(receipt.getCurrencyId())) {
            feeRate = settlementRate;
        } else {
            throw new ApiException(ErrorCode.BUSINESS,
                    "手续费账户必须是本位币账户或与本批结算原币相同的账户；第三币种暂不支持");
        }
        BigDecimal bankFeeLocal = money(bankFeeAccount.multiply(feeRate));
        BigDecimal otherFeeLocal = money(otherFeeAccount.multiply(feeRate));
        BigDecimal feeLocalTotal = money(bankFeeLocal.add(otherFeeLocal));

        // Actual bank amount is a source fact. A quote is evidence and cannot replace it.
        BigDecimal receivingAmount=positiveMoney(actualAccountAmount,"银行实际到账金额");
        if (receivingAmount.signum() <= 0) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED,
                    "手续费不能等于或超过本批到账毛额");
        }
        BigDecimal receivingLocal=money(receivingAmount.multiply(receivingRate));
        if(receiving.currencyId().equals(receipt.getCurrencyId())) {
            BigDecimal nativeGross=FEE_DEDUCTED.equals(feeMode)
                    ?money(receivingAmount.add(feeAccountTotal)):receivingAmount;
            if(nativeGross.compareTo(receipt.getAmountOriginal())!=0)
                throw new ApiException(ErrorCode.CONFLICT,
                        "同币种银行实收加到账扣费必须等于本次收款原币；多收部分请登记客户预收款");
            if(receiving.baseCurrency() && settlementRate.compareTo(BigDecimal.ONE)!=0)
                throw new ApiException(ErrorCode.VALIDATION_FAILED,"本位币同币收款汇率必须为1");
        }
        receipt.setAmountLocal(money(receivingLocal.add(FEE_DEDUCTED.equals(feeMode)?feeLocalTotal:BigDecimal.ZERO)));
        allocateActualBankBasis(receipt);
        if (otherFeeAccount.signum() > 0 && receipt.getOtherFeeStyleId() == null) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED,
                    "填写外贸代理费或其它费用时必须选择费用项目");
        }
        if (otherFeeAccount.signum() > 0) {
            assertExpenseStyleActive(receipt.getOtherFeeStyleId());
        }

        BigDecimal exchangeDifference=lineRepo
                .findByReceiptIdOrderByLineNoAsc(receipt.getId()).stream()
                .map(line->nz(line.getExchangeDiff()))
                .reduce(BigDecimal.ZERO,BigDecimal::add);
        UUID counterStyle=requiredPostingStyle(
                "CUSTOMER_PREPAYMENT".equals(receipt.getReceiptKind())
                        ?"CUSTOMER_ADVANCE":"AR_CONTROL");
        UUID bankFeeStyle=bankFeeLocal.signum()==0
                ?null:requiredPostingStyle("BANK_FEE_EXPENSE");
        UUID fxStyle=exchangeDifference.signum()==0
                ?null:requiredPostingStyle("FX_GAIN_LOSS");

        receipt.setSettlementChannel(channel);
        receipt.setExchangeRateSource(rateSource);
        receipt.setExchangeRate(settlementRate);
        receipt.setAccountCurrencyId(receiving.currencyId());
        receipt.setAccountExchangeRate(receivingRate);
        receipt.setAccountExchangeRateSource(receivingRateSource);
        receipt.setAccountAmount(receivingAmount);
        receipt.setAccountAmountLocal(receivingLocal);
        receipt.setBankFeeAccountAmount(bankFeeAccount);
        receipt.setOtherFeeAccountAmount(otherFeeAccount);
        receipt.setBankFee(bankFeeLocal);
        receipt.setOtherFee(otherFeeLocal);
        receipt.setFeeSettlementMode(feeMode);
        receipt.setFeeBearer(feeBearer);
        receipt.setFeePaymentAccountId(feePaymentAccountId);
        receipt.setFeeAccountCurrencyId(feeAccount.currencyId());
        receipt.setFeeAccountExchangeRate(feeRate);
        receipt.setGlAccountStyleId(receiving.styleId());
        receipt.setGlCounterStyleId(counterStyle);
        receipt.setGlBankFeeStyleId(bankFeeStyle);
        receipt.setGlFxStyleId(fxStyle);
        receipt.setGlFeePaymentStyleId(FEE_SEPARATE.equals(feeMode)
                ?feeAccount.styleId():null);
        // Set V2 last: any validation query before this point may auto-flush
        // the managed draft, which must remain a complete V0 shape until all
        // server-derived authority snapshots are ready.
        receipt.setSettlementAuthorityVersion(SETTLEMENT_AUTHORITY_V2);
        receiptRepo.save(receipt);
    }

    private void allocateActualBankBasis(FinanceReceipt receipt) {
        List<FinanceReceiptLine> lines=lineRepo.findByReceiptIdOrderByLineNoAsc(receipt.getId());
        if(lines.isEmpty())return;
        BigDecimal beforeOriginal=receipt.getAmountOriginal();
        BigDecimal beforeLocal=receipt.getAmountLocal();
        for(FinanceReceiptLine line:lines) {
            BigDecimal cash=positiveMoney(line.getAmountOriginal(),"明细实际收款原币");
            BigDecimal local=com.uten.imp.common.finance.FinancialBookAllocation.part(cash,beforeOriginal,beforeLocal);
            line.setBankBasisBeforeOriginal(beforeOriginal);line.setBankBasisBeforeLocal(beforeLocal);
            beforeOriginal=money(beforeOriginal.subtract(cash));beforeLocal=money(beforeLocal.subtract(local));
            line.setBankBasisAfterOriginal(beforeOriginal);line.setBankBasisAfterLocal(beforeLocal);
            line.setAmountLocal(local);
            line.setExchangeDiff(money(local.subtract(nz(line.getAppliedAmountLocal()))));
            lineRepo.save(line);
        }
        if(beforeOriginal.signum()!=0||beforeLocal.signum()!=0)
            throw new ApiException(ErrorCode.CONFLICT,"收款明细必须完整分配同一笔银行事实，剩余金额不能丢失");
    }

    private UUID requiredPostingStyle(String roleKey){
        Object value=em.createNativeQuery(
                        "SELECT system_posting_style_id(:roleKey)")
                .setParameter("roleKey",roleKey)
                .getSingleResult();
        if(!(value instanceof UUID id)){
            throw new ApiException(ErrorCode.CONFLICT,
                    "收款总账系统角色未配置有效科目 UUID："+roleKey);
        }
        return id;
    }

    private void refreshGlFxStyleSnapshot(
            FinanceReceipt receipt,List<FinanceReceiptLine> lines){
        BigDecimal difference=lines.stream()
                .map(line->nz(line.getExchangeDiff()))
                .reduce(BigDecimal.ZERO,BigDecimal::add);
        receipt.setGlFxStyleId(difference.signum()==0
                ?null:requiredPostingStyle("FX_GAIN_LOSS"));
        receiptRepo.save(receipt);
    }

    private Map<UUID, AccountCurrencySnapshot> loadAccountCurrencySnapshots(
            List<UUID> accountIds, boolean lock) {
        List<UUID> ids = accountIds.stream().distinct().sorted().toList();
        String sql = """
                SELECT account.id,account.currency_id,currency.is_base_currency,
                       currency.code,currency.name,account_style.id
                FROM accounts account
                JOIN currencies currency ON currency.id=account.currency_id
                JOIN payment_styles account_style ON account_style.id=account.style_id
                WHERE account.id IN (:ids)
                  AND account.status='使用' AND COALESCE(account.is_deleted,FALSE)=FALSE
                  AND currency.status='使用' AND COALESCE(currency.is_deleted,FALSE)=FALSE
                  AND account_style.category='ACCOUNT' AND account_style.status='使用'
                  AND COALESCE(account_style.is_deleted,FALSE)=FALSE
                  AND NOT EXISTS(SELECT 1 FROM payment_styles child
                                 WHERE child.parent_id=account_style.id
                                   AND COALESCE(child.is_deleted,FALSE)=FALSE)
                ORDER BY account.id
                """ + (lock ? " FOR UPDATE OF account" : "");
        @SuppressWarnings("unchecked")
        List<Object[]> rows = em.createNativeQuery(sql)
                .setParameter("ids", ids).getResultList();
        Map<UUID, AccountCurrencySnapshot> result = new HashMap<>();
        for (Object[] row : rows) {
            result.put((UUID) row[0], new AccountCurrencySnapshot(
                    (UUID) row[0], (UUID) row[1], Boolean.TRUE.equals(row[2]),
                    Objects.toString(row[3], ""), Objects.toString(row[4], ""),
                    (UUID)row[5]));
        }
        return result;
    }

    private String activeSupplierName(UUID supplierId, boolean lock) {
        String sql = """
                SELECT name FROM suppliers
                WHERE id=:id AND status='使用' AND COALESCE(is_deleted,FALSE)=FALSE
                """ + (lock ? " FOR SHARE" : "");
        @SuppressWarnings("unchecked")
        List<Object> rows = em.createNativeQuery(sql)
                .setParameter("id", supplierId).getResultList();
        if (rows.size() != 1 || rows.getFirst() == null
                || rows.getFirst().toString().isBlank()) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED,
                    "合作外贸公司不存在、已停用或名称缺失");
        }
        return rows.getFirst().toString();
    }

    private void applyReceiptMethod(FinanceReceiptSaveRequest req, FinanceReceipt receipt) {
        if (req.getReceiptMethodId() == null && req.getReceiptMethodLegacyId() == null
                && receipt.getLegacyId() != null && receipt.getReceiptMethodId() == null) {
            return; // imported RecStyle snapshot has no safe master mapping; keep it historical
        }
        var method = PaymentMethodReferenceResolver.resolve(
                em, req.getReceiptMethodId(), req.getReceiptMethodLegacyId(), "收款方式",
                PaymentMethodReferenceResolver.Direction.RECEIPT);
        receipt.setReceiptMethodId(method == null ? null : method.id());
        receipt.setReceiptMethodLegacyId(method == null ? null : method.legacyId());
    }

    private void applyOperator(UUID requestedId, FinanceReceipt receipt) {
        EmployeeReference operator = nameResolver.resolveForWrite(requestedId, null, null, "经手人");
        if (operator == null && receipt.getLegacyId() != null && receipt.getOperatorId() == null) {
            return; // preserve imported B_Worker snapshot when the current client has no field value
        }
        receipt.setOperatorId(operator == null ? null : operator.id());
        receipt.setOperatorLegacyId(operator == null ? null : operator.legacyId());
        receipt.setOperatorName(operator == null ? null : operator.name());
    }

    private void applyMakerIdentity(FinanceReceipt receipt) {
        if (receipt.getMakerId() == null) return;
        receipt.setMakerLegacyId(null); // Sys_Operator ids are not employees.legacy_id
        receipt.setMakerName(nameResolver.nameOf(receipt.getMakerId()));
    }

    private List<FinanceReceiptLineDto> saveLines(FinanceReceipt r, List<FinanceReceiptLineInput> inputs) {
        // 金额、汇率、人民币与汇兑差额全部由服务端按应收快照计算；客户端派生值不入账。
        if (inputs == null || inputs.isEmpty()) return List.of();
        List<FinanceReceiptLineDto> out = new ArrayList<>(inputs.size());
        int auto = 1;
        for (FinanceReceiptLineInput l : inputs) {
            ArApLedger ledger = l.getAppliedLedgerId() == null ? null : ledgerRepo.findById(l.getAppliedLedgerId())
                    .filter(item -> !item.isDeleted())
                    .orElseThrow(() -> new ApiException(ErrorCode.BUSINESS, "引用的应收记录不存在或已删除"));
            if (ledger != null && !"AR".equals(ledger.getDirection())) {
                throw new ApiException(ErrorCode.BUSINESS, "销售收款只能引用应收记录");
            }
            if (ledger != null && r.getClientId() != null
                    && !Objects.equals(r.getClientId(), ledger.getClientId())) {
                throw new ApiException(ErrorCode.CONFLICT, "收款客户与引用应收客户不一致");
            }
            UUID currencyId = l.getCurrencyId() != null
                    ? l.getCurrencyId()
                    : ledger != null ? ledger.getCurrencyId() : r.getCurrencyId();
            if (ledger != null && ledger.getCurrencyId() != null
                    && !Objects.equals(currencyId, ledger.getCurrencyId())) {
                throw new ApiException(ErrorCode.BUSINESS,
                        "核销原币必须与应收币种一致；美元应收可按本批实际到账汇率"
                                + "结汇进入人民币账户，不能以第三币种金额直接改写应收原币");
            }
            // 到账汇率是本次收款事实，必须由财务在 AR 核销行显式填写；
            // 禁止回退主表默认值、主表请求值或应收开账汇率。
            BigDecimal rate = positiveRate(l.getExchangeRate());
            BigDecimal cashOriginal = positiveMoney(l.getAmountOriginal(), "本次收款金额");
            BigDecimal writeOffOriginal = nonNegativeMoney(l.getWriteOffAmount(), "冲销金额");
            if (writeOffOriginal.signum() != 0) {
                throw new ApiException(ErrorCode.VALIDATION_FAILED,
                        "新收款不能把手续费、折让或坏账混入费用冲销；"
                                + "手续费请使用费用区，商业冲销请走专用调整流程");
            }
            BigDecimal cashLocal = money(cashOriginal.multiply(rate));
            BigDecimal writeOffLocal = money(writeOffOriginal.multiply(rate));
            BigDecimal recognitionRate = ledger == null
                    ? rate : positiveRate(ledger.getExchangeRate());
            BigDecimal appliedLocal = ledger==null
                    ? money(cashOriginal.add(writeOffOriginal).multiply(recognitionRate))
                    : sourceAllocation.plannedBookAmount(ledger,cashOriginal.add(writeOffOriginal));
            BigDecimal exchangeDiff = money(cashLocal.add(writeOffLocal).subtract(appliedLocal));
            FinanceReceiptLine ln = new FinanceReceiptLine();
            ln.setReceiptId(r.getId());
            ln.setBillNo(r.getBillNo());
            ln.setBillDate(r.getBillDate());
            ln.setLineNo(l.getLineNo() != null ? l.getLineNo() : auto);
            ln.setAppliedLedgerId(l.getAppliedLedgerId());
            ln.setAppliedBillNo(trimToNull(l.getAppliedBillNo()));
            ln.setClientId(l.getClientId() != null ? l.getClientId() : r.getClientId());
            ln.setCurrencyId(currencyId);
            ln.setExchangeRate(rate);
            ln.setAmountOriginal(cashOriginal);
            ln.setAmountLocal(cashLocal);
            ln.setWriteOffAmount(writeOffOriginal);
            ln.setWriteOffLocal(writeOffLocal);
            ln.setAppliedAmountLocal(appliedLocal);
            ln.setExchangeDiff(exchangeDiff);
            ln.setRemark(trimToNull(l.getRemark()));
            lineRepo.save(ln);
            out.add(toLineDto(ln));
            auto++;
        }
        return out;
    }

    private void assertBillNoFree(String billNo, UUID excludeId) {
        if (billNo == null || billNo.isBlank()) return;
        receiptRepo.findByBillNo(billNo).ifPresent(existing -> {
            if (excludeId == null || !existing.getId().equals(excludeId)) {
                throw new ApiException(ErrorCode.CONFLICT, "单号已存在：" + billNo);
            }
        });
    }

    private FinanceReceiptLineDto toLineDto(FinanceReceiptLine ln) {
        return new FinanceReceiptLineDto(ln.getId(), ln.getLineNo(), ln.getAppliedLedgerId(),
                ln.getAppliedBillNo(), ln.getClientId(), ln.getCurrencyId(), ln.getExchangeRate(),
                ln.getAmountOriginal(), ln.getAmountLocal(), ln.getWriteOffAmount(), ln.getWriteOffLocal(),
                ln.getAppliedAmountLocal(), ln.getBalanceBeforeOriginal(), ln.getBalanceAfterOriginal(),
                ln.getExchangeDiff(), ln.getRemark());
    }

    private FinanceReceiptListItem toList(FinanceReceipt r) {
        return new FinanceReceiptListItem(r.getId(), r.getBillNo(), r.getBillDate(),
                r.getReceiptKind(), r.getSalesOrderId(), r.getClientId(), r.getAccountId(),
                r.getAmountLocal(), r.getStatus(), r.getLegacyId());
    }

    private FinanceReceiptDetail toDetail(FinanceReceipt r, List<FinanceReceiptLineDto> items) {
        return new FinanceReceiptDetail(r.getId(), r.getLegacyId(), r.getBillNo(), r.getBillDate(),
                r.getReceiptKind(), r.getSalesOrderId(), r.getClientId(), r.getAccountId(), r.getCounterpartAccountId(), r.getCurrencyId(),
                r.getExchangeRate(), r.getAmountOriginal(), r.getAmountLocal(), r.getBankFee(), r.getOtherFee(),
                r.getOtherFeeStyleId(), r.getReceiptMethodId(), r.getReceiptMethodLegacyId(), r.getInvoiceNo(),
                r.getCancelDate(), r.getOperatorId(), r.getMakerId(), r.getApproverId(),
                r.getSourceRemark(), r.getRemark(), r.getStatus(), r.isClosed(), items,
                nameResolver.nameOf(r.getMakerId()), r.getCreatedAt(),
                r.getVersion()==null?0L:r.getVersion(),
                r.getSettlementAuthorityVersion(),
                r.getCreateIdempotencyKey(), r.getSettlementChannel(),
                r.getSettlementAgentSupplierId(), r.getSettlementAgentNameSnapshot(),
                r.getSettlementRateQuoteDirection(), r.getExchangeRateSource(),
                r.getExchangeRateEffectiveAt(), r.getBankBookedAt(),
                r.getBankReference(), r.getAgentStatementNo(),
                r.getAccountCurrencyId(), r.getAccountExchangeRate(),
                r.getAccountExchangeRateSource(), r.getAccountAmount(),
                r.getAccountAmountLocal(), r.getAmountLocal(),
                r.getBankFeeAccountAmount(), r.getOtherFeeAccountAmount(),
                r.getFeeSettlementMode(), r.getFeeBearer(), r.getFeePaymentAccountId(),
                r.getFeeAccountCurrencyId(), r.getFeeAccountExchangeRate());
    }

    private FinanceReceipt require(UUID id) {
        return receiptRepo.findById(id).filter(r -> !r.isDeleted())
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "销售收款单不存在"));
    }

    private FinanceReceipt lockActive(UUID id) {
        FinanceReceipt receipt = require(id);
        em.refresh(receipt, jakarta.persistence.LockModeType.PESSIMISTIC_WRITE);
        if (receipt.isDeleted()) {
            throw new ApiException(ErrorCode.NOT_FOUND, "销售收款单不存在");
        }
        return receipt;
    }

    private String normalizeIdempotencyKey(String raw) {
        String value = trimToNull(raw);
        if (value == null || value.length() < 8 || value.length() > 128
                || !value.matches("[A-Za-z0-9._:-]+")) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED,
                    "收款创建幂等键格式不正确");
        }
        return value;
    }

    private void lockCreateIdempotency(UUID makerId, String key) {
        em.createNativeQuery(
                        "SELECT pg_advisory_xact_lock(hashtextextended(:key,0))")
                .setParameter("key", "FIN_RECEIPT_CREATE|" + makerId + "|" + key)
                .getSingleResult();
    }

    private FinanceReceipt findCreateReplay(UUID makerId, String key) {
        @SuppressWarnings("unchecked")
        List<Object> ids = em.createNativeQuery("""
                        SELECT id FROM finance_receipts
                        WHERE maker_id=:maker AND create_idempotency_key=:key
                        """)
                .setParameter("maker", makerId)
                .setParameter("key", key)
                .getResultList();
        if (ids.isEmpty()) return null;
        if (ids.size() != 1) {
            throw new ApiException(ErrorCode.CONFLICT,
                    "收款创建幂等键存在重复历史，请先完成数据核对");
        }
        FinanceReceipt receipt = receiptRepo.findById((UUID) ids.getFirst())
                .orElseThrow(() -> new ApiException(
                        ErrorCode.CONFLICT, "收款幂等记录缺少来源单据"));
        if (receipt.isDeleted()) {
            throw new ApiException(ErrorCode.CONFLICT,
                    "该收款创建请求曾生成后删除，不能用同一幂等键重新造单");
        }
        access.requireReadable(receipt.getMakerId(), "销售收款单不存在");
        return receipt;
    }

    private static String requestHash(FinanceReceiptSaveRequest request) {
        StringBuilder value = new StringBuilder();
        appendHash(value, request.getBillDate());
        appendHash(value, upper(request.getReceiptKind()));
        appendHash(value, request.getSalesOrderId());
        appendHash(value, request.getClientId());
        appendHash(value, request.getAccountId());
        appendHash(value, request.getCounterpartAccountId());
        appendHash(value, request.getCurrencyId());
        appendHash(value, decimalText(request.getExchangeRate()));
        appendHash(value, decimalText(request.getAmountOriginal()));
        appendHash(value, upper(request.getSettlementChannel()));
        appendHash(value, request.getSettlementAgentSupplierId());
        appendHash(value, upper(request.getExchangeRateSource()));
        appendHash(value, request.getExchangeRateEffectiveAt());
        appendHash(value, request.getBankBookedAt());
        appendHash(value, trimToNull(request.getBankReference()));
        appendHash(value, trimToNull(request.getAgentStatementNo()));
        BigDecimal effectiveBankFee=request.getBankFeeAccountAmount()!=null
                ?request.getBankFeeAccountAmount():request.getBankFee();
        BigDecimal effectiveOtherFee=request.getOtherFeeAccountAmount()!=null
                ?request.getOtherFeeAccountAmount():request.getOtherFee();
        appendHash(value, decimalText(effectiveBankFee));
        appendHash(value, decimalText(effectiveOtherFee));
        boolean hasFees=nz(effectiveBankFee).add(nz(effectiveOtherFee)).signum()!=0;
        appendHash(value, hasFees?upper(request.getFeeSettlementMode()):FEE_NONE);
        appendHash(value, hasFees?upper(request.getFeeBearer()):FEE_BEARER_NONE);
        appendHash(value, request.getFeePaymentAccountId());
        appendHash(value, request.getOtherFeeStyleId());
        appendHash(value, request.getReceiptMethodId());
        appendHash(value, request.getReceiptMethodLegacyId());
        appendHash(value, request.getInvoiceNo());
        appendHash(value, request.getOperatorId());
        appendHash(value, request.getSourceRemark());
        appendHash(value, request.getRemark());
        List<FinanceReceiptLineInput> items =
                request.getItems() == null ? List.of() : request.getItems();
        appendHash(value, items.size());
        for (FinanceReceiptLineInput item : items) {
            appendHash(value, item == null ? null : item.getLineNo());
            appendHash(value, item == null ? null : item.getAppliedLedgerId());
            appendHash(value, item == null ? null : item.getAppliedBillNo());
            appendHash(value, item == null ? null : item.getClientId());
            appendHash(value, item == null ? null : item.getCurrencyId());
            appendHash(value, item == null ? null : decimalText(item.getExchangeRate()));
            appendHash(value, item == null ? null : decimalText(item.getAmountOriginal()));
            appendHash(value, item == null ? null : decimalText(item.getWriteOffAmount()));
            appendHash(value, item == null ? null : item.getRemark());
        }
        try {
            byte[] digest = MessageDigest.getInstance("SHA-256")
                    .digest(value.toString().getBytes(StandardCharsets.UTF_8));
            return HexFormat.of().formatHex(digest);
        } catch (NoSuchAlgorithmException impossible) {
            throw new IllegalStateException("SHA-256 unavailable", impossible);
        }
    }

    private static void appendHash(StringBuilder target, Object value) {
        String text = value == null ? "" : value.toString().trim();
        target.append(text.length()).append(':').append(text).append('|');
    }

    private static String decimalText(BigDecimal value) {
        return value == null ? null : value.stripTrailingZeros().toPlainString();
    }

    private static String upper(String value) {
        String trimmed = trimToNull(value);
        return trimmed == null ? null : trimmed.toUpperCase(java.util.Locale.ROOT);
    }

    private static String trimToNull(String value) {
        if (value == null) return null;
        String trimmed = value.trim();
        return trimmed.isEmpty() ? null : trimmed;
    }

    private record AccountCurrencySnapshot(
            UUID accountId,
            UUID currencyId,
            boolean baseCurrency,
            String currencyCode,
            String currencyName,
            UUID styleId) {}

    private static BigDecimal positiveRate(BigDecimal value) {
        if (value == null || value.signum() <= 0) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "收款汇率必须大于 0");
        }
        return com.uten.imp.common.util.FinancialExactAmount.rate(value,"收款汇率");
    }

    private static BigDecimal positiveMoney(BigDecimal value, String label) {
        if (value == null || value.signum() <= 0) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, label + "必须大于 0");
        }
        return money(com.uten.imp.common.util.FinancialExactAmount.require(value,label));
    }

    private static BigDecimal nonNegativeMoney(BigDecimal value, String label) {
        BigDecimal normalized = com.uten.imp.common.util.FinancialExactAmount.require(nz(value),label);
        if (normalized.signum() < 0) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, label + "不能为负数");
        }
        return normalized;
    }

    private static BigDecimal money(BigDecimal value) {
        return com.uten.imp.common.util.FinancialExactAmount.canonicalMoney(nz(value),"收款账面金额");
    }

    private static BigDecimal nz(BigDecimal x) {
        return x == null ? BigDecimal.ZERO : x;
    }
}
