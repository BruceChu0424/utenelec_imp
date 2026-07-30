package com.uten.imp.features.stock;

import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.util.NativeQueryResults;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.common.web.Pageables;
import com.uten.imp.common.web.TableSort;
import com.uten.imp.common.docnumber.DocNumberPrefix;
import com.uten.imp.common.docnumber.DocNumberService;
import com.uten.imp.features.stock.dto.StockDocDetail;
import com.uten.imp.features.stock.dto.StockDocIssueRequest;
import com.uten.imp.features.stock.dto.StockDocItemDto;
import com.uten.imp.features.stock.dto.StockDocItemLine;
import com.uten.imp.features.stock.dto.StockDocListItem;
import com.uten.imp.features.stock.dto.StockDocQueryFilter;
import com.uten.imp.features.stock.dto.StockDocSaveRequest;
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
import java.time.ZoneId;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
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

    /** DRAW 出库进度（V97）。 */
    private static final short ISSUE_NONE = 0, ISSUE_PARTIAL = 1, ISSUE_FULL = 2;

    /** 来源单据类型（与迁移 source_doc_type='STOCK_DOC' 对齐，报表/流水同源）。 */
    public static final String SRC_STOCK_DOC = "STOCK_DOC";

    /** movement_type（V45 1-12 + 本模块 13/14）。 */
    private static final short T_OTHER_IN = 11, T_OTHER_OUT = 12;
    private static final short T_DRAW = 5, T_WDRAW = 6;
    private static final short T_FINISHED_IN = 13, T_FINISHED_OUT = 14;
    private static final short T_TRANSFER_OUT = 8, T_TRANSFER_IN = 7;
    private static final short T_CHECK_GAIN = 9, T_CHECK_LOSS = 10;

    private static final short DIR_IN = 1, DIR_OUT = -1;

    /** 列排序白名单：前端列 key → JPA 实体属性名（日期/金额可排序；命中才排序，否则默认 billDate DESC）。 */
    private static final Map<String, String> ALLOWED_SORT = Map.of("billDate", "billDate", "total", "totalLocal");

    /** doc_type → 单据号前缀（无映射的 doc_type 如 WASTE 不自动生成，保留客户端值）。 */
    private static final Map<String, DocNumberPrefix> DOC_TYPE_TO_PREFIX = Map.of(
            "TRANSFER", DocNumberPrefix.STOCK_TRANSFER,
            "OTHER_IN", DocNumberPrefix.STOCK_OTHER_IN,
            "OTHER_OUT", DocNumberPrefix.STOCK_OTHER_OUT,
            "DRAW", DocNumberPrefix.STOCK_DRAW,
            "WDRAW", DocNumberPrefix.STOCK_WDRAW,
            "FINISHED_OUT", DocNumberPrefix.STOCK_FINISHED_OUT,
            "FINISHED_IN", DocNumberPrefix.STOCK_FINISHED_IN,
            "CHECK", DocNumberPrefix.STOCK_CHECK);

    private final StockDocumentRepository docRepo;
    private final StockDocumentItemRepository itemRepo;
    private final StockService stockService;
    private final StockReservationService reservationService;
    private final TxSessionVars tx;
    private final DocNumberService docNumberService;
    private final EntityManager em;
    private final com.uten.imp.security.SecurityContextCurrentUser currentUser;
    private final com.uten.imp.common.util.EmployeeNameResolver nameResolver;
    private final com.uten.imp.features.notice.ChainNoticeService chainNotice;

    // ===== 列表 =====

    @Transactional(readOnly = true)
    public PageResponse<StockDocListItem> list(StockDocQueryFilter f, int page, int size, String sort, String order) {
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
            if (f.departmentId() != null) ps.add(cb.equal(root.get("departmentId"), f.departmentId()));
            if (f.issueStatus() != null) ps.add(cb.equal(root.get("issueStatus"), f.issueStatus()));
            return cb.and(ps.toArray(new Predicate[0]));
        };
        Pageable pageable = Pageables.of(page, size,
                TableSort.resolve(sort, order, Sort.by(Sort.Direction.DESC, "billDate"), ALLOWED_SORT));
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
        d.setMakerId(currentUser.requireEmployeeId()); // 制单=当前登录用户（服务端权威，忽略客户端值）
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

    /** 审核：0→1，按 doc_type 写库存（流水+余额）。DRAW 例外：审核=确认领料单，库存由分轮出库产生（V97）。 */
    @Transactional
    public StockDocDetail approve(UUID id) {
        tx.bind();
        StockDocument d = requireDoc(id);
        em.lock(d, jakarta.persistence.LockModeType.PESSIMISTIC_WRITE); // 并发审核/红冲互斥（多账号同单操作）
        if (d.getStatus() == null || d.getStatus() != STATUS_DRAFT)
            throw new ApiException(ErrorCode.BUSINESS, "仅草稿单据可审核");
        List<StockDocumentItem> items = itemRepo.findByDocIdOrderByLineNoAsc(id);
        lockInventory(items);
        if (items.isEmpty()) throw new ApiException(ErrorCode.BUSINESS, "明细为空，不可审核");
        if (!"DRAW".equals(d.getDocType())) {
            applyStockEffect(d, items, +1);
        }
        if ("FINISHED_IN".equals(d.getDocType())) {
            applyFinishedInChain(d, items, +1); // 业务链：完工入库补预留 + 回写 iqty/produced_qty（V90）
            chainNotice.notifyFinishedInbound(d.getId()); // 旁路通知：完工/部分完工→销售，提交后发送
        }
        d.setStatus(STATUS_APPROVED);
        d.setApproverId(currentUser.requireEmployeeId()); // 审核=当前登录用户（服务端权威，忽略客户端值）
        docRepo.save(d);
        return detail(id);
    }

    /** 红冲：1→-1，反向冲销库存。DRAW 有已出库量时须先全部反出库（V97）。 */
    @Transactional
    public StockDocDetail reverse(UUID id) {
        tx.bind();
        StockDocument d = requireDoc(id);
        em.lock(d, jakarta.persistence.LockModeType.PESSIMISTIC_WRITE); // 并发审核/红冲互斥（多账号同单操作）
        if (d.getStatus() == null || d.getStatus() != STATUS_APPROVED)
            throw new ApiException(ErrorCode.BUSINESS, "仅已审核单据可红冲");
        List<StockDocumentItem> items = itemRepo.findByDocIdOrderByLineNoAsc(id);
        lockInventory(items);
        if ("DRAW".equals(d.getDocType())) {
            boolean anyIssued = items.stream().anyMatch(it ->
                    it.getIssuedQty() != null && it.getIssuedQty().signum() > 0);
            if (anyIssued) {
                throw new ApiException(ErrorCode.BUSINESS, "领料单已有出库记录，请先全部反出库再红冲");
            }
        } else {
            if ("FINISHED_IN".equals(d.getDocType())) {
                applyFinishedInChain(d, items, -1); // 先回退链（已发货的入库会拒绝，库存不动）
            }
            applyStockEffect(d, items, -1);
        }
        d.setStatus(STATUS_REVERSED);
        docRepo.save(d);
        return detail(id);
    }

    // ===== DRAW 部分出库（V97，仓库部门需求：领料单引用 + 部分出库 + 未完成保留） =====

    /**
     * 分轮出库：对「已审」DRAW 单按行扣减剩余可出量并写库存流水（T_DRAW 出库）。
     * 每行 0 < qty ≤ qty−issued_qty；金额/重量按比例分摊；全出完 is_closed=true。
     */
    @Transactional
    public StockDocDetail issue(UUID id, StockDocIssueRequest req) {
        tx.bind();
        StockDocument d = requireDrawForIssue(id);
        List<StockDocumentItem> items = itemRepo.findByDocIdOrderByLineNoAsc(id);
        lockInventory(items);
        OffsetDateTime ts = OffsetDateTime.now();
        for (StockDocIssueRequest.Line l : req.getLines()) {
            StockDocumentItem it = findItem(items, l.getItemId());
            BigDecimal remaining = it.getQty().subtract(it.getIssuedQty());
            if (l.getQty().compareTo(remaining) > 0) {
                throw new ApiException(ErrorCode.VALIDATION_FAILED,
                        "第 " + it.getLineNo() + " 行剩余可出 " + remaining.stripTrailingZeros().toPlainString()
                                + "，本次出库 " + l.getQty().stripTrailingZeros().toPlainString() + " 超出");
            }
            applyIssueMovement(d, it, l.getQty(), ts, +1);
            it.setIssuedQty(it.getIssuedQty().add(l.getQty()));
            itemRepo.save(it);
        }
        recomputeIssueStatus(d, itemRepo.findByDocIdOrderByLineNoAsc(id));
        return detail(id);
    }

    /**
     * 反出库：对称回退（库存反向流水 + issued_qty 回减）。
     * 每行 0 < qty ≤ issued_qty；回减后若不再全出完，is_closed 复位。
     */
    @Transactional
    public StockDocDetail reverseIssue(UUID id, StockDocIssueRequest req) {
        tx.bind();
        StockDocument d = requireDrawForIssue(id);
        List<StockDocumentItem> items = itemRepo.findByDocIdOrderByLineNoAsc(id);
        lockInventory(items);
        OffsetDateTime ts = OffsetDateTime.now();
        for (StockDocIssueRequest.Line l : req.getLines()) {
            StockDocumentItem it = findItem(items, l.getItemId());
            if (l.getQty().compareTo(it.getIssuedQty()) > 0) {
                throw new ApiException(ErrorCode.VALIDATION_FAILED,
                        "第 " + it.getLineNo() + " 行已出库 " + it.getIssuedQty().stripTrailingZeros().toPlainString()
                                + "，反出库 " + l.getQty().stripTrailingZeros().toPlainString() + " 超出");
            }
            applyIssueMovement(d, it, l.getQty(), ts, -1);
            it.setIssuedQty(it.getIssuedQty().subtract(l.getQty()));
            itemRepo.save(it);
        }
        recomputeIssueStatus(d, itemRepo.findByDocIdOrderByLineNoAsc(id));
        return detail(id);
    }

    /** DRAW 出库前置校验：类型 + 已审 + 行锁（与审核/红冲同一把锁，互斥并发）。 */
    private StockDocument requireDrawForIssue(UUID id) {
        StockDocument d = requireDoc(id);
        em.lock(d, jakarta.persistence.LockModeType.PESSIMISTIC_WRITE);
        if (!"DRAW".equals(d.getDocType())) {
            throw new ApiException(ErrorCode.BUSINESS, "仅生产领料单支持出库操作");
        }
        if (d.getStatus() == null || d.getStatus() != STATUS_APPROVED) {
            throw new ApiException(ErrorCode.BUSINESS, "领料单须先审核再出库");
        }
        return d;
    }

    private StockDocumentItem findItem(List<StockDocumentItem> items, UUID itemId) {
        return items.stream().filter(it -> it.getId().equals(itemId)).findFirst()
                .orElseThrow(() -> new ApiException(ErrorCode.VALIDATION_FAILED, "明细行不存在于本单: " + itemId));
    }

    private void lockInventory(List<StockDocumentItem> items) {
        stockService.lockInventory(items.stream()
                .filter(it -> it.getGoodsId() != null)
                .map(it -> new InventoryKey(it.getGoodsId(), it.getColorId()))
                .toList());
    }

    /**
     * 出库/反出库库存流水：数量按本次 qty（×unit_rate 转基本量），金额/重量按 本次/行总量 比例分摊。
     * sign +1=出库（DIR_OUT）/ -1=反出库（反向 DIR_IN）。
     */
    private void applyIssueMovement(StockDocument d, StockDocumentItem it, BigDecimal issueQty,
                                    OffsetDateTime ts, int sign) {
        BigDecimal rate = it.getUnitRate() == null ? BigDecimal.ONE : it.getUnitRate();
        BigDecimal baseQty = issueQty.multiply(rate);
        BigDecimal ratio = it.getQty().signum() == 0 ? BigDecimal.ZERO
                : issueQty.divide(it.getQty(), 6, java.math.RoundingMode.HALF_UP);
        BigDecimal amount = it.getAmountLocal() == null ? null : it.getAmountLocal().multiply(ratio);
        BigDecimal weight = it.getWeight() == null ? null : it.getWeight().multiply(ratio).multiply(rate);
        if (d.getWarehouseId() == null || baseQty.signum() == 0) return;
        stockService.recordMovement(new StockService.MovementRequest(
                ts, T_DRAW, SRC_STOCK_DOC, d.getId(), it.getId(),
                it.getGoodsId(), it.getColorId(), d.getWarehouseId(), (short) (DIR_OUT * sign), baseQty,
                it.getUnitId(), it.getUnitRate(), amount, it.getRemark(), weight));
    }

    /** 派生 issue_status：全部出完=2 / 有出库=1 / 未出库=0；全出完 is_closed=true，否则复位。 */
    private void recomputeIssueStatus(StockDocument d, List<StockDocumentItem> items) {
        boolean anyIssued = false, allIssued = true;
        for (StockDocumentItem it : items) {
            BigDecimal issued = it.getIssuedQty() == null ? BigDecimal.ZERO : it.getIssuedQty();
            if (issued.signum() > 0) anyIssued = true;
            if (issued.compareTo(it.getQty()) < 0) allIssued = false;
        }
        short st = !anyIssued ? ISSUE_NONE : (allIssued ? ISSUE_FULL : ISSUE_PARTIAL);
        d.setIssueStatus(st);
        d.setClosed(st == ISSUE_FULL);
        docRepo.save(d);
    }

    // ===== 业务链：成品入库 ↔ 订单行（V90，docs/07-业务链路/02 §三） =====

    /**
     * 成品入库链联动：
     * <b>审核（+1）</b>——按 plan_draw_links 找到来源计划，把入库量 FIFO 分摊到挂订单行的计划明细：
     * 回写 production_plan_items.iqty（顺带修复 MRP 依赖但从未回写的缺口）与 links.inbound_qty；
     * 入库即补预留（source=1，绑入库仓）；订单行 produced_qty/reserved_qty 回写，行状态 6部分完工/7可发货；
     * 最后重算计划 is_closed。无计划关联的手工入库单只动库存、不进链。
     * <b>红冲（-1）</b>——先释放本单补的预留（已发货则拒绝，库存不动），再对称回退各累计量。
     */
    private void applyFinishedInChain(StockDocument d, List<StockDocumentItem> items, int sign) {
        List<UUID> planIds = NativeQueryResults.typedRows(em.createNativeQuery("""
                SELECT l.plan_id FROM plan_draw_links l
                WHERE l.draw_id = :did AND l.is_deleted = false LIMIT 1
                """).setParameter("did", d.getId()), UUID.class);
        UUID planId = planIds.isEmpty() ? null : planIds.getFirst();
        if (sign < 0) {
            reservationService.releaseBySourceDoc("PRODUCTION_INBOUND", d.getId()); // 已消耗(已发货)抛错
        }
        for (StockDocumentItem it : items) {
            if (it.getGoodsId() == null) continue;
            BigDecimal baseQty = baseQty(it);
            if (baseQty.signum() <= 0) continue;
            if (planId == null) continue; // 手工入库：无计划关联不进链
            allocateFinishedIn(d, it, planId, baseQty, sign);
        }
    }

    /** 入库量按计划明细 FIFO 分摊（审核取 qty−iqty>0 正序；红冲取 iqty>0 倒序对称回退）。 */
    private void allocateFinishedIn(StockDocument d, StockDocumentItem it, UUID planId,
                                    BigDecimal baseQty, int sign) {
        String cond = sign > 0
                ? "COALESCE(i.qty,0) - COALESCE(i.iqty,0) > 0 ORDER BY i.line_no"
                : "COALESCE(i.iqty,0) > 0 ORDER BY i.line_no DESC";
        String remainExpr = sign > 0
                ? "COALESCE(i.qty,0) - COALESCE(i.iqty,0)"
                : "COALESCE(i.iqty,0)";
        List<Object[]> rows = NativeQueryResults.objectArrayRows(em.createNativeQuery(
                "SELECT i.id, i.sales_order_item_id, " + remainExpr + " AS remain"
                        + " FROM production_plan_items i"
                        + " WHERE i.plan_id = :pid AND i.is_deleted = false"
                        + " AND i.goods_id = :gid"
                        + " AND (i.color_id IS NOT DISTINCT FROM CAST(:cid AS uuid))"
                        + " AND i.sales_order_item_id IS NOT NULL AND " + cond)
                .setParameter("pid", planId)
                .setParameter("gid", it.getGoodsId())
                .setParameter("cid", it.getColorId()));
        BigDecimal remaining = baseQty;
        for (Object[] r : rows) {
            if (remaining.signum() <= 0) break;
            UUID planItemId = (UUID) r[0];
            UUID orderItemId = (UUID) r[1];
            BigDecimal chunk = ((BigDecimal) r[2]).min(remaining);
            remaining = remaining.subtract(chunk);
            BigDecimal delta = sign > 0 ? chunk : chunk.negate();
            // 计划明细 iqty（is_closed 派生依赖）
            em.createNativeQuery("UPDATE production_plan_items SET iqty = COALESCE(iqty,0) + :d WHERE id = :id")
                    .setParameter("d", delta).setParameter("id", planItemId).executeUpdate();
            // links.inbound_qty（红冲不回退成负，兜底 GREATEST 0）
            em.createNativeQuery("""
                    UPDATE plan_order_item_links
                    SET inbound_qty = GREATEST(0, COALESCE(inbound_qty,0) + :d), updated_at = now()
                    WHERE plan_item_id = :pi AND order_item_id = :oi AND is_deleted = false
                    """).setParameter("d", delta).setParameter("pi", planItemId)
                    .setParameter("oi", orderItemId).executeUpdate();
            if (sign > 0) {
                // 入库即补预留（绑入库仓，溯源本单，红冲按来源单释放）
                reservationService.reserve(orderItemId, it.getGoodsId(), it.getColorId(),
                        d.getWarehouseId(), chunk, StockReservation.SOURCE_PRODUCTION_IN,
                        "PRODUCTION_INBOUND", d.getId());
                // 订单行：produced/reserved 回写 + 行状态（1-6 低态才推进；齐→7 未齐→6）
                em.createNativeQuery("""
                        UPDATE sales_order_items
                        SET produced_qty = COALESCE(produced_qty,0) + :c,
                            reserved_qty = COALESCE(reserved_qty,0) + :c,
                            chain_status = CASE WHEN COALESCE(chain_status,0) BETWEEN 1 AND 6 THEN
                                CASE WHEN COALESCE(reserved_qty,0) + :c >= COALESCE(qty,0) - COALESCE(shipped_qty,0)
                                     THEN 7 ELSE 6 END
                            ELSE chain_status END
                        WHERE id = :id
                        """).setParameter("c", chunk).setParameter("id", orderItemId).executeUpdate();
            } else {
                // 红冲回退：produced/reserved 回减 + 行状态回退（齐→7 / 已排产→4 / 否则→2；仅 6/7 态回退）
                em.createNativeQuery("""
                        UPDATE sales_order_items
                        SET produced_qty = GREATEST(0, COALESCE(produced_qty,0) - :c),
                            reserved_qty = GREATEST(0, COALESCE(reserved_qty,0) - :c),
                            chain_status = CASE WHEN COALESCE(chain_status,0) IN (6,7) THEN
                                CASE
                                  WHEN GREATEST(0, COALESCE(reserved_qty,0) - :c)
                                       >= COALESCE(qty,0) - COALESCE(shipped_qty,0) THEN 7
                                  WHEN COALESCE(planned_qty,0) > 0 THEN 4
                                  ELSE 2 END
                            ELSE chain_status END
                        WHERE id = :id
                        """).setParameter("c", chunk).setParameter("id", orderItemId).executeUpdate();
            }
        }
        if (sign > 0 || !rows.isEmpty()) {
            recomputePlanClosed(planId);
        }
    }

    /** 重算生产计划 is_closed（与 ProductionPlanService.recomputeClosed 同口径）。 */
    private void recomputePlanClosed(UUID planId) {
        em.createNativeQuery("""
                UPDATE production_plans p SET is_closed = (
                    SELECT COALESCE(bool_and(COALESCE(i.qty,0) - COALESCE(i.iqty,0) <= 0), true)
                    FROM production_plan_items i
                    WHERE i.plan_id = p.id AND COALESCE(i.is_deleted, false) = false
                ) WHERE p.id = :pid
                """).setParameter("pid", planId).executeUpdate();
    }

    /**
     * 按 doc_type 生成库存流水（调 {@link StockService#recordMovement}）。
     *
     * @param sign +1=审核（正方向）/ -1=红冲（反方向）
     */
    private void applyStockEffect(StockDocument d, List<StockDocumentItem> items, int sign) {
        OffsetDateTime ts = d.getBillDate() == null ? OffsetDateTime.now()
                : d.getBillDate().atStartOfDay(BusinessTime.ZONE).toOffsetDateTime();
        for (StockDocumentItem it : items) {
            if (it.getGoodsId() == null) continue;
            BigDecimal baseQty = baseQty(it);
            // 基本重量 = 明细 weight × unit_rate（与 baseQty 同口径；无重量则为 null，余额重量不动）。
            BigDecimal baseWgt = baseWeight(it);
            switch (d.getDocType()) {
                case "OTHER_IN" -> move(d, it, T_OTHER_IN, DIR_IN, baseQty, baseWgt, d.getWarehouseId(), ts, sign);
                case "OTHER_OUT", "WASTE" -> move(d, it, T_OTHER_OUT, DIR_OUT, baseQty, baseWgt, d.getWarehouseId(), ts, sign);
                case "DRAW" -> move(d, it, T_DRAW, DIR_OUT, baseQty, baseWgt, d.getWarehouseId(), ts, sign);
                case "WDRAW" -> move(d, it, T_WDRAW, DIR_IN, baseQty, baseWgt, d.getWarehouseId(), ts, sign);
                case "FINISHED_IN" -> move(d, it, T_FINISHED_IN, DIR_IN, baseQty, baseWgt, d.getWarehouseId(), ts, sign);
                case "FINISHED_OUT" -> move(d, it, T_FINISHED_OUT, DIR_OUT, baseQty, baseWgt, d.getWarehouseId(), ts, sign);
                case "TRANSFER" -> {
                    if (d.getWarehouseId() != null)
                        move(d, it, T_TRANSFER_OUT, DIR_OUT, baseQty, baseWgt, d.getWarehouseId(), ts, sign);
                    if (d.getToWarehouseId() != null)
                        move(d, it, T_TRANSFER_IN, DIR_IN, baseQty, baseWgt, d.getToWarehouseId(), ts, sign);
                }
                case "CHECK" -> {
                    BigDecimal surplus = it.getSurplusQty();
                    if (surplus == null || surplus.signum() == 0) continue;
                    // 盘点只记差额数量；盘盈盘亏无单重口径，重量传 null（不动余额重量，避免错账）。
                    if (surplus.signum() > 0)
                        move(d, it, T_CHECK_GAIN, DIR_IN, surplus, null, d.getWarehouseId(), ts, sign);
                    else
                        move(d, it, T_CHECK_LOSS, DIR_OUT, surplus.abs(), null, d.getWarehouseId(), ts, sign);
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

    /** base_weight = weight × unit_rate（V80 即时库存重量基本量）；明细无重量返回 null。 */
    private BigDecimal baseWeight(StockDocumentItem it) {
        if (it.getWeight() == null) return null;
        BigDecimal rate = it.getUnitRate() == null ? BigDecimal.ONE : it.getUnitRate();
        return it.getWeight().multiply(rate);
    }

    /** 写一笔流水：审核用 naturalDir，红冲反向（naturalDir × sign）。weight 传正数，由 recordMovement 乘 direction。 */
    private void move(StockDocument d, StockDocumentItem it, short type, short naturalDir,
                      BigDecimal qty, BigDecimal weight, UUID warehouseId, OffsetDateTime ts, int sign) {
        if (warehouseId == null || qty == null || qty.signum() == 0) return;
        short dir = (short) (naturalDir * sign);
        stockService.recordMovement(new StockService.MovementRequest(
                ts, type, SRC_STOCK_DOC, d.getId(), it.getId(),
                it.getGoodsId(), it.getColorId(), warehouseId, dir, qty,
                it.getUnitId(), it.getUnitRate(), it.getAmountLocal(), it.getRemark(), weight));
    }

    // ===== 私有映射 =====

    private void applyHeader(StockDocSaveRequest req, StockDocument d) {
        d.setDocType(req.getDocType());
        // 单据号系统自动生成（服务端权威）：仅新建（billNo 空）时按 doc_type 取号；无映射类型（如 WASTE）保留客户端值；更新保留既有号。
        if (d.getBillNo() == null || d.getBillNo().isBlank()) {
            DocNumberPrefix prefix = DOC_TYPE_TO_PREFIX.get(d.getDocType());
            if (prefix != null) {
                d.setBillNo(docNumberService.nextNumber(prefix));
            }
        }
        d.setBillDate(req.getBillDate());
        d.setWarehouseId(req.getWarehouseId());
        d.setToWarehouseId(req.getToWarehouseId());
        d.setSupplierId(req.getSupplierId());
        d.setClientId(req.getClientId());
        d.setWorkerId(req.getWorkerId());
        // 制单员/审核员为服务端权威字段：建单/审核时由当前登录用户写入，忽略客户端传值（防伪造、划分责任）。
        d.setAssTeam(req.getAssTeam());
        d.setDepartmentId(req.getDepartmentId());
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
                d.isClosed(), d.getLegacyId(), d.getDepartmentId(),
                "DRAW".equals(d.getDocType()) ? d.getIssueStatus() : null);
    }

    private StockDocItemDto toItemDto(StockDocumentItem it) {
        return new StockDocItemDto(it.getId(), it.getLineNo(), it.getGoodsId(), it.getColorId(),
                it.getUnitId(), it.getUnitRate(), it.getQty(), it.getBaseQty(), it.getPrice(),
                it.getAmountOriginal(), it.getAmountLocal(), it.getWeight(), it.getGiftQty(),
                it.getSurplusQty(), it.getCountQty(), it.getPlace(), it.getUpstreamItemId(),
                it.getSourceDocNo(), it.getRemark(), it.getBillDate(), it.getIssuedQty());
    }

    private StockDocDetail toDetail(StockDocument d, List<StockDocItemDto> items) {
        return new StockDocDetail(d.getId(), d.getLegacyId(), d.getDocType(), d.getBillNo(), d.getBillDate(),
                d.getWarehouseId(), d.getToWarehouseId(), d.getSupplierId(), d.getClientId(),
                d.getWorkerId(), d.getMakerId(), d.getApproverId(), d.getAssTeam(), d.getPlanNo(), d.getRemark(),
                d.getTotalOriginal(), d.getTotalLocal(), d.getStatus(), d.isClosed(),
                d.getSourceDocNo(), d.getDepartmentId(), d.getIssueStatus(), items,
                nameResolver.nameOf(d.getMakerId()), d.getCreatedAt());
    }

    private StockDocument requireDoc(UUID id) {
        return docRepo.findById(id).filter(d -> !d.isDeleted())
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "仓库单据不存在"));
    }
}
