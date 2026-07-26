package com.uten.imp.features.stock;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.common.web.Pageables;
import com.uten.imp.features.stock.dto.StockDocDetail;
import com.uten.imp.features.stock.dto.StockDocItemDto;
import com.uten.imp.features.stock.dto.StockDocItemLine;
import com.uten.imp.features.stock.dto.StockDocListItem;
import com.uten.imp.features.stock.dto.StockDocQueryFilter;
import com.uten.imp.features.stock.dto.StockDocSaveRequest;
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
import java.time.ZoneId;
import java.util.ArrayList;
import java.util.List;
import java.util.UUID;

/**
 * 仓库管理统一单据服务（9 类 doc_type 共用）：CRUD（主+明细）+ 审核状态机 + 库存联动。
 *
 * <p>设计（doc 17）：一个 Service 覆盖全部 9 类——审核时 {@link #applyStockEffect} 按 doc_type
 * 生成 stock_movements（调拨双仓双动、盘点按盘盈亏），红冲反向。取代老库 9 套表 + 触发器。
 *
 * <p>状态机：0草稿 / 1已审 / -1红冲。审核 0→1（写库存）；红冲 1→-1（反向冲销）；编辑/删除仅草稿。
 */
@Service
@RequiredArgsConstructor
public class StockDocService {

    private static final short STATUS_DRAFT = 0;
    private static final short STATUS_APPROVED = 1;
    private static final short STATUS_REVERSED = -1;

    /** 来源单据类型（与迁移 source_doc_type='STOCK_DOC' 对齐，报表/流水同源）。 */
    public static final String SRC_STOCK_DOC = "STOCK_DOC";

    /** movement_type（V45 1-12 + 本模块 13/14）。 */
    private static final short T_OTHER_IN = 11, T_OTHER_OUT = 12;
    private static final short T_DRAW = 5, T_WDRAW = 6;
    private static final short T_FINISHED_IN = 13, T_FINISHED_OUT = 14;
    private static final short T_TRANSFER_OUT = 8, T_TRANSFER_IN = 7;
    private static final short T_CHECK_GAIN = 9, T_CHECK_LOSS = 10;

    private static final short DIR_IN = 1, DIR_OUT = -1;

    private final StockDocumentRepository docRepo;
    private final StockDocumentItemRepository itemRepo;
    private final StockService stockService;
    private final TxSessionVars tx;

    // ===== 列表 =====

    @Transactional(readOnly = true)
    public PageResponse<StockDocListItem> list(StockDocQueryFilter f, int page, int size) {
        Specification<StockDocument> spec = (Root<StockDocument> root,
                                             jakarta.persistence.criteria.CriteriaQuery<?> q,
                                             CriteriaBuilder cb) -> {
            List<Predicate> ps = new ArrayList<>();
            ps.add(cb.isFalse(root.get("deleted")));
            if (f.docType() != null && !f.docType().isBlank()) {
                ps.add(cb.equal(root.get("docType"), f.docType()));
            }
            if (f.keyword() != null && !f.keyword().isBlank()) {
                ps.add(cb.like(cb.lower(root.get("billNo")), "%" + f.keyword().toLowerCase() + "%"));
            }
            if (f.warehouseId() != null) ps.add(cb.equal(root.get("warehouseId"), f.warehouseId()));
            if (f.status() != null) ps.add(cb.equal(root.get("status"), f.status()));
            if (f.dateFrom() != null) ps.add(cb.greaterThanOrEqualTo(root.get("billDate"), f.dateFrom()));
            if (f.dateTo() != null) ps.add(cb.lessThanOrEqualTo(root.get("billDate"), f.dateTo()));
            return cb.and(ps.toArray(new Predicate[0]));
        };
        Pageable pageable = Pageables.of(page, size, Sort.by(Sort.Direction.DESC, "billDate"));
        Page<StockDocument> p = docRepo.findAll(spec, pageable);
        return new PageResponse<>(p.map(this::toList).getContent(), page, size,
                p.getTotalElements(), p.getTotalPages());
    }

    // ===== 详情 =====

    @Transactional(readOnly = true)
    public StockDocDetail detail(UUID id) {
        StockDocument d = requireDoc(id);
        List<StockDocItemDto> items = itemRepo.findByDocIdOrderByLineNoAsc(id).stream()
                .map(this::toItemDto).toList();
        return toDetail(d, items);
    }

    // ===== CRUD =====

    @Transactional
    public StockDocDetail create(StockDocSaveRequest req) {
        tx.bind();
        StockDocument d = new StockDocument();
        applyHeader(req, d);
        d.setStatus(STATUS_DRAFT);
        docRepo.save(d);
        List<StockDocItemDto> items = saveItems(d, req.getItems());
        applyTotals(d, items);
        return toDetail(d, items);
    }

    @Transactional
    public StockDocDetail update(UUID id, StockDocSaveRequest req) {
        tx.bind();
        StockDocument d = requireDoc(id);
        if (d.getStatus() != STATUS_DRAFT) throw new ApiException(ErrorCode.BUSINESS, "仅草稿单据可编辑");
        applyHeader(req, d);
        itemRepo.deleteByDocId(id);
        itemRepo.flush();
        List<StockDocItemDto> items = saveItems(d, req.getItems());
        applyTotals(d, items);
        return toDetail(d, items);
    }

    @Transactional
    public void delete(UUID id) {
        tx.bind();
        StockDocument d = requireDoc(id);
        if (d.getStatus() == STATUS_APPROVED)
            throw new ApiException(ErrorCode.BUSINESS, "已审核单据不可删，请红冲");
        d.setDeleted(true);
        d.setDeletedAt(OffsetDateTime.now());
        docRepo.save(d);
    }

    // ===== 审核 / 红冲（库存联动） =====

    /** 审核：0→1，按 doc_type 写库存（流水+余额）。 */
    @Transactional
    public StockDocDetail approve(UUID id) {
        tx.bind();
        StockDocument d = requireDoc(id);
        if (d.getStatus() == null || d.getStatus() != STATUS_DRAFT)
            throw new ApiException(ErrorCode.BUSINESS, "仅草稿单据可审核");
        List<StockDocumentItem> items = itemRepo.findByDocIdOrderByLineNoAsc(id);
        if (items.isEmpty()) throw new ApiException(ErrorCode.BUSINESS, "明细为空，不可审核");
        applyStockEffect(d, items, +1);
        d.setStatus(STATUS_APPROVED);
        docRepo.save(d);
        return detail(id);
    }

    /** 红冲：1→-1，反向冲销库存。 */
    @Transactional
    public StockDocDetail reverse(UUID id) {
        tx.bind();
        StockDocument d = requireDoc(id);
        if (d.getStatus() == null || d.getStatus() != STATUS_APPROVED)
            throw new ApiException(ErrorCode.BUSINESS, "仅已审核单据可红冲");
        List<StockDocumentItem> items = itemRepo.findByDocIdOrderByLineNoAsc(id);
        applyStockEffect(d, items, -1);
        d.setStatus(STATUS_REVERSED);
        docRepo.save(d);
        return detail(id);
    }

    /**
     * 按 doc_type 生成库存流水（调 {@link StockService#recordMovement}）。
     *
     * @param sign +1=审核（正方向）/ -1=红冲（反方向）
     */
    private void applyStockEffect(StockDocument d, List<StockDocumentItem> items, int sign) {
        OffsetDateTime ts = d.getBillDate() == null ? OffsetDateTime.now()
                : d.getBillDate().atStartOfDay(ZoneId.systemDefault()).toOffsetDateTime();
        for (StockDocumentItem it : items) {
            if (it.getGoodsId() == null) continue;
            BigDecimal baseQty = baseQty(it);
            switch (d.getDocType()) {
                case "OTHER_IN" -> move(d, it, T_OTHER_IN, DIR_IN, baseQty, d.getWarehouseId(), ts, sign);
                case "OTHER_OUT", "WASTE" -> move(d, it, T_OTHER_OUT, DIR_OUT, baseQty, d.getWarehouseId(), ts, sign);
                case "DRAW" -> move(d, it, T_DRAW, DIR_OUT, baseQty, d.getWarehouseId(), ts, sign);
                case "WDRAW" -> move(d, it, T_WDRAW, DIR_IN, baseQty, d.getWarehouseId(), ts, sign);
                case "FINISHED_IN" -> move(d, it, T_FINISHED_IN, DIR_IN, baseQty, d.getWarehouseId(), ts, sign);
                case "FINISHED_OUT" -> move(d, it, T_FINISHED_OUT, DIR_OUT, baseQty, d.getWarehouseId(), ts, sign);
                case "TRANSFER" -> {
                    if (d.getWarehouseId() != null)
                        move(d, it, T_TRANSFER_OUT, DIR_OUT, baseQty, d.getWarehouseId(), ts, sign);
                    if (d.getToWarehouseId() != null)
                        move(d, it, T_TRANSFER_IN, DIR_IN, baseQty, d.getToWarehouseId(), ts, sign);
                }
                case "CHECK" -> {
                    BigDecimal surplus = it.getSurplusQty();
                    if (surplus == null || surplus.signum() == 0) continue;
                    if (surplus.signum() > 0)
                        move(d, it, T_CHECK_GAIN, DIR_IN, surplus, d.getWarehouseId(), ts, sign);
                    else
                        move(d, it, T_CHECK_LOSS, DIR_OUT, surplus.abs(), d.getWarehouseId(), ts, sign);
                }
                default -> { /* 未识别类型不动库存 */ }
            }
        }
    }

    /** base_qty = qty × unit_rate（库存基本量）。 */
    private BigDecimal baseQty(StockDocumentItem it) {
        BigDecimal qty = it.getQty() == null ? BigDecimal.ZERO : it.getQty();
        BigDecimal rate = it.getUnitRate() == null ? BigDecimal.ONE : it.getUnitRate();
        return qty.multiply(rate);
    }

    /** 写一笔流水：审核用 naturalDir，红冲反向（naturalDir × sign）。 */
    private void move(StockDocument d, StockDocumentItem it, short type, short naturalDir,
                      BigDecimal qty, UUID warehouseId, OffsetDateTime ts, int sign) {
        if (warehouseId == null || qty == null || qty.signum() == 0) return;
        short dir = (short) (naturalDir * sign);
        stockService.recordMovement(new StockService.MovementRequest(
                ts, type, SRC_STOCK_DOC, d.getId(), it.getId(),
                it.getGoodsId(), it.getColorId(), warehouseId, dir, qty,
                it.getUnitId(), it.getUnitRate(), it.getAmountLocal(), it.getRemark()));
    }

    // ===== 私有映射 =====

    private void applyHeader(StockDocSaveRequest req, StockDocument d) {
        d.setDocType(req.getDocType());
        d.setBillNo(req.getBillNo());
        d.setBillDate(req.getBillDate());
        d.setWarehouseId(req.getWarehouseId());
        d.setToWarehouseId(req.getToWarehouseId());
        d.setSupplierId(req.getSupplierId());
        d.setClientId(req.getClientId());
        d.setWorkerId(req.getWorkerId());
        d.setMakerId(req.getMakerId());
        d.setApproverId(req.getApproverId());
        d.setAssTeam(req.getAssTeam());
        d.setPlanNo(req.getPlanNo());
        d.setRemark(req.getRemark());
    }

    private List<StockDocItemDto> saveItems(StockDocument d, List<StockDocItemLine> lines) {
        List<StockDocItemDto> out = new ArrayList<>(lines.size());
        int auto = 1;
        for (StockDocItemLine l : lines) {
            StockDocumentItem it = new StockDocumentItem();
            it.setDocId(d.getId());
            it.setBillType(d.getDocType());
            it.setBillNo(d.getBillNo());
            it.setBillDate(d.getBillDate());
            it.setLineNo(l.getLineNo() != null ? l.getLineNo() : auto);
            it.setGoodsId(l.getGoodsId());
            it.setColorId(l.getColorId());
            it.setUnitId(l.getUnitId());
            it.setUnitRate(l.getUnitRate());
            it.setQty(l.getQty());
            it.setBaseQty(baseQtyOf(l));
            it.setPrice(l.getPrice());
            it.setAmountOriginal(l.getAmountOriginal());
            it.setAmountLocal(l.getAmountLocal() != null ? l.getAmountLocal() : l.getAmountOriginal());
            it.setWeight(l.getWeight());
            it.setGiftQty(l.getGiftQty() != null ? l.getGiftQty() : BigDecimal.ZERO);
            it.setSurplusQty(l.getSurplusQty());
            it.setCountQty(l.getCountQty());
            it.setPlace(l.getPlace());
            it.setUpstreamItemId(l.getUpstreamItemId());
            it.setSourceDocNo(l.getSourceDocNo());
            it.setRemark(l.getRemark());
            itemRepo.save(it);
            out.add(toItemDto(it));
            auto++;
        }
        return out;
    }

    private BigDecimal baseQtyOf(StockDocItemLine l) {
        BigDecimal qty = l.getQty() == null ? BigDecimal.ZERO : l.getQty();
        BigDecimal rate = l.getUnitRate() == null ? BigDecimal.ONE : l.getUnitRate();
        return qty.multiply(rate);
    }

    private void applyTotals(StockDocument d, List<StockDocItemDto> items) {
        BigDecimal local = items.stream().map(i -> i.getAmountLocal() == null ? BigDecimal.ZERO : i.getAmountLocal())
                .reduce(BigDecimal.ZERO, BigDecimal::add);
        BigDecimal original = items.stream().map(i -> i.getAmountOriginal() == null ? BigDecimal.ZERO : i.getAmountOriginal())
                .reduce(BigDecimal.ZERO, BigDecimal::add);
        d.setTotalLocal(local);
        d.setTotalOriginal(original);
        docRepo.save(d);
    }

    private StockDocListItem toList(StockDocument d) {
        return new StockDocListItem(d.getId(), d.getDocType(), d.getBillNo(), d.getBillDate(),
                d.getWarehouseId(), d.getToWarehouseId(), d.getTotalLocal(), d.getStatus(),
                d.isClosed(), d.getLegacyId());
    }

    private StockDocItemDto toItemDto(StockDocumentItem it) {
        return new StockDocItemDto(it.getId(), it.getLineNo(), it.getGoodsId(), it.getColorId(),
                it.getUnitId(), it.getUnitRate(), it.getQty(), it.getBaseQty(), it.getPrice(),
                it.getAmountOriginal(), it.getAmountLocal(), it.getWeight(), it.getGiftQty(),
                it.getSurplusQty(), it.getCountQty(), it.getPlace(), it.getUpstreamItemId(),
                it.getSourceDocNo(), it.getRemark(), it.getBillDate());
    }

    private StockDocDetail toDetail(StockDocument d, List<StockDocItemDto> items) {
        return new StockDocDetail(d.getId(), d.getLegacyId(), d.getDocType(), d.getBillNo(), d.getBillDate(),
                d.getWarehouseId(), d.getToWarehouseId(), d.getSupplierId(), d.getClientId(),
                d.getWorkerId(), d.getMakerId(), d.getApproverId(), d.getAssTeam(), d.getPlanNo(), d.getRemark(),
                d.getTotalOriginal(), d.getTotalLocal(), d.getStatus(), d.isClosed(),
                d.getSourceDocNo(), items);
    }

    private StockDocument requireDoc(UUID id) {
        return docRepo.findById(id).filter(d -> !d.isDeleted())
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "仓库单据不存在"));
    }
}
