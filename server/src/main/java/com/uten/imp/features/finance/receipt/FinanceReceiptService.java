package com.uten.imp.features.finance.receipt;

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
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.UUID;

/**
 * 销售收款单服务：CRUD（主 + 明细）+ 审核状态机（核销 AR / 直接收款 / 账户累加 / 写流水）。
 *
 * <p>审核（status 0→1）调用 {@link #settleReceipt}：取代老库 TRI_M_get_B_M_in + TRI_GatheringCheck 触发器。
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

    @Transactional(readOnly = true)
    public PageResponse<FinanceReceiptListItem> list(FinanceReceiptQueryFilter f, int page, int size, String sort, String order) {
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
        Pageable pageable = Pageables.of(page, size,
                TableSort.resolve(sort, order, Sort.by(Sort.Direction.DESC, "billDate"), ALLOWED_SORT));
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
        r.setMakerId(currentUser.requireEmployeeId());   // 制单=当前登录用户（报表按 maker_id 解析制单员）
        receiptRepo.save(r);
        List<FinanceReceiptLineDto> items = saveLines(r, req.getItems());
        applyLineTotals(r, items);
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
        applyLineTotals(r, items);
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
        em.refresh(r, jakarta.persistence.LockModeType.PESSIMISTIC_WRITE); // M28：强制 SELECT...FOR UPDATE 重读字段，防陈旧状态绕过守卫
        if (r.getStatus() == null || r.getStatus() != STATUS_DRAFT) {
            throw new ApiException(ErrorCode.BUSINESS, "仅草稿单据可审核");
        }
        if (r.getAccountId() == null) {
            throw new ApiException(ErrorCode.BUSINESS, "收款单需指定收款账户");
        }
        assertNoExistingPosting(r.getId()); // M19：幂等护栏，finance_reconciliations 已存在该单流水则禁止重复审核
        UUID approver = currentUser.requireEmployeeId(); // 审核=当前登录用户（报表按 approver_id 解析审核员）
        if (r.getMakerId() != null && r.getMakerId().equals(approver)) {
            throw new ApiException(ErrorCode.BUSINESS, "制单人与审核人不可相同（职责分离）");
        }
        r.setApproverId(approver);
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
        em.refresh(r, jakarta.persistence.LockModeType.PESSIMISTIC_WRITE); // M28：强制 SELECT...FOR UPDATE 重读字段，防陈旧状态绕过守卫
        if (r.getStatus() == null || r.getStatus() != STATUS_APPROVED) {
            throw new ApiException(ErrorCode.BUSINESS, "仅已审核单据可红冲");
        }
        assertCompletePosting(r.getId(), 1L); // M19：红冲前确认流水完整（收款每单恰 1 行）
        reverseSettlement(r);
        r.setStatus(STATUS_REVERSED);
        receiptRepo.save(r);
        return detail(id);
    }

    // ===================== 核销逻辑（取代老库 TRI_M_get_B_M_in） =====================

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
        if (amountLocal.signum() == 0) {
            throw new ApiException(ErrorCode.BUSINESS, "收款金额必须非零");
        }
        if (!lines.isEmpty()) {
            for (FinanceReceiptLine ln : lines) {
                ArApLedger led = lockedLedgers.get(ln.getAppliedLedgerId());
                if (!"AR".equals(led.getDirection())) {
                    throw new ApiException(ErrorCode.BUSINESS, "收款只能核销 AR 行，传入方向=" + led.getDirection());
                }
                if (r.getClientId() == null || !Objects.equals(r.getClientId(), led.getClientId())
                        || (ln.getClientId() != null
                        && !Objects.equals(r.getClientId(), ln.getClientId()))) {
                    throw new ApiException(ErrorCode.CONFLICT, "收款客户与应收台账客户不一致");
                }
                BigDecimal origLocal = nz(led.getAmountOriginalLocal());
                BigDecimal lineAmt = nz(ln.getAmountLocal());
                if (lineAmt.signum() == 0) {
                    throw new ApiException(ErrorCode.BUSINESS, "核销金额必须非零");
                }
                BigDecimal newSettled = nz(led.getAmountSettled()).add(lineAmt);
                // ②b 防止用正数 line 核销红字负 AR（方向不一致会让 balance 数学错 + refreshSettlement 误判结清）
                if (origLocal.signum() != 0 && lineAmt.signum() != 0 && origLocal.signum() != lineAmt.signum()) {
                    throw new ApiException(ErrorCode.BUSINESS, "核销金额方向与应收余额方向不一致，红字应收须用同向金额核销");
                }
                // M9：预收立帐行（DIRECT_RECEIPT，原值=0）不得作为明细核销目标，
                // 否则 amount_settled 会被后续单据无界累加导致余额膨胀。预收款不参与核销循环。
                if (SRC_DIRECT_RECEIPT.equals(led.getSourceDocType())) {
                    throw new ApiException(ErrorCode.CONFLICT, "预收不能作为核销目标");
                }
                // ②a 超核校验：累计 settled 不得超过 original。
                if (exceedsOriginal(origLocal, newSettled)) {
                    throw new ApiException(ErrorCode.BUSINESS, "核销金额超过应收余额");
                }
                led.setAmountSettled(newSettled);
                led.setAmountBalance(origLocal.subtract(newSettled));
                refreshSettlement(led);
                ledgerRepo.save(led);
            }
        } else {
            // M6：直接收款（无明细）金额必须大于 0，防止负数造出"客户多欠 + 现金减少"。
            if (amountLocal.signum() <= 0) {
                throw new ApiException(ErrorCode.BUSINESS, "直接收款金额必须大于 0");
            }
            // 直接收款 / 客户预付：建 DIRECT_RECEIPT 立帐行（amount=0），再置 settled=amount_local、balance=-amount_local
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
            led.setAmountSettled(amountLocal);
            led.setAmountBalance(nz(led.getAmountOriginalLocal()).subtract(amountLocal));
            refreshSettlement(led);
            ledgerRepo.save(led);
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
            Map<UUID, ArApLedger> lockedLedgers = lockAppliedLedgers(lines);
            for (FinanceReceiptLine ln : lines) {
                ArApLedger led = lockedLedgers.get(ln.getAppliedLedgerId());
                if (!"AR".equals(led.getDirection())
                        || !Objects.equals(r.getClientId(), led.getClientId())) {
                    throw new ApiException(ErrorCode.CONFLICT, "收款反核销来源已不一致");
                }
                led.setAmountSettled(nz(led.getAmountSettled()).subtract(nz(ln.getAmountLocal())));
                led.setAmountBalance(nz(led.getAmountOriginalLocal()).subtract(led.getAmountSettled()));
                refreshSettlement(led);
                ledgerRepo.save(led);
            }
        } else {
            // 直接收款红冲：删本单建的直接收款立帐行（不经 reverseArAp，因其 amount_settled<>0 会被拦）
            List<ArApLedger> rows = ledgerRepo.findBySourceForUpdate(r.getId(), SRC_DIRECT_RECEIPT);
            if (rows.size() != 1) {
                throw new ApiException(ErrorCode.CONFLICT, "直接收款反立账来源缺失或重复");
            }
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
     * 自动结清维护（对齐 V129 数据库约束）：仅 balance = 0 时
     * {@code is_settled=true}。DIRECT_RECEIPT 的负余额表示仍可使用的客户预收款，
     * 必须保持未结清，不能混同为普通应收已核销。
     */
    private void refreshSettlement(ArApLedger led) {
        BigDecimal bal = nz(led.getAmountBalance());
        boolean settled = bal.signum() == 0;
        led.setSettled(settled);
        led.setSettledDate(
                settled ? (led.getBillDate() != null ? led.getBillDate() : BusinessTime.today()) : null);
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
        receiptRepo.save(receipt);
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
        if (req.getExchangeRate() != null) r.setExchangeRate(req.getExchangeRate());
        if (req.getAmountOriginal() != null) {
            r.setAmountOriginal(req.getAmountOriginal());
            // 金额服务端权威重算（4 位 HALF_UP）：本币额 = 原币额 × 汇率，忽略客户端 amountLocal，
            // 防止篡改本币额进而影响 AR 核销与账户增减（与 M1 银行转账服务端权威同型）。
            java.math.BigDecimal rate = r.getExchangeRate() != null
                    ? r.getExchangeRate() : java.math.BigDecimal.ONE;
            r.setAmountLocal(req.getAmountOriginal().multiply(rate)
                    .setScale(4, java.math.RoundingMode.HALF_UP));
        } else if (req.getAmountLocal() != null) {
            r.setAmountLocal(req.getAmountLocal());
        }
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
        // FIN-P2-4（路线图，未实现）：exchange_diff 当前完全由前端传入，服务端零校验/零计算。
        // 完整汇兑损益（FX gain/loss）= applied_ledger.amount_original_local（开账本币）与
        // amount_local（本次核销本币）按汇率差轧差，需在审核（settleReceipt）时根据
        // ar_ap_ledger.exchange_rate + receipts.exchange_rate 派生并落账到汇兑损益科目——
        // 是独立大特性，不在本次数据完整性修复范围。当前仅原样落库，不做符号/数值校验
        // （避免误拒历史合法行）。TODO: 排入钱流 FX 模块路线图后补服务端校验 + GL 过账。
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
                r.getSourceRemark(), r.getRemark(), r.getStatus(), r.isClosed(), items,
                nameResolver.nameOf(r.getMakerId()), r.getCreatedAt());
    }

    private FinanceReceipt require(UUID id) {
        return receiptRepo.findById(id).filter(r -> !r.isDeleted())
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "销售收款单不存在"));
    }

    private static BigDecimal nz(BigDecimal x) {
        return x == null ? BigDecimal.ZERO : x;
    }
}
