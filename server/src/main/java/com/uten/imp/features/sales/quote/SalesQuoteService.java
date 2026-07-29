package com.uten.imp.features.sales.quote;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.common.web.Pageables;
import com.uten.imp.common.web.TableSort;
import com.uten.imp.common.docnumber.DocNumberPrefix;
import com.uten.imp.common.docnumber.DocNumberService;
import com.uten.imp.features.sales.quote.dto.QuoteDetail;
import com.uten.imp.features.sales.quote.dto.QuoteItemDto;
import com.uten.imp.features.sales.quote.dto.QuoteItemLine;
import com.uten.imp.features.sales.quote.dto.QuoteListItem;
import com.uten.imp.features.sales.quote.dto.QuoteQueryFilter;
import com.uten.imp.features.sales.quote.dto.QuoteSaveRequest;
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
 * 销售报价单服务：CRUD（主+明细）+ 审核状态机（无库存/应收副作用）。
 *
 * <p>报价单为未来启用的空结构（老库 0 行）。审核仅切换 status 0→1；红冲 1→-1。
 * 明细独立仓库管理（update 时物理删旧+插新）；total 由明细 amount_local 求和。
 */
@Service
@RequiredArgsConstructor
public class SalesQuoteService {

    private static final short STATUS_DRAFT = 0;
    private static final short STATUS_APPROVED = 1;
    private static final short STATUS_REVERSED = -1;

    /** 列排序白名单：前端列 key → JPA 实体属性名（日期/金额可排序；命中才排序，否则默认 billDate DESC）。 */
    private static final Map<String, String> ALLOWED_SORT = Map.of("billDate", "billDate", "total", "totalLocal");

    private final SalesQuoteRepository quoteRepo;
    private final SalesQuoteItemRepository itemRepo;
    private final TxSessionVars tx;
    private final DocNumberService docNumberService;
    private final EntityManager em;
    private final com.uten.imp.security.SecurityContextCurrentUser currentUser;
    private final com.uten.imp.common.util.EmployeeNameResolver nameResolver;
    private final com.uten.imp.features.sales.order.SalesOrderService salesOrderService;

    @Transactional(readOnly = true)
    public PageResponse<QuoteListItem> list(QuoteQueryFilter f, int page, int size, String sort, String order) {
        Specification<SalesQuote> spec = (Root<SalesQuote> root, jakarta.persistence.criteria.CriteriaQuery<?> q,
                                          CriteriaBuilder cb) -> {
            List<Predicate> ps = new ArrayList<>();
            ps.add(cb.isFalse(root.get("deleted")));
            if (f.keyword() != null && !f.keyword().isBlank()) {
                ps.add(cb.like(cb.lower(root.get("billNo")), "%" + f.keyword().toLowerCase() + "%"));
            }
            if (f.clientId() != null) ps.add(cb.equal(root.get("clientId"), f.clientId()));
            if (f.status() != null) ps.add(cb.equal(root.get("status"), f.status()));
            if (f.dateFrom() != null) ps.add(cb.greaterThanOrEqualTo(root.get("billDate"), f.dateFrom()));
            if (f.dateTo() != null) ps.add(cb.lessThanOrEqualTo(root.get("billDate"), f.dateTo()));
            return cb.and(ps.toArray(new Predicate[0]));
        };
        Pageable pageable = Pageables.of(page, size,
                TableSort.resolve(sort, order, Sort.by(Sort.Direction.DESC, "billDate"), ALLOWED_SORT));
        Page<SalesQuote> p = quoteRepo.findAll(spec, pageable);
        return new PageResponse<>(p.map(this::toList).getContent(), page, size, p.getTotalElements(), p.getTotalPages());
    }

    @Transactional(readOnly = true)
    public QuoteDetail detail(UUID id) {
        SalesQuote q = requireQuote(id);
        List<QuoteItemDto> items = itemRepo.findByQuoteIdOrderByLineNoAsc(id).stream()
                .map(this::toItemDto).toList();
        return toDetail(q, items);
    }

    @Transactional
    public QuoteDetail create(QuoteSaveRequest req) {
        tx.bind();
        SalesQuote q = new SalesQuote();
        applyHeader(req, q);
        q.setMakerId(currentUser.requireEmployeeId()); // 制单=当前登录用户（报表按 maker_id 解析制单员）
        q.setStatus(STATUS_DRAFT);
        quoteRepo.save(q);
        List<QuoteItemDto> items = saveItems(q, req.getItems());
        applyTotals(q, items);
        return toDetail(q, items);
    }

    @Transactional
    public QuoteDetail update(UUID id, QuoteSaveRequest req) {
        tx.bind();
        SalesQuote q = requireQuote(id);
        if (q.getStatus() != STATUS_DRAFT) {
            throw new ApiException(ErrorCode.BUSINESS, "仅草稿单据可编辑");
        }
        applyHeader(req, q);
        itemRepo.deleteByQuoteId(id);
        itemRepo.flush();
        List<QuoteItemDto> items = saveItems(q, req.getItems());
        applyTotals(q, items);
        return toDetail(q, items);
    }

    @Transactional
    public void delete(UUID id) {
        tx.bind();
        SalesQuote q = requireQuote(id);
        if (q.getStatus() == STATUS_APPROVED) {
            throw new ApiException(ErrorCode.BUSINESS, "已审核单据不可删，请红冲");
        }
        q.setDeleted(true);
        q.setDeletedAt(OffsetDateTime.now());
        quoteRepo.save(q);
    }

    /** 审核：status 0→1（报价无库存/应收副作用）。 */
    @Transactional
    public QuoteDetail approve(UUID id) {
        tx.bind();
        SalesQuote q = requireQuote(id);
        em.lock(q, jakarta.persistence.LockModeType.PESSIMISTIC_WRITE); // 并发审核/红冲互斥（多账号同单操作）
        if (q.getStatus() == null || q.getStatus() != STATUS_DRAFT) {
            throw new ApiException(ErrorCode.BUSINESS, "仅草稿单据可审核");
        }
        if (itemRepo.findByQuoteIdOrderByLineNoAsc(id).isEmpty()) {
            throw new ApiException(ErrorCode.BUSINESS, "明细为空，不可审核");
        }
        q.setStatus(STATUS_APPROVED);
        q.setApproverId(currentUser.requireEmployeeId()); // 审核=当前登录用户（报表按 approver_id 解析审核员）
        quoteRepo.save(q);
        return detail(id);
    }

    /** 红冲：status 1→-1。 */
    @Transactional
    public QuoteDetail reverse(UUID id) {
        tx.bind();
        SalesQuote q = requireQuote(id);
        em.lock(q, jakarta.persistence.LockModeType.PESSIMISTIC_WRITE); // 并发审核/红冲互斥（多账号同单操作）
        if (q.getStatus() == null || q.getStatus() != STATUS_APPROVED) {
            throw new ApiException(ErrorCode.BUSINESS, "仅已审核单据可红冲");
        }
        q.setStatus(STATUS_REVERSED);
        quoteRepo.save(q);
        return detail(id);
    }

    /**
     * 报价转订货（SOP §三1）：已审报价一键生成订货草稿。
     * 行带入货品/颜色/单位/数量/价格；主表与各行 sourceDocNo=报价单号，
     * 订货详情据此回联来源报价（sourceQuoteId + 行级 quotePrice 比对，价格留痕）。
     * 转入为普通草稿：数量/价格可再改，审核才走库存检查+软预留（订货既有链路）。
     */
    @Transactional
    public com.uten.imp.features.sales.order.dto.OrderDetail convertToOrder(UUID id) {
        tx.bind();
        SalesQuote q = requireQuote(id);
        em.lock(q, jakarta.persistence.LockModeType.PESSIMISTIC_WRITE); // 防并发重复转入
        if (q.getStatus() == null || q.getStatus() != STATUS_APPROVED) {
            throw new ApiException(ErrorCode.BUSINESS, "仅已审核报价单可转订货单");
        }
        List<SalesQuoteItem> qitems = itemRepo.findByQuoteIdOrderByLineNoAsc(id);
        if (qitems.isEmpty()) {
            throw new ApiException(ErrorCode.BUSINESS, "明细为空，不可转入");
        }
        com.uten.imp.features.sales.order.dto.OrderSaveRequest req =
                new com.uten.imp.features.sales.order.dto.OrderSaveRequest();
        req.setBillDate(java.time.LocalDate.now());
        req.setClientId(q.getClientId());
        req.setSourceDocNo(q.getBillNo());
        req.setRemark("从报价单 " + q.getBillNo() + " 转入"
                + (q.getRemark() == null || q.getRemark().isBlank() ? "" : "；" + q.getRemark()));
        List<com.uten.imp.features.sales.order.dto.OrderItemLine> lines = new ArrayList<>(qitems.size());
        for (SalesQuoteItem qi : qitems) {
            com.uten.imp.features.sales.order.dto.OrderItemLine l =
                    new com.uten.imp.features.sales.order.dto.OrderItemLine();
            l.setLineNo(qi.getLineNo());
            l.setGoodsId(qi.getGoodsId());
            l.setColorId(qi.getColorId());
            l.setUnitId(qi.getUnitId());
            l.setUnitRate(qi.getUnitRate());
            l.setQty(qi.getQty());
            l.setPrice(qi.getPrice());
            l.setAmountOriginal(qi.getAmountOriginal());
            l.setAmountLocal(qi.getAmountLocal());
            l.setWeight(qi.getWeight());
            l.setSourceDocNo(q.getBillNo());
            l.setRemark(qi.getRemark());
            lines.add(l);
        }
        req.setItems(lines);
        return salesOrderService.create(req);
    }

    private void applyHeader(QuoteSaveRequest req, SalesQuote q) {
        // 单据号系统自动生成（服务端权威）：仅新建（billNo 空）时取号；更新保留既有号，忽略客户端值。
        if (q.getBillNo() == null || q.getBillNo().isBlank()) {
            q.setBillNo(docNumberService.nextNumber(DocNumberPrefix.SALES_QUOTE));
        }
        q.setBillDate(req.getBillDate());
        q.setClientId(req.getClientId());
        q.setValidUntil(req.getValidUntil());
        q.setRemark(req.getRemark());
    }

    private List<QuoteItemDto> saveItems(SalesQuote q, List<QuoteItemLine> lines) {
        List<QuoteItemDto> out = new ArrayList<>(lines.size());
        int auto = 1;
        for (QuoteItemLine l : lines) {
            SalesQuoteItem it = new SalesQuoteItem();
            it.setQuoteId(q.getId());
            it.setBillNo(q.getBillNo());
            it.setBillDate(q.getBillDate());
            it.setLineNo(l.getLineNo() != null ? l.getLineNo() : auto);
            it.setGoodsId(l.getGoodsId());
            it.setColorId(l.getColorId());
            it.setUnitId(l.getUnitId());
            it.setUnitRate(l.getUnitRate());
            it.setQty(l.getQty());
            it.setPrice(l.getPrice());
            it.setAmountOriginal(l.getAmountOriginal());
            it.setAmountLocal(l.getAmountLocal() != null ? l.getAmountLocal() : l.getAmountOriginal());
            it.setWeight(l.getWeight());
            it.setRemark(l.getRemark());
            itemRepo.save(it);
            out.add(toItemDto(it));
            auto++;
        }
        return out;
    }

    private void applyTotals(SalesQuote q, List<QuoteItemDto> items) {
        BigDecimal local = items.stream()
                .map(i -> i.getAmountLocal() == null ? BigDecimal.ZERO : i.getAmountLocal())
                .reduce(BigDecimal.ZERO, BigDecimal::add);
        BigDecimal original = items.stream()
                .map(i -> i.getAmountOriginal() == null ? BigDecimal.ZERO : i.getAmountOriginal())
                .reduce(BigDecimal.ZERO, BigDecimal::add);
        q.setTotalLocal(local);
        q.setTotalOriginal(original);
        quoteRepo.save(q);
    }

    private QuoteListItem toList(SalesQuote q) {
        return new QuoteListItem(q.getId(), q.getBillNo(), q.getBillDate(), q.getClientId(),
                q.getTotalLocal(), q.getStatus(), q.isClosed(), q.getLegacyId());
    }

    private QuoteItemDto toItemDto(SalesQuoteItem it) {
        return new QuoteItemDto(it.getId(), it.getLineNo(), it.getGoodsId(), it.getColorId(),
                it.getUnitId(), it.getUnitRate(), it.getQty(), it.getPrice(), it.getAmountOriginal(),
                it.getAmountLocal(), it.getWeight(), it.getRemark());
    }

    private QuoteDetail toDetail(SalesQuote q, List<QuoteItemDto> items) {
        return new QuoteDetail(q.getId(), q.getLegacyId(), q.getBillNo(), q.getBillDate(),
                q.getClientId(), q.getMakerId(), q.getApproverId(), q.getValidUntil(), q.getRemark(),
                q.getTotalOriginal(), q.getTotalLocal(), q.getStatus(), q.isClosed(), q.getSourceDocNo(), items,
                nameResolver.nameOf(q.getMakerId()), q.getCreatedAt());
    }

    private SalesQuote requireQuote(UUID id) {
        return quoteRepo.findById(id).filter(q -> !q.isDeleted())
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "销售报价单不存在"));
    }
}
