package com.uten.imp.features.finance.receipt;

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
import com.uten.imp.features.finance.arap.ArApLedger;
import com.uten.imp.features.finance.arap.ArApLedgerRepository;
import com.uten.imp.features.finance.arap.ArApLedgerService;
import com.uten.imp.features.finance.gl.GlPostingService;
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
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.math.RoundingMode;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Objects;
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
 *   <li>账户 {@code accounts.balance_current += amount_local, receipts_total += amount_local}。</li>
 *   <li>INSERT finance_reconciliations(source_doc_type=RECEIPT, in_amount=amount_local)。</li>
 * </ul>
 *
 * <p>红冲（1→-1）反向：回减核销 / 删 DIRECT_RECEIPT 行 / 回滚账户 / 删流水。
 */
@Service
@RequiredArgsConstructor
public class FinanceReceiptService {

    private static final short STATUS_DRAFT = 0;
    private static final short STATUS_APPROVED = 1;
    private static final short STATUS_REVERSED = -1;
    private static final int MONEY_SCALE = 4;
    private static final int RATE_SCALE = 6;

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

    @Transactional(readOnly = true)
    public PageResponse<FinanceReceiptListItem> list(FinanceReceiptQueryFilter f, int page, int size, String sort, String order) {
        var readScope = access.scope();
        Specification<FinanceReceipt> spec = (Root<FinanceReceipt> root, jakarta.persistence.criteria.CriteriaQuery<?> q,
                                              CriteriaBuilder cb) -> {
            List<Predicate> ps = new ArrayList<>();
            ps.add(cb.isFalse(root.get("deleted")));
            ps.add(access.readablePredicate(root, cb, "makerId", readScope));
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
        return new PageResponse<>(p.map(this::toList).getContent(), page, size, p.getTotalElements(), p.getTotalPages());
    }

    @Transactional(readOnly = true)
    public FinanceReceiptDetail detail(UUID id) {
        FinanceReceipt r = require(id);
        access.requireReadable(r.getMakerId(), "销售收款单不存在");
        List<FinanceReceiptLineDto> items = lineRepo.findByReceiptIdOrderByLineNoAsc(id).stream()
                .map(this::toLineDto).toList();
        return toDetail(r, items);
    }

    @Transactional
    public FinanceReceiptDetail create(FinanceReceiptSaveRequest req) {
        tx.bind();
        if (req.getOtherFeeStyleId() != null
                || req.getReceiptMethodId() != null
                || req.getReceiptMethodLegacyId() != null) {
            PaymentStyleHierarchyLock.lock(em);
        }
        assertBillNoFree(req.getBillNo(), null);
        FinanceReceipt r = new FinanceReceipt();
        applyHeader(req, r);
        r.setStatus(STATUS_DRAFT);
        r.setMakerId(currentUser.requireEmployeeId());   // 制单=当前登录用户（报表按 maker_id 解析制单员）
        applyMakerIdentity(r);
        receiptRepo.save(r);
        List<FinanceReceiptLineDto> items = saveLines(r, req.getItems());
        applyLineTotals(r, items);
        return toDetail(r, items);
    }

    @Transactional
    public FinanceReceiptDetail update(UUID id, FinanceReceiptSaveRequest req) {
        tx.bind();
        if (req.getOtherFeeStyleId() != null
                || req.getReceiptMethodId() != null
                || req.getReceiptMethodLegacyId() != null) {
            PaymentStyleHierarchyLock.lock(em);
        }
        FinanceReceipt r = lockActive(id);
        access.requireWritable(r.getMakerId(), "只能操作本人负责或已授权的销售收款单");
        if (r.getStatus() != STATUS_DRAFT) {
            throw new ApiException(ErrorCode.BUSINESS, "仅草稿单据可编辑");
        }
        assertBillNoFree(req.getBillNo(), id);
        applyHeader(req, r);
        applyMakerIdentity(r);
        lineRepo.deleteByReceiptId(id);
        lineRepo.flush();
        List<FinanceReceiptLineDto> items = saveLines(r, req.getItems());
        applyLineTotals(r, items);
        return toDetail(r, items);
    }

    @Transactional
    public void delete(UUID id) {
        tx.bind();
        FinanceReceipt r = lockActive(id);
        access.requireWritable(r.getMakerId(), "只能操作本人负责或已授权的销售收款单");
        if (r.getStatus() == null || r.getStatus() != STATUS_DRAFT) {
            throw new ApiException(ErrorCode.BUSINESS, "仅草稿单据可删除；已审核单据请红冲");
        }
        r.setDeleted(true);
        r.setDeletedAt(OffsetDateTime.now());
        receiptRepo.save(r);
    }

    /** 审核：status 0→1，核销 AR / 直接收款 / 账户累加 / 写流水。 */
    @Transactional
    public FinanceReceiptDetail approve(UUID id) {
        tx.bind();
        // 审核会校验并消费 other_fee_style_id。先取类别锁，再取单据行锁，
        // 与草稿编辑保持固定锁顺序，避免并发停用/增加子类造成 TOCTOU。
        PaymentStyleHierarchyLock.lock(em);
        FinanceReceipt r = lockActive(id);
        access.requireWritable(r.getMakerId(), "只能操作本人负责或已授权的销售收款单");
        if (r.getStatus() == null || r.getStatus() != STATUS_DRAFT) {
            throw new ApiException(ErrorCode.BUSINESS, "仅草稿单据可审核");
        }
        if (r.getAccountId() == null) {
            throw new ApiException(ErrorCode.BUSINESS, "收款单需指定收款账户");
        }
        if (r.getClientId() == null) {
            throw new ApiException(ErrorCode.BUSINESS, "收款单需指定客户");
        }
        assertNoExistingPosting(r.getId()); // M19：幂等护栏，finance_reconciliations 已存在该单流水则禁止重复审核
        UUID approver = currentUser.requireEmployeeId(); // 审核=当前登录用户（报表按 approver_id 解析审核员）
        if (r.getMakerId() != null && r.getMakerId().equals(approver)) {
            throw new ApiException(ErrorCode.BUSINESS, "制单人与审核人不可相同（职责分离）");
        }
        glPosting.lockAutoProjectionPeriod(r.getBillDate());
        r.setApproverId(approver);
        r.setApproverLegacyId(null);
        r.setApproverName(nameResolver.nameOf(approver));
        settleReceipt(r);
        r.setStatus(STATUS_APPROVED);
        r.setCancelDate(OffsetDateTime.now());
        receiptRepo.save(r);
        return detail(id);
    }

    /** 红冲：status 1→-1，反向冲销（回减核销 / 删 DIRECT_RECEIPT 行 / 回滚账户 / 删流水）。 */
    @Transactional
    public FinanceReceiptDetail reverse(UUID id) {
        tx.bind();
        FinanceReceipt r = lockActive(id);
        access.requireWritable(r.getMakerId(), "只能操作本人负责或已授权的销售收款单");
        if (r.getStatus() == null || r.getStatus() != STATUS_APPROVED) {
            throw new ApiException(ErrorCode.BUSINESS, "仅已审核单据可红冲");
        }
        assertCompletePosting(r.getId(), 1L); // M19：红冲前确认流水完整（收款每单恰 1 行）
        glPosting.removeAutoProjection(RECON_SOURCE, r.getId(), r.getBillNo(), r.getBillDate());
        reverseSettlement(r);
        r.setStatus(STATUS_REVERSED);
        receiptRepo.save(r);
        return detail(id);
    }

    // ===================== 核销逻辑 =====================

    /** 审核核销：lines 非空 → 累加 AR 核销；lines 空 → postArAp 建 DIRECT_RECEIPT 行。 */
    private void settleReceipt(FinanceReceipt r) {
        List<FinanceReceiptLine> lines = lineRepo.findByReceiptIdOrderByLineNoAsc(r.getId());
        Map<UUID, ArApLedger> lockedLedgers = lines.isEmpty()
                ? Map.of()
                : lockAppliedLedgers(lines);
        if (!lines.isEmpty()) {
            applyLineTotals(r, lines.stream().map(this::toLineDto).toList());
        }
        BigDecimal amountLocal = nz(r.getAmountLocal());
        if (!lines.isEmpty()) {
            settleAppliedLines(r, lines, lockedLedgers);
            amountLocal = nz(r.getAmountLocal());
            BigDecimal accountAmount = adjustAccount(
                    r.getAccountId(), r.getCurrencyId(), nz(r.getAmountOriginal()), amountLocal);
            insertReconciliation(r, accountAmount);
            return;
        }
        if (r.getCurrencyId() == null) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "直接预收款必须指定币别");
        }
        BigDecimal directRate = positiveRate(r.getExchangeRate());
        BigDecimal directOriginal = positiveMoney(r.getAmountOriginal(), "直接收款原币金额");
        amountLocal = money(directOriginal.multiply(directRate));
        r.setExchangeRate(directRate);
        r.setAmountOriginal(directOriginal);
        r.setAmountLocal(amountLocal);
        if (nz(r.getBankFee()).signum() != 0 || nz(r.getOtherFee()).signum() != 0) {
            throw new ApiException(ErrorCode.BUSINESS, "客户预收款暂不支持费用冲销；费用必须分配到引用的应收明细");
        }
        // 直接收款 / 客户预付：建 DIRECT_RECEIPT 立帐行（amount=0），再置到账和负应收余额。
        arApService.postArAp(new ArApLedgerService.ArApPostingRequest(
                "AR", SRC_DIRECT_RECEIPT, r.getId(), r.getBillNo(), r.getBillDate(),
                r.getClientId(), null, r.getCurrencyId(), r.getExchangeRate(),
                BigDecimal.ZERO, (short) 20, "直接收款"));
        List<ArApLedger> created = ledgerRepo.findBySourceForUpdate(
                r.getId(), SRC_DIRECT_RECEIPT);
        if (created.size() != 1) {
            throw new ApiException(ErrorCode.CONFLICT, "直接收款立账结果不唯一");
        }
        ArApLedger led = created.getFirst();
        led.setAmountReceivedOriginal(money(nz(r.getAmountOriginal())));
        led.setAmountReceivedLocal(money(amountLocal));
        led.setAmountWriteOffOriginal(BigDecimal.ZERO.setScale(MONEY_SCALE));
        led.setAmountWriteOffLocal(BigDecimal.ZERO.setScale(MONEY_SCALE));
        led.setAmountBalanceOriginal(money(nz(r.getAmountOriginal()).negate()));
        led.setAmountSettled(amountLocal);
        led.setAmountBalance(nz(led.getAmountOriginalLocal()).subtract(amountLocal));
        refreshSettlement(led, r.getBillDate());
        ledgerRepo.save(led);
        // 账户累加 + 写流水
        BigDecimal accountAmount = adjustAccount(
                r.getAccountId(), r.getCurrencyId(), nz(r.getAmountOriginal()), amountLocal);
        insertReconciliation(r, accountAmount);
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
                        "跨币种核销需要双币金额与双汇率；当前收款明细只能使用应收币别");
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
            BigDecimal cashLocal = money(cashOriginal.multiply(receiptRate));
            BigDecimal writeOffLocal = money(writeOffOriginal.multiply(receiptRate));
            BigDecimal originalLocal = nz(ledger.getAmountOriginalLocal());
            BigDecimal oldSettledLocal = nz(ledger.getAmountSettled());
            BigDecimal newSettledLocal = oldSettledLocal
                    .add(money(appliedOriginal.multiply(recognitionRate)));
            if (afterOriginal.signum() == 0) {
                newSettledLocal = originalLocal;
            }
            BigDecimal appliedLocal = money(newSettledLocal.subtract(oldSettledLocal));
            BigDecimal exchangeDiff = money(cashLocal.add(writeOffLocal).subtract(appliedLocal));

            line.setAmountLocal(cashLocal);
            line.setWriteOffLocal(writeOffLocal);
            line.setAppliedAmountLocal(appliedLocal);
            line.setExchangeDiff(exchangeDiff);
            line.setBalanceBeforeOriginal(beforeOriginal);
            line.setBalanceAfterOriginal(afterOriginal);
            lineRepo.save(line);

            ledger.setAmountReceivedOriginal(money(nz(ledger.getAmountReceivedOriginal()).add(cashOriginal)));
            ledger.setAmountReceivedLocal(money(nz(ledger.getAmountReceivedLocal()).add(cashLocal)));
            ledger.setAmountWriteOffOriginal(money(nz(ledger.getAmountWriteOffOriginal()).add(writeOffOriginal)));
            ledger.setAmountWriteOffLocal(money(nz(ledger.getAmountWriteOffLocal()).add(writeOffLocal)));
            ledger.setAmountBalanceOriginal(afterOriginal);
            ledger.setAmountSettled(money(newSettledLocal));
            ledger.setAmountBalance(money(originalLocal.subtract(newSettledLocal)));
            refreshSettlement(ledger, receipt.getBillDate());
            ledgerRepo.save(ledger);

            cashOriginalTotal = cashOriginalTotal.add(cashOriginal);
            cashLocalTotal = cashLocalTotal.add(cashLocal);
            writeOffLocalTotal = writeOffLocalTotal.add(writeOffLocal);
        }

        BigDecimal headerFees = money(nonNegativeMoney(receipt.getBankFee(), "手续费")
                .add(nonNegativeMoney(receipt.getOtherFee(), "其它费用")));
        if (nz(receipt.getOtherFee()).signum() > 0 && receipt.getOtherFeeStyleId() == null) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "填写其它费用时必须选择费用项目");
        }
        if (nz(receipt.getOtherFee()).signum() > 0) {
            assertExpenseStyleActive(receipt.getOtherFeeStyleId());
        }
        if (money(writeOffLocalTotal).compareTo(headerFees) != 0) {
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
            reverseAppliedLines(r, lines, lockAppliedLedgers(lines));
            adjustAccount(r.getAccountId(), r.getCurrencyId(),
                    nz(r.getAmountOriginal()).negate(), amountLocal.negate());
            deleteReconciliation(r.getId());
            return;
        }
        // 直接收款红冲：删本单建的直接收款立帐行（不经 reverseArAp，因其 amount_settled<>0 会被拦）
        List<ArApLedger> rows = ledgerRepo.findBySourceForUpdate(r.getId(), SRC_DIRECT_RECEIPT);
        if (rows.size() != 1) {
            throw new ApiException(ErrorCode.CONFLICT, "直接收款反立账来源缺失或重复");
        }
        for (ArApLedger led : rows) {
            ledgerRepo.delete(led);
        }
        if (amountLocal.signum() != 0) {
            adjustAccount(r.getAccountId(), r.getCurrencyId(),
                    nz(r.getAmountOriginal()).negate(), amountLocal.negate());
        }
        deleteReconciliation(r.getId());
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
            ledger.setAmountBalanceOriginal(money(nz(ledger.getAmountOriginal())
                    .subtract(newReceivedOriginal).subtract(newWriteOffOriginal)));
            ledger.setAmountSettled(newSettledLocal);
            ledger.setAmountBalance(money(nz(ledger.getAmountOriginalLocal()).subtract(newSettledLocal)));
            refreshSettlement(ledger, receipt.getBillDate());
            ledgerRepo.save(ledger);
        }
    }

    /**
     * 自动结清维护（对齐 数据库约束）：仅 balance = 0 时
     * {@code is_settled=true}。DIRECT_RECEIPT 的负余额表示仍可使用的客户预收款，
     * 必须保持未结清，不能混同为普通应收已核销。
     */
    private void refreshSettlement(ArApLedger led, LocalDate settlementDate) {
        BigDecimal bal = nz(led.getAmountBalance());
        boolean settled = bal.signum() == 0;
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
    private BigDecimal adjustAccount(
            UUID accountId,
            UUID receiptCurrencyId,
            BigDecimal originalDelta,
            BigDecimal localDelta) {
        @SuppressWarnings("unchecked")
        List<Object[]> rows = em.createNativeQuery("""
                        SELECT account.currency_id, currency.code, currency.name
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
        if (accountCurrencyId != null && currencyCode == null && currencyName == null) {
            throw new ApiException(ErrorCode.BUSINESS, "收款账户币种不存在或已停用");
        }
        boolean baseCurrency = accountCurrencyId == null
                || "CNY".equalsIgnoreCase(currencyCode)
                || "人民币".equals(currencyName == null ? null : currencyName.trim());
        BigDecimal accountDelta;
        if (baseCurrency) {
            accountDelta = money(localDelta);
        } else if (Objects.equals(accountCurrencyId, receiptCurrencyId)) {
            accountDelta = money(originalDelta);
        } else {
            throw new ApiException(ErrorCode.BUSINESS,
                    "收款账户币别与本次到账币别不兼容：" + accountId);
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

    private void deleteReconciliation(UUID receiptId) {
        em.createNativeQuery(
                "DELETE FROM finance_reconciliations WHERE source_doc_id = :sid AND source_doc_type = :src")
                .setParameter("sid", receiptId)
                .setParameter("src", RECON_SOURCE)
                .executeUpdate();
    }

    private void assertNoExistingPosting(UUID receiptId) {
        if (postingCount(receiptId) != 0) {
            throw new ApiException(ErrorCode.CONFLICT, "该单据已存在账户流水，禁止重复审核");
        }
    }

    private void assertCompletePosting(UUID receiptId, long expectedRows) {
        long actual = postingCount(receiptId);
        if (actual != expectedRows) {
            throw new ApiException(ErrorCode.CONFLICT,
                    "收款流水不完整，禁止红冲（期望 " + expectedRows + "，实际 " + actual + "）");
        }
    }

    private long postingCount(UUID receiptId) {
        return ((Number) em.createNativeQuery("""
                        SELECT COUNT(*)
                        FROM finance_reconciliations
                        WHERE source_doc_type = :src
                          AND source_doc_id = :id
                          AND COALESCE(is_deleted, false) = false
                        """)
                .setParameter("src", RECON_SOURCE)
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

    private void applyHeader(FinanceReceiptSaveRequest req, FinanceReceipt r) {
        // 单据号系统自动生成（服务端权威）：仅新建（billNo 空）时取号；更新保留既有号，忽略客户端值。
        if (r.getBillNo() == null || r.getBillNo().isBlank()) {
            r.setBillNo(docNumberService.nextNumber(DocNumberPrefix.FIN_RECEIPT));
        }
        r.setBillDate(req.getBillDate());
        r.setClientId(req.getClientId());
        r.setAccountId(req.getAccountId());
        r.setCounterpartAccountId(req.getCounterpartAccountId());
        r.setCurrencyId(req.getCurrencyId());
        // null 必须清掉实体默认值/旧草稿值；直收与预收也只能使用财务显式填写的到账汇率。
        r.setExchangeRate(req.getExchangeRate());
        r.setAmountOriginal(req.getAmountOriginal());
        // 金额服务端权威重算（4 位 HALF_UP）：本币额 = 原币额 × 汇率，忽略客户端 amountLocal，
        // 防止篡改本币额进而影响 AR 核销与账户增减（与 M1 银行转账服务端权威同型）。
        java.math.BigDecimal rate = r.getExchangeRate();
        r.setAmountLocal(req.getAmountOriginal() == null || rate == null
                ? null
                : req.getAmountOriginal().multiply(rate)
                        .setScale(4, java.math.RoundingMode.HALF_UP));
        if (req.getBankFee() != null) r.setBankFee(req.getBankFee());
        if (req.getOtherFee() != null) r.setOtherFee(req.getOtherFee());
        r.setOtherFeeStyleId(req.getOtherFeeStyleId());
        applyReceiptMethod(req, r);
        r.setInvoiceNo(req.getInvoiceNo());
        applyOperator(req.getOperatorId(), r);
        r.setSourceRemark(req.getSourceRemark());
        r.setRemark(req.getRemark());
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
                        "跨币种核销需要同时记录到账币种和应收币种金额；当前收款明细只能使用应收币别");
            }
            // 到账汇率是本次收款事实，必须由财务在 AR 核销行显式填写；
            // 禁止回退主表默认值、主表请求值或应收开账汇率。
            BigDecimal rate = positiveRate(l.getExchangeRate());
            BigDecimal cashOriginal = positiveMoney(l.getAmountOriginal(), "本次收款金额");
            BigDecimal writeOffOriginal = nonNegativeMoney(l.getWriteOffAmount(), "冲销金额");
            BigDecimal cashLocal = money(cashOriginal.multiply(rate));
            BigDecimal writeOffLocal = money(writeOffOriginal.multiply(rate));
            BigDecimal recognitionRate = ledger == null
                    ? rate : positiveRate(ledger.getExchangeRate());
            BigDecimal appliedLocal = money(cashOriginal.add(writeOffOriginal).multiply(recognitionRate));
            BigDecimal exchangeDiff = money(cashLocal.add(writeOffLocal).subtract(appliedLocal));
            FinanceReceiptLine ln = new FinanceReceiptLine();
            ln.setReceiptId(r.getId());
            ln.setBillNo(r.getBillNo());
            ln.setBillDate(r.getBillDate());
            ln.setLineNo(l.getLineNo() != null ? l.getLineNo() : auto);
            ln.setAppliedLedgerId(l.getAppliedLedgerId());
            ln.setAppliedBillNo(l.getAppliedBillNo());
            ln.setClientId(l.getClientId() != null ? l.getClientId() : r.getClientId());
            ln.setCurrencyId(currencyId);
            ln.setExchangeRate(rate);
            ln.setAmountOriginal(cashOriginal);
            ln.setAmountLocal(cashLocal);
            ln.setWriteOffAmount(writeOffOriginal);
            ln.setWriteOffLocal(writeOffLocal);
            ln.setAppliedAmountLocal(appliedLocal);
            ln.setExchangeDiff(exchangeDiff);
            ln.setRemark(l.getRemark());
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
                r.getClientId(), r.getAccountId(), r.getAmountLocal(), r.getStatus(), r.getLegacyId());
    }

    private FinanceReceiptDetail toDetail(FinanceReceipt r, List<FinanceReceiptLineDto> items) {
        return new FinanceReceiptDetail(r.getId(), r.getLegacyId(), r.getBillNo(), r.getBillDate(),
                r.getClientId(), r.getAccountId(), r.getCounterpartAccountId(), r.getCurrencyId(),
                r.getExchangeRate(), r.getAmountOriginal(), r.getAmountLocal(), r.getBankFee(), r.getOtherFee(),
                r.getOtherFeeStyleId(), r.getReceiptMethodId(), r.getReceiptMethodLegacyId(), r.getInvoiceNo(),
                r.getCancelDate(), r.getOperatorId(), r.getMakerId(), r.getApproverId(),
                r.getSourceRemark(), r.getRemark(), r.getStatus(), r.isClosed(), items,
                nameResolver.nameOf(r.getMakerId()), r.getCreatedAt());
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

    private static BigDecimal positiveRate(BigDecimal value) {
        if (value == null || value.signum() <= 0) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "收款汇率必须大于 0");
        }
        return value.setScale(RATE_SCALE, RoundingMode.HALF_UP);
    }

    private static BigDecimal positiveMoney(BigDecimal value, String label) {
        if (value == null || value.signum() <= 0) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, label + "必须大于 0");
        }
        return money(value);
    }

    private static BigDecimal nonNegativeMoney(BigDecimal value, String label) {
        BigDecimal normalized = money(nz(value));
        if (normalized.signum() < 0) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, label + "不能为负数");
        }
        return normalized;
    }

    private static BigDecimal money(BigDecimal value) {
        return nz(value).setScale(MONEY_SCALE, RoundingMode.HALF_UP);
    }

    private static BigDecimal nz(BigDecimal x) {
        return x == null ? BigDecimal.ZERO : x;
    }
}
