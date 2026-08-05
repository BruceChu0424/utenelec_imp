package com.uten.imp.features.finance.payment;

import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.common.web.Pageables;
import com.uten.imp.common.web.TableSort;
import com.uten.imp.common.docnumber.DocNumberPrefix;
import com.uten.imp.common.docnumber.DocNumberService;
import com.uten.imp.features.finance.arap.ArApLedger;
import com.uten.imp.features.finance.arap.ArApLedgerRepository;
import com.uten.imp.features.finance.arap.ArApLedgerService;
import com.uten.imp.features.finance.payment.dto.FinancePaymentDetail;
import com.uten.imp.features.finance.payment.dto.FinancePaymentLineDto;
import com.uten.imp.features.finance.payment.dto.FinancePaymentLineInput;
import com.uten.imp.features.finance.payment.dto.FinancePaymentListItem;
import com.uten.imp.features.finance.payment.dto.FinancePaymentQueryFilter;
import com.uten.imp.features.finance.payment.dto.FinancePaymentSaveRequest;
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
 * 采购付款单服务：CRUD（主 + 明细）+ 审核状态机（核销 AP / 直接付款 / 账户扣减 / 写流水）。
 *
 * <p>与 {@code FinanceReceiptService} 对称（Client↔Vend、receipt↔payment、AR↔AP）。
 * 取代老库 TRI_M_Paid_B_M_Out + TRI_PaymentCheck 触发器。
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

    /** 列排序白名单：前端列 key → JPA 实体属性名（日期/金额可排序；命中才排序，否则默认 billDate DESC）。 */
    private static final Map<String, String> ALLOWED_SORT = Map.of("billDate", "billDate", "amountLocal", "amountLocal");

    public static final String SRC_DIRECT_PAYMENT = "DIRECT_PAYMENT";
    public static final String RECON_SOURCE = "PAYMENT";

    private final FinancePaymentRepository paymentRepo;
    private final FinancePaymentLineRepository lineRepo;
    private final ArApLedgerRepository ledgerRepo;
    private final ArApLedgerService arApService;
    private final TxSessionVars tx;
    private final SecurityContextCurrentUser currentUser;
    private final com.uten.imp.common.util.EmployeeNameResolver nameResolver;
    private final EntityManager em;
    private final DocNumberService docNumberService;

    @Transactional(readOnly = true)
    public PageResponse<FinancePaymentListItem> list(FinancePaymentQueryFilter f, int page, int size, String sort, String order) {
        Specification<FinancePayment> spec = (Root<FinancePayment> root, jakarta.persistence.criteria.CriteriaQuery<?> q,
                                              CriteriaBuilder cb) -> {
            List<Predicate> ps = new ArrayList<>();
            ps.add(cb.isFalse(root.get("deleted")));
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
        List<FinancePaymentLineDto> items = lineRepo.findByPaymentIdOrderByLineNoAsc(id).stream()
                .map(this::toLineDto).toList();
        return toDetail(p, items);
    }

    @Transactional
    public FinancePaymentDetail create(FinancePaymentSaveRequest req) {
        tx.bind();
        assertBillNoFree(req.getBillNo(), null);
        FinancePayment p = new FinancePayment();
        applyHeader(req, p);
        p.setStatus(STATUS_DRAFT);
        p.setMakerId(currentUser.requireEmployeeId());   // 制单=当前登录用户（报表按 maker_id 解析制单员）
        paymentRepo.save(p);
        List<FinancePaymentLineDto> items = saveLines(p, req.getItems());
        applyLineTotals(p, items);
        return toDetail(p, items);
    }

    @Transactional
    public FinancePaymentDetail update(UUID id, FinancePaymentSaveRequest req) {
        tx.bind();
        FinancePayment p = require(id);
        if (p.getStatus() != STATUS_DRAFT) {
            throw new ApiException(ErrorCode.BUSINESS, "仅草稿单据可编辑");
        }
        assertBillNoFree(req.getBillNo(), id);
        applyHeader(req, p);
        lineRepo.deleteByPaymentId(id);
        lineRepo.flush();
        List<FinancePaymentLineDto> items = saveLines(p, req.getItems());
        applyLineTotals(p, items);
        return toDetail(p, items);
    }

    @Transactional
    public void delete(UUID id) {
        tx.bind();
        FinancePayment p = require(id);
        if (p.getStatus() == STATUS_APPROVED) {
            throw new ApiException(ErrorCode.BUSINESS, "已审核单据不可删，请红冲");
        }
        p.setDeleted(true);
        p.setDeletedAt(OffsetDateTime.now());
        paymentRepo.save(p);
    }

    /** 审核：status 0→1，核销 AP / 直接付款 / 账户扣减 / 写流水。 */
    @Transactional
    public FinancePaymentDetail approve(UUID id) {
        tx.bind();
        FinancePayment p = require(id);
        em.refresh(p, jakarta.persistence.LockModeType.PESSIMISTIC_WRITE); // M28：强制 SELECT...FOR UPDATE 重读字段，防陈旧状态绕过守卫
        if (p.getStatus() == null || p.getStatus() != STATUS_DRAFT) {
            throw new ApiException(ErrorCode.BUSINESS, "仅草稿单据可审核");
        }
        if (p.getAccountId() == null) {
            throw new ApiException(ErrorCode.BUSINESS, "付款单需指定付款账户");
        }
        assertNoExistingPosting(p.getId()); // M19：幂等护栏，finance_reconciliations 已存在该单流水则禁止重复审核
        UUID approver = currentUser.requireEmployeeId(); // 审核=当前登录用户（报表按 approver_id 解析审核员）
        if (p.getMakerId() != null && p.getMakerId().equals(approver)) {
            throw new ApiException(ErrorCode.BUSINESS, "制单人与审核人不可相同（职责分离）");
        }
        p.setApproverId(approver);
        settlePayment(p);
        p.setStatus(STATUS_APPROVED);
        p.setCancelDate(OffsetDateTime.now());
        paymentRepo.save(p);
        return detail(id);
    }

    /** 红冲：status 1→-1，反向冲销。 */
    @Transactional
    public FinancePaymentDetail reverse(UUID id) {
        tx.bind();
        FinancePayment p = require(id);
        em.refresh(p, jakarta.persistence.LockModeType.PESSIMISTIC_WRITE); // M28：强制 SELECT...FOR UPDATE 重读字段，防陈旧状态绕过守卫
        if (p.getStatus() == null || p.getStatus() != STATUS_APPROVED) {
            throw new ApiException(ErrorCode.BUSINESS, "仅已审核单据可红冲");
        }
        assertCompletePosting(p.getId(), 1L); // M19：红冲前确认流水完整（付款每单恰 1 行）
        reverseSettlement(p);
        p.setStatus(STATUS_REVERSED);
        paymentRepo.save(p);
        return detail(id);
    }

    // ===================== 核销逻辑（取代老库 TRI_M_Paid_B_M_Out） =====================

    private void settlePayment(FinancePayment p) {
        List<FinancePaymentLine> lines = lineRepo.findByPaymentIdOrderByLineNoAsc(p.getId());
        Map<UUID, ArApLedger> lockedLedgers = lines.isEmpty()
                ? Map.of()
                : lockAppliedLedgers(lines);
        if (!lines.isEmpty()) {
            applyLineTotals(p, lines.stream().map(this::toLineDto).toList());
        }
        BigDecimal amountLocal = nz(p.getAmountLocal());
        if (amountLocal.signum() == 0) {
            throw new ApiException(ErrorCode.BUSINESS, "付款金额必须非零");
        }
        if (!lines.isEmpty()) {
            for (FinancePaymentLine ln : lines) {
                ArApLedger led = lockedLedgers.get(ln.getAppliedLedgerId());
                if (!"AP".equals(led.getDirection())) {
                    throw new ApiException(ErrorCode.BUSINESS, "付款只能核销 AP 行，传入方向=" + led.getDirection());
                }
                if (p.getSupplierId() == null || !Objects.equals(p.getSupplierId(), led.getSupplierId())
                        || (ln.getSupplierId() != null
                        && !Objects.equals(p.getSupplierId(), ln.getSupplierId()))) {
                    throw new ApiException(ErrorCode.CONFLICT, "付款供应商与应付台账供应商不一致");
                }
                BigDecimal origLocal = nz(led.getAmountOriginalLocal());
                BigDecimal lineAmt = nz(ln.getAmountLocal());
                if (lineAmt.signum() == 0) {
                    throw new ApiException(ErrorCode.BUSINESS, "核销金额必须非零");
                }
                BigDecimal newSettled = nz(led.getAmountSettled()).add(lineAmt);
                // ②b 防止用正数 line 核销红字负 AP（方向不一致会让 balance 数学错 + refreshSettlement 误判结清）
                if (origLocal.signum() != 0 && lineAmt.signum() != 0 && origLocal.signum() != lineAmt.signum()) {
                    throw new ApiException(ErrorCode.BUSINESS, "核销金额方向与应付余额方向不一致，红字应付须用同向金额核销");
                }
                // M9：预付立帐行（DIRECT_PAYMENT，原值=0）不得作为明细核销目标，
                // 否则 amount_settled 会被后续单据无界累加导致余额膨胀。预付款不参与核销循环。
                if (SRC_DIRECT_PAYMENT.equals(led.getSourceDocType())) {
                    throw new ApiException(ErrorCode.CONFLICT, "预付不能作为核销目标");
                }
                // ②a 超核校验：累计 settled 不得超过 original。
                if (exceedsOriginal(origLocal, newSettled)) {
                    throw new ApiException(ErrorCode.BUSINESS, "核销金额超过应付余额");
                }
                led.setAmountSettled(newSettled);
                led.setAmountBalance(origLocal.subtract(newSettled));
                refreshSettlement(led);
                ledgerRepo.save(led);
            }
        } else {
            // M6：直接付款（无明细）金额必须大于 0，防止负数造出"供应商多欠 + 现金减少"。
            if (amountLocal.signum() <= 0) {
                throw new ApiException(ErrorCode.BUSINESS, "直接付款金额必须大于 0");
            }
            // 直接付款 / 供应商预付：建 DIRECT_PAYMENT 立帐行（amount=0），再置 settled/balance
            arApService.postArAp(new ArApLedgerService.ArApPostingRequest(
                    "AP", SRC_DIRECT_PAYMENT, p.getId(), p.getBillNo(), p.getBillDate(),
                    null, p.getSupplierId(), p.getCurrencyId(), p.getExchangeRate(),
                    BigDecimal.ZERO, (short) 21, "直接付款"));
            List<ArApLedger> created = ledgerRepo.findBySourceForUpdate(
                    p.getId(), SRC_DIRECT_PAYMENT);
            if (created.size() != 1) {
                throw new ApiException(ErrorCode.CONFLICT, "直接付款立账结果不唯一");
            }
            ArApLedger led = created.getFirst();
            led.setAmountSettled(amountLocal);
            led.setAmountBalance(nz(led.getAmountOriginalLocal()).subtract(amountLocal));
            refreshSettlement(led);
            ledgerRepo.save(led);
        }
        if (amountLocal.signum() != 0) {
            adjustAccount(p.getAccountId(), amountLocal);
        }
        insertReconciliation(p, amountLocal);
    }

    private void reverseSettlement(FinancePayment p) {
        List<FinancePaymentLine> lines = lineRepo.findByPaymentIdOrderByLineNoAsc(p.getId());
        BigDecimal amountLocal = nz(p.getAmountLocal());
        if (!lines.isEmpty()) {
            Map<UUID, ArApLedger> lockedLedgers = lockAppliedLedgers(lines);
            for (FinancePaymentLine ln : lines) {
                ArApLedger led = lockedLedgers.get(ln.getAppliedLedgerId());
                if (!"AP".equals(led.getDirection())
                        || !Objects.equals(p.getSupplierId(), led.getSupplierId())) {
                    throw new ApiException(ErrorCode.CONFLICT, "付款反核销来源已不一致");
                }
                led.setAmountSettled(nz(led.getAmountSettled()).subtract(nz(ln.getAmountLocal())));
                led.setAmountBalance(nz(led.getAmountOriginalLocal()).subtract(led.getAmountSettled()));
                refreshSettlement(led);
                ledgerRepo.save(led);
            }
        } else {
            List<ArApLedger> rows = ledgerRepo.findBySourceForUpdate(
                    p.getId(), SRC_DIRECT_PAYMENT);
            if (rows.size() != 1) {
                throw new ApiException(ErrorCode.CONFLICT, "直接付款反立账来源缺失或重复");
            }
            for (ArApLedger led : rows) {
                ledgerRepo.delete(led);
            }
        }
        if (amountLocal.signum() != 0) {
            adjustAccount(p.getAccountId(), amountLocal.negate());
        }
        deleteReconciliation(p.getId());
    }

    /**
     * 对齐 V129 数据库约束：仅余额恰好为零时结清。DIRECT_PAYMENT 的负余额
     * 表示仍可使用的供应商预付款，保持未结清。
     */
    private void refreshSettlement(ArApLedger led) {
        BigDecimal bal = nz(led.getAmountBalance());
        boolean settled = bal.signum() == 0;
        led.setSettled(settled);
        led.setSettledDate(
                settled ? (led.getBillDate() != null ? led.getBillDate() : BusinessTime.today()) : null);
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
        payment.setAmountLocal(local);
        payment.setAmountOriginal(original);
        paymentRepo.save(payment);
    }

    private static boolean exceedsOriginal(BigDecimal original, BigDecimal settled) {
        if (original.signum() > 0) {
            return settled.compareTo(original) > 0;
        }
        if (original.signum() < 0) {
            return settled.compareTo(original) < 0;
        }
        return settled.signum() != 0;
    }

    /** 付款账户扣减（money-out）：balance_current -= delta, payments_total += delta（delta 已带符号）。 */
    private void adjustAccount(UUID accountId, BigDecimal delta) {
        // delta = +amount_local（审核）/ -amount_local（红冲）。balance_current 受 delta 反向影响（付款减余额）。
        int rows = em.createNativeQuery("""
                UPDATE accounts
                SET balance_current = COALESCE(balance_current, 0) - :amt,
                    payments_total  = COALESCE(payments_total, 0) + :amt,
                    updated_at = now()
                WHERE id = :id
                  AND COALESCE(is_deleted, false) = false
                  AND status = '使用'
                """)
                .setParameter("amt", delta)
                .setParameter("id", accountId)
                .executeUpdate();
        if (rows == 0) {
            throw new ApiException(ErrorCode.BUSINESS, "账户不存在或已禁用：" + accountId);
        }
    }

    private void insertReconciliation(FinancePayment p, BigDecimal amountLocal) {
        String counterpart = p.getSupplierId() == null ? null : lookupSupplierName(p.getSupplierId());
        em.createNativeQuery("""
                INSERT INTO finance_reconciliations
                  (bill_no, source_doc_type, source_doc_id, account_id, check_no, counterpart_name,
                   in_amount, out_amount, bill_date, settled_date, source_remark, legacy_bstyle, created_at, updated_at, is_deleted)
                VALUES (:billNo, :src, :sid, :acc, :chk, :cpn, 0, :outAmt, :bd, :sd, :sr, 21, now(), now(), false)
                """)
                .setParameter("billNo", p.getBillNo())
                .setParameter("src", RECON_SOURCE)
                .setParameter("sid", p.getId())
                .setParameter("acc", p.getAccountId())
                .setParameter("chk", p.getInvoiceNo())
                .setParameter("cpn", counterpart)
                .setParameter("outAmt", amountLocal)
                .setParameter("bd", p.getBillDate().atStartOfDay(java.time.ZoneOffset.UTC).toOffsetDateTime()) // M17：bill_date 用单据日期，settled_date 保持审核时刻
                .setParameter("sd", OffsetDateTime.now())
                .setParameter("sr", p.getSourceRemark())
                .executeUpdate();
    }

    private void deleteReconciliation(UUID paymentId) {
        em.createNativeQuery(
                "DELETE FROM finance_reconciliations WHERE source_doc_id = :sid AND source_doc_type = :src")
                .setParameter("sid", paymentId)
                .setParameter("src", RECON_SOURCE)
                .executeUpdate();
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
                    "付款流水不完整，禁止红冲（期望 " + expectedRows + "，实际 " + actual + "）");
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
        if (req.getExchangeRate() != null) p.setExchangeRate(req.getExchangeRate());
        if (req.getAmountOriginal() != null) p.setAmountOriginal(req.getAmountOriginal());
        if (req.getAmountLocal() != null) p.setAmountLocal(req.getAmountLocal());
        p.setPaymentMethodId(req.getPaymentMethodId());
        p.setPaymentMethodLegacyId(req.getPaymentMethodLegacyId());
        p.setInvoiceNo(req.getInvoiceNo());
        p.setOperatorName(req.getOperatorName());
        p.setOperatorId(req.getOperatorId());
        p.setSourceRemark(req.getSourceRemark());
        p.setRemark(req.getRemark());
    }

    private List<FinancePaymentLineDto> saveLines(FinancePayment p, List<FinancePaymentLineInput> inputs) {
        // FIN-P2-4（路线图，未实现）：exchange_diff 当前完全由前端传入，服务端零校验/零计算。
        // 完整汇兑损益（FX gain/loss）需在审核（settlePayment）时按 ar_ap_ledger.exchange_rate
        // 与 payments.exchange_rate 派生，并落账到汇兑损益科目——独立大特性，不在本次数据完整性
        // 修复范围。当前仅原样落库，不做符号/数值校验（避免误拒历史合法行）。
        // TODO: 排入钱流 FX 模块路线图后补服务端校验 + GL 过账。
        if (inputs == null || inputs.isEmpty()) return List.of();
        List<FinancePaymentLineDto> out = new ArrayList<>(inputs.size());
        int auto = 1;
        for (FinancePaymentLineInput l : inputs) {
            FinancePaymentLine ln = new FinancePaymentLine();
            ln.setPaymentId(p.getId());
            ln.setBillNo(p.getBillNo());
            ln.setBillDate(p.getBillDate());
            ln.setLineNo(l.getLineNo() != null ? l.getLineNo() : auto);
            ln.setAppliedLedgerId(l.getAppliedLedgerId());
            ln.setAppliedBillNo(l.getAppliedBillNo());
            ln.setSupplierId(l.getSupplierId() != null ? l.getSupplierId() : p.getSupplierId());
            ln.setAmountOriginal(l.getAmountOriginal());
            ln.setAmountLocal(l.getAmountLocal());
            ln.setExchangeDiff(l.getExchangeDiff());
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
                ln.getExchangeDiff(), ln.getRemark());
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
                nameResolver.nameOf(p.getMakerId()), p.getCreatedAt());
    }

    private FinancePayment require(UUID id) {
        return paymentRepo.findById(id).filter(p -> !p.isDeleted())
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "采购付款单不存在"));
    }

    private static BigDecimal nz(BigDecimal x) {
        return x == null ? BigDecimal.ZERO : x;
    }
}
