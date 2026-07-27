package com.uten.imp.features.finance.receipt;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.common.web.Pageables;
import com.uten.imp.features.finance.arap.ArApLedger;
import com.uten.imp.features.finance.arap.ArApLedgerRepository;
import com.uten.imp.features.finance.arap.ArApLedgerService;
import com.uten.imp.features.finance.receipt.dto.FinanceReceiptDetail;
import com.uten.imp.features.finance.receipt.dto.FinanceReceiptLineDto;
import com.uten.imp.features.finance.receipt.dto.FinanceReceiptLineInput;
import com.uten.imp.features.finance.receipt.dto.FinanceReceiptListItem;
import com.uten.imp.features.finance.receipt.dto.FinanceReceiptQueryFilter;
import com.uten.imp.features.finance.receipt.dto.FinanceReceiptSaveRequest;
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
import java.util.List;
import java.util.UUID;

/**
 * 销售收款单服务：CRUD（主 + 明细）+ 审核状态机（核销 AR / 直接收款 / 账户累加 / 写流水）。
 *
 * <p>审核（status 0→1）调用 {@link #settleReceipt}：取代老库 TRI_M_get_B_M_in + TRI_GatheringCheck 触发器。
 * <ul>
 *   <li>明细非空（指定核销 AR）：每行 {@code applied_ledger_id} 回写 ar_ap_ledger.amount_settled += line.amount_local
 *       + amount_balance 重算 + balance ≤ 0 自动 is_settled=true。</li>
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
    private final EntityManager em;

    @Transactional(readOnly = true)
    public PageResponse<FinanceReceiptListItem> list(FinanceReceiptQueryFilter f, int page, int size) {
        Specification<FinanceReceipt> spec = (Root<FinanceReceipt> root, jakarta.persistence.criteria.CriteriaQuery<?> q,
                                              CriteriaBuilder cb) -> {
            List<Predicate> ps = new ArrayList<>();
            ps.add(cb.isFalse(root.get("deleted")));
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
        Pageable pageable = Pageables.of(page, size, Sort.by(Sort.Direction.DESC, "billDate"));
        Page<FinanceReceipt> p = receiptRepo.findAll(spec, pageable);
        return new PageResponse<>(p.map(this::toList).getContent(), page, size, p.getTotalElements(), p.getTotalPages());
    }

    @Transactional(readOnly = true)
    public FinanceReceiptDetail detail(UUID id) {
        FinanceReceipt r = require(id);
        List<FinanceReceiptLineDto> items = lineRepo.findByReceiptIdOrderByLineNoAsc(id).stream()
                .map(this::toLineDto).toList();
        return toDetail(r, items);
    }

    @Transactional
    public FinanceReceiptDetail create(FinanceReceiptSaveRequest req) {
        tx.bind();
        assertBillNoFree(req.getBillNo(), null);
        FinanceReceipt r = new FinanceReceipt();
        applyHeader(req, r);
        r.setStatus(STATUS_DRAFT);
        r.setMakerId(currentUser.requireId());   // 制单=当前登录用户（报表按 maker_id 解析制单员）
        receiptRepo.save(r);
        List<FinanceReceiptLineDto> items = saveLines(r, req.getItems());
        return toDetail(r, items);
    }

    @Transactional
    public FinanceReceiptDetail update(UUID id, FinanceReceiptSaveRequest req) {
        tx.bind();
        FinanceReceipt r = require(id);
        if (r.getStatus() != STATUS_DRAFT) {
            throw new ApiException(ErrorCode.BUSINESS, "仅草稿单据可编辑");
        }
        assertBillNoFree(req.getBillNo(), id);
        applyHeader(req, r);
        lineRepo.deleteByReceiptId(id);
        lineRepo.flush();
        List<FinanceReceiptLineDto> items = saveLines(r, req.getItems());
        return toDetail(r, items);
    }

    @Transactional
    public void delete(UUID id) {
        tx.bind();
        FinanceReceipt r = require(id);
        if (r.getStatus() == STATUS_APPROVED) {
            throw new ApiException(ErrorCode.BUSINESS, "已审核单据不可删，请红冲");
        }
        r.setDeleted(true);
        r.setDeletedAt(OffsetDateTime.now());
        receiptRepo.save(r);
    }

    /** 审核：status 0→1，核销 AR / 直接收款 / 账户累加 / 写流水。 */
    @Transactional
    public FinanceReceiptDetail approve(UUID id) {
        tx.bind();
        FinanceReceipt r = require(id);
        if (r.getStatus() == null || r.getStatus() != STATUS_DRAFT) {
            throw new ApiException(ErrorCode.BUSINESS, "仅草稿单据可审核");
        }
        if (r.getAccountId() == null) {
            throw new ApiException(ErrorCode.BUSINESS, "收款单需指定收款账户");
        }
        r.setApproverId(currentUser.requireId()); // 审核=当前登录用户（报表按 approver_id 解析审核员）
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
        FinanceReceipt r = require(id);
        if (r.getStatus() == null || r.getStatus() != STATUS_APPROVED) {
            throw new ApiException(ErrorCode.BUSINESS, "仅已审核单据可红冲");
        }
        reverseSettlement(r);
        r.setStatus(STATUS_REVERSED);
        receiptRepo.save(r);
        return detail(id);
    }

    // ===================== 核销逻辑（取代老库 TRI_M_get_B_M_in） =====================

    /** 审核核销：lines 非空 → 累加 AR 核销；lines 空 → postArAp 建 DIRECT_RECEIPT 行。 */
    private void settleReceipt(FinanceReceipt r) {
        List<FinanceReceiptLine> lines = lineRepo.findByReceiptIdOrderByLineNoAsc(r.getId());
        BigDecimal amountLocal = nz(r.getAmountLocal());
        if (!lines.isEmpty()) {
            for (FinanceReceiptLine ln : lines) {
                if (ln.getAppliedLedgerId() == null) continue;
                ArApLedger led = ledgerRepo.findById(ln.getAppliedLedgerId())
                        .filter(x -> !x.isDeleted())
                        .orElseThrow(() -> new ApiException(ErrorCode.BUSINESS, "核销的应收记录不存在：" + ln.getAppliedLedgerId()));
                if (!"AR".equals(led.getDirection())) {
                    throw new ApiException(ErrorCode.BUSINESS, "收款只能核销 AR 行，传入方向=" + led.getDirection());
                }
                BigDecimal origLocal = nz(led.getAmountOriginalLocal());
                BigDecimal lineAmt = nz(ln.getAmountLocal());
                BigDecimal newSettled = nz(led.getAmountSettled()).add(lineAmt);
                // ②b 防止用正数 line 核销红字负 AR（方向不一致会让 balance 数学错 + refreshSettlement 误判结清）
                if (origLocal.signum() != 0 && lineAmt.signum() != 0 && origLocal.signum() != lineAmt.signum()) {
                    throw new ApiException(ErrorCode.BUSINESS, "核销金额方向与应收余额方向不一致，红字应收须用同向金额核销");
                }
                // ②a 超核校验：累计 settled 不得超过 original。DIRECT_RECEIPT（预付款）原值=0 走 else 分支不进此循环，
                // 这里仍防御性地排除，避免把 receipt_line 错挂到 DIRECT_RECEIPT 立帐行上。
                if (!SRC_DIRECT_RECEIPT.equals(led.getSourceDocType())
                        && origLocal.signum() > 0 && newSettled.compareTo(origLocal) > 0) {
                    throw new ApiException(ErrorCode.BUSINESS, "核销金额超过应收余额");
                }
                led.setAmountSettled(newSettled);
                led.setAmountBalance(origLocal.subtract(newSettled));
                refreshSettlement(led);
                ledgerRepo.save(led);
            }
        } else {
            // 直接收款 / 客户预付：建 DIRECT_RECEIPT 立帐行（amount=0），再置 settled=amount_local、balance=-amount_local
            arApService.postArAp(new ArApLedgerService.ArApPostingRequest(
                    "AR", SRC_DIRECT_RECEIPT, r.getId(), r.getBillNo(), r.getBillDate(),
                    r.getClientId(), null, r.getCurrencyId(), r.getExchangeRate(),
                    BigDecimal.ZERO, (short) 20, "直接收款"));
            List<ArApLedger> created = ledgerRepo.findBySourceDocIdAndSourceDocTypeAndDeletedFalse(
                    r.getId(), SRC_DIRECT_RECEIPT);
            if (!created.isEmpty()) {
                ArApLedger led = created.get(created.size() - 1);
                led.setAmountSettled(amountLocal);
                led.setAmountBalance(nz(led.getAmountOriginalLocal()).subtract(amountLocal));
                refreshSettlement(led);
                ledgerRepo.save(led);
            }
        }
        // 账户累加 + 写流水
        if (amountLocal.signum() != 0) {
            adjustAccount(r.getAccountId(), amountLocal);
        }
        insertReconciliation(r, amountLocal);
    }

    /** 红冲反向：lines 非空 → 回减 AR 核销；lines 空 → 删 DIRECT_RECEIPT 立帐行。 */
    private void reverseSettlement(FinanceReceipt r) {
        List<FinanceReceiptLine> lines = lineRepo.findByReceiptIdOrderByLineNoAsc(r.getId());
        BigDecimal amountLocal = nz(r.getAmountLocal());
        if (!lines.isEmpty()) {
            for (FinanceReceiptLine ln : lines) {
                if (ln.getAppliedLedgerId() == null) continue;
                ArApLedger led = ledgerRepo.findById(ln.getAppliedLedgerId())
                        .filter(x -> !x.isDeleted()).orElse(null);
                if (led == null) continue;
                led.setAmountSettled(nz(led.getAmountSettled()).subtract(nz(ln.getAmountLocal())));
                led.setAmountBalance(nz(led.getAmountOriginalLocal()).subtract(led.getAmountSettled()));
                refreshSettlement(led);
                ledgerRepo.save(led);
            }
        } else {
            // 直接收款红冲：删本单建的直接收款立帐行（不经 reverseArAp，因其 amount_settled<>0 会被拦）
            List<ArApLedger> rows = ledgerRepo.findBySourceDocIdAndSourceDocTypeAndDeletedFalse(
                    r.getId(), SRC_DIRECT_RECEIPT);
            for (ArApLedger led : rows) {
                ledgerRepo.delete(led);
            }
        }
        if (amountLocal.signum() != 0) {
            adjustAccount(r.getAccountId(), amountLocal.negate());
        }
        deleteReconciliation(r.getId());
    }

    /**
     * 自动结清维护（取代老库 TRI_GatheringCheck）：balance ≤ 0 → is_settled=true, settled_date=billDate；
     * balance > 0 → is_settled=false, settled_date=null。DIRECT_RECEIPT 负 balance 也视为结清（客户已预付）。
     */
    private void refreshSettlement(ArApLedger led) {
        BigDecimal bal = nz(led.getAmountBalance());
        boolean settled = bal.signum() <= 0;
        led.setSettled(settled);
        led.setSettledDate(settled ? (led.getBillDate() != null ? led.getBillDate() : LocalDate.now()) : null);
    }

    /**
     * 累加账户余额 + receipts_total（收款方）。
     *
     * <p>{@code delta} 已带符号：审核 +amount_local / 红冲 -amount_local。收款仅影响 receipts_total（不影响 payments_total）。
     */
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

    private void insertReconciliation(FinanceReceipt r, BigDecimal amountLocal) {
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
                .setParameter("inAmt", amountLocal)
                .setParameter("bd", OffsetDateTime.now())
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

    private String lookupClientName(UUID clientId) {
        try {
            Object r = em.createNativeQuery("SELECT name FROM clients WHERE id = :id AND COALESCE(is_deleted, false) = false")
                    .setParameter("id", clientId).getSingleResult();
            return r == null ? null : r.toString();
        } catch (Exception ignored) {
            return null;
        }
    }

    // ===================== CRUD 辅助 =====================

    private void applyHeader(FinanceReceiptSaveRequest req, FinanceReceipt r) {
        r.setBillNo(req.getBillNo());
        r.setBillDate(req.getBillDate());
        r.setClientId(req.getClientId());
        r.setAccountId(req.getAccountId());
        r.setCounterpartAccountId(req.getCounterpartAccountId());
        r.setCurrencyId(req.getCurrencyId());
        if (req.getExchangeRate() != null) r.setExchangeRate(req.getExchangeRate());
        if (req.getAmountOriginal() != null) r.setAmountOriginal(req.getAmountOriginal());
        if (req.getAmountLocal() != null) r.setAmountLocal(req.getAmountLocal());
        if (req.getBankFee() != null) r.setBankFee(req.getBankFee());
        if (req.getOtherFee() != null) r.setOtherFee(req.getOtherFee());
        r.setOtherFeeStyleId(req.getOtherFeeStyleId());
        r.setReceiptMethodId(req.getReceiptMethodId());
        r.setReceiptMethodLegacyId(req.getReceiptMethodLegacyId());
        r.setInvoiceNo(req.getInvoiceNo());
        r.setOperatorId(req.getOperatorId());
        r.setSourceRemark(req.getSourceRemark());
        r.setRemark(req.getRemark());
    }

    private List<FinanceReceiptLineDto> saveLines(FinanceReceipt r, List<FinanceReceiptLineInput> inputs) {
        if (inputs == null || inputs.isEmpty()) return List.of();
        List<FinanceReceiptLineDto> out = new ArrayList<>(inputs.size());
        int auto = 1;
        for (FinanceReceiptLineInput l : inputs) {
            FinanceReceiptLine ln = new FinanceReceiptLine();
            ln.setReceiptId(r.getId());
            ln.setBillNo(r.getBillNo());
            ln.setBillDate(r.getBillDate());
            ln.setLineNo(l.getLineNo() != null ? l.getLineNo() : auto);
            ln.setAppliedLedgerId(l.getAppliedLedgerId());
            ln.setAppliedBillNo(l.getAppliedBillNo());
            ln.setClientId(l.getClientId() != null ? l.getClientId() : r.getClientId());
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
        receiptRepo.findByBillNo(billNo).ifPresent(existing -> {
            if (excludeId == null || !existing.getId().equals(excludeId)) {
                throw new ApiException(ErrorCode.CONFLICT, "单号已存在：" + billNo);
            }
        });
    }

    private FinanceReceiptLineDto toLineDto(FinanceReceiptLine ln) {
        return new FinanceReceiptLineDto(ln.getId(), ln.getLineNo(), ln.getAppliedLedgerId(),
                ln.getAppliedBillNo(), ln.getClientId(), ln.getAmountOriginal(), ln.getAmountLocal(),
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
                r.getSourceRemark(), r.getRemark(), r.getStatus(), r.isClosed(), items);
    }

    private FinanceReceipt require(UUID id) {
        return receiptRepo.findById(id).filter(r -> !r.isDeleted())
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "销售收款单不存在"));
    }

    private static BigDecimal nz(BigDecimal x) {
        return x == null ? BigDecimal.ZERO : x;
    }
}
