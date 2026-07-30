package com.uten.imp.features.sales.ret;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.common.web.Pageables;
import com.uten.imp.common.web.TableSort;
import com.uten.imp.common.docnumber.DocNumberPrefix;
import com.uten.imp.common.docnumber.DocNumberService;
import com.uten.imp.features.finance.arap.ArApLedgerService;
import com.uten.imp.features.finance.arap.ArApLedgerService.ArApPostingRequest;
import com.uten.imp.features.sales.ret.dto.ReturnDetail;
import com.uten.imp.features.sales.ret.dto.ReturnItemDto;
import com.uten.imp.features.sales.ret.dto.ReturnItemLine;
import com.uten.imp.features.sales.ret.dto.ReturnListItem;
import com.uten.imp.features.sales.ret.dto.ReturnQueryFilter;
import com.uten.imp.features.sales.ret.dto.ReturnSaveRequest;
import com.uten.imp.features.stock.StockService;
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
 * 销售退货单服务：CRUD（主+明细）+ 审核状态机（库存入库 + 双挂回写 + 立红字应收 + 结案）。
 *
 * <p>审核（status 0→1）同事务内：
 * <ol>
 *   <li>逐明细 {@link StockService#recordMovement} 入库（TYPE_SALES_RETURN / DIR_IN，退货入库）</li>
 *   <li>双挂回写：sales_shipment_items.returned_qty/returned_amount += qty/amt（out_item_id 非空时）
 *       + sales_order_items.returned_qty += qty（order_item_id 非空时）+ 订货结案重算</li>
 *   <li>{@link ArApLedgerService#postArAp} 立红字应收（AR, SALES_RETURN, BStyle=18, amountOriginalLocal=负数）</li>
 *   <li>ar_posted=true</li>
 * </ol>
 *
 * <p>红冲（1→-1）同事务反向：先 {@link ArApLedgerService#reverseArAp}（钱流校验无收款核销，否则抛
 * "此单已经存在收/付款，请先反审"，对齐老库 RAISERROR）→ 反向库存（DIR_OUT 倒回）+ 回减 returned_qty
 * + 订货结案重算 + ar_posted=false。
 *
 * <p>取代老库 S_Withdraw 触发器 TRI_SWStockItem（库存段）+ 钱流立 M_in 红字段（design 20 §〇/§4.4）。
 *
 * <p>金额口径（design 20 §6.1/§7.3）：明细 amount 与主表 total 均为正数；红字负数仅在 ar_ap_ledger
 * 立帐时由 Service 取负传入（amountOriginalLocal = -totalLocal）。
 */
@Service
@RequiredArgsConstructor
public class SalesReturnService {

    private static final short STATUS_DRAFT = 0;
    private static final short STATUS_APPROVED = 1;
    private static final short STATUS_REVERSED = -1;

    /** 老库 BStyle=18 销售退货红字应收。 */
    private static final short BSTYLE_SALES_RETURN = 18;

    /** 列排序白名单：前端列 key → JPA 实体属性名（日期/金额可排序；命中才排序，否则默认 billDate DESC）。 */
    private static final Map<String, String> ALLOWED_SORT = Map.of("billDate", "billDate", "total", "totalLocal");

    private final SalesReturnRepository returnRepo;
    private final SalesReturnItemRepository itemRepo;
    private final StockService stockService;
    private final ArApLedgerService arApService;
    private final TxSessionVars tx;
    private final EntityManager em;
    private final com.uten.imp.security.SecurityContextCurrentUser currentUser;
    private final com.uten.imp.common.util.EmployeeNameResolver nameResolver;
    private final DocNumberService docNumberService;
    private final com.uten.imp.security.OwnerVisibility ownerVisibility;

    @Transactional(readOnly = true)
    public PageResponse<ReturnListItem> list(ReturnQueryFilter f, int page, int size, String sort, String order) {
        Specification<SalesReturn> spec = (Root<SalesReturn> root, jakarta.persistence.criteria.CriteriaQuery<?> q,
                                           CriteriaBuilder cb) -> {
            List<Predicate> ps = new ArrayList<>();
            ps.add(cb.isFalse(root.get("deleted")));
            // 归属可见性（销售按人授权）：公共或可见归属人；超管/sales:view:all 全见
            var ownerScope = ownerVisibility.evaluate("sales", "sales:view:all");
            if (!ownerScope.seeAll()) {
                if (ownerScope.visibleOwners().isEmpty()) {
                    ps.add(cb.isNull(root.get("ownerEmployeeId")));
                } else {
                    ps.add(cb.or(cb.isNull(root.get("ownerEmployeeId")),
                            root.get("ownerEmployeeId").in(ownerScope.visibleOwners())));
                }
            }
            if (f.keyword() != null && !f.keyword().isBlank()) {
                String kw = "%" + f.keyword().toLowerCase() + "%";
                // 关键字同时匹配 单据号 / 客户名称（日常检索按客户找单）
                jakarta.persistence.criteria.Subquery<java.util.UUID> cs = q.subquery(java.util.UUID.class);
                Root<com.uten.imp.features.master.client.Client> cr =
                        cs.from(com.uten.imp.features.master.client.Client.class);
                cs.select(cr.get("id")).where(cb.isFalse(cr.get("deleted")),
                        cb.like(cb.lower(cr.get("name")), kw));
                ps.add(cb.or(cb.like(cb.lower(root.get("billNo")), kw),
                        root.get("clientId").in(cs)));
            }
            if (f.clientId() != null) ps.add(cb.equal(root.get("clientId"), f.clientId()));
            if (f.warehouseId() != null) ps.add(cb.equal(root.get("warehouseId"), f.warehouseId()));
            if (f.status() != null) ps.add(cb.equal(root.get("status"), f.status()));
            if (f.arPosted() != null) ps.add(cb.equal(root.get("arPosted"), f.arPosted()));
            if (f.dateFrom() != null) ps.add(cb.greaterThanOrEqualTo(root.get("billDate"), f.dateFrom()));
            if (f.dateTo() != null) ps.add(cb.lessThanOrEqualTo(root.get("billDate"), f.dateTo()));
            return cb.and(ps.toArray(new Predicate[0]));
        };
        Pageable pageable = Pageables.of(page, size,
                TableSort.resolve(sort, order, Sort.by(Sort.Direction.DESC, "billDate"), ALLOWED_SORT));
        Page<SalesReturn> p = returnRepo.findAll(spec, pageable);
        return new PageResponse<>(p.map(this::toList).getContent(), page, size, p.getTotalElements(), p.getTotalPages());
    }

    @Transactional(readOnly = true)
    public ReturnDetail detail(UUID id) {
        SalesReturn r = requireReturn(id);
        List<ReturnItemDto> items = itemRepo.findByReturnIdOrderByLineNoAsc(id).stream()
                .map(this::toItemDto).toList();
        return toDetail(r, items);
    }

    @Transactional
    public ReturnDetail create(ReturnSaveRequest req) {
        tx.bind();
        SalesReturn r = new SalesReturn();
        applyHeader(req, r);
        r.setMakerId(currentUser.requireEmployeeId()); // 制单=当前登录用户（报表按 maker_id 解析制单员）
        r.setStatus(STATUS_DRAFT);
        returnRepo.save(r);
        List<ReturnItemDto> items = saveItems(r, req.getItems());
        applyTotals(r, items);
        return toDetail(r, items);
    }

    @Transactional
    public ReturnDetail update(UUID id, ReturnSaveRequest req) {
        tx.bind();
        SalesReturn r = requireReturn(id);
        if (r.getStatus() != STATUS_DRAFT) {
            throw new ApiException(ErrorCode.BUSINESS, "仅草稿单据可编辑");
        }
        applyHeader(req, r);
        itemRepo.deleteByReturnId(id);
        itemRepo.flush();
        List<ReturnItemDto> items = saveItems(r, req.getItems());
        applyTotals(r, items);
        return toDetail(r, items);
    }

    @Transactional
    public void delete(UUID id) {
        tx.bind();
        SalesReturn r = requireReturn(id);
        if (r.getStatus() == STATUS_APPROVED) {
            throw new ApiException(ErrorCode.BUSINESS, "已审核单据不可删，请红冲");
        }
        r.setDeleted(true);
        r.setDeletedAt(OffsetDateTime.now());
        returnRepo.save(r);
    }

    /**
     * 审核：status 0→1，库存入库（type=4/dir=+1）+ 双挂回写（shipment_item 与 order_item 的 returned_qty）
     * + 立红字应收（AR, SALES_RETURN, BStyle=18, 负数）+ 订货结案重算。
     */
    @Transactional
    public ReturnDetail approve(UUID id) {
        tx.bind();
        SalesReturn r = requireReturn(id);
        em.lock(r, jakarta.persistence.LockModeType.PESSIMISTIC_WRITE); // 并发审核/红冲互斥（多账号同单操作）
        if (r.getStatus() == null || r.getStatus() != STATUS_DRAFT) {
            throw new ApiException(ErrorCode.BUSINESS, "仅草稿单据可审核");
        }
        if (r.getWarehouseId() == null) {
            throw new ApiException(ErrorCode.BUSINESS, "退货单需指定仓库");
        }
        if (r.getClientId() == null) {
            throw new ApiException(ErrorCode.BUSINESS, "退货单需指定客户");
        }
        List<SalesReturnItem> items = itemRepo.findByReturnIdOrderByLineNoAsc(id);
        if (items.isEmpty()) {
            throw new ApiException(ErrorCode.BUSINESS, "明细为空，不可审核");
        }

        OffsetDateTime now = OffsetDateTime.now();
        for (SalesReturnItem it : items) {
            applyMovement(r, it, StockService.DIR_IN, now, null);
            writeback(it, +1);
        }

        // 立红字应收（AR, SALES_RETURN, BStyle=18）。金额为本币总额的负数（红字，直接冲减客户应收余额）。
        // 主表 totalLocal 为正数（与明细同号），ar_ap_ledger 端取负。
        if (!r.isArPosted()) {
            BigDecimal negAmount = r.getTotalLocal() == null ? BigDecimal.ZERO : r.getTotalLocal().negate();
            arApService.postArAp(new ArApPostingRequest(
                    "AR",
                    StockService.SRC_SALES_RETURN,
                    r.getId(), r.getBillNo(), r.getBillDate(),
                    r.getClientId(), null,
                    r.getCurrencyId(), r.getExchangeRate(),
                    negAmount,
                    BSTYLE_SALES_RETURN,
                    r.getRemark()));
            r.setArPosted(true);
        }

        r.setStatus(STATUS_APPROVED);
        r.setApproverId(currentUser.requireEmployeeId()); // 审核=当前登录用户（报表按 approver_id 解析审核员）
        r.setLastDate(now);
        returnRepo.save(r);
        return detail(id);
    }

    /**
     * 红冲：status 1→-1，先校验收款核销 → 反向库存（DIR_OUT 倒回）+ 回减 returned_qty
     * + 订货结案重算 + ar_posted=false。
     */
    @Transactional
    public ReturnDetail reverse(UUID id) {
        tx.bind();
        SalesReturn r = requireReturn(id);
        em.lock(r, jakarta.persistence.LockModeType.PESSIMISTIC_WRITE); // 并发审核/红冲互斥（多账号同单操作）
        if (r.getStatus() == null || r.getStatus() != STATUS_APPROVED) {
            throw new ApiException(ErrorCode.BUSINESS, "仅已审核单据可红冲");
        }

        // 1. 钱流先校验：若已有收款核销 → reverseArAp 抛 IllegalStateException（阻止红冲）
        if (r.isArPosted()) {
            arApService.reverseArAp(r.getId(), StockService.SRC_SALES_RETURN);
            r.setArPosted(false);
        }

        // 2. 反向库存（type=4 dir=-1 倒回）+ 回减 returned_qty
        // 反向只翻 direction；amountLocal 传正数（StockService 内部乘 direction）。negate 会致金额符号不回滚。
        List<SalesReturnItem> items = itemRepo.findByReturnIdOrderByLineNoAsc(id);
        OffsetDateTime now = OffsetDateTime.now();
        for (SalesReturnItem it : items) {
            applyMovement(r, it, StockService.DIR_OUT, now, null);
            writeback(it, -1);
        }

        r.setStatus(STATUS_REVERSED);
        returnRepo.save(r);
        return detail(id);
    }

    /** 写一笔库存流水（方向由调用方给）。qty 为明细量，baseQty = qty×unit_rate。 */
    private void applyMovement(SalesReturn r, SalesReturnItem it, short direction,
                               OffsetDateTime ts, BigDecimal overrideAmount) {
        BigDecimal rate = it.getUnitRate() == null ? BigDecimal.ONE : it.getUnitRate();
        BigDecimal baseQty = it.getQty().multiply(rate);
        BigDecimal amt = overrideAmount != null ? overrideAmount : it.getAmountLocal();
        stockService.recordMovement(new StockService.MovementRequest(
                ts, StockService.TYPE_SALES_RETURN, StockService.SRC_SALES_RETURN,
                r.getId(), it.getId(), it.getGoodsId(), it.getColorId(), r.getWarehouseId(),
                direction, baseQty, it.getUnitId(), it.getUnitRate(), amt,
                direction > 0 ? null : "红冲"));
    }

    /**
     * 双挂回写（sign=+1 审核 / -1 红冲）：
     * <ul>
     *   <li>out_item_id 非空：sales_shipment_items.returned_qty += sign×qty, returned_amount += sign×amountLocal</li>
     *   <li>order_item_id 非空：sales_order_items.returned_qty += sign×qty + 订货结案重算</li>
     * </ul>
     */
    private void writeback(SalesReturnItem it, int sign) {
        BigDecimal amt = it.getAmountLocal() == null ? BigDecimal.ZERO : it.getAmountLocal();
        if (it.getOutItemId() != null) {
            em.createNativeQuery(
                    "UPDATE sales_shipment_items SET returned_qty = COALESCE(returned_qty,0) + (:q * :s), "
                            + "returned_amount = COALESCE(returned_amount,0) + (:a * :s) WHERE id = :id")
                    .setParameter("q", it.getQty()).setParameter("a", amt).setParameter("s", sign)
                    .setParameter("id", it.getOutItemId()).executeUpdate();
        }
        if (it.getOrderItemId() != null) {
            em.createNativeQuery(
                    "UPDATE sales_order_items SET returned_qty = COALESCE(returned_qty,0) + (:q * :s) WHERE id = :id")
                    .setParameter("q", it.getQty()).setParameter("s", sign)
                    .setParameter("id", it.getOrderItemId()).executeUpdate();
            recalcOrderClosed(it.getOrderItemId());
        }
    }

    /** 重算订货单结案：所有明细 qty - shipped_qty + returned_qty - flag_qty ≤ 0 → is_closed=true。 */
    private void recalcOrderClosed(UUID orderItemId) {
        em.createNativeQuery("""
                UPDATE sales_orders o SET is_closed = (
                    SELECT COALESCE(bool_and(
                        COALESCE(i.qty,0) - COALESCE(i.shipped_qty,0)
                        + COALESCE(i.returned_qty,0) - COALESCE(i.flag_qty,0) <= 0
                    ), true)
                    FROM sales_order_items i
                    WHERE i.order_id = o.id AND COALESCE(i.is_deleted, false) = false
                ) WHERE o.id = (SELECT order_id FROM sales_order_items WHERE id = :iid)
                """).setParameter("iid", orderItemId).executeUpdate();
    }

    private void applyHeader(ReturnSaveRequest req, SalesReturn r) {
        // 单据号系统自动生成（服务端权威）：仅新建（billNo 空）时取号；更新保留既有号，忽略客户端值。
        if (r.getBillNo() == null || r.getBillNo().isBlank()) {
            r.setBillNo(docNumberService.nextNumber(DocNumberPrefix.SALES_RETURN));
        }
        r.setBillDate(req.getBillDate());
        r.setClientId(req.getClientId());
        r.setWarehouseId(req.getWarehouseId());
        r.setCurrencyId(req.getCurrencyId());
        r.setExchangeRate(req.getExchangeRate());
        r.setTaxRate(req.getTaxRate());
        r.setPaymentStyleId(req.getPaymentStyleId());
        r.setSellerId(req.getSellerId());
        r.setRemark(req.getRemark());
    }

    private List<ReturnItemDto> saveItems(SalesReturn r, List<ReturnItemLine> lines) {
        List<ReturnItemDto> out = new ArrayList<>(lines.size());
        int auto = 1;
        for (ReturnItemLine l : lines) {
            SalesReturnItem it = new SalesReturnItem();
            it.setReturnId(r.getId());
            it.setBillNo(r.getBillNo());
            it.setBillDate(r.getBillDate());
            it.setLineNo(l.getLineNo() != null ? l.getLineNo() : auto);
            it.setOutItemId(l.getOutItemId());
            it.setOrderItemId(l.getOrderItemId());
            it.setGoodsId(l.getGoodsId());
            it.setColorId(l.getColorId());
            it.setUnitId(l.getUnitId());
            it.setUnitRate(l.getUnitRate());
            it.setQty(l.getQty());
            it.setPrice(l.getPrice());
            it.setAmountOriginal(l.getAmountOriginal());
            it.setAmountLocal(l.getAmountLocal() != null ? l.getAmountLocal() : l.getAmountOriginal());
            it.setCostAmount(l.getCostAmount());
            it.setWeight(l.getWeight());
            it.setClientNo(l.getClientNo());
            it.setClientModel(l.getClientModel());
            it.setSolution(l.getSolution());
            it.setResponsible(l.getResponsible());
            it.setDiscount(l.getDiscount());
            it.setSourceDocNo(l.getSourceDocNo());
            it.setRemark(l.getRemark());
            itemRepo.save(it);
            out.add(toItemDto(it));
            auto++;
        }
        return out;
    }

    private void applyTotals(SalesReturn r, List<ReturnItemDto> items) {
        BigDecimal local = items.stream()
                .map(i -> i.getAmountLocal() == null ? BigDecimal.ZERO : i.getAmountLocal())
                .reduce(BigDecimal.ZERO, BigDecimal::add);
        BigDecimal original = items.stream()
                .map(i -> i.getAmountOriginal() == null ? BigDecimal.ZERO : i.getAmountOriginal())
                .reduce(BigDecimal.ZERO, BigDecimal::add);
        r.setTotalLocal(local);
        r.setTotalOriginal(original);
        returnRepo.save(r);
    }

    private ReturnListItem toList(SalesReturn r) {
        return new ReturnListItem(r.getId(), r.getBillNo(), r.getBillDate(), r.getClientId(),
                r.getWarehouseId(), r.getTotalLocal(), r.getStatus(), r.isClosed(), r.isArPosted(), r.getLegacyId());
    }

    private ReturnItemDto toItemDto(SalesReturnItem it) {
        return new ReturnItemDto(it.getId(), it.getLineNo(), it.getOutItemId(), it.getOrderItemId(),
                it.getGoodsId(), it.getColorId(), it.getUnitId(), it.getUnitRate(), it.getQty(), it.getPrice(),
                it.getAmountOriginal(), it.getAmountLocal(), it.getCostAmount(), it.getWeight(),
                it.getClientNo(), it.getClientModel(), it.getSolution(), it.getResponsible(),
                it.getDiscount(), it.getSourceDocNo(), it.getRemark());
    }

    private ReturnDetail toDetail(SalesReturn r, List<ReturnItemDto> items) {
        return new ReturnDetail(r.getId(), r.getLegacyId(), r.getBillNo(), r.getBillDate(),
                r.getClientId(), r.getWarehouseId(), r.getCurrencyId(), r.getExchangeRate(), r.getTaxRate(),
                r.getPaymentStyleId(), r.getSellerId(), r.getMakerId(), r.getApproverId(),
                r.getLastDate(), r.getRemark(), r.getTotalOriginal(), r.getTotalLocal(), r.getStatus(),
                r.isClosed(), r.getSourceDocNo(), r.isArPosted(), items,
                nameResolver.nameOf(r.getMakerId()), r.getCreatedAt());
    }

    private SalesReturn requireReturn(UUID id) {
        return returnRepo.findById(id).filter(r -> !r.isDeleted())
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "销售退货单不存在"));
    }
}
