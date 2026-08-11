package com.uten.imp.features.subcontract.inquiry;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.common.web.Pageables;
import com.uten.imp.common.web.TableSort;
import com.uten.imp.common.docnumber.DocNumberPrefix;
import com.uten.imp.common.docnumber.DocNumberService;
import com.uten.imp.features.subcontract.SubcontractDocumentAccessPolicy;
import com.uten.imp.features.subcontract.inquiry.dto.InquiryDetail;
import com.uten.imp.features.subcontract.inquiry.dto.InquiryItemDto;
import com.uten.imp.features.subcontract.inquiry.dto.InquiryItemLine;
import com.uten.imp.features.subcontract.inquiry.dto.InquiryListItem;
import com.uten.imp.features.subcontract.inquiry.dto.InquiryQueryFilter;
import com.uten.imp.features.subcontract.inquiry.dto.InquirySaveRequest;
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
 * 委外询价单服务：CRUD（主+明细）+ 审核状态机（仅状态变更）。
 *
 * <p>询价单是<b>链路起点</b>：审核仅 0→1 状态变更，<b>无库存联动、无上游回写、无应收应付</b>
 * （同采购申请单）。design doc 22 §一决策1：询价/申请老库 0 行，独立建结构保未来启用零返工。
 *
 * <p>状态机：0 草稿 / 1 已审 / -1 红冲；已审不可删（红冲保留）。
 */
@Service
@RequiredArgsConstructor
public class SubcontractInquiryService {

    private static final short STATUS_DRAFT = 0;
    private static final short STATUS_APPROVED = 1;
    private static final short STATUS_REVERSED = -1;

    /** 列排序白名单：前端列 key → JPA 实体属性名（日期/金额可排序；命中才排序，否则默认 billDate DESC）。 */
    private static final Map<String, String> ALLOWED_SORT = Map.of("billDate", "billDate", "total", "totalLocal");

    private final SubcontractInquiryRepository inquiryRepo;
    private final SubcontractInquiryItemRepository itemRepo;
    private final TxSessionVars tx;
    private final DocNumberService docNumberService;
    private final EntityManager em;
    private final com.uten.imp.security.SecurityContextCurrentUser currentUser;
    private final com.uten.imp.common.util.EmployeeNameResolver nameResolver;
    private final SubcontractDocumentAccessPolicy access;

    @Transactional(readOnly = true)
    public PageResponse<InquiryListItem> list(InquiryQueryFilter f, int page, int size, String sort, String order) {
        var readScope = access.scope();
        Specification<SubcontractInquiry> spec = (Root<SubcontractInquiry> root,
                                                  jakarta.persistence.criteria.CriteriaQuery<?> q,
                                                  CriteriaBuilder cb) -> {
            List<Predicate> ps = new ArrayList<>();
            ps.add(cb.isFalse(root.get("deleted")));
            ps.add(access.readablePredicate(root, cb, "makerId", readScope));
            if (f.keyword() != null && !f.keyword().isBlank()) {
                ps.add(cb.like(cb.lower(root.get("billNo")), "%" + f.keyword().toLowerCase() + "%"));
            }
            if (f.supplierId() != null) ps.add(cb.equal(root.get("supplierId"), f.supplierId()));
            if (f.warehouseId() != null) ps.add(cb.equal(root.get("warehouseId"), f.warehouseId()));
            if (f.status() != null) ps.add(cb.equal(root.get("status"), f.status()));
            if (f.dateFrom() != null) ps.add(cb.greaterThanOrEqualTo(root.get("billDate"), f.dateFrom()));
            if (f.dateTo() != null) ps.add(cb.lessThanOrEqualTo(root.get("billDate"), f.dateTo()));
            return cb.and(ps.toArray(new Predicate[0]));
        };
        Pageable pageable = Pageables.of(page, size,
                TableSort.resolve(sort, order, Sort.by(Sort.Direction.DESC, "billDate"), ALLOWED_SORT));
        Page<SubcontractInquiry> p = inquiryRepo.findAll(spec, pageable);
        return new PageResponse<>(p.map(this::toList).getContent(), page, size, p.getTotalElements(), p.getTotalPages());
    }

    @Transactional(readOnly = true)
    public InquiryDetail detail(UUID id) {
        SubcontractInquiry r = requireInquiry(id);
        access.requireReadable(r.getMakerId(), "委外询价单不存在");
        List<InquiryItemDto> items = itemRepo.findByInquiryIdOrderByLineNoAsc(id).stream()
                .map(this::toItemDto).toList();
        return toDetail(r, items);
    }

    @Transactional
    public InquiryDetail create(InquirySaveRequest req) {
        tx.bind();
        SubcontractInquiry r = new SubcontractInquiry();
        applyHeader(req, r);
        r.setMakerId(currentUser.requireEmployeeId()); // 制单=当前登录用户（报表按 maker_id 解析制单员）
        r.setStatus(STATUS_DRAFT);
        inquiryRepo.save(r);
        List<InquiryItemDto> items = saveItems(r, req.getItems());
        applyTotals(r, items);
        return toDetail(r, items);
    }

    @Transactional
    public InquiryDetail update(UUID id, InquirySaveRequest req) {
        tx.bind();
        SubcontractInquiry r = requireInquiry(id);
        access.requireWritable(r.getMakerId(), "只能操作本人负责的委外询价单");
        if (r.getStatus() != STATUS_DRAFT) {
            throw new ApiException(ErrorCode.BUSINESS, "仅草稿单据可编辑");
        }
        applyHeader(req, r);
        itemRepo.deleteByInquiryId(id);
        itemRepo.flush();
        List<InquiryItemDto> items = saveItems(r, req.getItems());
        applyTotals(r, items);
        return toDetail(r, items);
    }

    @Transactional
    public void delete(UUID id) {
        tx.bind();
        SubcontractInquiry r = requireInquiry(id);
        access.requireWritable(r.getMakerId(), "只能操作本人负责的委外询价单");
        if (r.getStatus() == STATUS_APPROVED) {
            throw new ApiException(ErrorCode.BUSINESS, "已审核单据不可删，请红冲");
        }
        r.setDeleted(true);
        r.setDeletedAt(OffsetDateTime.now());
        inquiryRepo.save(r);
    }

    /** 审核：0→1（仅状态变更；询价是链路起点，无库存/上游/ArAp 联动）。 */
    @Transactional
    public InquiryDetail approve(UUID id) {
        tx.bind();
        SubcontractInquiry r = requireInquiry(id);
        access.requireWritable(r.getMakerId(), "只能操作本人负责的委外询价单");
        em.refresh(r, jakarta.persistence.LockModeType.PESSIMISTIC_WRITE); // 锁行并重读最新状态，防陈旧快照绕过状态守卫（TOCTOU，对齐 M28）
        if (r.getStatus() == null || r.getStatus() != STATUS_DRAFT) {
            throw new ApiException(ErrorCode.BUSINESS, "仅草稿单据可审核");
        }
        if (itemRepo.findByInquiryIdOrderByLineNoAsc(id).isEmpty()) {
            throw new ApiException(ErrorCode.BUSINESS, "明细为空，不可审核");
        }
        r.setStatus(STATUS_APPROVED);
        r.setApproverId(currentUser.requireEmployeeId()); // 审核=当前登录用户（报表按 approver_id 解析审核员）
        inquiryRepo.save(r);
        return detail(id);
    }

    /** 红冲：1→-1（仅状态变更；询价无 ArAp 无库存，无需反向冲销）。 */
    @Transactional
    public InquiryDetail reverse(UUID id) {
        tx.bind();
        SubcontractInquiry r = requireInquiry(id);
        access.requireWritable(r.getMakerId(), "只能操作本人负责的委外询价单");
        em.refresh(r, jakarta.persistence.LockModeType.PESSIMISTIC_WRITE); // 锁行并重读最新状态，防陈旧快照绕过状态守卫（TOCTOU，对齐 M28）
        if (r.getStatus() == null || r.getStatus() != STATUS_APPROVED) {
            throw new ApiException(ErrorCode.BUSINESS, "仅已审核单据可红冲");
        }
        r.setStatus(STATUS_REVERSED);
        inquiryRepo.save(r);
        return detail(id);
    }

    private void applyHeader(InquirySaveRequest req, SubcontractInquiry r) {
        // 单据号系统自动生成（服务端权威）：仅新建（billNo 空）时取号；更新保留既有号，忽略客户端值。
        if (r.getBillNo() == null || r.getBillNo().isBlank()) {
            r.setBillNo(docNumberService.nextNumber(DocNumberPrefix.SUB_INQUIRY));
        }
        r.setBillDate(req.getBillDate());
        r.setSupplierId(req.getSupplierId());
        r.setWarehouseId(req.getWarehouseId());
        r.setCurrencyId(req.getCurrencyId());
        r.setExchangeRate(req.getExchangeRate());
        r.setDeliverDate(req.getDeliverDate());
        r.setRemark(req.getRemark());
    }

    private List<InquiryItemDto> saveItems(SubcontractInquiry r, List<InquiryItemLine> lines) {
        List<InquiryItemDto> out = new ArrayList<>(lines.size());
        int autoLine = 1;
        for (InquiryItemLine l : lines) {
            SubcontractInquiryItem it = new SubcontractInquiryItem();
            it.setInquiryId(r.getId());
            it.setBillNo(r.getBillNo());
            it.setBillDate(r.getBillDate());
            it.setLineNo(l.getLineNo() != null ? l.getLineNo() : autoLine);
            it.setGoodsId(l.getGoodsId());
            it.setColorId(l.getColorId());
            it.setUnitId(l.getUnitId());
            it.setUnitRate(l.getUnitRate());
            it.setQty(l.getQty());
            it.setPrice(l.getPrice());
            it.setAmountOriginal(l.getAmountOriginal());
            it.setAmountLocal(l.getAmountLocal() != null ? l.getAmountLocal() : l.getAmountOriginal());
            it.setWeight(l.getWeight());
            it.setSourceDocNo(l.getSourceDocNo());
            it.setRemark(l.getRemark());
            itemRepo.save(it);
            out.add(toItemDto(it));
            autoLine++;
        }
        return out;
    }

    private void applyTotals(SubcontractInquiry r, List<InquiryItemDto> items) {
        BigDecimal local = items.stream()
                .map(i -> i.getAmountLocal() == null ? BigDecimal.ZERO : i.getAmountLocal())
                .reduce(BigDecimal.ZERO, BigDecimal::add);
        BigDecimal original = items.stream()
                .map(i -> i.getAmountOriginal() == null ? BigDecimal.ZERO : i.getAmountOriginal())
                .reduce(BigDecimal.ZERO, BigDecimal::add);
        r.setTotalLocal(local);
        r.setTotalOriginal(original);
        inquiryRepo.save(r);
    }

    private InquiryListItem toList(SubcontractInquiry r) {
        return new InquiryListItem(r.getId(), r.getBillNo(), r.getBillDate(), r.getSupplierId(),
                r.getWarehouseId(), r.getTotalLocal(), r.getStatus(), r.isClosed(), r.getLegacyId());
    }

    private InquiryItemDto toItemDto(SubcontractInquiryItem it) {
        return new InquiryItemDto(it.getId(), it.getLineNo(), it.getGoodsId(), it.getColorId(),
                it.getUnitId(), it.getUnitRate(), it.getQty(), it.getPrice(), it.getAmountOriginal(),
                it.getAmountLocal(), it.getWeight(), it.getSourceDocNo(), it.getRemark());
    }

    private InquiryDetail toDetail(SubcontractInquiry r, List<InquiryItemDto> items) {
        return new InquiryDetail(r.getId(), r.getLegacyId(), r.getBillNo(), r.getBillDate(),
                r.getSupplierId(), r.getWarehouseId(), r.getCurrencyId(), r.getExchangeRate(),
                r.getMakerId(), r.getApproverId(), r.getDeliverDate(), r.getRemark(),
                r.getTotalOriginal(), r.getTotalLocal(), r.getStatus(), r.isClosed(), r.getSourceDocNo(), items,
                nameResolver.nameOf(r.getMakerId()), r.getCreatedAt());
    }

    private SubcontractInquiry requireInquiry(UUID id) {
        return inquiryRepo.findById(id)
                .filter(r -> !r.isDeleted())
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "委外询价单不存在"));
    }
}
