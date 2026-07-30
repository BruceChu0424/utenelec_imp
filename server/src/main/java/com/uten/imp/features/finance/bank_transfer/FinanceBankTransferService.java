package com.uten.imp.features.finance.bank_transfer;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.common.web.Pageables;
import com.uten.imp.common.web.TableSort;
import com.uten.imp.common.docnumber.DocNumberPrefix;
import com.uten.imp.common.docnumber.DocNumberService;
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
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.time.OffsetDateTime;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.UUID;

/**
 * 银行存取款单服务：保结构 CRUD（老库 M_Bank 0 行，未来启用）。
 *
 * <p><b>审核/红冲暂未实现账户联动</b>：跨币种换算核销（老库 TRI_BankItem）逻辑较复杂，
 * 当前 approve/reverse 仅翻转 status，不动账户余额、不写 finance_reconciliations。
 * 真正启用时需补：
 * <ul>
 *   <li>每个 line（in_account）：{@code in_account.receipts_total += amount × out.exchange_rate / in.exchange_rate}（跨币种换算）；</li>
 *   <li>{@code out_account.payments_total += amount_local}；</li>
 *   <li>每账户写一行 {@code finance_reconciliations(source='BANK_TRANSFER')}。</li>
 * </ul>
 *
 * <p>详见 design doc 26 §4.7、§5.3 {@code approveBankTransfer}。
 */
@Service
@RequiredArgsConstructor
public class FinanceBankTransferService {

    private static final short STATUS_DRAFT = 0;
    private static final short STATUS_APPROVED = 1;
    private static final short STATUS_REVERSED = -1;

    /** 列排序白名单：前端列 key → JPA 实体属性名（日期/金额可排序；命中才排序，否则默认 billDate DESC）。 */
    private static final Map<String, String> ALLOWED_SORT = Map.of("billDate", "billDate", "amountLocal", "amountLocal");

    private final FinanceBankTransferRepository transferRepo;
    private final FinanceBankTransferLineRepository lineRepo;
    private final TxSessionVars tx;
    private final SecurityContextCurrentUser currentUser;
    private final com.uten.imp.common.util.EmployeeNameResolver nameResolver;
    private final DocNumberService docNumberService;
    private final EntityManager em;

    @Transactional(readOnly = true)
    public PageResponse<FinanceBankTransferListItem> list(FinanceBankTransferQueryFilter f, int page, int size, String sort, String order) {
        Specification<FinanceBankTransfer> spec = (Root<FinanceBankTransfer> root,
                                                   jakarta.persistence.criteria.CriteriaQuery<?> q,
                                                   CriteriaBuilder cb) -> {
            List<Predicate> ps = new ArrayList<>();
            ps.add(cb.isFalse(root.get("deleted")));
            if (f.keyword() != null && !f.keyword().isBlank()) {
                ps.add(cb.like(cb.lower(root.get("billNo")), "%" + f.keyword().toLowerCase() + "%"));
            }
            if (f.outAccountId() != null) ps.add(cb.equal(root.get("outAccountId"), f.outAccountId()));
            if (f.status() != null) ps.add(cb.equal(root.get("status"), f.status()));
            if (f.dateFrom() != null) ps.add(cb.greaterThanOrEqualTo(root.get("billDate"), f.dateFrom()));
            if (f.dateTo() != null) ps.add(cb.lessThanOrEqualTo(root.get("billDate"), f.dateTo()));
            return cb.and(ps.toArray(new Predicate[0]));
        };
        Pageable pageable = Pageables.of(page, size,
                TableSort.resolve(sort, order, Sort.by(Sort.Direction.DESC, "billDate"), ALLOWED_SORT));
        Page<FinanceBankTransfer> p = transferRepo.findAll(spec, pageable);
        return new PageResponse<>(p.map(this::toList).getContent(), page, size, p.getTotalElements(), p.getTotalPages());
    }

    @Transactional(readOnly = true)
    public FinanceBankTransferDetail detail(UUID id) {
        FinanceBankTransfer t = require(id);
        List<FinanceBankTransferLineDto> items = lineRepo.findByTransferIdOrderByLineNoAsc(id).stream()
                .map(this::toLineDto).toList();
        return toDetail(t, items);
    }

    @Transactional
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
    public FinanceBankTransferDetail update(UUID id, FinanceBankTransferSaveRequest req) {
        tx.bind();
        FinanceBankTransfer t = require(id);
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
    public void delete(UUID id) {
        tx.bind();
        FinanceBankTransfer t = require(id);
        if (t.getStatus() == STATUS_APPROVED) {
            throw new ApiException(ErrorCode.BUSINESS, "已审核单据不可删，请红冲");
        }
        t.setDeleted(true);
        t.setDeletedAt(OffsetDateTime.now());
        transferRepo.save(t);
    }

    /**
     * 审核（占位实现，不动账户）。
     *
     * <p><b>TODO 启用时</b>：实现跨币种换算核销（{@code in_account.receipts_total += amount × 跨币种汇率}，
     * {@code out_account.payments_total += amount_local}），并写 finance_reconciliations(BANK_TRANSFER)。
     */
    @Transactional
    public FinanceBankTransferDetail approve(UUID id) {
        tx.bind();
        FinanceBankTransfer t = require(id);
        em.lock(t, jakarta.persistence.LockModeType.PESSIMISTIC_WRITE); // 并发审核/红冲互斥（多账号同单操作）
        if (t.getStatus() == null || t.getStatus() != STATUS_DRAFT) {
            throw new ApiException(ErrorCode.BUSINESS, "仅草稿单据可审核");
        }
        // TODO: 跨币种换算核销（design doc 26 §4.7、§5.3）
        t.setApproverId(currentUser.requireEmployeeId()); // 审核=当前登录用户（报表按 approver_id 解析审核员）
        t.setStatus(STATUS_APPROVED);
        transferRepo.save(t);
        return detail(id);
    }

    /** 红冲（占位实现，不动账户）。 */
    @Transactional
    public FinanceBankTransferDetail reverse(UUID id) {
        tx.bind();
        FinanceBankTransfer t = require(id);
        em.lock(t, jakarta.persistence.LockModeType.PESSIMISTIC_WRITE); // 并发审核/红冲互斥（多账号同单操作）
        if (t.getStatus() == null || t.getStatus() != STATUS_APPROVED) {
            throw new ApiException(ErrorCode.BUSINESS, "仅已审核单据可红冲");
        }
        // TODO: 反向账户联动（与 approve 对称）
        t.setStatus(STATUS_REVERSED);
        transferRepo.save(t);
        return detail(id);
    }

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
        if (req.getAmountOriginal() != null) t.setAmountOriginal(req.getAmountOriginal());
        if (req.getAmountLocal() != null) t.setAmountLocal(req.getAmountLocal());
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
            ln.setAmountOriginal(l.getAmountOriginal());
            ln.setAmountLocal(l.getAmountLocal());
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

    private FinanceBankTransfer require(UUID id) {
        return transferRepo.findById(id).filter(t -> !t.isDeleted())
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "银行存取款单不存在"));
    }
}
