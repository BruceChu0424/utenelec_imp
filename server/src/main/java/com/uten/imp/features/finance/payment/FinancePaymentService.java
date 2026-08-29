package com.uten.imp.features.finance.payment;

import com.uten.imp.common.time.BusinessTime;
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
import com.uten.imp.features.finance.payables.SupplierClosedPeriodGuard;
import com.uten.imp.features.finance.arap.ArApLedger;
import com.uten.imp.features.finance.arap.ArApLedgerRepository;
import com.uten.imp.features.finance.payment.dto.FinancePaymentDetail;
import com.uten.imp.features.finance.payment.dto.FinancePaymentLineDto;
import com.uten.imp.features.finance.payment.dto.FinancePaymentLineInput;
import com.uten.imp.features.finance.payment.dto.FinancePaymentListItem;
import com.uten.imp.features.finance.payment.dto.FinancePaymentQueryFilter;
import com.uten.imp.features.finance.payment.dto.FinancePaymentSaveRequest;
import com.uten.imp.features.finance.gl.GlPostingService;
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
import java.math.RoundingMode;
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
import java.util.UUID;

/**
 * 采购付款单服务：CRUD（主 + 明细）+ 审核状态机（核销 AP / 账户扣减 / 写流水）。
 *
 * <p>与 {@code FinanceReceiptService} 对称（Client↔Vend、receipt↔payment、AR↔AP）。
 *
 * <p>账户累加方向相反：付款 money-out，{@code balance_current -= amount_local}，{@code payments_total += amount_local}。
 * finance_reconciliations.source_doc_type='PAYMENT'，{@code out_amount=amount_local}。
 */
@Service
@RequiredArgsConstructor
public class FinancePaymentService {

    private static final short STATUS_DRAFT = 0;
    private static final short STATUS_APPROVED = 1;
    private static final short STATUS_REVERSED = -1;
    private static final int MONEY_SCALE = 4;
    private static final int RATE_SCALE = 6;
    private static final short AMOUNT_AUTHORITY_VERSION = 1;

    /** 列排序白名单：前端列 key → JPA 实体属性名（日期/金额可排序；命中才排序，否则默认 billDate DESC）。 */
    private static final Map<String, String> ALLOWED_SORT = Map.of("billDate", "billDate", "amountLocal", "amountLocal");

    private final SupplierClosedPeriodGuard closedPeriodGuard;
    public static final String SRC_DIRECT_PAYMENT = "DIRECT_PAYMENT";
    public static final String RECON_SOURCE = "PAYMENT";

    private final FinancePaymentRepository paymentRepo;
    private final FinancePaymentLineRepository lineRepo;
    private final ArApLedgerRepository ledgerRepo;
    private final TxSessionVars tx;
    private final SecurityContextCurrentUser currentUser;
    private final com.uten.imp.common.util.EmployeeNameResolver nameResolver;
    private final EntityManager em;
    private final DocNumberService docNumberService;
    private final FinanceDocumentAccessPolicy access;
    private final GlPostingService glPostingService;
    private final AccountFlowLedgerService accountFlowLedger;

    @Transactional(readOnly = true)
    public PageResponse<FinancePaymentListItem> list(FinancePaymentQueryFilter f, int page, int size, String sort, String order) {
        var readScope = access.scope();
        Specification<FinancePayment> spec = (Root<FinancePayment> root, jakarta.persistence.criteria.CriteriaQuery<?> q,
                                              CriteriaBuilder cb) -> {
            List<Predicate> ps = new ArrayList<>();
            ps.add(cb.isFalse(root.get("deleted")));
            ps.add(access.readablePredicate(root, cb, "makerId", readScope));
            if (f.keyword() != null && !f.keyword().isBlank()) {
                ps.add(cb.like(cb.lower(root.get("billNo")), "%" + f.keyword().toLowerCase() + "%"));
            }
            if (f.supplierId() != null) ps.add(cb.equal(root.get("supplierId"), f.supplierId()));
            if (f.accountId() != null) ps.add(cb.equal(root.get("accountId"), f.accountId()));
            if (f.status() != null) ps.add(cb.equal(root.get("status"), f.status()));
            if (f.dateFrom() != null) ps.add(cb.greaterThanOrEqualTo(root.get("billDate"), f.dateFrom()));
            if (f.dateTo() != null) ps.add(cb.lessThanOrEqualTo(root.get("billDate"), f.dateTo()));
            return cb.and(ps.toArray(new Predicate[0]));
        };
        Pageable pageable = Pageables.of(page, size,
                TableSort.resolve(sort, order, Sort.by(Sort.Direction.DESC, "billDate"), ALLOWED_SORT));
        Page<FinancePayment> p = paymentRepo.findAll(spec, pageable);
        return new PageResponse<>(p.map(this::toList).getContent(), page, size, p.getTotalElements(), p.getTotalPages());
    }

    @Transactional(readOnly = true)
    public FinancePaymentDetail detail(UUID id) {
        FinancePayment p = require(id);
        access.requireReadable(p.getMakerId(), "采购付款单不存在");
        List<FinancePaymentLineDto> items = lineRepo.findByPaymentIdOrderByLineNoAsc(id).stream()
                .map(this::toLineDto).toList();
        return toDetail(p, items);
    }

    @Transactional
    @PreAuthorize("hasAuthority('finance_payment:create')")
    public FinancePaymentDetail create(FinancePaymentSaveRequest req) {
        tx.bind();
        UUID makerId = currentUser.requireEmployeeId();
        String idempotencyKey = normalizeIdempotencyKey(req.getCreateIdempotencyKey());
        String requestHash = requestHash(req);
        lockCreateIdempotency(makerId, idempotencyKey);
        FinancePayment replay = findCreateReplay(makerId, idempotencyKey);
        if (replay != null) {
            if (!Objects.equals(replay.getCreateRequestHash(), requestHash)) {
                throw new ApiException(ErrorCode.CONFLICT,
                        "付款创建幂等键已用于不同内容，请刷新后重新提交");
            }
            return detail(replay.getId());
        }
        if (req.getPaymentMethodId() != null || req.getPaymentMethodLegacyId() != null) {
            PaymentStyleHierarchyLock.lock(em);
        }
        assertBillNoFree(req.getBillNo(), null);
        FinancePayment p = new FinancePayment();
        p.setMakerId(makerId);
        p.setCreateIdempotencyKey(idempotencyKey);
        p.setCreateRequestHash(requestHash);
        applyHeader(req, p);
        p.setStatus(STATUS_DRAFT);
        applyMakerIdentity(p);
        paymentRepo.save(p);
        List<FinancePaymentLineDto> items = saveLines(p, req.getItems());
        applyLineTotals(p, items);
        markAmountsAuthoritative(p);
        paymentRepo.flush();
        return toDetail(p, items);
    }

    @Transactional
    @PreAuthorize("hasAuthority('finance_payment:edit')")
    public FinancePaymentDetail update(UUID id, FinancePaymentSaveRequest req) {
        tx.bind();
        if (req.getPaymentMethodId() != null || req.getPaymentMethodLegacyId() != null) {
            PaymentStyleHierarchyLock.lock(em);
        }
        FinancePayment p = require(id);
        em.refresh(p, jakarta.persistence.LockModeType.PESSIMISTIC_WRITE);
        requireActiveAfterLock(p);
        access.requireWritable(p.getMakerId(), "只能操作本人负责或已授权的采购付款单");
        if (p.getStatus() != STATUS_DRAFT) {
            throw new ApiException(ErrorCode.BUSINESS, "仅草稿单据可编辑");
        }
        if (req.getExpectedVersion() == null
                || p.getVersion() == null
                || req.getExpectedVersion().longValue() != p.getVersion().longValue()) {
            throw new ApiException(ErrorCode.CONFLICT,
                    "付款草稿已被其他操作更新，请刷新后重试");
        }
        assertBillNoFree(req.getBillNo(), id);
        applyHeader(req, p);
        applyMakerIdentity(p);
        lineRepo.deleteByPaymentId(id);
        lineRepo.flush();
        List<FinancePaymentLineDto> items = saveLines(p, req.getItems());
        applyLineTotals(p, items);
        markAmountsAuthoritative(p);
        paymentRepo.flush();
        return toDetail(p, items);
    }

    @Transactional
    @PreAuthorize("hasAuthority('finance_payment:delete')")
    public void delete(UUID id) {
        tx.bind();
        FinancePayment p = require(id);
        em.refresh(p, jakarta.persistence.LockModeType.PESSIMISTIC_WRITE);
        requireActiveAfterLock(p);
        access.requireWritable(p.getMakerId(), "只能操作本人负责或已授权的采购付款单");
        if (p.getStatus() == null || p.getStatus() != STATUS_DRAFT) {
            throw new ApiException(ErrorCode.BUSINESS, "仅草稿单据可删除");
        }
        p.setDeleted(true);
        p.setDeletedAt(OffsetDateTime.now());
        paymentRepo.save(p);
    }

    /** 审核：status 0→1，核销 AP / 直接付款 / 账户扣减 / 写流水。 */
    @Transactional
    @PreAuthorize("hasAuthority('finance_payment:approve')")
    public FinancePaymentDetail approve(UUID id) {
        tx.bind();
        FinancePayment p = require(id);
        UUID guardedSupplierId=p.getSupplierId();
        UUID guardedCurrencyId=p.getCurrencyId();
        LocalDate guardedBillDate=p.getBillDate();
        closedPeriodGuard.requireOpen(
                guardedSupplierId,guardedCurrencyId,guardedBillDate,"供应商付款审核");
        em.refresh(p, jakarta.persistence.LockModeType.PESSIMISTIC_WRITE); // M28：强制 SELECT...FOR UPDATE 重读字段，防陈旧状态绕过守卫
        requirePeriodIdentityUnchanged(
                p,guardedSupplierId,guardedCurrencyId,guardedBillDate);
        requireActiveAfterLock(p);
        access.requireScopedOperationWritable(p.getMakerId(), "只能操作本人负责或已交接的采购付款单",
                "finance_payment:approve");
        if (p.getStatus() == null || p.getStatus() != STATUS_DRAFT) {
            throw new ApiException(ErrorCode.BUSINESS, "仅草稿单据可审核");
        }
        requireAuthoritativeAmounts(p, "审核");
        if (p.getAccountId() == null) {
            throw new ApiException(ErrorCode.BUSINESS, "付款单需指定付款账户");
        }
        assertNoExistingPosting(p.getId()); // M19：幂等护栏，finance_reconciliations 已存在该单流水则禁止重复审核
        UUID approver = currentUser.requireEmployeeId(); // 审核=当前登录用户（报表按 approver_id 解析审核员）
        if (p.getMakerId() != null && p.getMakerId().equals(approver)) {
            throw new ApiException(ErrorCode.BUSINESS, "制单人与审核人不可相同(职责分离)");
        }
        glPostingService.lockAutoProjectionPeriod(p.getBillDate());
        p.setApproverId(approver);
        p.setApproverLegacyId(null);
        p.setApproverName(nameResolver.nameOf(approver));
        settlePayment(p);
        p.setStatus(STATUS_APPROVED);
        p.setCancelDate(OffsetDateTime.now());
        paymentRepo.save(p);
        return detail(id);
    }

    /** 红冲：status 1→-1，反向冲销。 */
    @Transactional
    @PreAuthorize("hasAuthority('finance_payment:reverse')")
    public FinancePaymentDetail reverse(UUID id) {
        tx.bind();
        FinancePayment p = require(id);
        UUID guardedSupplierId=p.getSupplierId();
        UUID guardedCurrencyId=p.getCurrencyId();
        LocalDate guardedBillDate=p.getBillDate();
        closedPeriodGuard.requireOpen(
                guardedSupplierId,guardedCurrencyId,BusinessTime.today(),"供应商付款反审");
        em.refresh(p, jakarta.persistence.LockModeType.PESSIMISTIC_WRITE); // M28：强制 SELECT...FOR UPDATE 重读字段，防陈旧状态绕过守卫
        requirePeriodIdentityUnchanged(
                p,guardedSupplierId,guardedCurrencyId,guardedBillDate);
        requireActiveAfterLock(p);
        access.requireScopedOperationWritable(p.getMakerId(), "只能操作本人负责或已交接的采购付款单",
                "finance_payment:reverse");
        if (p.getStatus() == null || p.getStatus() != STATUS_APPROVED) {
            throw new ApiException(ErrorCode.BUSINESS, "仅已审核单据可红冲");
        }
        requireAuthoritativeAmounts(p, "红冲");
        assertCompletePosting(p.getId(), 1L); // M19：红冲前确认流水完整（付款每单恰 1 行）
        glPostingService.removePaymentDoc(p.getId(), p.getBillNo(), p.getBillDate());
        reverseSettlement(p);
        p.setStatus(STATUS_REVERSED);
        p.setReversedAt(OffsetDateTime.now()); // V390：一次写入，数据库触发器锁定
        paymentRepo.save(p);
        return detail(id);
    }

    // ===================== 核销逻辑 =====================

    private void settlePayment(FinancePayment p) {
        List<FinancePaymentLine> lines = lineRepo.findByPaymentIdOrderByLineNoAsc(p.getId());
        if (lines.isEmpty()) {
            throw new ApiException(
                    ErrorCode.CONFLICT,
                    "无应付核销明细的直接付款属于供应商预付；供应商预付资产科目、应用、退款和总账链未完成，当前禁止审核");
        }
        Map<UUID, ArApLedger> lockedLedgers = lockAppliedLedgers(lines);
        settleAppliedLines(p, lines, lockedLedgers);
        BigDecimal accountAmount = adjustAccount(
                p.getAccountId(), p.getCurrencyId(), p.getAmountOriginal(), p.getAmountLocal());
        insertReconciliation(p, accountAmount);
    }

    private void reverseSettlement(FinancePayment p) {
        List<FinancePaymentLine> lines = lineRepo.findByPaymentIdOrderByLineNoAsc(p.getId());
        if (!lines.isEmpty()) {
            reverseAppliedLines(p, lines, lockAppliedLedgers(lines));
            adjustAccount(p.getAccountId(), p.getCurrencyId(),
                    nz(p.getAmountOriginal()).negate(), nz(p.getAmountLocal()).negate());
            reverseReconciliation(p.getId());
            return;
        }

        List<ArApLedger> rows = ledgerRepo.findBySourceForUpdate(
                p.getId(), SRC_DIRECT_PAYMENT);
        if (rows.size() != 1) {
            throw new ApiException(ErrorCode.CONFLICT, "直接付款反立账来源缺失或重复");
        }
        OffsetDateTime reversedAt = OffsetDateTime.now();
        for (ArApLedger ledger : rows) {
            ledger.setStatus((short) -1);
            ledger.setDeleted(true);
            ledger.setDeletedAt(reversedAt);
            ledgerRepo.save(ledger);
        }
        adjustAccount(p.getAccountId(), p.getCurrencyId(),
                nz(p.getAmountOriginal()).negate(), nz(p.getAmountLocal()).negate());
        reverseReconciliation(p.getId());
    }

    private void settleAppliedLines(
            FinancePayment payment,
            List<FinancePaymentLine> lines,
            Map<UUID, ArApLedger> lockedLedgers) {
        BigDecimal originalTotal = BigDecimal.ZERO;
        BigDecimal localTotal = BigDecimal.ZERO;
        for (FinancePaymentLine line : lines) {
            ArApLedger ledger = lockedLedgers.get(line.getAppliedLedgerId());
            validateAppliedLedger(payment, line.getSupplierId(), ledger, false);
            AppliedPayment amounts = calculateAppliedPayment(payment, line.getAmountOriginal(), ledger);

            line.setAppliedBillNo(ledger.getBillNo());
            line.setSupplierId(ledger.getSupplierId());
            line.setAmountOriginal(amounts.cashOriginal());
            line.setAmountLocal(amounts.cashLocal());
            line.setExchangeDiff(amounts.exchangeDiff());
            line.setCashRate(amounts.cashRate());
            line.setRecognitionRate(amounts.recognitionRate());
            line.setAppliedAmountLocal(amounts.appliedLocal());
            line.setBalanceBeforeOriginal(amounts.beforeOriginal());
            line.setBalanceAfterOriginal(amounts.afterOriginal());
            lineRepo.save(line);

            BigDecimal newSettled = money(nz(ledger.getAmountSettled()).add(amounts.appliedLocal()));
            ledger.setAmountReceivedOriginal(money(
                    nz(ledger.getAmountReceivedOriginal()).add(amounts.cashOriginal())));
            ledger.setAmountReceivedLocal(money(
                    nz(ledger.getAmountReceivedLocal()).add(amounts.cashLocal())));
            ledger.setAmountBalanceOriginal(amounts.afterOriginal());
            ledger.setAmountSettled(newSettled);
            ledger.setAmountBalance(money(nz(ledger.getAmountOriginalLocal())
                    .subtract(newSettled)
                    .subtract(nz(ledger.getAmountOffsetLocal()))));
            refreshSettlement(ledger, payment.getBillDate());
            ledgerRepo.save(ledger);

            originalTotal = originalTotal.add(amounts.cashOriginal());
            localTotal = localTotal.add(amounts.cashLocal());
        }
        payment.setAmountOriginal(money(originalTotal));
        payment.setAmountLocal(money(localTotal));
        paymentRepo.save(payment);
    }

    private void reverseAppliedLines(
            FinancePayment payment,
            List<FinancePaymentLine> lines,
            Map<UUID, ArApLedger> lockedLedgers) {
        for (FinancePaymentLine line : lines) {
            ArApLedger ledger = lockedLedgers.get(line.getAppliedLedgerId());
            validateAppliedLedger(payment, line.getSupplierId(), ledger, false);
            BigDecimal cashOriginal = positiveMoney(line.getAmountOriginal(), "本次付款金额");
            BigDecimal cashLocal = positiveMoney(line.getAmountLocal(), "本次付款本币金额");
            BigDecimal appliedLocal = positiveMoney(
                    authoritativeAppliedAmountLocal(line), "本次核销账面本币金额");
            BigDecimal newSettled = money(nz(ledger.getAmountSettled()).subtract(appliedLocal));
            if (newSettled.signum() < 0) {
                throw new ApiException(ErrorCode.CONFLICT, "应付累计核销不足，禁止红冲该付款单");
            }

            BigDecimal receivedOriginal = ledger.getAmountReceivedOriginal();
            BigDecimal receivedLocal = ledger.getAmountReceivedLocal();
            if (receivedOriginal == null || receivedLocal == null
                    || ledger.getAmountBalanceOriginal() == null
                    || ledger.getAmountWriteOffOriginal() == null) {
                throw new ApiException(ErrorCode.CONFLICT,
                        "应付双币累计不完整，禁止红冲该付款单");
            }
            if (receivedOriginal.compareTo(cashOriginal) < 0
                    || receivedLocal.compareTo(cashLocal) < 0) {
                throw new ApiException(ErrorCode.CONFLICT,
                        "应付双币累计不足，禁止红冲该付款单");
            }
            BigDecimal newReceivedOriginal = money(receivedOriginal.subtract(cashOriginal));
            BigDecimal newReceivedLocal = money(receivedLocal.subtract(cashLocal));
            ledger.setAmountReceivedOriginal(newReceivedOriginal);
            ledger.setAmountReceivedLocal(newReceivedLocal);
            ledger.setAmountBalanceOriginal(money(nz(ledger.getAmountOriginal())
                    .subtract(newReceivedOriginal)
                    .subtract(ledger.getAmountWriteOffOriginal())
                    .subtract(nz(ledger.getAmountOffsetOriginal()))));
            ledger.setAmountSettled(newSettled);
            ledger.setAmountBalance(money(nz(ledger.getAmountOriginalLocal())
                    .subtract(newSettled)
                    .subtract(nz(ledger.getAmountOffsetLocal()))));
            refreshSettlement(ledger, payment.getBillDate());
            ledgerRepo.save(ledger);
        }
    }

    /**
     * 对齐 数据库约束：仅余额恰好为零时结清。DIRECT_PAYMENT 的负余额
     * 表示仍可使用的供应商预付款，保持未结清。
     */
    private void refreshSettlement(ArApLedger led, LocalDate settlementDate) {
        BigDecimal bal = nz(led.getAmountBalance());
        boolean settled = bal.signum() == 0;
        led.setSettled(settled);
        led.setSettledDate(settled
                ? (settlementDate != null ? settlementDate : BusinessTime.today())
                : null);
    }

    private Map<UUID, ArApLedger> lockAppliedLedgers(List<FinancePaymentLine> lines) {
        List<UUID> ids = lines.stream()
                .map(FinancePaymentLine::getAppliedLedgerId)
                .toList();
        if (ids.stream().anyMatch(Objects::isNull)) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "付款核销明细必须关联应付台账");
        }
        if (new HashSet<>(ids).size() != ids.size()) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "同一应付台账不能在一张付款单中重复核销");
        }
        List<ArApLedger> locked = ledgerRepo.findAllByIdInForUpdate(
                ids.stream().sorted().toList());
        if (locked.size() != ids.size()) {
            throw new ApiException(ErrorCode.BUSINESS, "核销的应付记录不存在或已删除");
        }
        Map<UUID, ArApLedger> byId = new HashMap<>();
        for (ArApLedger ledger : locked) {
            byId.put(ledger.getId(), ledger);
        }
        return byId;
    }

    private void validateAppliedLedger(
            FinancePayment payment,
            UUID lineSupplierId,
            ArApLedger ledger,
            boolean allowHeaderDefaults) {
        if (!"AP".equals(ledger.getDirection())) {
            throw new ApiException(ErrorCode.BUSINESS, "采购付款只能引用应付记录");
        }
        if (SRC_DIRECT_PAYMENT.equals(ledger.getSourceDocType())) {
            throw new ApiException(ErrorCode.CONFLICT, "供应商预付款不能作为普通应付引用");
        }
        if (ledger.getSupplierId() == null) {
            throw new ApiException(ErrorCode.CONFLICT, "引用的应付未关联供应商");
        }
        if (payment.getSupplierId() == null && allowHeaderDefaults) {
            payment.setSupplierId(ledger.getSupplierId());
        }
        if (!Objects.equals(payment.getSupplierId(), ledger.getSupplierId())
                || lineSupplierId != null && !Objects.equals(lineSupplierId, ledger.getSupplierId())) {
            throw new ApiException(ErrorCode.CONFLICT, "付款供应商与引用应付供应商不一致");
        }
        if (ledger.getCurrencyId() == null) {
            throw new ApiException(ErrorCode.CONFLICT,
                    "该历史应付的币别尚未核验，不能自动核销；请先由财务完成历史币别确认");
        }
        if (payment.getCurrencyId() == null && allowHeaderDefaults) {
            payment.setCurrencyId(ledger.getCurrencyId());
        }
        if (!Objects.equals(payment.getCurrencyId(), ledger.getCurrencyId())) {
            throw new ApiException(ErrorCode.BUSINESS,
                    "跨币种核销需要双币金额与双汇率；当前付款只能使用应付币别");
        }
    }

    private AppliedPayment calculateAppliedPayment(
            FinancePayment payment,
            BigDecimal requestedOriginal,
            ArApLedger ledger) {
        BigDecimal paymentRate = positiveRate(payment.getExchangeRate());
        BigDecimal recognitionRate = positiveRate(ledger.getExchangeRate());
        BigDecimal cashOriginal = positiveMoney(requestedOriginal, "本次付款金额");
        if (ledger.getAmountBalanceOriginal() == null || ledger.getAmountOriginalLocal() == null) {
            throw new ApiException(ErrorCode.CONFLICT,
                    "该历史应付的原币余额或账面本币尚未核验，不能自动核销；请先由财务完成历史金额确认");
        }
        BigDecimal beforeOriginal = money(ledger.getAmountBalanceOriginal());
        if (beforeOriginal.signum() <= 0) {
            throw new ApiException(ErrorCode.CONFLICT, "引用的应付没有可付余额");
        }
        if (cashOriginal.compareTo(beforeOriginal) > 0) {
            throw new ApiException(ErrorCode.BUSINESS, "本次付款超过应付未付金额");
        }
        BigDecimal afterOriginal = money(beforeOriginal.subtract(cashOriginal));
        BigDecimal cashLocal = money(cashOriginal.multiply(paymentRate));
        BigDecimal originalLocal = money(ledger.getAmountOriginalLocal());
        BigDecimal offsetLocal = money(nz(ledger.getAmountOffsetLocal()));
        if (offsetLocal.signum() < 0 || offsetLocal.compareTo(originalLocal) > 0) {
            throw new ApiException(ErrorCode.CONFLICT, "应付抵销本币快照异常，不能核销");
        }
        BigDecimal oldSettledLocal = money(nz(ledger.getAmountSettled()));
        BigDecimal newSettledLocal = money(oldSettledLocal
                .add(money(cashOriginal.multiply(recognitionRate))));
        if (afterOriginal.signum() == 0) {
            newSettledLocal = money(originalLocal.subtract(offsetLocal));
        }
        if (money(newSettledLocal.add(offsetLocal)).compareTo(originalLocal) > 0) {
            throw new ApiException(ErrorCode.CONFLICT,
                    "应付累计账面核销金额超过应付账面本币总额(含已抵销金额)，禁止审核");
        }
        BigDecimal appliedLocal = money(newSettledLocal.subtract(oldSettledLocal));
        if (appliedLocal.signum() <= 0) {
            throw new ApiException(ErrorCode.CONFLICT, "引用的应付账面余额异常，不能核销");
        }
        BigDecimal exchangeDiff = money(cashLocal.subtract(appliedLocal));
        return new AppliedPayment(
                cashOriginal, cashLocal, paymentRate, recognitionRate,
                appliedLocal, exchangeDiff, beforeOriginal, afterOriginal);
    }

    private record AppliedPayment(
            BigDecimal cashOriginal,
            BigDecimal cashLocal,
            BigDecimal cashRate,
            BigDecimal recognitionRate,
            BigDecimal appliedLocal,
            BigDecimal exchangeDiff,
            BigDecimal beforeOriginal,
            BigDecimal afterOriginal) {}

    private void applyLineTotals(FinancePayment payment, List<FinancePaymentLineDto> lines) {
        if (lines == null || lines.isEmpty()) {
            return;
        }
        BigDecimal local = lines.stream()
                .map(line -> nz(line.getAmountLocal()))
                .reduce(BigDecimal.ZERO, BigDecimal::add);
        BigDecimal original = lines.stream()
                .map(line -> line.getAmountOriginal() == null
                        ? nz(line.getAmountLocal())
                        : line.getAmountOriginal())
                .reduce(BigDecimal.ZERO, BigDecimal::add);
        payment.setAmountLocal(money(local));
        payment.setAmountOriginal(money(original));
        paymentRepo.save(payment);
    }

    /** 扣减付款账户，并返回账户流水使用的同币种金额。 */
    private BigDecimal adjustAccount(
            UUID accountId,
            UUID paymentCurrencyId,
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
            throw new ApiException(ErrorCode.BUSINESS, "付款账户不存在或已停用：" + accountId);
        }
        Object[] row = rows.getFirst();
        UUID accountCurrencyId = (UUID) row[0];
        String currencyCode = row[1] == null ? null : row[1].toString();
        String currencyName = row[2] == null ? null : row[2].toString();
        boolean baseCurrency = Boolean.TRUE.equals(row[3]);
        if (accountCurrencyId == null) {
            throw new ApiException(ErrorCode.BUSINESS, "付款账户未设置币种");
        }
        if (currencyCode == null && currencyName == null) {
            throw new ApiException(ErrorCode.BUSINESS, "付款账户币种不存在或已停用");
        }
        BigDecimal accountDelta;
        if (baseCurrency) {
            accountDelta = money(localDelta);
        } else if (Objects.equals(accountCurrencyId, paymentCurrencyId)) {
            accountDelta = money(originalDelta);
        } else {
            throw new ApiException(ErrorCode.BUSINESS,
                    "付款账户必须为人民币本位币账户或与付款原币相同的账户，"
                            + "不能直接使用第三币种账户：" + accountId);
        }
        int updated = em.createNativeQuery("""
                        UPDATE accounts
                        SET balance_current=COALESCE(balance_current,0)-:amount,
                            payments_total=COALESCE(payments_total,0)+:amount,
                            updated_at=now()
                        WHERE id=:id
                        """)
                .setParameter("amount", accountDelta)
                .setParameter("id", accountId)
                .executeUpdate();
        if (updated != 1) {
            throw new ApiException(ErrorCode.CONFLICT, "付款账户余额更新失败：" + accountId);
        }
        return accountDelta;
    }

    private void insertReconciliation(FinancePayment p, BigDecimal accountAmount) {
        String counterpart = p.getSupplierId() == null ? null : lookupSupplierName(p.getSupplierId());
        em.createNativeQuery("""
                INSERT INTO finance_reconciliations
                  (bill_no, source_doc_type, source_doc_id, account_id, check_no, counterpart_name,
                   in_amount, out_amount, amount_local, bill_date, settled_date, source_remark,
                   legacy_bstyle, created_at, updated_at, is_deleted)
                VALUES (:billNo, :src, :sid, :acc, :chk, :cpn, 0, :outAmt, :localAmt,
                        :bd, :sd, :sr, 21, now(), now(), false)
                """)
                .setParameter("billNo", p.getBillNo())
                .setParameter("src", RECON_SOURCE)
                .setParameter("sid", p.getId())
                .setParameter("acc", p.getAccountId())
                .setParameter("chk", p.getInvoiceNo())
                .setParameter("cpn", counterpart)
                .setParameter("outAmt", accountAmount)
                .setParameter("localAmt", p.getAmountLocal())
                .setParameter("bd", p.getBillDate().atStartOfDay(java.time.ZoneOffset.UTC).toOffsetDateTime()) // M17：bill_date 用单据日期，settled_date 保持审核时刻
                .setParameter("sd", OffsetDateTime.now())
                .setParameter("sr", p.getSourceRemark())
                .executeUpdate();
    }

    private void reverseReconciliation(UUID paymentId) {
        accountFlowLedger.reverse(
                RECON_SOURCE, paymentId, OffsetDateTime.now(), "采购付款红冲");
    }

    private void assertNoExistingPosting(UUID paymentId) {
        if (postingCount(paymentId) != 0) {
            throw new ApiException(ErrorCode.CONFLICT, "该单据已存在账户流水，禁止重复审核");
        }
    }

    private void assertCompletePosting(UUID paymentId, long expectedRows) {
        long actual = postingCount(paymentId);
        if (actual != expectedRows) {
            throw new ApiException(ErrorCode.CONFLICT,
                    "付款流水不完整，禁止红冲(期望 " + expectedRows + "，实际 " + actual + ")");
        }
    }

    private long postingCount(UUID paymentId) {
        return ((Number) em.createNativeQuery("""
                        SELECT COUNT(*)
                        FROM finance_reconciliations
                        WHERE source_doc_type = :src
                          AND source_doc_id = :id
                          AND COALESCE(is_deleted, false) = false
                        """)
                .setParameter("src", RECON_SOURCE)
                .setParameter("id", paymentId)
                .getSingleResult()).longValue();
    }

    private String lookupSupplierName(UUID supplierId) {
        try {
            Object r = em.createNativeQuery("SELECT name FROM suppliers WHERE id = :id AND COALESCE(is_deleted, false) = false")
                    .setParameter("id", supplierId).getSingleResult();
            return r == null ? null : r.toString();
        } catch (jakarta.persistence.NoResultException e) {
            return null;
        } catch (jakarta.persistence.NonUniqueResultException e) {
            throw new ApiException(ErrorCode.CONFLICT, "供应商主档存在重复：" + supplierId);
        }
    }

    // ===================== CRUD 辅助 =====================

    private void applyHeader(FinancePaymentSaveRequest req, FinancePayment p) {
        // 单据号系统自动生成（服务端权威）：仅新建（billNo 空）时取号；更新保留既有号，忽略客户端值。
        if (p.getBillNo() == null || p.getBillNo().isBlank()) {
            p.setBillNo(docNumberService.nextNumber(DocNumberPrefix.FIN_PAYMENT));
        }
        p.setBillDate(req.getBillDate());
        p.setSupplierId(req.getSupplierId());
        p.setAccountId(req.getAccountId());
        p.setCounterpartAccountId(req.getCounterpartAccountId());
        p.setCurrencyId(req.getCurrencyId());
        if (req.getExchangeRate() == null) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "付款汇率不能为空");
        }
        p.setExchangeRate(positiveRate(req.getExchangeRate()));
        boolean appliedPayment = req.getItems() != null && !req.getItems().isEmpty();
        if (!appliedPayment) {
            if (p.getCurrencyId() == null) {
                throw new ApiException(ErrorCode.VALIDATION_FAILED, "直接付款必须指定币别");
            }
            BigDecimal amountOriginal = positiveMoney(req.getAmountOriginal(), "直接付款金额");
            p.setAmountOriginal(amountOriginal);
            p.setAmountLocal(money(amountOriginal.multiply(p.getExchangeRate())));
        }
        applyPaymentMethod(req, p);
        p.setInvoiceNo(req.getInvoiceNo());
        applyOperator(req, p);
        p.setSourceRemark(req.getSourceRemark());
        p.setRemark(req.getRemark());
    }

    private void applyPaymentMethod(FinancePaymentSaveRequest req, FinancePayment payment) {
        if (req.getPaymentMethodId() == null && req.getPaymentMethodLegacyId() == null
                && payment.getLegacyId() != null && payment.getPaymentMethodId() == null) {
            return; // imported PaidStyle snapshot has no safe master mapping; keep it historical
        }
        var method = PaymentMethodReferenceResolver.resolve(
                em, req.getPaymentMethodId(), req.getPaymentMethodLegacyId(), "付款方式",
                PaymentMethodReferenceResolver.Direction.PAYMENT);
        payment.setPaymentMethodId(method == null ? null : method.id());
        payment.setPaymentMethodLegacyId(method == null ? null : method.legacyId());
    }

    private void applyOperator(FinancePaymentSaveRequest req, FinancePayment payment) {
        EmployeeReference operator = nameResolver.resolveForWrite(
                req.getOperatorId(), null, req.getOperatorName(), "经手人");
        if (operator == null && payment.getLegacyId() != null && payment.getOperatorId() == null) {
            return; // preserve imported B_Worker/jsr snapshot when omitted by current clients
        }
        payment.setOperatorId(operator == null ? null : operator.id());
        payment.setOperatorLegacyId(operator == null ? null : operator.legacyId());
        payment.setOperatorName(operator == null ? null : operator.name());
    }

    private void applyMakerIdentity(FinancePayment payment) {
        if (payment.getMakerId() == null) return;
        payment.setMakerLegacyId(null); // Sys_Operator ids are not employees.legacy_id
        payment.setMakerName(nameResolver.nameOf(payment.getMakerId()));
    }

    private List<FinancePaymentLineDto> saveLines(FinancePayment p, List<FinancePaymentLineInput> inputs) {
        if (inputs == null || inputs.isEmpty()) return List.of();
        List<UUID> ledgerIds = inputs.stream()
                .map(FinancePaymentLineInput::getAppliedLedgerId)
                .toList();
        if (ledgerIds.stream().anyMatch(Objects::isNull)) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "付款核销明细必须关联应付台账");
        }
        if (new HashSet<>(ledgerIds).size() != ledgerIds.size()) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "同一应付台账不能在一张付款单中重复核销");
        }
        List<FinancePaymentLineDto> out = new ArrayList<>(inputs.size());
        int auto = 1;
        for (FinancePaymentLineInput l : inputs) {
            ArApLedger ledger = ledgerRepo.findById(l.getAppliedLedgerId())
                    .filter(item -> !item.isDeleted())
                    .orElseThrow(() -> new ApiException(ErrorCode.BUSINESS, "引用的应付记录不存在或已删除"));
            validateAppliedLedger(p, l.getSupplierId(), ledger, true);
            AppliedPayment amounts = calculateAppliedPayment(p, l.getAmountOriginal(), ledger);
            FinancePaymentLine ln = new FinancePaymentLine();
            ln.setPaymentId(p.getId());
            ln.setBillNo(p.getBillNo());
            ln.setBillDate(p.getBillDate());
            ln.setLineNo(l.getLineNo() != null ? l.getLineNo() : auto);
            ln.setAppliedLedgerId(l.getAppliedLedgerId());
            ln.setAppliedBillNo(ledger.getBillNo());
            ln.setSupplierId(ledger.getSupplierId());
            ln.setAmountOriginal(amounts.cashOriginal());
            ln.setAmountLocal(amounts.cashLocal());
            ln.setExchangeDiff(amounts.exchangeDiff());
            ln.setCashRate(amounts.cashRate());
            ln.setRecognitionRate(amounts.recognitionRate());
            ln.setAppliedAmountLocal(amounts.appliedLocal());
            ln.setBalanceBeforeOriginal(amounts.beforeOriginal());
            ln.setBalanceAfterOriginal(amounts.afterOriginal());
            ln.setRemark(l.getRemark());
            lineRepo.save(ln);
            out.add(toLineDto(ln));
            auto++;
        }
        return out;
    }

    private void assertBillNoFree(String billNo, UUID excludeId) {
        if (billNo == null || billNo.isBlank()) return;
        paymentRepo.findByBillNo(billNo).ifPresent(existing -> {
            if (excludeId == null || !existing.getId().equals(excludeId)) {
                throw new ApiException(ErrorCode.CONFLICT, "单号已存在：" + billNo);
            }
        });
    }

    private FinancePaymentLineDto toLineDto(FinancePaymentLine ln) {
        return new FinancePaymentLineDto(ln.getId(), ln.getLineNo(), ln.getAppliedLedgerId(),
                ln.getAppliedBillNo(), ln.getSupplierId(), ln.getAmountOriginal(), ln.getAmountLocal(),
                appliedAmountLocal(ln), ln.getExchangeDiff(), ln.getRemark());
    }

    private FinancePaymentListItem toList(FinancePayment p) {
        return new FinancePaymentListItem(p.getId(), p.getBillNo(), p.getBillDate(),
                p.getSupplierId(), p.getAccountId(), p.getAmountLocal(), p.getStatus(), p.getLegacyId());
    }

    private FinancePaymentDetail toDetail(FinancePayment p, List<FinancePaymentLineDto> items) {
        return new FinancePaymentDetail(p.getId(), p.getLegacyId(), p.getBillNo(), p.getBillDate(),
                p.getSupplierId(), p.getAccountId(), p.getCounterpartAccountId(), p.getCurrencyId(),
                p.getExchangeRate(), p.getAmountOriginal(), p.getAmountLocal(), p.getPaymentMethodId(),
                p.getPaymentMethodLegacyId(), p.getInvoiceNo(), p.getCancelDate(),
                p.getOperatorName(), p.getOperatorId(), p.getMakerId(), p.getApproverId(),
                p.getSourceRemark(), p.getRemark(), p.getStatus(), p.isClosed(), items,
                nameResolver.nameOf(p.getMakerId()), p.getCreatedAt(),
                p.getVersion() == null ? 0L : p.getVersion(),
                p.getCreateIdempotencyKey());
    }

    private FinancePayment require(UUID id) {
        return paymentRepo.findById(id).filter(p -> !p.isDeleted())

                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "采购付款单不存在"));
    }

    private String normalizeIdempotencyKey(String raw) {
        String value = raw == null ? null : raw.trim();
        if (value == null || value.length() < 8 || value.length() > 128
                || !value.matches("[A-Za-z0-9._:-]+")) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED,
                    "付款创建幂等键格式不正确");
        }
        return value;
    }

    private void lockCreateIdempotency(UUID makerId, String key) {
        em.createNativeQuery(
                        "SELECT pg_advisory_xact_lock(hashtextextended(:key,0))")
                .setParameter("key", "FIN_PAYMENT_CREATE|" + makerId + "|" + key)
                .getSingleResult();
    }

    private FinancePayment findCreateReplay(UUID makerId, String key) {
        @SuppressWarnings("unchecked")
        List<Object> ids = em.createNativeQuery("""
                        SELECT id FROM finance_payments
                        WHERE maker_id=:maker AND create_idempotency_key=:key
                        """)
                .setParameter("maker", makerId)
                .setParameter("key", key)
                .getResultList();
        if (ids.isEmpty()) return null;
        if (ids.size() != 1) {
            throw new ApiException(ErrorCode.CONFLICT,
                    "付款创建幂等键存在重复历史，请先完成数据核对");
        }
        FinancePayment payment = paymentRepo.findById((UUID) ids.getFirst())
                .orElseThrow(() -> new ApiException(
                        ErrorCode.CONFLICT, "付款幂等记录缺少来源单据"));
        if (payment.isDeleted()) {
            throw new ApiException(ErrorCode.CONFLICT,
                    "该付款创建请求曾生成后删除，不能用同一幂等键重新造单");
        }
        access.requireReadable(payment.getMakerId(), "采购付款单不存在");
        return payment;
    }

    private static String requestHash(FinancePaymentSaveRequest request) {
        StringBuilder value = new StringBuilder();
        appendHash(value, request.getBillDate());
        appendHash(value, request.getSupplierId());
        appendHash(value, request.getAccountId());
        appendHash(value, request.getCounterpartAccountId());
        appendHash(value, request.getCurrencyId());
        appendHash(value, decimalText(request.getExchangeRate()));
        List<FinancePaymentLineInput> items =
                request.getItems() == null ? List.of() : request.getItems();
        appendHash(value, items.isEmpty()
                ? decimalText(request.getAmountOriginal()) : null);
        appendHash(value, request.getPaymentMethodId());
        appendHash(value, request.getPaymentMethodLegacyId());
        appendHash(value, request.getInvoiceNo());
        appendHash(value, request.getOperatorName());
        appendHash(value, request.getOperatorId());
        appendHash(value, request.getSourceRemark());
        appendHash(value, request.getRemark());
        appendHash(value, items.size());
        for (FinancePaymentLineInput item : items) {
            appendHash(value, item == null ? null : item.getLineNo());
            appendHash(value, item == null ? null : item.getAppliedLedgerId());
            appendHash(value, item == null ? null : item.getAppliedBillNo());
            appendHash(value, item == null ? null : item.getSupplierId());
            appendHash(value, item == null ? null : decimalText(item.getAmountOriginal()));
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
        String text = value == null ? "" : value.toString();
        target.append(text.length()).append(':').append(text).append('|');
    }

    private static String decimalText(BigDecimal value) {
        return value == null ? null : value.stripTrailingZeros().toPlainString();
    }

    private static void requirePeriodIdentityUnchanged(
            FinancePayment payment,UUID supplierId,UUID currencyId,LocalDate billDate){
        if(!Objects.equals(payment.getSupplierId(),supplierId)
                ||!Objects.equals(payment.getCurrencyId(),currencyId)
                ||!Objects.equals(payment.getBillDate(),billDate)){
            throw new ApiException(
                    ErrorCode.CONFLICT,
                    "付款单供应商、币种或业务日期已变化，请刷新后重试");
        }
    }



    private static void requireActiveAfterLock(FinancePayment payment) {
        if (payment.isDeleted()) {
            throw new ApiException(ErrorCode.NOT_FOUND, "采购付款单不存在");
        }
    }

    private static BigDecimal nz(BigDecimal x) {
        return x == null ? BigDecimal.ZERO : x;
    }

    private static BigDecimal appliedAmountLocal(FinancePaymentLine line) {
        return line.getAppliedAmountLocal() != null
                ? money(line.getAppliedAmountLocal())
                : money(nz(line.getAmountLocal()).subtract(nz(line.getExchangeDiff())));
    }

    private static BigDecimal authoritativeAppliedAmountLocal(FinancePaymentLine line) {
        if (line.getAppliedAmountLocal() == null) {
            throw new ApiException(ErrorCode.CONFLICT,
                    "付款行缺少服务端账面核销快照，禁止红冲");
        }
        return money(line.getAppliedAmountLocal());
    }

    private void markAmountsAuthoritative(FinancePayment payment) {
        payment.setAmountAuthorityVersion(AMOUNT_AUTHORITY_VERSION);
        paymentRepo.save(payment);
    }

    private static void requireAuthoritativeAmounts(FinancePayment payment, String operation) {
        if (payment.getAmountAuthorityVersion() != AMOUNT_AUTHORITY_VERSION) {
            throw new ApiException(ErrorCode.CONFLICT,
                    "历史付款金额尚未经过服务端核验，禁止" + operation + "；请先重新编辑并保存草稿，或由财务完成专项核验");
        }
    }

    private static BigDecimal positiveRate(BigDecimal value) {
        if (value == null || value.signum() <= 0) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "付款汇率必须大于 0");
        }
        return value.setScale(RATE_SCALE, RoundingMode.HALF_UP);
    }

    private static BigDecimal positiveMoney(BigDecimal value, String label) {
        if (value == null || value.signum() <= 0) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, label + "必须大于 0");
        }
        return money(value);
    }

    private static BigDecimal money(BigDecimal value) {
        return nz(value).setScale(MONEY_SCALE, RoundingMode.HALF_UP);
    }
}
