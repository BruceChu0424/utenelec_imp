package com.uten.imp.features.production.dailyreport;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.common.web.Pageables;
import com.uten.imp.common.web.TableSort;
import com.uten.imp.common.docnumber.DocNumberPrefix;
import com.uten.imp.common.docnumber.DocNumberService;
import com.uten.imp.features.production.dailyreport.dto.DailyReportDetail;
import com.uten.imp.features.production.dailyreport.dto.DailyReportItemDto;
import com.uten.imp.features.production.dailyreport.dto.DailyReportItemLine;
import com.uten.imp.features.production.dailyreport.dto.DailyReportListItem;
import com.uten.imp.features.production.dailyreport.dto.DailyReportQueryFilter;
import com.uten.imp.features.production.dailyreport.dto.DailyReportSaveRequest;
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

import java.time.OffsetDateTime;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.UUID;

/**
 * 生产日报服务：CRUD（主+明细）+ 审核（<b>本期空结构保未来</b>）。
 *
 * <p>老库 F_DateReport 从未启用（design §3.4），本期建空结构 CRUD 保未来零成本启用。
 *
 * <p>审核（status 0→1）：<b>本期仅置状态</b>，不调 {@code StockService}。
 * <p>【本期后置】未来日报审核需调 {@code StockService.recordMovement(TYPE_PRODUCTION_IN/OUT)}
 * 写产成品进仓等库存联动（design §四 F_DateReport 触发器全 0；待车间/工序模块上线后实现）。
 */
@Service
@RequiredArgsConstructor
public class ProductionDailyReportService {

    private static final short STATUS_DRAFT = 0;
    private static final short STATUS_APPROVED = 1;
    private static final short STATUS_REVERSED = -1;

    /** 列排序白名单：前端列 key → JPA 实体属性名（日期可排序；命中才排序，否则默认 billDate DESC）。 */
    private static final Map<String, String> ALLOWED_SORT = Map.of("billDate", "billDate");

    private final ProductionDailyReportRepository reportRepo;
    private final ProductionDailyReportItemRepository itemRepo;
    private final TxSessionVars tx;
    private final DocNumberService docNumberService;

    @Transactional(readOnly = true)
    public PageResponse<DailyReportListItem> list(DailyReportQueryFilter f, int page, int size, String sort, String order) {
        Specification<ProductionDailyReport> spec = (Root<ProductionDailyReport> root,
                                                     jakarta.persistence.criteria.CriteriaQuery<?> q,
                                                     CriteriaBuilder cb) -> {
            List<Predicate> ps = new ArrayList<>();
            ps.add(cb.isFalse(root.get("deleted")));
            if (f.keyword() != null && !f.keyword().isBlank()) {
                ps.add(cb.like(cb.lower(root.get("billNo")), "%" + f.keyword().toLowerCase() + "%"));
            }
            if (f.warehouseId() != null) ps.add(cb.equal(root.get("warehouseId"), f.warehouseId()));
            if (f.departmentId() != null) ps.add(cb.equal(root.get("departmentId"), f.departmentId()));
            if (f.workerId() != null) ps.add(cb.equal(root.get("workerId"), f.workerId()));
            if (f.status() != null) ps.add(cb.equal(root.get("status"), f.status()));
            if (f.dateFrom() != null) ps.add(cb.greaterThanOrEqualTo(root.get("billDate"), f.dateFrom()));
            if (f.dateTo() != null) ps.add(cb.lessThanOrEqualTo(root.get("billDate"), f.dateTo()));
            return cb.and(ps.toArray(new Predicate[0]));
        };
        Pageable pageable = Pageables.of(page, size,
                TableSort.resolve(sort, order, Sort.by(Sort.Direction.DESC, "billDate"), ALLOWED_SORT));
        Page<ProductionDailyReport> p = reportRepo.findAll(spec, pageable);
        return new PageResponse<>(p.map(this::toList).getContent(), page, size, p.getTotalElements(), p.getTotalPages());
    }

    @Transactional(readOnly = true)
    public DailyReportDetail detail(UUID id) {
        ProductionDailyReport r = requireReport(id);
        List<DailyReportItemDto> items = itemRepo.findByReportIdOrderByLineNoAsc(id).stream().map(this::toItemDto).toList();
        return toDetail(r, items);
    }

    @Transactional
    public DailyReportDetail create(DailyReportSaveRequest req) {
        tx.bind();
        ProductionDailyReport r = new ProductionDailyReport();
        applyHeader(req, r);
        r.setStatus(STATUS_DRAFT);
        reportRepo.save(r);
        saveItems(r, req.getItems());
        return detail(r.getId());
    }

    @Transactional
    public DailyReportDetail update(UUID id, DailyReportSaveRequest req) {
        tx.bind();
        ProductionDailyReport r = requireReport(id);
        if (r.getStatus() != STATUS_DRAFT) throw new ApiException(ErrorCode.BUSINESS, "仅草稿单据可编辑");
        applyHeader(req, r);
        itemRepo.deleteByReportId(id);
        itemRepo.flush();
        saveItems(r, req.getItems());
        return detail(id);
    }

    @Transactional
    public void delete(UUID id) {
        tx.bind();
        ProductionDailyReport r = requireReport(id);
        if (r.getStatus() == STATUS_APPROVED) throw new ApiException(ErrorCode.BUSINESS, "已审核单据不可删，请红冲");
        r.setDeleted(true);
        r.setDeletedAt(OffsetDateTime.now());
        reportRepo.save(r);
    }

    /**
     * 审核（status 0→1）。
     *
     * <p>本期仅置状态。<b>【本期后置】</b>未来需调 {@code StockService} 写产成品进仓等库存联动
     * （design §四 F_DateReport 触发器全 0；待车间/工序模块上线后实现）。
     */
    @Transactional
    public DailyReportDetail approve(UUID id) {
        tx.bind();
        ProductionDailyReport r = requireReport(id);
        if (r.getStatus() == null || r.getStatus() != STATUS_DRAFT)
            throw new ApiException(ErrorCode.BUSINESS, "仅草稿单据可审核");
        if (itemRepo.findByReportIdOrderByLineNoAsc(id).isEmpty())
            throw new ApiException(ErrorCode.BUSINESS, "明细为空，不可审核");
        r.setStatus(STATUS_APPROVED);
        reportRepo.save(r);
        // 本期后置：未来调 StockService 写产成品进仓等库存联动（design §四）
        return detail(id);
    }

    /** 红冲（status 1→-1）：本期仅置状态（无库存联动可冲）。 */
    @Transactional
    public DailyReportDetail reverse(UUID id) {
        tx.bind();
        ProductionDailyReport r = requireReport(id);
        if (r.getStatus() == null || r.getStatus() != STATUS_APPROVED)
            throw new ApiException(ErrorCode.BUSINESS, "仅已审核单据可红冲");
        r.setStatus(STATUS_REVERSED);
        reportRepo.save(r);
        return detail(id);
    }

    // ====================== 私有辅助 ======================

    private void applyHeader(DailyReportSaveRequest req, ProductionDailyReport r) {
        // 单据号系统自动生成（服务端权威）：仅新建（billNo 空）时取号；更新保留既有号，忽略客户端值。
        if (r.getBillNo() == null || r.getBillNo().isBlank()) {
            r.setBillNo(docNumberService.nextNumber(DocNumberPrefix.PROD_DAILY_REPORT));
        }
        r.setBillDate(req.getBillDate());
        r.setWarehouseId(req.getWarehouseId());
        r.setDepartmentId(req.getDepartmentId());
        r.setWorkshopName(req.getWorkshopName());
        r.setWorkerId(req.getWorkerId());
        r.setSupplierId(req.getSupplierId());
        r.setRemark(req.getRemark());
        r.setSourceDocNo(req.getSourceDocNo());
    }

    private List<DailyReportItemDto> saveItems(ProductionDailyReport r, List<DailyReportItemLine> lines) {
        List<DailyReportItemDto> out = new ArrayList<>(lines.size());
        int auto = 1;
        for (DailyReportItemLine l : lines) {
            ProductionDailyReportItem it = new ProductionDailyReportItem();
            it.setReportId(r.getId());
            it.setBillNo(r.getBillNo());
            it.setBillDate(r.getBillDate());
            it.setLineNo(l.getLineNo() != null ? l.getLineNo() : auto);
            it.setGoodsId(l.getGoodsId());
            it.setColorId(l.getColorId());
            it.setUnitId(l.getUnitId());
            it.setUnitRate(l.getUnitRate());
            it.setQty(l.getQty());
            it.setPrice(l.getPrice());
            it.setTotal(l.getTotal());
            it.setStotal(l.getStotal());
            it.setSalesOrderItemId(l.getSalesOrderItemId());
            it.setSalesOrderNo(l.getSalesOrderNo());
            it.setPlanItemId(l.getPlanItemId());
            it.setPlanNo(l.getPlanNo());
            it.setOutboundNo(l.getOutboundNo());
            it.setOutboundQty(l.getOutboundQty());
            it.setOrderQty(l.getOrderQty());
            it.setStepLegacyId(l.getStepLegacyId());
            it.setOrderDate(l.getOrderDate());
            it.setBoxes(l.getBoxes());
            it.setPerBoxQty(l.getPerBoxQty());
            it.setWeight(l.getWeight());
            it.setClientName(l.getClientName());
            it.setSourceDocNo(l.getSourceDocNo());
            it.setRemark(l.getRemark());
            itemRepo.save(it);
            out.add(toItemDto(it));
            auto++;
        }
        return out;
    }

    private DailyReportListItem toList(ProductionDailyReport r) {
        return new DailyReportListItem(r.getId(), r.getBillNo(), r.getBillDate(), r.getWarehouseId(),
                r.getDepartmentId(), r.getWorkshopName(), r.getWorkerId(), r.getSupplierId(),
                r.getStatus(), r.isClosed(), r.isCanceled(), r.getLegacyId());
    }

    private DailyReportItemDto toItemDto(ProductionDailyReportItem it) {
        return new DailyReportItemDto(it.getId(), it.getLineNo(), it.getGoodsId(), it.getColorId(),
                it.getUnitId(), it.getUnitRate(), it.getQty(), it.getPrice(), it.getTotal(), it.getStotal(),
                it.getSalesOrderItemId(), it.getSalesOrderNo(), it.getPlanItemId(), it.getPlanNo(),
                it.getOutboundNo(), it.getOutboundQty(), it.getOrderQty(), it.getStepLegacyId(),
                it.getOrderDate(), it.getBoxes(), it.getPerBoxQty(), it.getWeight(),
                it.getClientName(), it.getSourceDocNo(), it.getRemark());
    }

    private DailyReportDetail toDetail(ProductionDailyReport r, List<DailyReportItemDto> items) {
        return new DailyReportDetail(r.getId(), r.getLegacyId(), r.getBillNo(), r.getBillDate(),
                r.getWarehouseId(), r.getDepartmentId(), r.getWorkshopName(), r.getWorkerId(), r.getSupplierId(),
                r.getMakerId(), r.getApproverId(), r.getMakerLegacyId(), r.getApproverLegacyId(), r.getRemark(),
                r.getStatus(), r.isClosed(), r.isCanceled(), r.getSourceDocNo(), items);
    }

    private ProductionDailyReport requireReport(UUID id) {
        return reportRepo.findById(id).filter(r -> !r.isDeleted())
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "生产日报单不存在"));
    }
}
