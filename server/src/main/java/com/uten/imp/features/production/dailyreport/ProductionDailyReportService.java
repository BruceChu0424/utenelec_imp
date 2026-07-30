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
import com.uten.imp.features.production.plan.PlanOrderItemLink;
import com.uten.imp.features.production.plan.PlanOrderItemLinkRepository;
import com.uten.imp.features.production.plan.ProductionPlan;
import com.uten.imp.features.production.plan.ProductionPlanItem;
import com.uten.imp.features.production.plan.ProductionPlanItemRepository;
import com.uten.imp.features.production.plan.ProductionPlanRepository;
import com.uten.imp.features.stock.StockDocument;
import com.uten.imp.features.stock.StockDocumentItem;
import com.uten.imp.features.stock.StockDocumentItemRepository;
import com.uten.imp.features.stock.StockDocumentRepository;
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

import java.time.OffsetDateTime;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.UUID;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;

/**
 * 生产日报服务：CRUD（主+明细）+ 审核状态机 + 业务链报工联动（V90/V95）。
 *
 * <p>审核（status 0→1）同事务内：
 * <ol>
 *   <li>解析计划行（planItemId 直给，或 planNo+货品+颜色解析已审计划）并回写；
 *       超报硬校验（累计 fqty ≤ 计划量）</li>
 *   <li>回写 plan_items.fqty + plan_order_item_links.produced_qty（指定订单行直击，
 *       未指定按 FIFO 分摊）；订单行状态 3/4→5 生产中</li>
 *   <li>有仓库时按来源计划自动生成成品入库单（草稿）+ plan_draw_links，
 *       仓库审核后即入链（补预留，见 StockDocService.applyFinishedInChain）</li>
 *   <li>is_final 完结行：合格不足 → 缺额封顶（qty/allocated 砍到实际，砍量记 capped_qty）
 *       + 自动生成补产计划（links source=1）</li>
 * </ol>
 *
 * <p>红冲（1→-1）对称：回退 fqty/produced → 成品入库单（草稿删/已审拒）→
 * 恢复封顶量 → 补产计划（草稿删/已审拒）。
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
    private final ProductionPlanRepository planRepo;
    private final ProductionPlanItemRepository planItemRepo;
    private final PlanOrderItemLinkRepository linkRepo;
    private final StockDocumentRepository stockDocRepo;
    private final StockDocumentItemRepository stockDocItemRepo;
    private final SecurityContextCurrentUser currentUser;
    private final com.uten.imp.common.util.EmployeeNameResolver nameResolver;
    private final TxSessionVars tx;
    private final DocNumberService docNumberService;
    private final EntityManager em;
    private final com.uten.imp.features.notice.ChainNoticeService chainNotice;

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

    /** 审核（status 0→1）：报工链联动（见类注释）。 */
    @Transactional
    public DailyReportDetail approve(UUID id) {
        tx.bind();
        ProductionDailyReport r = requireReport(id);
        em.lock(r, jakarta.persistence.LockModeType.PESSIMISTIC_WRITE); // 并发审核/红冲互斥（多账号同单操作）
        if (r.getStatus() == null || r.getStatus() != STATUS_DRAFT)
            throw new ApiException(ErrorCode.BUSINESS, "仅草稿单据可审核");
        List<ProductionDailyReportItem> items = itemRepo.findByReportIdOrderByLineNoAsc(id);
        if (items.isEmpty())
            throw new ApiException(ErrorCode.BUSINESS, "明细为空，不可审核");

        // 1) 逐行报工回写（fqty + links.produced + 行状态）；收集来源计划行
        Map<UUID, List<ProductionDailyReportItem>> byPlan = new LinkedHashMap<>();
        List<UUID> finalPlanItemIds = new ArrayList<>();
        for (ProductionDailyReportItem it : items) {
            UUID planItemId = resolvePlanItem(it);
            if (planItemId == null) continue; // 手工行（无计划关联）不进链
            Object[] pi = planItemRow(planItemId);
            BigDecimal qty = it.getQty() == null ? BigDecimal.ZERO : it.getQty();
            BigDecimal remain = bd(pi[2]).subtract(bd(pi[3])); // qty - fqty
            if (qty.signum() <= 0 || qty.compareTo(remain) > 0) {
                throw new ApiException(ErrorCode.BUSINESS, "报工量超过计划剩余（剩 "
                        + remain.stripTrailingZeros().toPlainString() + "）");
            }
            em.createNativeQuery("UPDATE production_plan_items SET fqty = COALESCE(fqty,0) + :q WHERE id = :id")
                    .setParameter("q", qty).setParameter("id", planItemId).executeUpdate();
            distributeProduced(planItemId, it.getSalesOrderItemId(), qty, +1);
            byPlan.computeIfAbsent((UUID) pi[1], k -> new ArrayList<>()).add(it);
            if (Boolean.TRUE.equals(it.isFinal()) && !finalPlanItemIds.contains(planItemId)) {
                finalPlanItemIds.add(planItemId);
            }
        }

        // 2) 有仓库 → 按来源计划自动生成成品入库单（草稿，仓库审核后入链补预留）
        if (r.getWarehouseId() != null) {
            for (var e : byPlan.entrySet()) {
                createFinishedInDraft(r, e.getKey(), e.getValue());
            }
        }

        // 3) 完结行：缺额封顶 + 自动补产
        for (UUID planItemId : finalPlanItemIds) {
            capAndRemake(r, planItemId);
        }
        // 4) 受影响计划重算结案
        for (UUID planId : byPlan.keySet()) {
            recomputePlanClosed(planId);
        }

        r.setStatus(STATUS_APPROVED);
        r.setApproverId(currentUser.requireEmployeeId());
        reportRepo.save(r);
        chainNotice.notifyRemakeCreated(r.getBillNo()); // 旁路通知：完结缺额已自动补产→销售（无补产时静默）
        return detail(id);
    }

    /** 红冲（status 1→-1）：对称回退（见类注释）。 */
    @Transactional
    public DailyReportDetail reverse(UUID id) {
        tx.bind();
        ProductionDailyReport r = requireReport(id);
        em.lock(r, jakarta.persistence.LockModeType.PESSIMISTIC_WRITE); // 并发审核/红冲互斥（多账号同单操作）
        if (r.getStatus() == null || r.getStatus() != STATUS_APPROVED)
            throw new ApiException(ErrorCode.BUSINESS, "仅已审核单据可红冲");
        List<ProductionDailyReportItem> items = itemRepo.findByReportIdOrderByLineNoAsc(id);

        // 1) 回退 fqty / links.produced / 行状态
        List<UUID> affectedPlans = new ArrayList<>();
        for (ProductionDailyReportItem it : items) {
            UUID planItemId = it.getPlanItemId();
            if (planItemId == null) continue;
            Object[] pi = planItemRow(planItemId);
            BigDecimal qty = it.getQty() == null ? BigDecimal.ZERO : it.getQty();
            if (!affectedPlans.contains((UUID) pi[1])) affectedPlans.add((UUID) pi[1]);
            em.createNativeQuery("UPDATE production_plan_items SET fqty = GREATEST(0, COALESCE(fqty,0) - :q) WHERE id = :id")
                    .setParameter("q", qty).setParameter("id", planItemId).executeUpdate();
            distributeProduced(planItemId, it.getSalesOrderItemId(), qty, -1);
            // 恢复封顶（若该行是完结行）
            restoreCap(planItemId);
        }

        // 2) 本单生成的成品入库单：草稿→软删；已审→拒绝
        for (Object[] d : docsBySource("FINISHED_IN", r.getBillNo())) {
            short st = ((Number) d[1]).shortValue();
            if (st == STATUS_APPROVED) {
                throw new ApiException(ErrorCode.BUSINESS,
                        "报工生成的成品入库单 " + d[2] + " 已审核，请先红冲该单");
            }
            if (st == STATUS_DRAFT) {
                softDeleteStockDoc((UUID) d[0]);
            }
        }

        // 3) 本单生成的补产计划：草稿→软删；已审→拒绝
        for (Object[] p : remakePlansOf(r.getBillNo())) {
            short st = ((Number) p[1]).shortValue();
            if (st == STATUS_APPROVED) {
                throw new ApiException(ErrorCode.BUSINESS,
                        "报工生成的补产计划 " + p[2] + " 已审核，请先红冲该计划");
            }
            if (st == STATUS_DRAFT) {
                softDeleteRemakePlan((UUID) p[0]);
            }
        }

        for (UUID planId : affectedPlans) {
            recomputePlanClosed(planId);
        }
        r.setStatus(STATUS_REVERSED);
        reportRepo.save(r);
        return detail(id);
    }

    // ====================== 报工链辅助 ======================

    /** 解析计划行：planItemId 直给；否则 planNo + 货品 + 颜色匹配已审计划（多命中报错，零命中=手工行）。 */
    private UUID resolvePlanItem(ProductionDailyReportItem it) {
        if (it.getPlanItemId() != null) return it.getPlanItemId();
        if (it.getPlanNo() == null || it.getPlanNo().isBlank()) return null;
        @SuppressWarnings("unchecked")
        List<UUID> rs = em.createNativeQuery("""
                SELECT i.id FROM production_plan_items i
                JOIN production_plans p ON p.id = i.plan_id
                WHERE p.bill_no = :no AND p.is_deleted = false AND p.status = 1
                  AND i.is_deleted = false AND i.goods_id = :gid
                  AND (i.color_id IS NOT DISTINCT FROM CAST(:cid AS uuid))
                """).setParameter("no", it.getPlanNo().trim())
                .setParameter("gid", it.getGoodsId())
                .setParameter("cid", it.getColorId())
                .getResultList();
        if (rs.isEmpty()) return null;
        if (rs.size() > 1) {
            throw new ApiException(ErrorCode.BUSINESS,
                    "计划 " + it.getPlanNo() + " 存在多个同货品行，请直接指定计划行");
        }
        // 解析结果回写（红冲/后续直接用存储值）
        em.createNativeQuery("UPDATE production_daily_report_items SET plan_item_id = :pi WHERE id = :id")
                .setParameter("pi", rs.get(0)).setParameter("id", it.getId()).executeUpdate();
        it.setPlanItemId(rs.get(0));
        return rs.get(0);
    }

    /** 计划行快照：id / plan_id / qty / fqty / goods_id / color_id / unit_id / outbound_date / delivery_date。 */
    private Object[] planItemRow(UUID planItemId) {
        return (Object[]) em.createNativeQuery("""
                SELECT i.id, i.plan_id, i.qty, COALESCE(i.fqty,0), i.goods_id, i.color_id, i.unit_id,
                       i.outbound_date, p.delivery_date, p.bill_no
                FROM production_plan_items i JOIN production_plans p ON p.id = i.plan_id
                WHERE i.id = :id AND i.is_deleted = false AND p.status = 1 AND p.is_deleted = false
                """).setParameter("id", planItemId).getSingleResult();
    }

    /**
     * 报工量分摊到 links.produced_qty（sign=+1；红冲 sign=-1 逆序回退）。
     * 指定订单行直击；未指定按创建序 FIFO 分摊剩余（allocated − produced）。
     * 订单行状态推进/回退：+1 时 3/4→5 生产中；-1 时 5→4。
     */
    private void distributeProduced(UUID planItemId, UUID orderItemId, BigDecimal qty, int sign) {
        List<PlanOrderItemLink> links = linkRepo.findActiveByPlanItemIds(List.of(planItemId));
        if (links.isEmpty()) return;
        List<PlanOrderItemLink> targets = new ArrayList<>();
        if (orderItemId != null) {
            targets = links.stream().filter(l -> l.getOrderItemId().equals(orderItemId)).toList();
            if (targets.isEmpty()) {
                throw new ApiException(ErrorCode.BUSINESS, "该订单行不在此计划行的排产联动中");
            }
        } else {
            targets = sign > 0 ? links : links.reversed();
        }
        BigDecimal remaining = qty;
        for (PlanOrderItemLink l : targets) {
            if (remaining.signum() <= 0) break;
            if (sign > 0) {
                BigDecimal room = l.getAllocatedQty().subtract(l.getProducedQty());
                BigDecimal c = room.min(remaining);
                if (c.signum() <= 0) continue;
                l.setProducedQty(l.getProducedQty().add(c));
                linkRepo.save(l);
                advanceChain(l.getOrderItemId(), "5", "3,4");
                remaining = remaining.subtract(c);
            } else {
                BigDecimal c = l.getProducedQty().min(remaining);
                if (c.signum() <= 0) continue;
                l.setProducedQty(l.getProducedQty().subtract(c));
                linkRepo.save(l);
                advanceChain(l.getOrderItemId(), "4", "5");
                remaining = remaining.subtract(c);
            }
        }
        if (sign > 0 && remaining.signum() > 0 && orderItemId != null) {
            throw new ApiException(ErrorCode.BUSINESS,
                    "报工量超过该订单行的排产分摊剩余（剩 "
                            + remaining.stripTrailingZeros().toPlainString() + " 已无法分摊）");
        }
    }

    /** 订单行状态迁移：chain_status ∈ fromSet → to。 */
    private void advanceChain(UUID orderItemId, String to, String fromSet) {
        em.createNativeQuery("UPDATE sales_order_items SET chain_status = " + to
                        + " WHERE id = :id AND COALESCE(chain_status,0) IN (" + fromSet + ")")
                .setParameter("id", orderItemId).executeUpdate();
    }

    /** 自动生成成品入库单（草稿）+ plan_draw_links（仓库审核后经 applyFinishedInChain 补预留）。 */
    private void createFinishedInDraft(ProductionDailyReport r, UUID planId,
                                       List<ProductionDailyReportItem> reportItems) {
        String planNo = (String) em.createNativeQuery(
                "SELECT bill_no FROM production_plans WHERE id = :id")
                .setParameter("id", planId).getSingleResult();
        StockDocument d = new StockDocument();
        d.setDocType("FINISHED_IN");
        d.setBillNo(docNumberService.nextNumber(DocNumberPrefix.STOCK_FINISHED_IN));
        d.setBillDate(LocalDate.now());
        d.setWarehouseId(r.getWarehouseId());
        d.setPlanNo(planNo);
        d.setSourceDocNo(r.getBillNo()); // 红冲按此回查
        d.setRemark("报工 " + r.getBillNo() + " 自动生成");
        d.setWorkerId(r.getWorkerId() != null ? r.getWorkerId() : currentUser.requireId());
        d.setMakerId(currentUser.requireEmployeeId());
        d.setStatus((short) 0);
        stockDocRepo.save(d);
        int line = 0;
        for (ProductionDailyReportItem ri : reportItems) {
            line++;
            StockDocumentItem it = new StockDocumentItem();
            it.setDocId(d.getId());
            it.setBillType("FINISHED_IN");
            it.setBillNo(d.getBillNo());
            it.setBillDate(d.getBillDate());
            it.setLineNo(line);
            it.setGoodsId(ri.getGoodsId());
            it.setColorId(ri.getColorId());
            it.setUnitId(ri.getUnitId());
            it.setUnitRate(BigDecimal.ONE);
            it.setQty(ri.getQty());
            it.setBaseQty(ri.getQty());
            it.setSourceDocNo(r.getBillNo());
            stockDocItemRepo.save(it);
        }
        em.createNativeQuery("""
                INSERT INTO plan_draw_links (plan_id, draw_id, created_by)
                VALUES (:planId, :drawId, :by)
                """).setParameter("planId", planId).setParameter("drawId", d.getId())
                .setParameter("by", currentUser.requireId()).executeUpdate();
    }

    /**
     * 完结缺额封顶 + 自动补产（V95）：
     * 合格（fqty）< 计划量 → 计划行 qty 砍到 fqty（砍量记 capped_qty）、
     * links.allocated 砍到 produced（砍量记 link.capped_qty，订单 planned_qty 同步回退），
     * 差额生成补产计划（草稿，links source=1，溯源本单 source_doc_no=报工单号）。
     */
    private void capAndRemake(ProductionDailyReport r, UUID planItemId) {
        Object[] pi = planItemRow(planItemId);
        BigDecimal plannedQty = bd(pi[2]);
        BigDecimal produced = bd(pi[3]);
        BigDecimal shortfall = plannedQty.subtract(produced);
        if (shortfall.signum() <= 0) return; // 足量完结，无需补产

        UUID planId = (UUID) pi[1];
        String planNo = (String) pi[9];
        // 封顶：计划行
        em.createNativeQuery("""
                UPDATE production_plan_items
                SET capped_qty = :cap, qty = :produced WHERE id = :id
                """).setParameter("cap", shortfall).setParameter("produced", produced)
                .setParameter("id", planItemId).executeUpdate();

        // links 封顶 + 收集补产分摊
        List<PlanOrderItemLink> links = linkRepo.findActiveByPlanItemIds(List.of(planItemId));
        record Remake(UUID orderItemId, BigDecimal qty) {}
        List<Remake> remakes = new ArrayList<>();
        for (PlanOrderItemLink l : links) {
            BigDecimal linkShort = l.getAllocatedQty().subtract(l.getProducedQty());
            if (linkShort.signum() <= 0) continue;
            l.setCappedQty(linkShort);
            l.setAllocatedQty(l.getProducedQty());
            linkRepo.save(l);
            em.createNativeQuery("""
                    UPDATE sales_order_items
                    SET planned_qty = GREATEST(0, COALESCE(planned_qty,0) - :d)
                    WHERE id = :id
                    """).setParameter("d", linkShort).setParameter("id", l.getOrderItemId())
                    .executeUpdate();
            remakes.add(new Remake(l.getOrderItemId(), linkShort));
        }
        if (remakes.isEmpty()) return;

        // 补产计划（草稿；同货合并一行——完结行单货品，即一行）
        ProductionPlan rp = new ProductionPlan();
        rp.setBillNo(docNumberService.nextNumber(DocNumberPrefix.PRODUCTION_PLAN));
        rp.setBillDate(LocalDate.now());
        rp.setDeliveryDate(pi[8] == null ? null : ((java.sql.Date) pi[8]).toLocalDate());
        rp.setRemark("补产：原计划 " + planNo + "（报工 " + r.getBillNo() + " 缺额自动生成）");
        rp.setSourceDocNo(r.getBillNo()); // 红冲按此回查
        rp.setMakerId(currentUser.requireEmployeeId());
        rp.setStatus((short) 0);
        planRepo.save(rp);

        ProductionPlanItem ri = new ProductionPlanItem();
        ri.setPlanId(rp.getId());
        ri.setBillNo(rp.getBillNo());
        ri.setBillDate(rp.getBillDate());
        ri.setLineNo(1);
        ri.setProductNo(rp.getBillNo() + "-1");
        ri.setGoodsId((UUID) pi[4]);
        ri.setColorId((UUID) pi[5]);
        ri.setUnitId((UUID) pi[6]);
        ri.setUnitRate(BigDecimal.ONE);
        ri.setQty(shortfall);
        ri.setOutboundDate(pi[7] == null ? null : ((java.sql.Date) pi[7]).toLocalDate());
        planItemRepo.save(ri);

        for (Remake m : remakes) {
            PlanOrderItemLink rl = new PlanOrderItemLink();
            rl.setPlanItemId(ri.getId());
            rl.setOrderItemId(m.orderItemId());
            rl.setAllocatedQty(m.qty());
            rl.setSource(PlanOrderItemLink.SOURCE_REMAKE);
            linkRepo.save(rl);
        }
    }

    /** 红冲恢复封顶：计划行/links 砍量恢复（capped_qty 置空），订单 planned_qty 回补。 */
    private void restoreCap(UUID planItemId) {
        Object capObj = em.createNativeQuery(
                "SELECT capped_qty FROM production_plan_items WHERE id = :id")
                .setParameter("id", planItemId).getSingleResult();
        BigDecimal cap = bd(capObj);
        if (cap.signum() <= 0) return;
        em.createNativeQuery("""
                UPDATE production_plan_items
                SET qty = COALESCE(qty,0) + :cap, capped_qty = NULL WHERE id = :id
                """).setParameter("cap", cap).setParameter("id", planItemId).executeUpdate();
        for (PlanOrderItemLink l : linkRepo.findActiveByPlanItemIds(List.of(planItemId))) {
            BigDecimal lc = l.getCappedQty() == null ? BigDecimal.ZERO : l.getCappedQty();
            if (lc.signum() <= 0) continue;
            l.setAllocatedQty(l.getAllocatedQty().add(lc));
            l.setCappedQty(null);
            linkRepo.save(l);
            em.createNativeQuery("""
                    UPDATE sales_order_items
                    SET planned_qty = COALESCE(planned_qty,0) + :d WHERE id = :id
                    """).setParameter("d", lc).setParameter("id", l.getOrderItemId())
                    .executeUpdate();
        }
    }

    /** 本报工生成的成品入库单（id/status/bill_no）。 */
    @SuppressWarnings("unchecked")
    private List<Object[]> docsBySource(String docType, String sourceBillNo) {
        return em.createNativeQuery("""
                SELECT id, status, bill_no FROM stock_documents
                WHERE doc_type = :t AND source_doc_no = :no AND is_deleted = false
                """).setParameter("t", docType).setParameter("no", sourceBillNo).getResultList();
    }

    /** 本报工生成的补产计划（id/status/bill_no）。 */
    @SuppressWarnings("unchecked")
    private List<Object[]> remakePlansOf(String reportBillNo) {
        return em.createNativeQuery("""
                SELECT id, status, bill_no FROM production_plans
                WHERE source_doc_no = :no AND remark LIKE '补产：%' AND is_deleted = false
                """).setParameter("no", reportBillNo).getResultList();
    }

    /** 软删成品入库单（草稿）：主表 + 明细 + plan_draw_links 留痕。 */
    private void softDeleteStockDoc(UUID docId) {
        em.createNativeQuery("UPDATE stock_documents SET is_deleted = true, deleted_at = now() WHERE id = :id")
                .setParameter("id", docId).executeUpdate();
        em.createNativeQuery("UPDATE stock_document_items SET is_deleted = true WHERE doc_id = :id")
                .setParameter("id", docId).executeUpdate();
        em.createNativeQuery("UPDATE plan_draw_links SET is_deleted = true, deleted_at = now() WHERE draw_id = :id")
                .setParameter("id", docId).executeUpdate();
    }

    /** 软删补产计划（草稿）：主表 + 明细 + links 留痕。 */
    private void softDeleteRemakePlan(UUID planId) {
        em.createNativeQuery("""
                UPDATE plan_order_item_links l SET is_deleted = true, deleted_at = now()
                WHERE l.is_deleted = false AND l.plan_item_id IN
                    (SELECT id FROM production_plan_items WHERE plan_id = :pid)
                """).setParameter("pid", planId).executeUpdate();
        em.createNativeQuery("UPDATE production_plan_items SET is_deleted = true WHERE plan_id = :pid")
                .setParameter("pid", planId).executeUpdate();
        em.createNativeQuery("UPDATE production_plans SET is_deleted = true, deleted_at = now() WHERE id = :pid")
                .setParameter("pid", planId).executeUpdate();
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

    private static BigDecimal bd(Object v) {
        return v == null ? BigDecimal.ZERO : (BigDecimal) v;
    }

    // ====================== 私有辅助 ======================

    private void applyHeader(DailyReportSaveRequest req, ProductionDailyReport r) {
        // 单据号系统自动生成（服务端权威）：仅新建（billNo 空）时取号；更新保留既有号，忽略客户端值。
        if (r.getBillNo() == null || r.getBillNo().isBlank()) {
            r.setBillNo(docNumberService.nextNumber(DocNumberPrefix.PRODUCTION_DAILY_REPORT));
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
            it.setFinal(Boolean.TRUE.equals(l.getIsFinal()));
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
                it.getClientName(), it.getSourceDocNo(), it.getRemark(), it.isFinal());
    }

    private DailyReportDetail toDetail(ProductionDailyReport r, List<DailyReportItemDto> items) {
        return new DailyReportDetail(r.getId(), r.getLegacyId(), r.getBillNo(), r.getBillDate(),
                r.getWarehouseId(), r.getDepartmentId(), r.getWorkshopName(), r.getWorkerId(), r.getSupplierId(),
                r.getMakerId(), r.getApproverId(), r.getMakerLegacyId(), r.getApproverLegacyId(), r.getRemark(),
                r.getStatus(), r.isClosed(), r.isCanceled(), r.getSourceDocNo(), items,
                nameResolver.nameOf(r.getMakerId()), r.getCreatedAt());
    }

    private ProductionDailyReport requireReport(UUID id) {
        return reportRepo.findById(id).filter(r -> !r.isDeleted())
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "生产日报单不存在"));
    }
}
