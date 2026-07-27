package com.uten.imp.features.purchase.request;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.common.web.Pageables;
import com.uten.imp.common.web.TableSort;
import com.uten.imp.features.purchase.request.dto.RequestDetail;
import com.uten.imp.features.purchase.request.dto.RequestItemDto;
import com.uten.imp.features.purchase.request.dto.RequestItemLine;
import com.uten.imp.features.purchase.request.dto.RequestListItem;
import com.uten.imp.features.purchase.request.dto.RequestQueryFilter;
import com.uten.imp.features.purchase.request.dto.RequestSaveRequest;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
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
 * 采购申请单服务：CRUD + 审核。链路起点：审核无库存联动、无上游回写
 * （被订货单审核时回写 ordered_qty + is_closed）。
 */
@Service
@RequiredArgsConstructor
public class PurchaseRequestService {

    private static final short STATUS_DRAFT = 0;
    private static final short STATUS_APPROVED = 1;
    private static final short STATUS_REVERSED = -1;

    private final PurchaseRequestRepository requestRepo;
    private final PurchaseRequestItemRepository itemRepo;
    private final TxSessionVars tx;
    private final SecurityContextCurrentUser currentUser;

    @Transactional(readOnly = true)
    public PageResponse<RequestListItem> list(RequestQueryFilter f, int page, int size, String sort, String order) {
        Specification<PurchaseRequest> spec = (Root<PurchaseRequest> root, jakarta.persistence.criteria.CriteriaQuery<?> q,
                                               CriteriaBuilder cb) -> {
            List<Predicate> ps = new ArrayList<>();
            ps.add(cb.isFalse(root.get("deleted")));
            if (f.keyword() != null && !f.keyword().isBlank()) {
                ps.add(cb.like(cb.lower(root.get("billNo")), "%" + f.keyword().toLowerCase() + "%"));
            }
            if (f.warehouseId() != null) ps.add(cb.equal(root.get("warehouseId"), f.warehouseId()));
            if (f.status() != null) ps.add(cb.equal(root.get("status"), f.status()));
            if (f.dateFrom() != null) ps.add(cb.greaterThanOrEqualTo(root.get("billDate"), f.dateFrom()));
            if (f.dateTo() != null) ps.add(cb.lessThanOrEqualTo(root.get("billDate"), f.dateTo()));
            return cb.and(ps.toArray(new Predicate[0]));
        };
        // 列排序：sort 命中白名单(日期/金额)才按实体属性排序，否则默认 billDate DESC。
        Pageable pageable = Pageables.of(page, size,
                TableSort.resolve(sort, order, Sort.by(Sort.Direction.DESC, "billDate"),
                        Map.of("billDate", "billDate", "total", "totalLocal")));
        Page<PurchaseRequest> p = requestRepo.findAll(spec, pageable);
        return new PageResponse<>(p.map(this::toList).getContent(), page, size, p.getTotalElements(), p.getTotalPages());
    }

    @Transactional(readOnly = true)
    public RequestDetail detail(UUID id) {
        PurchaseRequest r = requireRequest(id);
        List<RequestItemDto> items = itemRepo.findByRequestIdOrderByLineNoAsc(id).stream().map(this::toItemDto).toList();
        return toDetail(r, items);
    }

    @Transactional
    public RequestDetail create(RequestSaveRequest req) {
        tx.bind();
        PurchaseRequest r = new PurchaseRequest();
        applyHeader(req, r);
        r.setMakerId(currentUser.requireId()); // 制单=当前登录用户
        r.setStatus(STATUS_DRAFT);
        requestRepo.save(r);
        List<RequestItemDto> items = saveItems(r, req.getItems());
        applyTotals(r, items);
        return toDetail(r, items);
    }

    @Transactional
    public RequestDetail update(UUID id, RequestSaveRequest req) {
        tx.bind();
        PurchaseRequest r = requireRequest(id);
        if (r.getStatus() != STATUS_DRAFT) throw new ApiException(ErrorCode.BUSINESS, "仅草稿单据可编辑");
        applyHeader(req, r);
        itemRepo.deleteByRequestId(id);
        itemRepo.flush();
        List<RequestItemDto> items = saveItems(r, req.getItems());
        applyTotals(r, items);
        return toDetail(r, items);
    }

    @Transactional
    public void delete(UUID id) {
        tx.bind();
        PurchaseRequest r = requireRequest(id);
        if (r.getStatus() == STATUS_APPROVED) throw new ApiException(ErrorCode.BUSINESS, "已审核单据不可删，请红冲");
        r.setDeleted(true);
        r.setDeletedAt(OffsetDateTime.now());
        requestRepo.save(r);
    }

    /** 审核：链路起点，仅改状态（无库存联动、无上游回写）。 */
    @Transactional
    public RequestDetail approve(UUID id) {
        tx.bind();
        PurchaseRequest r = requireRequest(id);
        if (r.getStatus() == null || r.getStatus() != STATUS_DRAFT)
            throw new ApiException(ErrorCode.BUSINESS, "仅草稿单据可审核");
        if (itemRepo.findByRequestIdOrderByLineNoAsc(id).isEmpty())
            throw new ApiException(ErrorCode.BUSINESS, "明细为空，不可审核");
        r.setStatus(STATUS_APPROVED);
        r.setApproverId(currentUser.requireId()); // 审核=当前登录用户
        requestRepo.save(r);
        return detail(id);
    }

    @Transactional
    public RequestDetail reverse(UUID id) {
        tx.bind();
        PurchaseRequest r = requireRequest(id);
        if (r.getStatus() == null || r.getStatus() != STATUS_APPROVED)
            throw new ApiException(ErrorCode.BUSINESS, "仅已审核单据可红冲");
        r.setStatus(STATUS_REVERSED);
        requestRepo.save(r);
        return detail(id);
    }

    private void applyHeader(RequestSaveRequest req, PurchaseRequest r) {
        r.setBillNo(req.getBillNo());
        r.setBillDate(req.getBillDate());
        r.setWarehouseId(req.getWarehouseId());
        r.setApplicantId(req.getApplicantId());
        r.setNeedDate(req.getNeedDate());
        r.setRemark(req.getRemark());
    }

    private List<RequestItemDto> saveItems(PurchaseRequest r, List<RequestItemLine> lines) {
        List<RequestItemDto> out = new ArrayList<>(lines.size());
        int auto = 1;
        for (RequestItemLine l : lines) {
            PurchaseRequestItem it = new PurchaseRequestItem();
            it.setRequestId(r.getId());
            it.setBillNo(r.getBillNo());
            it.setBillDate(r.getBillDate());
            it.setLineNo(l.getLineNo() != null ? l.getLineNo() : auto);
            it.setGoodsId(l.getGoodsId());
            it.setColorId(l.getColorId());
            it.setUnitId(l.getUnitId());
            it.setUnitRate(l.getUnitRate());
            it.setQty(l.getQty());
            it.setPrice(l.getPrice());
            it.setAmountOriginal(l.getAmountOriginal());
            it.setAmountLocal(l.getAmountLocal() != null ? l.getAmountLocal() : l.getAmountOriginal());
            it.setGiftQty(l.getGiftQty() != null ? l.getGiftQty() : BigDecimal.ZERO);
            it.setWeight(l.getWeight());
            it.setSourceDocNo(l.getSourceDocNo());
            it.setRemark(l.getRemark());
            itemRepo.save(it);
            out.add(toItemDto(it));
            auto++;
        }
        return out;
    }

    private void applyTotals(PurchaseRequest r, List<RequestItemDto> items) {
        BigDecimal local = items.stream().map(i -> i.getAmountLocal() == null ? BigDecimal.ZERO : i.getAmountLocal())
                .reduce(BigDecimal.ZERO, BigDecimal::add);
        r.setTotalLocal(local);
        r.setTotalOriginal(local);
        requestRepo.save(r);
    }

    private RequestListItem toList(PurchaseRequest r) {
        return new RequestListItem(r.getId(), r.getBillNo(), r.getBillDate(), r.getWarehouseId(),
                r.getTotalLocal(), r.getStatus(), r.isClosed(), r.getLegacyId());
    }

    private RequestItemDto toItemDto(PurchaseRequestItem it) {
        return new RequestItemDto(it.getId(), it.getLineNo(), it.getGoodsId(), it.getColorId(),
                it.getUnitId(), it.getUnitRate(), it.getQty(), it.getPrice(), it.getAmountOriginal(),
                it.getAmountLocal(), it.getOrderedQty(), it.getGiftQty(), it.getWeight(),
                it.getSourceDocNo(), it.getRemark());
    }

    private RequestDetail toDetail(PurchaseRequest r, List<RequestItemDto> items) {
        return new RequestDetail(r.getId(), r.getLegacyId(), r.getBillNo(), r.getBillDate(),
                r.getWarehouseId(), r.getApplicantId(), r.getMakerId(), r.getApproverId(),
                r.getNeedDate(), r.getRemark(), r.getTotalOriginal(), r.getTotalLocal(),
                r.getStatus(), r.isClosed(), r.getSourceDocNo(), items);
    }

    private PurchaseRequest requireRequest(UUID id) {
        return requestRepo.findById(id).filter(r -> !r.isDeleted())
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "采购申请单不存在"));
    }
}
