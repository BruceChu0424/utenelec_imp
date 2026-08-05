package com.uten.imp.features.production.dailyreport;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.common.web.Pageables;
import com.uten.imp.common.web.TableSort;
import com.uten.imp.common.docnumber.DocNumberPrefix;
import com.uten.imp.common.docnumber.DocNumberService;
import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.util.NativeQueryResults;
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

import java.math.BigDecimal;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Objects;
import java.util.Map;
import java.util.TreeSet;
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
    private final DailyReportExecutionSegmentGuard executionSegments;
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
        ProductionDailyReport r = requireReportForUpdate(id);
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
        ProductionDailyReport r = requireReportForUpdate(id);
        if (r.getStatus() == STATUS_APPROVED) throw new ApiException(ErrorCode.BUSINESS, "已审核单据不可删，请红冲");
        r.setDeleted(true);
        r.setDeletedAt(OffsetDateTime.now());
        reportRepo.save(r);
    }

    /** 审核（status 0→1）：报工链联动（见类注释）。 */
    @Transactional
    public DailyReportDetail approve(UUID id) {
        tx.bind();
        ProductionDailyReport r = requireReportForUpdate(id);
        if (r.getStatus() == null || r.getStatus() != STATUS_DRAFT)
            throw new ApiException(ErrorCode.BUSINESS, "仅草稿单据可审核");
        List<ProductionDailyReportItem> items = itemRepo.findByReportIdOrderByLineNoAsc(id);
        if (items.isEmpty())
            throw new ApiException(ErrorCode.BUSINESS, "明细为空，不可审核");
        if (r.getWarehouseId() == null
                && items.stream().anyMatch(item -> item.getExecutionSegmentId() != null)) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED,
                    "执行子计划报工必须指定成品入库仓库");
        }
        executionSegments.approve(id, items);

        for (ProductionDailyReportItem item : items) {
            if (item.getQty() == null || item.getQty().signum() <= 0) {
                throw new ApiException(ErrorCode.VALIDATION_FAILED, "报工明细数量必须大于 0");
            }
        }

        // 1) 逐行报工回写（fqty + links.produced + 行状态）；收集来源计划行
        Map<UUID, List<ProductionDailyReportItem>> byPlan = new LinkedHashMap<>();
        List<UUID> finalPlanItemIds = new ArrayList<>();
        Map<UUID, UUID> resolvedPlanItems = new HashMap<>();
        for (ProductionDailyReportItem item : items) {
            UUID planItemId = resolvePlanItem(item);
            if (planItemId != null) {
                resolvedPlanItems.put(item.getId(), planItemId);
            }
        }
        lockPlanItems(resolvedPlanItems.values());
        Map<UUID, List<PlanOrderItemLink>> lockedLinks =
                lockPlanLinkGraph(resolvedPlanItems.values(), true);
        for (ProductionDailyReportItem it : items) {
            UUID planItemId = resolvedPlanItems.get(it.getId());
            if (planItemId == null) continue; // 手工行（无计划关联）不进链
            Object[] pi = planItemRow(planItemId, true);
            requireMatchingPlanDimension(it, pi);
            BigDecimal qty = it.getQty();
            BigDecimal remain = bd(pi[2]).subtract(bd(pi[3])); // qty - fqty
            if (qty.compareTo(remain) > 0) {
                throw new ApiException(ErrorCode.BUSINESS, "报工量超过计划剩余（剩 "
                        + remain.stripTrailingZeros().toPlainString() + "）");
            }
            em.createNativeQuery("UPDATE production_plan_items SET fqty = COALESCE(fqty,0) + :q WHERE id = :id")
                    .setParameter("q", qty).setParameter("id", planItemId).executeUpdate();
            distributeProduced(
                    planItemId,
                    it.getExecutionSegmentSalesAllocationId(),
                    it.getSalesOrderItemId(), qty, +1,
                    lockedLinks.getOrDefault(planItemId, List.of()));
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
            capAndRemake(r, planItemId,
                    lockedLinks.getOrDefault(planItemId, List.of()));
        }
        // 4) 受影响计划重算结案
        for (UUID planId : byPlan.keySet()) {
            recomputePlanClosed(planId);
        }

        r.setStatus(STATUS_APPROVED);
        r.setApproverId(currentUser.requireEmployeeId());
        reportRepo.save(r);
        chainNotice.notifyProductionReported(r.getId());
        chainNotice.notifyRemakeCreated(r.getBillNo()); // 旁路通知：完结缺额已自动补产→销售（无补产时静默）
        return detail(id);
    }

    /** 红冲（status 1→-1）：对称回退（见类注释）。 */
    @Transactional
    public DailyReportDetail reverse(UUID id) {
        tx.bind();
        ProductionDailyReport r = requireReportForUpdate(id);
        if (r.getStatus() == null || r.getStatus() != STATUS_APPROVED)
            throw new ApiException(ErrorCode.BUSINESS, "仅已审核单据可红冲");
        List<ProductionDailyReportItem> items = itemRepo.findByReportIdOrderByLineNoAsc(id);
        executionSegments.reverse(items);
        lockPlanItems(items.stream()
                .map(ProductionDailyReportItem::getPlanItemId)
                .filter(java.util.Objects::nonNull)
                .toList());
        Map<UUID, List<PlanOrderItemLink>> lockedLinks = lockPlanLinkGraph(
                items.stream().map(ProductionDailyReportItem::getPlanItemId)
                        .filter(Objects::nonNull).toList(), false);

        // 1) 回退 fqty / links.produced / 行状态
        List<UUID> affectedPlans = new ArrayList<>();
        for (ProductionDailyReportItem it : items) {
            UUID planItemId = it.getPlanItemId();
            if (planItemId == null) continue;
            Object[] pi = planItemRow(planItemId, false);
            requireMatchingPlanDimension(it, pi);
            BigDecimal qty = it.getQty() == null ? BigDecimal.ZERO : it.getQty();
            if (qty.signum() <= 0) {
                throw new ApiException(ErrorCode.CONFLICT, "历史报工明细数量无效，禁止自动红冲");
            }
            BigDecimal finishedAfterReverse = bd(pi[3]).subtract(qty);
            BigDecimal alreadyInbound = bd(pi[11]);
            if (finishedAfterReverse.compareTo(alreadyInbound) < 0) {
                throw new ApiException(ErrorCode.CONFLICT,
                        "红冲后已报工合格量将小于已入库量，请先红冲相关成品入库单");
            }
            if (!affectedPlans.contains((UUID) pi[1])) affectedPlans.add((UUID) pi[1]);
            int finishedUpdated = em.createNativeQuery("""
                            UPDATE production_plan_items
                            SET fqty = COALESCE(fqty,0) - :q
                            WHERE id = :id AND COALESCE(fqty,0) >= :q
                            """).setParameter("q", qty).setParameter("id", planItemId).executeUpdate();
            if (finishedUpdated != 1) {
                throw new ApiException(ErrorCode.CONFLICT, "生产计划已报工累计不足，禁止自动吞并红冲错账");
            }
            List<PlanOrderItemLink> planLinks =
                    lockedLinks.getOrDefault(planItemId, List.of());
            distributeProduced(
                    planItemId,
                    it.getExecutionSegmentSalesAllocationId(),
                    it.getSalesOrderItemId(), qty, -1, planLinks);
            // 恢复封顶（若该行是完结行）
            if (Boolean.TRUE.equals(it.isFinal())) {
                restoreCap(planItemId, planLinks);
            }
        }

        // 2) 本单生成的成品入库单：草稿→软删；已审→拒绝
        for (Object[] d : docsBySource("FINISHED_IN", r.getBillNo())) {
            StockDocument linkedDocument = em.find(
                    StockDocument.class, (UUID) d[0],
                    jakarta.persistence.LockModeType.PESSIMISTIC_WRITE);
            if (linkedDocument == null || linkedDocument.isDeleted()) continue;
            short st = linkedDocument.getStatus() == null
                    ? Short.MIN_VALUE : linkedDocument.getStatus();
            if (st == STATUS_APPROVED) {
                throw new ApiException(ErrorCode.BUSINESS,
                        "报工生成的成品入库单 " + linkedDocument.getBillNo() + " 已审核，请先红冲该单");
            }
            if (st == STATUS_DRAFT) {
                softDeleteStockDoc(linkedDocument.getId());
            } else if (st != STATUS_REVERSED) {
                throw new ApiException(ErrorCode.CONFLICT,
                        "报工生成的成品入库单状态异常，禁止自动红冲");
            }
        }

        // 3) 本单生成的补产计划：草稿→软删；已审→拒绝
        for (Object[] p : remakePlansOf(r.getBillNo())) {
            ProductionPlan remakePlan = em.find(
                    ProductionPlan.class, (UUID) p[0],
                    jakarta.persistence.LockModeType.PESSIMISTIC_WRITE);
            if (remakePlan == null || remakePlan.isDeleted()) continue;
            short st = remakePlan.getStatus() == null
                    ? Short.MIN_VALUE : remakePlan.getStatus();
            if (st == STATUS_APPROVED) {
                throw new ApiException(ErrorCode.BUSINESS,
                        "报工生成的补产计划 " + remakePlan.getBillNo() + " 已审核，请先红冲该计划");
            }
            if (st == STATUS_DRAFT) {
                softDeleteRemakePlan(remakePlan.getId());
            } else if (st != STATUS_REVERSED) {
                throw new ApiException(ErrorCode.CONFLICT,
                        "报工生成的补产计划状态异常，禁止自动红冲");
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

    /** 解析计划行；只有完全没有计划引用的明细才允许作为历史手工行。 */
    private UUID resolvePlanItem(ProductionDailyReportItem it) {
        if (it.getPlanItemId() != null) return it.getPlanItemId();
        String planNo = firstNonBlank(it.getPlanNo(), it.getSourceDocNo());
        if (planNo == null) return null;
        @SuppressWarnings("unchecked")
        List<UUID> rs = em.createNativeQuery("""
                SELECT i.id FROM production_plan_items i
                JOIN production_plans p ON p.id = i.plan_id
                WHERE p.bill_no = :no AND p.is_deleted = false AND p.status = 1
                  AND p.is_stopped = false AND p.is_canceled = false
                  AND i.is_deleted = false AND i.goods_id = :gid
                  AND (i.color_id IS NOT DISTINCT FROM CAST(:cid AS uuid))
                """).setParameter("no", planNo)
                .setParameter("gid", it.getGoodsId())
                .setParameter("cid", it.getColorId())
                .getResultList();
        if (rs.isEmpty()) {
            throw new ApiException(ErrorCode.CONFLICT,
                    "报工引用的生产计划不存在、未审核、已停止或已取消：" + planNo);
        }
        if (rs.size() > 1) {
            throw new ApiException(ErrorCode.BUSINESS,
                    "计划 " + planNo + " 存在多个同货品行，请直接指定计划行");
        }
        // 解析结果回写（红冲/后续直接用存储值）
        em.createNativeQuery("UPDATE production_daily_report_items SET plan_item_id = :pi WHERE id = :id")
                .setParameter("pi", rs.get(0)).setParameter("id", it.getId()).executeUpdate();
        it.setPlanItemId(rs.get(0));
        return rs.get(0);
    }

    private static String firstNonBlank(String preferred, String fallback) {
        if (preferred != null && !preferred.isBlank()) return preferred.trim();
        if (fallback != null && !fallback.isBlank()) return fallback.trim();
        return null;
    }

    /** 计划行快照：正向报工拒绝终态计划；红冲仍允许读取终态并逆向清理。 */
    private Object[] planItemRow(UUID planItemId, boolean positiveWrite) {
        String terminalGate = positiveWrite
                ? " AND p.status = 1 AND p.is_stopped = false AND p.is_canceled = false"
                : "";
        List<Object[]> rows = NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT i.id, i.plan_id, i.qty, COALESCE(i.fqty,0), i.goods_id, i.color_id, i.unit_id,
                       i.outbound_date, p.delivery_date, p.bill_no, COALESCE(i.unit_rate,1),
                       COALESCE(i.iqty,0)
                FROM production_plan_items i JOIN production_plans p ON p.id = i.plan_id
                WHERE i.id = :id AND i.is_deleted = false AND p.is_deleted = false
                """ + terminalGate + " FOR UPDATE OF i, p")
                .setParameter("id", planItemId));
        if (rows.size() != 1) {
            throw new ApiException(ErrorCode.CONFLICT,
                    positiveWrite
                            ? "报工关联的生产计划行不存在，或计划未审核、已停止、已取消"
                            : "报工关联的生产计划行不存在或已删除");
        }
        return rows.getFirst();
    }

    private static void requireMatchingPlanDimension(
            ProductionDailyReportItem reportItem, Object[] planItem) {
        BigDecimal reportRate = reportItem.getUnitRate() == null
                ? BigDecimal.ONE : reportItem.getUnitRate();
        BigDecimal planRate = planItem[10] == null
                ? BigDecimal.ONE : (BigDecimal) planItem[10];
        if (reportRate.signum() <= 0 || planRate.signum() <= 0) {
            throw new ApiException(ErrorCode.CONFLICT, "报工或生产计划的单位换算率必须大于 0");
        }
        if (!Objects.equals(reportItem.getGoodsId(), planItem[4])
                || !Objects.equals(reportItem.getColorId(), planItem[5])) {
            throw new ApiException(ErrorCode.CONFLICT, "报工货品或颜色与生产计划行不一致");
        }
        if (reportItem.getUnitId() == null
                || planItem[6] == null
                || !Objects.equals(reportItem.getUnitId(), planItem[6])
                || reportRate.compareTo(planRate) != 0) {
            throw new ApiException(ErrorCode.CONFLICT, "报工单位或换算率与生产计划行不一致");
        }
    }

    private void lockPlanItems(java.util.Collection<UUID> requestedIds) {
        TreeSet<UUID> ids = new TreeSet<>(requestedIds);
        if (ids.isEmpty()) return;
        List<?> locked = em.createNativeQuery("""
                        SELECT id
                        FROM production_plan_items
                        WHERE id IN (:ids) AND COALESCE(is_deleted, false) = false
                        ORDER BY id
                        FOR UPDATE
                        """)
                .setParameter("ids", ids)
                .getResultList();
        if (locked.size() != ids.size()) {
            throw new ApiException(ErrorCode.CONFLICT, "报工关联的生产计划行不存在或已删除");
        }
    }

    /**
     * 报工量分摊到 links.produced_qty（sign=+1；红冲 sign=-1 逆序回退）。
     * 指定订单行直击；未指定按创建序 FIFO 分摊剩余（allocated − produced）。
     * 订单行状态推进/回退：+1 时 3/4→5 生产中；-1 时 5→4。
     */
    private void distributeProduced(
            UUID planItemId,
            UUID executionSegmentSalesAllocationId,
            UUID orderItemId,
            BigDecimal qty,
            int sign,
            List<PlanOrderItemLink> lockedLinks) {
        List<PlanOrderItemLink> links = new ArrayList<>(lockedLinks);
        if (links.isEmpty()) {
            if (orderItemId == null) return;
            throw new ApiException(ErrorCode.CONFLICT, "报工指定了销售订单行，但生产计划行没有有效联动");
        }
        if (links.size() > 1 && orderItemId == null) {
            throw new ApiException(
                    ErrorCode.CONFLICT,
                    "合并排产的计划行报工必须指定销售订单行；未建立报工分摊台账前禁止自动猜测");
        }
        List<PlanOrderItemLink> targets = new ArrayList<>();
        if (executionSegmentSalesAllocationId != null) {
            List<Object[]> allocationRows =
                    NativeQueryResults.objectArrayRows(
                            em.createNativeQuery("""
                                            SELECT
                                              allocation.plan_order_item_link_id,
                                              allocation.sales_order_item_id
                                            FROM execution_segment_sales_allocations allocation
                                            JOIN production_execution_segments segment
                                              ON segment.id =
                                                 allocation.execution_segment_id
                                            WHERE allocation.id = :allocationId
                                              AND segment.source_plan_item_id =
                                                  :planItemId
                                            """)
                                    .setParameter(
                                            "allocationId",
                                            executionSegmentSalesAllocationId)
                                    .setParameter(
                                            "planItemId", planItemId));
            if (allocationRows.size() != 1
                    || !Objects.equals(
                            orderItemId,
                            allocationRows.getFirst()[1])) {
                throw new ApiException(
                        ErrorCode.CONFLICT,
                        "报工的销售分摊与计划行/订单行不一致");
            }
            UUID exactLinkId = (UUID) allocationRows.getFirst()[0];
            targets = links.stream()
                    .filter(link -> exactLinkId.equals(link.getId()))
                    .toList();
            if (targets.size() != 1) {
                throw new ApiException(
                        ErrorCode.CONFLICT,
                        "报工的销售分摊关联已失效");
            }
            // PROD-P1-2: 分段归属红冲必须命中正向报工同一联动行；若累计 produced 不足，
            // 说明正向可能按 FIFO 计入了其他联动行——此处加 CAS 拦截防负漂移，并抛清晰错。
            // 精确的 FIFO 反向需要"按行持久化正向归因台账"的重构，暂以保守拦截兜底。
            if (sign < 0) {
                PlanOrderItemLink target = targets.get(0);
                if (target.getProducedQty().compareTo(qty) < 0) {
                    throw new ApiException(ErrorCode.CONFLICT,
                            "红冲分摊与原报工不一致：该销售分摊累计报工 "
                                    + target.getProducedQty().stripTrailingZeros().toPlainString()
                                    + " 小于本次红冲量 "
                                    + qty.stripTrailingZeros().toPlainString()
                                    + "（可能存在跨链 FIFO 分摊），须先核对再红冲");
                }
            }
        } else if (orderItemId != null) {
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
        if (remaining.signum() > 0) {
            String action = sign > 0 ? "报工" : "红冲";
            throw new ApiException(
                    ErrorCode.CONFLICT,
                    action + "量超过生产计划与销售订单的可分摊量（剩 "
                            + remaining.stripTrailingZeros().toPlainString() + " 无法分摊）");
        }
    }

    /**
     * 锁序固定为销售订单头/行 → 计划联动行。普通查询只用于发现候选集合，
     * 真正写入前逐行 PESSIMISTIC_WRITE + refresh，并校验集合未被并发增删。
     */
    private Map<UUID, List<PlanOrderItemLink>> lockPlanLinkGraph(
            java.util.Collection<UUID> requestedPlanItemIds, boolean positiveWrite) {
        TreeSet<UUID> planItemIds = new TreeSet<>(requestedPlanItemIds);
        planItemIds.remove(null);
        if (planItemIds.isEmpty()) return Map.of();

        List<PlanOrderItemLink> snapshots = new ArrayList<>(
                linkRepo.findActiveByPlanItemIds(new ArrayList<>(planItemIds)));
        snapshots.sort(java.util.Comparator.comparing(PlanOrderItemLink::getId));
        if (positiveWrite) {
            java.util.Set<UUID> activePlanItemIds = snapshots.stream()
                    .map(PlanOrderItemLink::getPlanItemId)
                    .collect(java.util.stream.Collectors.toSet());
            List<UUID> historicallyLinkedPlanItemIds = NativeQueryResults.typedRows(
                    em.createNativeQuery("""
                            SELECT DISTINCT plan_item_id
                            FROM plan_order_item_links
                            WHERE plan_item_id IN (:planItemIds)
                            ORDER BY plan_item_id
                            """).setParameter("planItemIds", planItemIds),
                    UUID.class);
            boolean detachedSource = historicallyLinkedPlanItemIds.stream()
                    .anyMatch(planItemId -> !activePlanItemIds.contains(planItemId));
            if (detachedSource) {
                throw new ApiException(ErrorCode.CONFLICT,
                        "生产计划曾关联销售订单但当前联动已失效，禁止降级为内部计划继续报工");
            }
        }
        if (snapshots.isEmpty()) return Map.of();

        lockSalesTargets(snapshots, positiveWrite);

        List<UUID> expectedIds = snapshots.stream()
                .map(PlanOrderItemLink::getId).toList();
        List<UUID> currentIds = NativeQueryResults.typedRows(em.createNativeQuery("""
                        SELECT id
                        FROM plan_order_item_links
                        WHERE plan_item_id IN (:planItemIds)
                          AND COALESCE(is_deleted, false) = false
                        ORDER BY id
                        FOR UPDATE
                        """).setParameter("planItemIds", planItemIds), UUID.class);
        if (!currentIds.equals(expectedIds)) {
            throw new ApiException(ErrorCode.CONFLICT,
                    "报工关联的排产分摊已被并发变更，请刷新后重试");
        }

        Map<UUID, List<PlanOrderItemLink>> result = new HashMap<>();
        for (PlanOrderItemLink snapshot : snapshots) {
            PlanOrderItemLink link = em.find(
                    PlanOrderItemLink.class, snapshot.getId(),
                    jakarta.persistence.LockModeType.PESSIMISTIC_WRITE);
            if (link == null) {
                throw new ApiException(ErrorCode.CONFLICT, "报工关联的排产分摊不存在");
            }
            em.refresh(link, jakarta.persistence.LockModeType.PESSIMISTIC_WRITE);
            BigDecimal allocated = link.getAllocatedQty();
            BigDecimal produced = link.getProducedQty();
            BigDecimal inbound = link.getInboundQty();
            BigDecimal capped = link.getCappedQty();
            if (link.isDeleted()
                    || !planItemIds.contains(link.getPlanItemId())
                    || link.getOrderItemId() == null
                    || allocated == null || allocated.signum() < 0
                    || produced == null || produced.signum() < 0
                    || produced.compareTo(allocated) > 0
                    || inbound == null || inbound.signum() < 0
                    || inbound.compareTo(produced) > 0
                    || (capped != null && capped.signum() < 0)) {
                throw new ApiException(ErrorCode.CONFLICT,
                        "报工关联的排产分摊状态或数量异常，禁止继续写入");
            }
            result.computeIfAbsent(link.getPlanItemId(), ignored -> new ArrayList<>())
                    .add(link);
        }
        for (List<PlanOrderItemLink> links : result.values()) {
            links.sort(java.util.Comparator
                    .comparing(PlanOrderItemLink::getCreatedAt,
                            java.util.Comparator.nullsLast(java.util.Comparator.naturalOrder()))
                    .thenComparing(PlanOrderItemLink::getId));
        }
        return result;
    }

    /**
     * 正向报工的最终销售状态门槛。锁订单头与订单行后再检查，避免审核报工与订单停止/结案并发穿透。
     * 红冲不调用本门槛，终态订单仍可逆向清理。
     */
    private void lockSalesTargets(
            List<PlanOrderItemLink> targets, boolean positiveWrite) {
        List<UUID> orderItemIds = targets.stream()
                .map(PlanOrderItemLink::getOrderItemId)
                .distinct()
                .sorted()
                .toList();
        List<Object[]> rows = NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT soi.id, o.id, o.status, o.is_stopped, o.is_closed,
                       o.is_deleted, soi.is_deleted, COALESCE(soi.chain_status,0)
                FROM sales_order_items soi
                JOIN sales_orders o ON o.id = soi.order_id
                WHERE soi.id IN (:ids)
                ORDER BY o.id, soi.id
                FOR UPDATE OF o, soi
                """).setParameter("ids", orderItemIds));
        if (rows.size() != orderItemIds.size()) {
            throw new ApiException(ErrorCode.CONFLICT, "报工关联的销售订单行或订单不存在");
        }
        for (Object[] row : rows) {
            Short status = row[2] == null ? null : ((Number) row[2]).shortValue();
            int chainStatus = ((Number) row[7]).intValue();
            if (positiveWrite && (status == null || status != STATUS_APPROVED
                    || Boolean.TRUE.equals(row[3])
                    || Boolean.TRUE.equals(row[4])
                    || Boolean.TRUE.equals(row[5])
                    || Boolean.TRUE.equals(row[6])
                    || chainStatus <= 0
                    // 8=部分发货：既有计划仍须完成未发余量；9=已全部发货才是终态。
                    || chainStatus > 8)) {
                throw new ApiException(ErrorCode.CONFLICT,
                        "正向报工关联的销售订单须有效，且订单行必须处于未发货的生产阶段");
            }
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
        d.setBillDate(BusinessTime.today());
        d.setWarehouseId(r.getWarehouseId());
        d.setPlanNo(planNo);
        d.setSourceDocNo(r.getBillNo()); // 红冲按此回查
        d.setRemark("报工 " + r.getBillNo() + " 自动生成");
        d.setWorkerId(r.getWorkerId() != null ? r.getWorkerId() : currentUser.requireEmployeeId());
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
            BigDecimal rate = ri.getUnitRate() == null ? BigDecimal.ONE : ri.getUnitRate();
            if (rate.signum() <= 0) {
                throw new ApiException(ErrorCode.CONFLICT, "报工单位换算率必须大于 0");
            }
            it.setUnitRate(rate);
            it.setQty(ri.getQty());
            it.setBaseQty(ri.getQty().multiply(rate));
            it.setUpstreamItemId(ri.getPlanItemId());
            it.setExecutionSegmentId(ri.getExecutionSegmentId());
            it.setExecutionSegmentSalesAllocationId(
                    ri.getExecutionSegmentSalesAllocationId());
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
    private void capAndRemake(ProductionDailyReport r, UUID planItemId,
                              List<PlanOrderItemLink> lockedLinks) {
        Object[] pi = planItemRow(planItemId, true);
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
        List<PlanOrderItemLink> links = lockedLinks;
        record Remake(UUID orderItemId, BigDecimal qty) {}
        List<Remake> remakes = new ArrayList<>();
        // V217: 分段归属的计划行需同步镜像削减 execution_segment_sales_allocations，
        // 否则 V157 总量等式/超分摊约束在提交时漂移。先查明各联动行的销售分摊段数。
        Map<UUID, Long> allocationSegCount = links.isEmpty()
                ? Map.of()
                : countLinkAllocationSegments(links);
        boolean segmentAttributed = !allocationSegCount.isEmpty();
        if (segmentAttributed) {
            em.createNativeQuery(
                    "SELECT set_config('app.cap_segment_allocations', 'on', true)")
                    .getSingleResult();
        }
        List<UUID> cappedAllocationLinkIds = new ArrayList<>();
        for (PlanOrderItemLink l : links) {
            BigDecimal linkShort = l.getAllocatedQty().subtract(l.getProducedQty());
            if (linkShort.signum() <= 0) continue;
            l.setCappedQty(linkShort);
            l.setAllocatedQty(l.getProducedQty());
            linkRepo.save(l);
            int plannedUpdated = em.createNativeQuery("""
                    UPDATE sales_order_items
                    SET planned_qty = COALESCE(planned_qty,0) - :d
                    WHERE id = :id AND COALESCE(planned_qty,0) >= :d
                    """).setParameter("d", linkShort).setParameter("id", l.getOrderItemId())
                    .executeUpdate();
            if (plannedUpdated != 1) {
                throw new ApiException(ErrorCode.CONFLICT,
                        "订单已排产累计小于完结封顶回退量，禁止自动吞并错账");
            }
            // 镜像削减销售分摊：单段联动=常态（恰好 1 行命中 CAS）；多段联动暂不支持
            // （各分段行 < linkShort 会使 CAS 落空 → 抛错防静默漂移）；无分摊=旧式计划跳过。
            if (allocationSegCount.containsKey(l.getId())) {
                long segs = allocationSegCount.get(l.getId());
                if (segs != 1) {
                    throw new ApiException(ErrorCode.CONFLICT,
                            "完结封顶暂不支持跨多执行段(" + segs + ")的订单行，须人工核对后再审核");
                }
                int allocationCut = em.createNativeQuery("""
                        UPDATE execution_segment_sales_allocations
                        SET allocated_qty = allocated_qty - :cut
                        WHERE plan_order_item_link_id = :lid
                          AND allocated_qty >= :cut
                        """).setParameter("cut", linkShort)
                        .setParameter("lid", l.getId())
                        .executeUpdate();
                if (allocationCut != 1) {
                    throw new ApiException(ErrorCode.CONFLICT,
                            "完结封顶镜像削减销售分摊失败，须人工核对后再审核");
                }
                cappedAllocationLinkIds.add(l.getId());
            }
            remakes.add(new Remake(l.getOrderItemId(), linkShort));
        }
        // 重算受影响分段 planned_qty = SUM(allocations)，保持 V157 总量等式（多联动同行分段也成立）。
        if (!cappedAllocationLinkIds.isEmpty()) {
            em.createNativeQuery("""
                    UPDATE production_execution_segments seg
                    SET planned_qty = COALESCE((
                        SELECT SUM(a.allocated_qty)
                        FROM execution_segment_sales_allocations a
                        WHERE a.execution_segment_id = seg.id
                    ), seg.planned_qty)
                    WHERE seg.is_deleted = FALSE
                      AND EXISTS (
                        SELECT 1 FROM execution_segment_sales_allocations a2
                        WHERE a2.execution_segment_id = seg.id
                          AND a2.plan_order_item_link_id IN (:links)
                      )
                    """).setParameter("links", cappedAllocationLinkIds)
                    .executeUpdate();
        }
        if (segmentAttributed) {
            em.createNativeQuery(
                    "SELECT set_config('app.cap_segment_allocations', 'off', true)")
                    .getSingleResult();
        }
        if (remakes.isEmpty()) return;

        // 补产计划（草稿；同货合并一行——完结行单货品，即一行）
        ProductionPlan rp = new ProductionPlan();
        rp.setBillNo(docNumberService.nextNumber(DocNumberPrefix.PRODUCTION_PLAN));
        rp.setBillDate(BusinessTime.today());
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
        ri.setUnitRate((BigDecimal) pi[10]);
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

    /**
     * 红冲恢复封顶：计划行/links 砍量恢复（capped_qty 置空），订单 planned_qty 回补。
     * V217: 对分段归属计划行对称镜像恢复 execution_segment_sales_allocations，
     * 并重算 production_execution_segments.planned_qty，保持 V157 总量等式。
     */
    private void restoreCap(UUID planItemId, List<PlanOrderItemLink> lockedLinks) {
        Object capObj = em.createNativeQuery(
                "SELECT capped_qty FROM production_plan_items WHERE id = :id")
                .setParameter("id", planItemId).getSingleResult();
        BigDecimal cap = bd(capObj);
        if (cap.signum() <= 0) return;
        int planUpdated = em.createNativeQuery("""
                UPDATE production_plan_items
                SET qty = COALESCE(qty,0) + :cap, capped_qty = NULL WHERE id = :id
                """).setParameter("cap", cap).setParameter("id", planItemId).executeUpdate();
        if (planUpdated != 1) {
            throw new ApiException(ErrorCode.CONFLICT, "封顶生产计划行不存在，禁止自动恢复");
        }
        // V217: 分段归属计划行对称镜像恢复 allocations（GUC 窗口仅本方法放开 UPDATE）。
        Map<UUID, Long> allocationSegCount = lockedLinks.isEmpty()
                ? Map.of()
                : countLinkAllocationSegments(lockedLinks);
        boolean segmentAttributed = !allocationSegCount.isEmpty();
        if (segmentAttributed) {
            em.createNativeQuery(
                    "SELECT set_config('app.cap_segment_allocations', 'on', true)")
                    .getSingleResult();
        }
        List<UUID> restoredAllocationLinkIds = new ArrayList<>();
        for (PlanOrderItemLink l : lockedLinks) {
            BigDecimal lc = l.getCappedQty() == null ? BigDecimal.ZERO : l.getCappedQty();
            if (lc.signum() <= 0) continue;
            l.setAllocatedQty(l.getAllocatedQty().add(lc));
            l.setCappedQty(null);
            linkRepo.save(l);
            int plannedUpdated = em.createNativeQuery("""
                    UPDATE sales_order_items
                    SET planned_qty = COALESCE(planned_qty,0) + :d WHERE id = :id
                    """).setParameter("d", lc).setParameter("id", l.getOrderItemId())
                    .executeUpdate();
            if (plannedUpdated != 1) {
                throw new ApiException(ErrorCode.CONFLICT, "封顶关联订单行不存在，禁止自动恢复");
            }
            // 镜像恢复销售分摊：单段联动=常态；多段暂不支持（避免每行重复加回致漂移）；无分摊=旧式跳过。
            if (allocationSegCount.containsKey(l.getId())) {
                long segs = allocationSegCount.get(l.getId());
                if (segs != 1) {
                    throw new ApiException(ErrorCode.CONFLICT,
                            "红冲恢复暂不支持跨多执行段(" + segs + ")的订单行，须人工核对后再红冲");
                }
                int allocationRestored = em.createNativeQuery("""
                        UPDATE execution_segment_sales_allocations
                        SET allocated_qty = allocated_qty + :add
                        WHERE plan_order_item_link_id = :lid
                        """).setParameter("add", lc)
                        .setParameter("lid", l.getId())
                        .executeUpdate();
                if (allocationRestored != 1) {
                    throw new ApiException(ErrorCode.CONFLICT,
                            "红冲恢复镜像销售分摊失败，须人工核对后再红冲");
                }
                restoredAllocationLinkIds.add(l.getId());
            }
        }
        if (!restoredAllocationLinkIds.isEmpty()) {
            em.createNativeQuery("""
                    UPDATE production_execution_segments seg
                    SET planned_qty = COALESCE((
                        SELECT SUM(a.allocated_qty)
                        FROM execution_segment_sales_allocations a
                        WHERE a.execution_segment_id = seg.id
                    ), seg.planned_qty)
                    WHERE seg.is_deleted = FALSE
                      AND EXISTS (
                        SELECT 1 FROM execution_segment_sales_allocations a2
                        WHERE a2.execution_segment_id = seg.id
                          AND a2.plan_order_item_link_id IN (:links)
                      )
                    """).setParameter("links", restoredAllocationLinkIds)
                    .executeUpdate();
        }
        if (segmentAttributed) {
            em.createNativeQuery(
                    "SELECT set_config('app.cap_segment_allocations', 'off', true)")
                    .getSingleResult();
        }
    }

    /** 本报工生成的成品入库单（id/status/bill_no）。 */
    @SuppressWarnings("unchecked")
    private List<Object[]> docsBySource(String docType, String sourceBillNo) {
        return em.createNativeQuery("""
                SELECT id, status, bill_no FROM stock_documents
                WHERE doc_type = :t AND source_doc_no = :no AND is_deleted = false
                ORDER BY id
                """).setParameter("t", docType).setParameter("no", sourceBillNo).getResultList();
    }

    /** 本报工生成的补产计划（id/status/bill_no）。 */
    @SuppressWarnings("unchecked")
    private List<Object[]> remakePlansOf(String reportBillNo) {
        return em.createNativeQuery("""
                SELECT id, status, bill_no FROM production_plans
                WHERE source_doc_no = :no AND remark LIKE '补产：%' AND is_deleted = false
                ORDER BY id
                """).setParameter("no", reportBillNo).getResultList();
    }

    /** 软删成品入库单（草稿）：主表 + 明细 + plan_draw_links 留痕。 */
    private void softDeleteStockDoc(UUID docId) {
        // V164: the transaction-local exact document marker opens only the
        // production-report cleanup path. Generic stock CRUD never sets it.
        em.createNativeQuery("""
                        SELECT set_config(
                            'app.production_report_reverse_doc_id', :id, true)
                        """)
                .setParameter("id", docId.toString())
                .getSingleResult();
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

    /**
     * V217: 各联动行对应的执行分段销售分摊段数（用于判定是否分段归属，以及多段防护）。
     * 返回 0 表示该联动行无销售分摊（旧式非分段计划），>0 表示分段归属。
     */
    private Map<UUID, Long> countLinkAllocationSegments(List<PlanOrderItemLink> links) {
        List<UUID> linkIds = links.stream().map(PlanOrderItemLink::getId).toList();
        List<Object[]> rows = NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT a.plan_order_item_link_id, COUNT(*) AS seg_count
                FROM execution_segment_sales_allocations a
                WHERE a.plan_order_item_link_id IN (:linkIds)
                GROUP BY a.plan_order_item_link_id
                """).setParameter("linkIds", linkIds));
        Map<UUID, Long> result = new HashMap<>();
        for (Object[] row : rows) {
            result.put((UUID) row[0], ((Number) row[1]).longValue());
        }
        return result;
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
        executionSegments.validateDraft(r.getId(), lines);
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
            it.setExecutionSegmentId(l.getExecutionSegmentId());
            it.setExecutionSegmentSalesAllocationId(
                    l.getExecutionSegmentSalesAllocationId());
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
                it.getSalesOrderItemId(), it.getSalesOrderNo(), it.getPlanItemId(),
                it.getExecutionSegmentId(),
                it.getExecutionSegmentSalesAllocationId(), it.getPlanNo(),
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

    /** 单次数据库往返即取得写锁，避免普通读取与随后加锁之间的陈旧状态窗口。 */
    private ProductionDailyReport requireReportForUpdate(UUID id) {
        ProductionDailyReport report = em.find(
                ProductionDailyReport.class, id, jakarta.persistence.LockModeType.PESSIMISTIC_WRITE);
        if (report == null || report.isDeleted()) {
            throw new ApiException(ErrorCode.NOT_FOUND, "生产日报单不存在");
        }
        return report;
    }
}
