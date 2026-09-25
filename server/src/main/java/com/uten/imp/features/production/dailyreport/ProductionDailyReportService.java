package com.uten.imp.features.production.dailyreport;

import com.uten.imp.application.port.ProductionMaterialConsumptionWritePort;
import com.uten.imp.application.port.ProductionQualityInspectionPort;
import com.uten.imp.application.port.ProductionFqcRecoveryPort;
import com.uten.imp.common.util.NativeValueConverters;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.saleschain.SalesOrderChainSql;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.common.web.Pageables;
import com.uten.imp.common.web.TableSort;
import com.uten.imp.common.docnumber.DocNumberPrefix;
import com.uten.imp.common.docnumber.DocNumberService;
import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.util.CanonicalFingerprint;
import com.uten.imp.common.util.NativeQueryResults;
import com.uten.imp.features.production.ProductionDocumentAccessPolicy;
import com.uten.imp.features.production.dailyreport.dto.DailyReportApproveRequest;
import com.uten.imp.features.production.dailyreport.dto.DailyReportDetail;
import com.uten.imp.features.production.dailyreport.dto.DailyReportItemDto;
import com.uten.imp.features.production.dailyreport.dto.DailyReportItemLine;
import com.uten.imp.features.production.dailyreport.dto.DailyReportListItem;
import com.uten.imp.features.production.dailyreport.dto.DailyReportMaterialUsageDto;
import com.uten.imp.features.production.dailyreport.dto.DailyReportMaterialUsageLine;
import com.uten.imp.features.production.dailyreport.dto.DailyReportQueryFilter;
import com.uten.imp.features.production.dailyreport.dto.DailyReportSaveRequest;
import com.uten.imp.features.production.plan.PlanOrderItemLink;
import com.uten.imp.features.production.plan.PlanOrderItemLinkRepository;
import com.uten.imp.features.production.plan.ProductionPlan;
import com.uten.imp.features.production.plan.ProductionPlanItem;
import com.uten.imp.features.production.plan.ProductionPlanItemRepository;
import com.uten.imp.features.production.plan.ProductionPlanRepository;
import com.uten.imp.features.production.plan.ProductionProductNoAllocator;
import com.uten.imp.features.stock.StockDocument;
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
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Locale;
import java.util.Objects;
import java.util.Map;
import java.util.Set;
import java.util.TreeSet;
import java.util.UUID;

/**
 * 生产日报服务：CRUD（主+明细）+ 审核状态机 + 业务链报工联动。
 *
 * <p>审核（status 0→1）同事务内：
 * <ol>
 *   <li>按 planItemId + executionSegmentId UUID 精确锁定已开工来源；
 *       原计划份按批准配额校验，实际超产以独立公共产出事实分账</li>
 *   <li>回写 plan_items.fqty + plan_order_item_links.produced_qty（指定订单行直击，
 *       未指定按 FIFO 分摊）；订单行状态 3/4→5 生产中</li>
 *   <li>审核后进入仓库送检登记队列；仓库冻结目标仓/库位后逐行
 *       建立 FQC。只有 PASS 数量生成 FINISHED_IN，最终点收才增加库存/iqty</li>
 *   <li>is_final 完结行：合格不足 → 缺额封顶（qty/allocated 砍到实际，砍量记 capped_qty）
 *       + 自动生成补产计划（links source=1）</li>
 * </ol>
 *
 * <p>红冲（1→-1）对称：回退 fqty/produced → 成品入库单（草稿删/已审拒）→
 * 追加 FQC 取消事实 → 恢复封顶量 → 补产计划（草稿删/已审拒）。
 */
@Service
@RequiredArgsConstructor
public class ProductionDailyReportService {

    private static final short STATUS_DRAFT = 0;
    private static final short STATUS_APPROVED = 1;
    private static final short STATUS_REVERSED = -1;

    /** 日报命令账本的命令种类(V644)：同一把 (操作者, 幂等键) 永久绑定一种命令和一张日报。 */
    private static final String COMMAND_CREATE = "CREATE";
    private static final String COMMAND_APPROVE = "APPROVE";

    /** 列排序白名单：前端列 key → JPA 实体属性名（日期可排序；命中才排序，否则默认 billDate DESC）。 */
    private static final Map<String, String> ALLOWED_SORT = Map.of("billDate", "billDate");

    private final ProductionDailyReportRepository reportRepo;
    private final ProductionDailyReportItemRepository itemRepo;
    private final ProductionPlanRepository planRepo;
    private final ProductionPlanItemRepository planItemRepo;
    private final PlanOrderItemLinkRepository linkRepo;
    private final DailyReportExecutionSegmentGuard executionSegments;
    private final DailyReportOutputAllocationService outputAllocation;
    private final ActualOutputSupplementService outputSupplements;
    private final SecurityContextCurrentUser currentUser;
    private final com.uten.imp.common.util.EmployeeNameResolver nameResolver;
    private final com.uten.imp.common.util.DepartmentNameResolver departmentNameResolver;
    private final TxSessionVars tx;
    private final DocNumberService docNumberService;
    private final ProductionProductNoAllocator productNoAllocator;
    private final EntityManager em;
    // V476：叶子仓落库校验。字段注入+可空——单测手工构造时缺省跳过，Spring 环境恒注入。
    @org.springframework.beans.factory.annotation.Autowired(required = false)
    private com.uten.imp.features.master.warehouse.WarehouseScopeService warehouseScopes;
    private final com.uten.imp.features.notice.ChainNoticeService chainNotice;
    private final ProductionDocumentAccessPolicy access;
    private final ProductionQualityInspectionPort qualityInspection;
    private final ProductionFqcRecoveryPort fqcRecovery;
    private final ProductionLegacyFinishedInboundService
            legacyFinishedInbound;
    private final com.uten.imp.features.production.quality.ProductionQualityMutationFootprintService mutationFootprint;
    private final com.uten.imp.application.port.ProductionCostTargetPort costTargets;
    /** V583：报工同页登记的实际用料，审核时与完工量同事务记账，红冲时一起退回。 */
    private final ProductionMaterialConsumptionWritePort materialConsumption;
    /** V584/V585：车间内部直送，审核时同事务放行入线边仓并投给同车间上层工单。 */
    private final com.uten.imp.features.production.directtransfer
            .ProductionWorkshopDirectTransferService directTransfer;
    /** V595：持续生产完结时释放直送子件余量后刷新需求状态。字段注入+可空——单测手工构造时缺省跳过。 */
    @org.springframework.beans.factory.annotation.Autowired(required = false)
    private com.uten.imp.features.production.fulfillment.ProductionFulfillmentLedgerService fulfillmentLedger;

    @Transactional(readOnly = true)
    public PageResponse<DailyReportListItem> list(DailyReportQueryFilter f, int page, int size, String sort, String order) {
        var readScope = access.scope(
                "production_daily_report:approve",
                "production_daily_report:reverse");
        Specification<ProductionDailyReport> spec = (Root<ProductionDailyReport> root,
                                                     jakarta.persistence.criteria.CriteriaQuery<?> q,
                                                     CriteriaBuilder cb) -> {
            List<Predicate> ps = new ArrayList<>();
            ps.add(cb.isFalse(root.get("deleted")));
            ps.add(access.readablePredicate(root, cb, "makerId", readScope));
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
        return new PageResponse<>(p.map(this::toList).getContent(), p);
    }

    @Transactional(readOnly = true)
    public DailyReportDetail detail(UUID id) {
        ProductionDailyReport r = requireReport(id);
        access.requireReadable(
                r.getMakerId(), "生产日报单不存在",
                "production_daily_report:approve",
                "production_daily_report:reverse");
        List<ProductionDailyReportItem> rows = itemRepo.findByReportIdOrderByLineNoAsc(id);
        Map<UUID, String> transferLabels = directTransferTargetLabels(rows);
        Map<UUID, String[]> identities = goodsIdentities(rows);
        List<DailyReportItemDto> items = rows.stream()
                .map(item -> toItemDto(item, transferLabels, identities)).toList();
        populateExecutionContext(r, items);
        return toDetail(r, items, allowedActions(r, rows));
    }

    /**
     * 明细行的货品身份三列与单位，一次 IN 查询取齐，详情页直接显示。
     *
     * <p>不让页面拿 UUID 自己查字典：客户端字典缓存会随连接恢复或权限快照变化整体清空，
     * 那时这四列会集体变成「—」且不会自愈；跨模块读字典还要 goods:view/color:view/unit:view。
     * 同一响应里的制单员与「转给工单」本来就走服务端解析，这里补齐同一口径。
     */
    private Map<UUID, String[]> goodsIdentities(List<ProductionDailyReportItem> items) {
        List<UUID> itemIds = items.stream()
                .map(ProductionDailyReportItem::getId)
                .filter(Objects::nonNull)
                .distinct()
                .toList();
        if (itemIds.isEmpty()) return Map.of();
        Map<UUID, String[]> byItem = new HashMap<>();
        for (Object[] row : NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT item.id, goods.name, goods.code, color.name, unit.name
                FROM production_daily_report_items item
                LEFT JOIN goods ON goods.id = item.goods_id
                LEFT JOIN colors color ON color.id = item.color_id
                LEFT JOIN units unit ON unit.id = item.unit_id
                WHERE item.id IN (:ids)
                """).setParameter("ids", itemIds))) {
            byItem.put((UUID) row[0], new String[] {
                    (String) row[1], (String) row[2], (String) row[3], (String) row[4]});
        }
        return byItem;
    }

    private void populateExecutionContext(ProductionDailyReport report, List<DailyReportItemDto> items) {
        List<UUID> segmentIds = items.stream().map(DailyReportItemDto::getExecutionSegmentId)
                .filter(Objects::nonNull).distinct().toList();
        if (segmentIds.isEmpty()) return;
        for(Object[] row:NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT id,fn_daily_report_is_public_output(id) FROM production_daily_report_items
                WHERE report_id=:report AND NOT is_deleted
                """).setParameter("report",report.getId()))) {
            items.stream().filter(item->Objects.equals(item.getId(),row[0])).findFirst()
                    .ifPresent(item->item.setPublicOutput(Boolean.TRUE.equals(row[1])));
        }
        Map<UUID, Object[]> contexts = new HashMap<>();
        for (Object[] row : NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT segment.id, segment.plan_id,
                       CASE WHEN :draft THEN GREATEST(segment.planned_qty - COALESCE((
                           SELECT SUM(item.qty) FROM production_daily_report_items item
                           JOIN production_daily_reports other ON other.id=item.report_id
                           WHERE item.execution_segment_id=segment.id
                             AND item.fqc_recovery_authorization_id IS NULL AND NOT item.is_actual_surplus AND NOT item.is_deleted
                             AND other.status=1 AND NOT other.is_deleted
                             AND other.id<>:report),0),0) ELSE NULL END,
                       segment.allowed_overproduction_rate,
                       trunc(segment.planned_qty*(1+segment.allowed_overproduction_rate),4),
                       fn_execution_actual_surplus_available(segment.id,:report),
                       fn_execution_overproduction_policy_applies(segment.id)
                FROM production_execution_segments segment WHERE segment.id IN (:segments)
                """).setParameter("segments",segmentIds).setParameter("report",report.getId())
                .setParameter("draft",report.getStatus()==STATUS_DRAFT))) {
            contexts.put((UUID) row[0],row);
        }
        for (DailyReportItemDto item : items) {
            Object[] context = contexts.get(item.getExecutionSegmentId());
            if (context == null) continue;
            item.setPlanId((UUID) context[1]);
            item.setRemainingPlanQty((BigDecimal) context[2]);
            item.setAllowedOverproductionRate((BigDecimal)context[3]);
            item.setOverproductionLimitQty((BigDecimal)context[4]);
            item.setRemainingActualSurplusQty((BigDecimal)context[5]);
            item.setAllowActualOverproduction(item.getFqcRecoveryAuthorizationId()==null&&Boolean.TRUE.equals(context[6]));
        }
        Map<UUID,DailyReportItemDto> byId=items.stream().collect(java.util.stream.Collectors.toMap(DailyReportItemDto::getId,item->item));
        for(Object[] row:NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT item.id,proof.id,proof.batch_id,proof.actual_batch_qty,source.id,source.source_plan_item_id,
                       request.source_sales_allocation_id,allocation.sales_order_item_id,source.plan_id
                FROM production_daily_report_items item
                JOIN production_actual_output_supplement_proofs proof ON proof.id=item.supplement_proof_id
                JOIN production_actual_output_supplement_requests request ON request.id=proof.command_id
                JOIN production_execution_segments source ON source.id=proof.source_execution_segment_id
                LEFT JOIN execution_segment_sales_allocations allocation ON allocation.id=request.source_sales_allocation_id
                WHERE item.report_id=:report AND NOT item.is_deleted AND item.fqc_recovery_authorization_id IS NULL
                """).setParameter("report",report.getId()))) {
            var item=byId.get((UUID)row[0]);if(item==null)continue;
            item.setSupplementProofId((UUID)row[1]);item.setOutputBatchId((UUID)row[2]);item.setOutputBatchQty((BigDecimal)row[3]);
            item.setOutputSourceExecutionSegmentId((UUID)row[4]);item.setOutputSourcePlanItemId((UUID)row[5]);
            item.setOutputSourceSalesAllocationId((UUID)row[6]);item.setOutputSourceSalesOrderItemId((UUID)row[7]);
            item.setOutputSourcePlanId((UUID)row[8]);
        }
    }

    @Transactional
    @PreAuthorize("hasAuthority('production_daily_report:create')")
    public DailyReportDetail create(DailyReportSaveRequest req) {
        tx.bind();
        if (req == null || req.getItems() == null) {
            throw new ApiException(
                    ErrorCode.VALIDATION_FAILED, "生产日报创建请求或明细不能为空");
        }
        UUID actorId = currentUser.requireId();
        String idempotencyKey =
                normalizeCreateIdempotencyKey(req.getIdempotencyKey());
        List<UUID> workerIds = normalizeWorkerIds(req);
        String requestHash = createRequestHash(req);
        lockCommand(COMMAND_CREATE, actorId, idempotencyKey);
        ReportCommand replay = findCommand(actorId, idempotencyKey);
        if (replay != null) {
            if (!COMMAND_CREATE.equals(replay.commandKind())
                    || !requestHash.equals(replay.requestHash())) {
                throw new ApiException(
                        ErrorCode.CONFLICT, "同一幂等键已用于不同的生产日报创建请求");
            }
            return detail(replay.reportId());
        }
        validateWorkerIds(workerIds);

        ProductionDailyReport r = new ProductionDailyReport();
        applyHeader(req, r, workerIds);
        r.setMakerId(currentUser.requireEmployeeId()); // 制单=当前登录用户（对象级归属）
        r.setStatus(STATUS_DRAFT);
        reportRepo.saveAndFlush(r);
        saveItems(r, req.getItems());
        itemRepo.flush();
        syncMaterialUsages(r, req);
        outputAllocation.requireMaterialDeclarations(r.getId());
        syncReportWorkers(r.getId(), workerIds);
        recordCommand(COMMAND_CREATE,
                actorId, idempotencyKey, requestHash, r.getId());
        return detail(r.getId());
    }

    @Transactional
    @PreAuthorize("hasAuthority('production_daily_report:edit')")
    public DailyReportDetail update(UUID id, DailyReportSaveRequest req) {
        tx.bind();
        ProductionDailyReport r = requireReportForUpdate(id);
        access.requireWritable(r.getMakerId(), "只能操作本人负责的生产日报");
        requireExpectedVersion(req == null ? null : req.getExpectedVersion(),
                r.getRowVersion());
        if (r.getStatus() != STATUS_DRAFT) throw new ApiException(ErrorCode.BUSINESS, "仅草稿单据可编辑");
        var existingProofs=itemRepo.findByReportIdOrderByLineNoAsc(id).stream()
                .filter(item->item.getFqcRecoveryAuthorizationId()==null).map(ProductionDailyReportItem::getSupplementProofId)
                .filter(Objects::nonNull).collect(java.util.stream.Collectors.toSet());
        var submittedProofs=req.getItems().stream().filter(Objects::nonNull)
                .filter(item->item.getFqcRecoveryAuthorizationId()==null).map(DailyReportItemLine::getSupplementProofId)
                .filter(Objects::nonNull).collect(java.util.stream.Collectors.toSet());
        if(!submittedProofs.containsAll(existingProofs))throw new ApiException(ErrorCode.CONFLICT,
                "已批准的追加批次关联不可在同一草稿中移除或替换；本单其他行未改变。需要撤回本批时请先删除草稿，再按原申请办理取消或新单续报");
        List<UUID> workerIds = normalizeWorkerIds(req);
        validateWorkerIds(workerIds);
        applyHeader(req, r, workerIds);
        itemRepo.deleteByReportId(id);
        itemRepo.flush();
        saveItems(r, req.getItems());
        itemRepo.flush();
        syncMaterialUsages(r, req);
        outputAllocation.requireMaterialDeclarations(r.getId());
        syncReportWorkers(id, workerIds);
        // An item-only edit must still dirty the header so JPA @Version advances.
        r.setUpdatedAt(java.time.Instant.now());
        reportRepo.saveAndFlush(r);
        return detail(id);
    }

    @Transactional
    @PreAuthorize("hasAuthority('production_daily_report:delete')")
    public void delete(UUID id) {
        tx.bind();
        ProductionDailyReport r = requireReportForUpdate(id);
        access.requireWritable(r.getMakerId(), "只能操作本人负责的生产日报");
        com.uten.imp.common.web.StandardDocumentLifecycleCapabilities.requireDraftForDelete(r.getStatus());
        r.setDeleted(true);
        r.setDeletedAt(OffsetDateTime.now());
        reportRepo.saveAndFlush(r);
        outputSupplements.releaseClaims(r.getId());
    }

    /** 审核（status 0→1）：报工链联动（见类注释）。 */
    @Transactional
    @PreAuthorize("hasAuthority('production_daily_report:approve')")
    public DailyReportDetail approve(UUID id, DailyReportApproveRequest req) {
        tx.bind();
        // 幂等闸门排在最前：回放请求不该去抢履约图的顾问锁和日报行写锁，
        // 它只在 (操作者, 幂等键) 这一把顾问锁上等前一笔提交，然后原样返回结果。
        UUID actorId = currentUser.requireId();
        String idempotencyKey = normalizeApproveIdempotencyKey(
                req == null ? null : req.getIdempotencyKey());
        String requestHash = approveRequestHash(id);
        lockCommand(COMMAND_APPROVE, actorId, idempotencyKey);
        ReportCommand replay = findCommand(actorId, idempotencyKey);
        if (replay != null) {
            if (!COMMAND_APPROVE.equals(replay.commandKind())
                    || !id.equals(replay.reportId())
                    || !requestHash.equals(replay.requestHash())) {
                throw new ApiException(
                        ErrorCode.CONFLICT, "同一幂等键已用于不同的生产日报审核请求");
            }
            return detail(id);
        }
        var sourceGuard = mutationFootprint.beginReport(id);
        ProductionDailyReport r = requireReportForUpdate(id);
        access.requireWritable(
                r.getMakerId(), "无权审核此生产日报",
                "production_daily_report:approve");
        // 状态闸绝不放宽——它是唯一挡住重复副作用的东西(fqty 累加与直送单都是纯增量)。
        // 只把错误码从 BUSINESS(400) 换成 CONFLICT(409)：客户端据此知道该刷新而不是当校验失败。
        if (r.getStatus() == null || r.getStatus() != STATUS_DRAFT)
            throw new ApiException(
                    ErrorCode.CONFLICT,
                    "生产日报已不是草稿状态，不能重复审核；请刷新后查看当前状态");
        // 过了闸门就落命令账本：同事务，失败一起回滚；重发时上面的回放分支直接命中。
        recordCommand(COMMAND_APPROVE, actorId, idempotencyKey, requestHash, id);
        List<ProductionDailyReportItem> items = itemRepo.findByReportIdOrderByLineNoAsc(id);
        if (items.isEmpty())
            throw new ApiException(ErrorCode.BUSINESS, "明细为空，不可审核");
        if (items.stream().anyMatch(item ->
                item.getPlanItemId() == null)) {
            throw new ApiException(
                    ErrorCode.VALIDATION_FAILED,
                    "每条报工必须关联精确生产计划行；新流程还必须选择已开工执行子任务");
        }
        outputAllocation.requireMaterialDeclarations(id);
        outputAllocation.requirePersistedAllowance(id);
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
                lockPlanLinkGraph(resolvedPlanItems.values(), true,
                        items.stream().map(ProductionDailyReportItem::getSalesOrderItemId)
                                .filter(Objects::nonNull).collect(java.util.stream.Collectors.toSet()),
                        items.stream().filter(item -> item.getExecutionSegmentId() == null
                                        && item.getSalesOrderItemId() == null)
                                .map(item -> resolvedPlanItems.get(item.getId()))
                                .filter(Objects::nonNull).collect(java.util.stream.Collectors.toSet()));
        sourceGuard.verifyUnchanged();
        for (ProductionDailyReportItem it : items) {
            UUID planItemId = resolvedPlanItems.get(it.getId());
            if (planItemId == null) continue; // 手工行（无计划关联）不进链
            Object[] pi = planItemRow(planItemId, true);
            requireMatchingPlanDimension(it, pi);
            BigDecimal qty = it.getQty();
            BigDecimal actualAllowance = bd(em.createNativeQuery("SELECT fn_plan_actual_surplus_qty(:id,TRUE)")
                    .setParameter("id",planItemId).getSingleResult());
            BigDecimal remain = bd(pi[2]).add(actualAllowance).subtract(bd(pi[3]));
            if (qty.compareTo(remain) > 0) {
                throw new ApiException(ErrorCode.BUSINESS, "报工量超过计划剩余(剩 "
                        + remain.stripTrailingZeros().toPlainString() + ")");
            }
            em.createNativeQuery("UPDATE production_plan_items SET fqty = COALESCE(fqty,0) + :q WHERE id = :id")
                    .setParameter("q", qty).setParameter("id", planItemId).executeUpdate();
            if (!isInternalExecutionReport(it)) {
                distributeProduced(
                        planItemId,
                        it.getExecutionSegmentSalesAllocationId(),
                        it.getSalesOrderItemId(), qty, +1,
                        lockedLinks.getOrDefault(planItemId, List.of()));
            }
            byPlan.computeIfAbsent((UUID) pi[1], k -> new ArrayList<>()).add(it);
            if (Boolean.TRUE.equals(it.isFinal()) && !finalPlanItemIds.contains(planItemId)) {
                finalPlanItemIds.add(planItemId);
            }
        }

        // 2) 完结行：缺额封顶 + 自动补产
        for (UUID planItemId : finalPlanItemIds) {
            capAndRemake(r, planItemId,
                    lockedLinks.getOrDefault(planItemId, List.of()));
        }
        // 2.5) V583 报工同页登记的本次实际用料：与完工量同事务记账，收尾按意愿提交余料退仓。
        // 放在计划结案重算之前——材料结清会改写 is_closed，顺序反过来会让刚算好的结案状态失效。
        settleMaterialUsageOnApprove(r);
        // 2.6) V595 持续生产：完结行所在工单的直送子件余量就此释放(不会再有人送料)。
        releaseContinuousMaterialRemainderOnFinal(r.getId(), items);

        // 3) 受影响计划重算结案
        for (UUID planId : byPlan.keySet()) {
            recomputePlanClosed(planId);
        }

        r.setStatus(STATUS_APPROVED);
        r.setApproverId(currentUser.requireEmployeeId());
        reportRepo.saveAndFlush(r);
        costTargets.targetChangedByReport(r.getId(),currentUser.requireId());
        for (ProductionDailyReportItem item : items) {
            if (item.getFqcRecoveryAuthorizationId() != null) {
                fqcRecovery.allocateApprovedRecoveryReportItem(
                        item.getId(),
                        item.getFqcRecoveryAuthorizationId(),
                        item.getQty());
            }
        }
        // Preserve the explicit pre-execution compatibility lane. New clients
        // cannot create no-segment lines, but an existing legacy draft with a
        // reviewed exemption and warehouse must not become an orphan.
        if (r.getWarehouseId() != null) {
            for (var entry : byPlan.entrySet()) {
                List<ProductionDailyReportItem> legacyItems =
                        entry.getValue().stream()
                                .filter(item ->
                                        item.getExecutionSegmentId() == null)
                                .toList();
                if (!legacyItems.isEmpty()) {
                    for (ProductionDailyReportItem legacyItem : legacyItems) {
                        fqcRecovery.requireLegacyExemption(legacyItem.getId());
                    }
                    legacyFinishedInbound.createDraft(
                            r, entry.getKey(), legacyItems);
                }
            }
        }
        // V584/V585 车间内部直送：选了「转下一道工序」的行不走仓库，在这里同事务
        // 完成班组自检放行 → 料进本车间线边仓 → 重算上层工单齐套 → 投给上层工单。
        // 放在通知之前——下面那条仓库待登记通知要按「还剩不剩送仓库的行」来发。
        directTransfer.executeForApprovedReport(r, items);

        // 报工审核只增加 fqty。仓库完成目标仓/库位送检登记后，
        // 登记事务才逐行建立 FQC；PASS 后生成 FINISHED_IN 待点收草稿。
        chainNotice.notifyProductionReported(r.getId());
        // 整单都直送时不要给仓库发待登记通知：那会变成仓库永远清不掉的假待办
        //(待登记视图本身已按「有没有 FQC 检验」把直送行排除，通知这一侧要单独对齐)。
        if (items.stream().anyMatch(
                    item -> !"WORKSHOP".equals(item.getDestination()))
                && items.stream().allMatch(
                    item -> item.getExecutionSegmentId() != null)) {
            chainNotice.notifyProductionFinishedArrivalPending(r.getId());
        }
        chainNotice.notifyRemakeCreated(r.getId()); // UUID 真源：完结缺额已自动补产→销售（无补产时静默）
        return detail(id);
    }

    /** 红冲（status 1→-1）：对称回退（见类注释）。 */
    @Transactional
    @PreAuthorize("hasAuthority('production_daily_report:reverse')")
    public DailyReportDetail reverse(UUID id) {
        tx.bind();
        var sourceGuard = mutationFootprint.beginReport(id);
        ProductionDailyReport r = requireReportForUpdate(id);
        qualityInspection.prelockForReportReversal(r.getId());
        access.requireWritable(
                r.getMakerId(), "无权红冲此生产日报",
                "production_daily_report:reverse");
        if (r.getStatus() == null || r.getStatus() != STATUS_APPROVED)
            throw new ApiException(ErrorCode.BUSINESS, "仅已审核单据可红冲");
        List<ProductionDailyReportItem> items = itemRepo.findByReportIdOrderByLineNoAsc(id);
        executionSegments.prelockForReverse(items);
        lockPlanItems(items.stream()
                .map(ProductionDailyReportItem::getPlanItemId)
                .filter(java.util.Objects::nonNull)
                .toList());
        Map<UUID, List<PlanOrderItemLink>> lockedLinks = lockPlanLinkGraph(
                items.stream().map(ProductionDailyReportItem::getPlanItemId)
                        .filter(Objects::nonNull).toList(), false);
        // Validate the locked source before our own reversals change its state.
        // Material reversal may legitimately reopen a completed segment; comparing
        // the old fingerprint after that write mistakes our change for a race.
        sourceGuard.verifyUnchanged();
        // V583：先退掉本单审核时登记的实际用料。放在执行段回退之前——材料冲销会把已完工段
        // 打回生产中，先冲再回退，后面的执行段校验看到的才是最终状态。
        reverseMaterialUsageOnReverse(r);
        // V584：撤回本单的直送承诺。库存与放行事实各走各的反向链路(下面的成品入库单
        // 红冲、FQC 取消事件)，这里只把「承诺」作废，让同一条报工行日后可以重新直送。
        directTransfer.reverseForReport(
                r.getId(),
                "生产日报 " + (r.getBillNo() == null ? "" : r.getBillNo()) + " 红冲");
        executionSegments.reverse(items);

        // 1) 回退 fqty / links.produced / 行状态
        List<UUID> affectedPlans = new ArrayList<>();
        for (ProductionDailyReportItem it : items) {
            UUID planItemId = it.getPlanItemId();
            if (planItemId == null) continue;
            Object[] pi = planItemRow(planItemId, false);
            requireMatchingPlanDimension(it, pi);
            BigDecimal declaredQty = it.getQty() == null
                    ? BigDecimal.ZERO : it.getQty();
            if (declaredQty.signum() <= 0) {
                throw new ApiException(
                        ErrorCode.CONFLICT,
                        "历史报工明细数量无效，禁止自动红冲");
            }
            BigDecimal qty = fqcRecovery.effectiveContribution(
                    it.getId(), declaredQty);
            if (qty.signum() < 0) {
                throw new ApiException(
                        ErrorCode.CONFLICT,
                        "FQC 有效贡献为负，禁止自动红冲");
            }
            BigDecimal finishedAfterReverse = bd(pi[3]).subtract(qty);
            BigDecimal alreadyInbound = bd(pi[11]);
            if (finishedAfterReverse.compareTo(alreadyInbound) < 0) {
                throw new ApiException(ErrorCode.CONFLICT,
                        "红冲后已报工合格量将小于已入库量，请先红冲相关成品入库单");
            }
            if (!affectedPlans.contains((UUID) pi[1])) affectedPlans.add((UUID) pi[1]);
            int finishedUpdated = qty.signum() == 0 ? 1 : em.createNativeQuery("""
                            UPDATE production_plan_items
                            SET fqty = COALESCE(fqty,0) - :q
                            WHERE id = :id AND COALESCE(fqty,0) >= :q
                            """).setParameter("q", qty).setParameter("id", planItemId).executeUpdate();
            if (finishedUpdated != 1) {
                throw new ApiException(ErrorCode.CONFLICT, "生产计划已报工累计不足，禁止自动吞并红冲错账");
            }
            List<PlanOrderItemLink> planLinks =
                    lockedLinks.getOrDefault(planItemId, List.of());
            if (qty.signum() > 0 && !isInternalExecutionReport(it)) {
                distributeProduced(
                        planItemId,
                        it.getExecutionSegmentSalesAllocationId(),
                        it.getSalesOrderItemId(), qty, -1, planLinks);
            }
            // 恢复封顶（若该行是完结行）
            if (Boolean.TRUE.equals(it.isFinal())) {
                restoreCap(r.getId(),planItemId, planLinks);
            }
        }

        // 2) 本单生成的成品入库单：草稿→软删；已审→拒绝
        for (Object[] d : docsBySource("FINISHED_IN", r.getId())) {
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
        for (Object[] p : remakePlansOf(r.getId())) {
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

        restoreContinuousMaterialRemainder(r.getId(), items);
        for (UUID planId : affectedPlans) {
            recomputePlanClosed(planId);
        }
        r.setStatus(STATUS_REVERSED);
        reportRepo.saveAndFlush(r);
        outputSupplements.releaseClaims(r.getId());
        costTargets.targetChangedByReport(r.getId(),currentUser.requireId());
        fqcRecovery.reverseReportEffects(r.getId());
        qualityInspection.cancelForReversedReport(r.getId());
        return detail(id);
    }

    // ====================== 报工链辅助 ======================

    /**
     * Resolve the authoritative plan-line identity.
     * Number snapshots never establish a relation: an old row with only a
     * plan number must be explicitly relinked before it can drive writeback.
     */
    private UUID resolvePlanItem(ProductionDailyReportItem it) {
        if (it.getPlanItemId() != null) {
            return it.getPlanItemId();
        }
        if (hasText(it.getPlanNo()) || hasText(it.getSalesOrderNo())) {
            throw new ApiException(
                    ErrorCode.CONFLICT,
                    "报工来源只有编号快照，不能自动猜关联；请重新选择来源子任务或清除来源");
        }
        return null;
    }

    private static boolean hasText(String value) {
        return value != null && !value.isBlank();
    }

    /** 计划行快照：正向报工拒绝终态计划；红冲仍允许读取终态并逆向清理。 */
    private Object[] planItemRow(UUID planItemId, boolean positiveWrite) {
        String terminalGate = positiveWrite
                ? " AND p.status = 1 AND p.is_stopped = false AND p.is_canceled = false AND p.is_closed = false"
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
                                    + "(可能存在跨链 FIFO 分摊)，须先核对再红冲");
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
                advanceChainToProducing(l.getOrderItemId());
                remaining = remaining.subtract(c);
            } else {
                BigDecimal c = l.getProducedQty().min(remaining);
                if (c.signum() <= 0) continue;
                l.setProducedQty(l.getProducedQty().subtract(c));
                linkRepo.save(l);
                recomputeChainAfterReportReversal(l.getOrderItemId());
                remaining = remaining.subtract(c);
            }
        }
        if (remaining.signum() > 0) {
            String action = sign > 0 ? "报工" : "红冲";
            throw new ApiException(
                    ErrorCode.CONFLICT,
                    action + "量超过生产计划与销售订单的可分摊量(剩 "
                            + remaining.stripTrailingZeros().toPlainString() + " 无法分摊)");
        }
    }

    /**
     * 锁序固定为销售订单头/行 → 计划联动行。普通查询只用于发现候选集合，
     * 真正写入前逐行 PESSIMISTIC_WRITE + refresh，并校验集合未被并发增删。
     */
    private Map<UUID, List<PlanOrderItemLink>> lockPlanLinkGraph(
            java.util.Collection<UUID> requestedPlanItemIds, boolean positiveWrite) {
        return lockPlanLinkGraph(requestedPlanItemIds, positiveWrite, null, null);
    }

    private Map<UUID, List<PlanOrderItemLink>> lockPlanLinkGraph(
            java.util.Collection<UUID> requestedPlanItemIds, boolean positiveWrite,
            java.util.Set<UUID> salesRequiredOrderItemIds,
            java.util.Set<UUID> legacyRequiredPlanItemIds) {
        // 构造时即滤除 null：TreeSet 基于 TreeMap，其 add/remove null 在 Java 21 必抛 NPE
        // （此前对含 null 的集合 new TreeSet<>() 构造或随后 remove(null) 都会崩 → 任何日报审核都 NPE，全链断）。
        TreeSet<UUID> planItemIds = requestedPlanItemIds == null
                ? new TreeSet<>()
                : requestedPlanItemIds.stream()
                        .filter(java.util.Objects::nonNull)
                        .collect(java.util.stream.Collectors.toCollection(TreeSet::new));
        if (planItemIds.isEmpty()) return Map.of();

        List<PlanOrderItemLink> snapshots = new ArrayList<>(
                linkRepo.findActiveByPlanItemIds(new ArrayList<>(planItemIds)));
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

        // Public stock belongs to the execution task, so a completed customer
        // order must not prevent producing the independently approved surplus.
        // We still lock and validate the original graph without rewriting it.
        lockSalesTargets(snapshots, positiveWrite, salesRequiredOrderItemIds, legacyRequiredPlanItemIds);

        java.util.Set<UUID> expectedIds = snapshots.stream()
                .map(PlanOrderItemLink::getId)
                .collect(java.util.stream.Collectors.toSet());
        List<UUID> currentIds = NativeQueryResults.typedRows(em.createNativeQuery("""
                        SELECT id
                        FROM plan_order_item_links
                        WHERE plan_item_id IN (:planItemIds)
                          AND COALESCE(is_deleted, false) = false
                        ORDER BY id
                        FOR UPDATE
                        """).setParameter("planItemIds", planItemIds), UUID.class);
        // UUID.compareTo compares signed longs, while PostgreSQL orders UUID
        // bytes unsigned. Compare membership rather than these different list
        // orders, retaining detection of inserted/deleted/replaced links.
        if (currentIds.size() != snapshots.size()
                || !new java.util.HashSet<>(currentIds).equals(expectedIds)) {
            throw new ApiException(ErrorCode.CONFLICT,
                    "报工关联的排产分摊已被并发变更，请刷新后重试");
        }

        Map<UUID, List<PlanOrderItemLink>> result = new HashMap<>();
        // Preserve the database's already-acquired lock order for entity refresh.
        for (UUID linkId : currentIds) {
            PlanOrderItemLink link = em.find(
                    PlanOrderItemLink.class, linkId,
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
            List<PlanOrderItemLink> targets, boolean positiveWrite,
            java.util.Set<UUID> salesRequiredOrderItemIds,
            java.util.Set<UUID> legacyRequiredPlanItemIds) {
        List<UUID> orderItemIds = targets.stream()
                .map(PlanOrderItemLink::getOrderItemId)
                .distinct()
                .sorted()
                .toList();
        java.util.Set<UUID> requiredOrderItemIds = targets.stream()
                .filter(link -> salesRequiredOrderItemIds == null
                        || salesRequiredOrderItemIds.contains(link.getOrderItemId())
                        || (legacyRequiredPlanItemIds != null
                            && legacyRequiredPlanItemIds.contains(link.getPlanItemId())))
                .map(PlanOrderItemLink::getOrderItemId)
                .collect(java.util.stream.Collectors.toSet());
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
            if (positiveWrite && requiredOrderItemIds.contains((UUID) row[0])
                    && (status == null || status != STATUS_APPROVED
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

    /** The execution guard has proved this line's separate internal quota. */
    static boolean isInternalExecutionReport(ProductionDailyReportItem item) {
        return item.getExecutionSegmentId() != null
                && item.getExecutionSegmentSalesAllocationId() == null
                && item.getSalesOrderItemId() == null;
    }

    /**
     * 报工审核推进订单行 3/4 → 5 生产中。V545：只有剩余未排量归零（整行已排满）才推进；
     * 部分排产的行（订 10 排 4）留在 1/2 待排产，报工事实仍写在 links.produced_qty。
     */
    private void advanceChainToProducing(UUID orderItemId) {
        em.createNativeQuery("UPDATE sales_order_items SET chain_status = 5"
                        + " WHERE id = :id AND COALESCE(chain_status,0) IN (3,4)"
                        + " AND " + SalesOrderChainSql.unplannedQtySql("") + " <= 0")
                .setParameter("id", orderItemId).executeUpdate();
    }

    /**
     * 报工红冲后重算订单行状态（V545 统一派生）：仍有有效报工量则留在 5，
     * 报工全部冲回才退到已排产（原值 3 保留 3，否则 4）；其余分支按数量收敛。
     */
    private void recomputeChainAfterReportReversal(UUID orderItemId) {
        // 必须带表别名：EXISTS 子查询里裸写 id 会绑到 plan_order_item_links.id（内层作用域优先）。
        em.createNativeQuery("UPDATE sales_order_items order_item SET chain_status = "
                        + SalesOrderChainSql.chainStatusCaseSql(
                                SalesOrderChainSql.ChainStatusInputs.of("order_item")
                                        .producing(SalesOrderChainSql.hasReportedQtySql("order_item")))
                        + " WHERE order_item.id = :id")
                .setParameter("id", orderItemId).executeUpdate();
    }

    /** 自动生成成品入库单（草稿）+ plan_draw_links（仓库审核后经 applyFinishedInChain 补预留）。 */
    /**
     * 完结缺额封顶 + 自动补产：
     * 合格（fqty）< 计划量 → 计划行 qty 砍到 fqty（砍量记 capped_qty）、
     * links.allocated 砍到 produced（砍量记 link.capped_qty，订单 planned_qty 同步回退），
     * 差额生成补产计划（草稿，links source=1，来源以报工 UUID 为真源、单号为展示快照）。
     */
    private void capAndRemake(ProductionDailyReport r, UUID planItemId,
                              List<PlanOrderItemLink> lockedLinks) {
        Object[] pi = planItemRow(planItemId, true);
        BigDecimal plannedQty = bd(pi[2]);
        BigDecimal actualContribution=bd(em.createNativeQuery("SELECT fn_plan_actual_output_contribution_qty(:item,:report)")
                .setParameter("item",planItemId).setParameter("report",r.getId()).getSingleResult());
        BigDecimal produced = bd(pi[3]).subtract(actualContribution).max(BigDecimal.ZERO)
                .max(primaryReportedQuantity(r.getId(),planItemId,null));
        BigDecimal shortfall = plannedQty.subtract(produced);
        if (shortfall.signum() <= 0) return; // 足量完结，无需补产

        if(Boolean.TRUE.equals(em.createNativeQuery("SELECT fn_daily_report_has_unissued_material(:item)")
                .setParameter("item",planItemId).getSingleResult())) {
            throw new ApiException(ErrorCode.CONFLICT,
                    "仍有已备料但未实发的预留或领料明细，不能提前完结后遗留继续发料的任务；请先普通分次报工，继续按原任务领料生产，达量后再完成");
        }
        Number openSupply = (Number) em.createNativeQuery("""
                SELECT COUNT(*) FROM production_material_demands demand
                JOIN production_material_supply_pegs peg ON peg.demand_id=demand.id
                WHERE demand.source_plan_item_id=:item AND NOT demand.is_deleted
                  AND peg.status<>'REVERSED' AND peg.allocated_qty-peg.consumed_qty-peg.released_qty>0
                """).setParameter("item",planItemId).getSingleResult();
        if(openSupply.longValue()>0)throw new ApiException(ErrorCode.CONFLICT,
                "仍有未兑现的采购、委外或生产供给承诺，请先按原供给链撤回或改派后提前完结；本次可继续普通分次报工");

        UUID planId = (UUID) pi[1];
        String planNo = (String) pi[9];
        // Freeze the exact owner of the target change before updating its projection.
        em.createNativeQuery("""
                INSERT INTO production_daily_report_target_events(
                    report_id,plan_item_id,event_type,before_qty,after_qty,created_by)
                VALUES(:report,:item,'CAP',:before,:after,:actor)
                """).setParameter("report",r.getId()).setParameter("item",planItemId)
                .setParameter("before",plannedQty).setParameter("after",produced)
                .setParameter("actor",currentUser.requireId()).executeUpdate();
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
        // 分段归属的计划行需同步镜像削减 execution_segment_sales_allocations，
        // 否则总量等式/超分摊约束在提交时漂移。先查明各联动行的销售分摊段数。
        Map<UUID, Long> allocationSegCount = links.isEmpty()
                ? Map.of()
                : countLinkAllocationSegments(links);
        boolean segmentAttributed = !allocationSegCount.isEmpty();
        if (segmentAttributed) {
            em.createNativeQuery("SELECT set_config('app.cap_segment_report_id',:id,true)").setParameter("id",r.getId().toString()).getSingleResult();
            em.createNativeQuery(
                    "SELECT set_config('app.cap_segment_allocations', 'on', true)")
                    .getSingleResult();
        }
        List<UUID> cappedAllocationLinkIds = new ArrayList<>();
        for (PlanOrderItemLink l : links) {
            BigDecimal producedBasis=l.getProducedQty().max(primaryReportedQuantity(r.getId(),planItemId,l.getId()));
            BigDecimal linkShort = l.getAllocatedQty().subtract(producedBasis);
            if (linkShort.signum() <= 0) continue;
            l.setCappedQty(linkShort);
            l.setAllocatedQty(producedBasis);
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
        // 重算受影响分段 planned_qty = SUM(allocations)，保持总量等式（多联动同行分段也成立）。
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
        rp.setDeliveryDate(pi[8] == null ? null : NativeValueConverters.toLocalDate(pi[8]));
        rp.setRemark("补产：原计划 " + planNo + "(报工 " + r.getBillNo() + " 缺额自动生成)");
        rp.setSourceDailyReportId(r.getId()); // 运行时关联真源
        rp.setSourceDocNo(r.getBillNo()); // 创建时单号快照，仅供展示
        rp.setMakerId(currentUser.requireEmployeeId());
        rp.setStatus((short) 0);
        planRepo.save(rp);
        planRepo.flush();

        ProductionPlanItem ri = new ProductionPlanItem();
        ri.setPlanId(rp.getId());
        ri.setBillNo(rp.getBillNo());
        ri.setBillDate(rp.getBillDate());
        ri.setLineNo(1);
        ri.setProductNo(productNoAllocator.allocate(rp.getId(), Set.of()));
        ri.setGoodsId((UUID) pi[4]);
        ri.setAllowedOverproductionRate(com.uten.imp.features.production.plan.ProductionOverproductionAllowance
                .resolve(em, (UUID) pi[4], null));
        ri.setColorId((UUID) pi[5]);
        ri.setUnitId((UUID) pi[6]);
        ri.setUnitRate((BigDecimal) pi[10]);
        ri.setQty(shortfall);
        ri.setOutboundDate(pi[7] == null ? null : NativeValueConverters.toLocalDate(pi[7]));
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
     * 对分段归属计划行对称镜像恢复 execution_segment_sales_allocations，
     * 并重算 production_execution_segments.planned_qty，保持总量等式。
     */
    private void restoreCap(UUID reportId,UUID planItemId, List<PlanOrderItemLink> lockedLinks) {
        List<Object[]> caps = NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT cap.id,cap.before_qty,cap.after_qty
                FROM production_daily_report_target_events cap
                WHERE cap.report_id=:report AND cap.plan_item_id=:item AND cap.event_type='CAP'
                  AND NOT EXISTS(SELECT 1 FROM production_daily_report_target_events back WHERE back.source_event_id=cap.id)
                """).setParameter("report",reportId).setParameter("item",planItemId));
        if(caps.isEmpty()) {
            Number ambiguous = (Number)em.createNativeQuery("""
                    SELECT COUNT(*) FROM production_plan_items item
                    WHERE item.id=:item AND COALESCE(item.capped_qty,0)>0
                      AND NOT EXISTS(SELECT 1 FROM production_daily_report_target_events cap WHERE cap.plan_item_id=item.id)
                    """).setParameter("item",planItemId).getSingleResult();
            if(ambiguous.longValue()>0)throw new ApiException(ErrorCode.CONFLICT,
                    "历史完结封顶缺少原日报数量事实，请先核对封顶来源，不能按当前余额猜测恢复");
            return; // This final report did not reduce the target; another report owns any cap.
        }
        Object[] source=caps.getFirst();
        BigDecimal cap=bd(source[1]).subtract(bd(source[2]));
        em.createNativeQuery("""
                INSERT INTO production_daily_report_target_events(
                    report_id,plan_item_id,event_type,before_qty,after_qty,source_event_id,created_by)
                VALUES(:report,:item,'RESTORE',:before,:after,:source,:actor)
                """).setParameter("report",reportId).setParameter("item",planItemId)
                .setParameter("before",source[2]).setParameter("after",source[1])
                .setParameter("source",source[0]).setParameter("actor",currentUser.requireId()).executeUpdate();
        int planUpdated = em.createNativeQuery("""
                UPDATE production_plan_items
                SET qty = COALESCE(qty,0) + :cap, capped_qty = NULL WHERE id = :id
                """).setParameter("cap", cap).setParameter("id", planItemId).executeUpdate();
        if (planUpdated != 1) {
            throw new ApiException(ErrorCode.CONFLICT, "封顶生产计划行不存在，禁止自动恢复");
        }
        // 分段归属计划行对称镜像恢复 allocations（GUC 窗口仅本方法放开 UPDATE）。
        Map<UUID, Long> allocationSegCount = lockedLinks.isEmpty()
                ? Map.of()
                : countLinkAllocationSegments(lockedLinks);
        boolean segmentAttributed = !allocationSegCount.isEmpty();
        if (segmentAttributed) {
            em.createNativeQuery("SELECT set_config('app.cap_segment_report_id',:id,true)").setParameter("id",reportId.toString()).getSingleResult();
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

    /** Failed physical output is produced output; a final report may only cancel work not produced. */
    private BigDecimal primaryReportedQuantity(UUID currentReport,UUID planItem,UUID link){
        var query=em.createNativeQuery("""
                SELECT coalesce(sum(item.qty),0) FROM production_daily_report_items item
                JOIN production_daily_reports report ON report.id=item.report_id
                LEFT JOIN execution_segment_sales_allocations allocation ON allocation.id=item.execution_segment_sales_allocation_id
                WHERE item.plan_item_id=:planItem AND NOT item.is_deleted AND NOT report.is_deleted
                    AND item.fqc_recovery_authorization_id IS NULL AND NOT item.is_actual_surplus
                    AND (report.status=1 OR report.id=:currentReport)
                """+(link==null?"":" AND allocation.plan_order_item_link_id=:link"))
                .setParameter("planItem",planItem).setParameter("currentReport",currentReport);
        if(link!=null)query.setParameter("link",link);
        return (BigDecimal)query.getSingleResult();
    }

    /** 本报工生成的成品入库单（id/status/bill_no）。 */
    @SuppressWarnings("unchecked")
    private List<Object[]> docsBySource(String docType, UUID sourceReportId) {
        return em.createNativeQuery("""
                SELECT id, status, bill_no FROM stock_documents
                WHERE doc_type = :t AND source_daily_report_id = :reportId
                  AND is_deleted = false
                ORDER BY id
                """).setParameter("t", docType)
                .setParameter("reportId", sourceReportId).getResultList();
    }

    /** 本报工生成的补产计划（id/status/bill_no）。 */
    @SuppressWarnings("unchecked")
    private List<Object[]> remakePlansOf(UUID sourceReportId) {
        return em.createNativeQuery("""
                SELECT id, status, bill_no FROM production_plans
                WHERE source_daily_report_id = :reportId AND is_deleted = false
                ORDER BY id
                """).setParameter("reportId", sourceReportId).getResultList();
    }

    /** 软删成品入库单（草稿）：主表 + 明细 + plan_draw_links 留痕。 */
    private void softDeleteStockDoc(UUID docId) {
        // the transaction-local exact document marker opens only the
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
                    SELECT COALESCE(bool_and(COALESCE(i.qty,0) + fn_plan_actual_surplus_qty(i.id,FALSE) - COALESCE(i.iqty,0) <= 0), true)
                    FROM production_plan_items i
                    WHERE i.plan_id = p.id AND COALESCE(i.is_deleted, false) = false
                ) WHERE p.id = :pid
                """).setParameter("pid", planId).executeUpdate();
    }

    /**
     * 各联动行对应的执行分段销售分摊段数（用于判定是否分段归属，以及多段防护）。
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

    private void lockCommand(
            String commandKind, UUID actorId, String idempotencyKey) {
        em.createNativeQuery("""
                SELECT pg_advisory_xact_lock(
                    hashtextextended(:lockKey, CAST(409 AS bigint)))
                """)
                .setParameter("lockKey",
                        "PRODUCTION-DAILY-REPORT-" + commandKind + ":"
                                + actorId + ":" + idempotencyKey)
                .getSingleResult();
    }

    /**
     * 按 (操作者, 幂等键) 查，故意不按命令种类过滤：唯一键就是这两列，
     * 一把键被用在另一种命令上必须当场说清楚，而不是让 INSERT 撞唯一键报裸错。
     */
    private ReportCommand findCommand(UUID actorId, String idempotencyKey) {
        List<Object[]> rows = NativeQueryResults.objectArrayRows(
                em.createNativeQuery("""
                        SELECT command_kind, request_hash, report_id
                        FROM production_daily_report_commands
                        WHERE actor_user_id = :actorId
                          AND idempotency_key = :idempotencyKey
                        """)
                        .setParameter("actorId", actorId)
                        .setParameter("idempotencyKey", idempotencyKey));
        if (rows.isEmpty()) return null;
        return new ReportCommand(
                Objects.toString(rows.getFirst()[0], ""),
                Objects.toString(rows.getFirst()[1], ""),
                (UUID) rows.getFirst()[2]);
    }

    private void recordCommand(
            String commandKind,
            UUID actorId,
            String idempotencyKey,
            String requestHash,
            UUID reportId) {
        // 列默认值只用来回填历史行，应用写入永远显式给种类，
        // 否则将来新加的命令会静默落成 CREATE。
        em.createNativeQuery("""
                INSERT INTO production_daily_report_commands(
                    id, actor_user_id, idempotency_key, request_hash,
                    report_id, created_by, command_kind)
                VALUES(
                    gen_random_uuid(), :actorId, :idempotencyKey, :requestHash,
                    :reportId, :actorId, :commandKind)
                """)
                .setParameter("commandKind", commandKind)
                .setParameter("actorId", actorId)
                .setParameter("idempotencyKey", idempotencyKey)
                .setParameter("requestHash", requestHash)
                .setParameter("reportId", reportId)
                .executeUpdate();
    }

    static String normalizeCreateIdempotencyKey(String raw) {
        return normalizeCommandIdempotencyKey(raw, "新建生产日报必须提供幂等键");
    }

    static String normalizeApproveIdempotencyKey(String raw) {
        return normalizeCommandIdempotencyKey(raw, "审核生产日报必须提供幂等键");
    }

    /** 长度与去空白口径由 production_daily_report_command_key_chk 在库里兜底，两种命令不得分叉。 */
    private static String normalizeCommandIdempotencyKey(
            String raw, String missingMessage) {
        if (raw == null || raw.isBlank()) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, missingMessage);
        }
        String normalized = raw.strip();
        if (normalized.length() < 8 || normalized.length() > 128) {
            throw new ApiException(
                    ErrorCode.VALIDATION_FAILED,
                    "生产日报幂等键长度必须为 8-128");
        }
        return normalized;
    }

    static void requireExpectedVersion(Long expectedVersion, long currentVersion) {
        if (expectedVersion == null || expectedVersion < 0) {
            throw new ApiException(
                    ErrorCode.VALIDATION_FAILED,
                    "编辑生产日报必须提供有效 expectedVersion");
        }
        if (expectedVersion.longValue() != currentVersion) {
            throw new ApiException(
                    ErrorCode.CONFLICT,
                    "生产日报已被其他用户修改，请刷新后重试");
        }
    }

    /**
     * New clients author the ordered list. A missing list means an old client,
     * so its single workerId is lifted into the same canonical representation.
     * An explicitly empty list clears both the relation and legacy header.
     */
    static List<UUID> normalizeWorkerIds(DailyReportSaveRequest request) {
        if (request == null) {
            throw new ApiException(
                    ErrorCode.VALIDATION_FAILED, "生产日报请求不能为空");
        }
        List<UUID> requested = request.getWorkerIds();
        if (requested == null) {
            return request.getWorkerId() == null
                    ? List.of() : List.of(request.getWorkerId());
        }
        if (requested.size() > 100) {
            throw new ApiException(
                    ErrorCode.VALIDATION_FAILED, "生产日报参与人员最多 100 人");
        }
        LinkedHashSet<UUID> normalized = new LinkedHashSet<>();
        for (UUID employeeId : requested) {
            if (employeeId == null) {
                throw new ApiException(
                        ErrorCode.VALIDATION_FAILED, "生产日报参与人员不能为空");
            }
            normalized.add(employeeId);
        }
        return List.copyOf(normalized);
    }

    /**
     * Canonical create payload. Server-owned bill numbers, retry metadata and
     * readable plan/order number snapshots are intentionally excluded.
     */
    /**
     * 审核当前没有可变载荷，指纹只绑定「审核哪张日报」。
     * 留成独立函数是为了以后审核加参数时有地方挂，
     * 也满足 production_daily_report_command_hash_chk 的 64 位十六进制形状。
     */
    static String approveRequestHash(UUID reportId) {
        return CanonicalFingerprint.sha256(List.of(
                "PRODUCTION-DAILY-REPORT-APPROVE-V1",
                "report:" + reportId));
    }

    static String createRequestHash(DailyReportSaveRequest request) {
        if (request == null) {
            throw new ApiException(
                    ErrorCode.VALIDATION_FAILED, "生产日报创建请求不能为空");
        }
        List<String> parts = new ArrayList<>();
        addCanonical(parts, "schema", "PRODUCTION-DAILY-REPORT-CREATE-V2");
        addCanonical(parts, "header.billDate", request.getBillDate());
        addCanonical(parts, "header.warehouseId", request.getWarehouseId());
        addCanonical(parts, "header.departmentId", request.getDepartmentId());
        addCanonical(parts, "header.workshopName", request.getWorkshopName());
        List<UUID> workerIds = normalizeWorkerIds(request);
        addCanonical(parts, "header.workerIds.count", workerIds.size());
        for (int index = 0; index < workerIds.size(); index++) {
            addCanonical(parts, "header.workerIds[" + index + "]",
                    workerIds.get(index));
        }
        addCanonical(parts, "header.supplierId", request.getSupplierId());
        addCanonical(parts, "header.remark", request.getRemark());
        addCanonical(parts, "header.sourceDocNo", request.getSourceDocNo());

        List<DailyReportItemLine> lines = request.getItems() == null
                ? List.of() : request.getItems();
        addCanonical(parts, "lines.count", lines.size());
        for (int index = 0; index < lines.size(); index++) {
            DailyReportItemLine line = lines.get(index);
            String path = "lines[" + index + "]";
            if (line == null) {
                addCanonical(parts, path, null);
                continue;
            }
            int effectiveLineNo =
                    line.getLineNo() == null ? index + 1 : line.getLineNo();
            addCanonical(parts, path + ".lineNo", effectiveLineNo);
            addCanonical(parts, path + ".goodsId", line.getGoodsId());
            addCanonical(parts, path + ".colorId", line.getColorId());
            addCanonical(parts, path + ".unitId", line.getUnitId());
            addCanonical(parts, path + ".unitRate", line.getUnitRate());
            addCanonical(parts, path + ".qty", line.getQty());
            addCanonical(parts, path + ".price", line.getPrice());
            addCanonical(parts, path + ".total", line.getTotal());
            addCanonical(parts, path + ".stotal", line.getStotal());
            addCanonical(parts, path + ".salesOrderItemId",
                    line.getSalesOrderItemId());
            addCanonical(parts, path + ".planItemId", line.getPlanItemId());
            addCanonical(parts, path + ".executionSegmentId",
                    line.getExecutionSegmentId());
            addCanonical(parts, path + ".executionSegmentSalesAllocationId",
                    line.getExecutionSegmentSalesAllocationId());
            if (line.getFqcRecoveryAuthorizationId() != null) {
                addCanonical(parts, path + ".fqcRecoveryAuthorizationId",
                        line.getFqcRecoveryAuthorizationId());
            }
            if(line.getSupplementProofId()!=null)addCanonical(parts,path+".supplementProofId",line.getSupplementProofId());
            addCanonical(parts, path + ".isFinal",
                    Boolean.TRUE.equals(line.getIsFinal()));
            addCanonical(parts, path + ".outboundNo", line.getOutboundNo());
            addCanonical(parts, path + ".outboundQty", line.getOutboundQty());
            addCanonical(parts, path + ".orderQty", line.getOrderQty());
            addCanonical(parts, path + ".stepLegacyId",
                    line.getStepLegacyId());
            addCanonical(parts, path + ".orderDate", line.getOrderDate());
            addCanonical(parts, path + ".boxes", line.getBoxes());
            addCanonical(parts, path + ".perBoxQty", line.getPerBoxQty());
            addCanonical(parts, path + ".weight", line.getWeight());
            addCanonical(parts, path + ".clientName", line.getClientName());
            addCanonical(parts, path + ".sourceDocNo", line.getSourceDocNo());
            addCanonical(parts, path + ".remark", line.getRemark());
            // Normalize absent and explicit WAREHOUSE to the same destination.
            // Only WORKSHOP has a meaningful receiving demand identity.
            if (line.getDestination() != null
                    && !"WAREHOUSE".equalsIgnoreCase(line.getDestination().strip())) {
                addCanonical(parts, path + ".destination",
                        line.getDestination().strip().toUpperCase(Locale.ROOT));
                addCanonical(parts, path + ".directTransferDemandId",
                        line.getDirectTransferDemandId());
            }
        }
        // V583：实耗与收尾退仓意愿必须进指纹。漏掉的话，「同一幂等键、只改了实际用料数字」
        // 的重发会被当成重放，静默返回旧单，用户改的数字一个都没存进去。
        //
        // An absent material list and an empty list represent the same payload.
        List<DailyReportMaterialUsageLine> materialLines =
                request.getMaterialLines() == null
                        ? List.of() : request.getMaterialLines();
        if (!materialLines.isEmpty()) {
            addCanonical(parts, "materialLines.count", materialLines.size());
            for (int index = 0; index < materialLines.size(); index++) {
                DailyReportMaterialUsageLine line = materialLines.get(index);
                String path = "materialLines[" + index + "]";
                if (line == null) {
                    addCanonical(parts, path, null);
                    continue;
                }
                addCanonical(parts, path + ".demandId", line.getDemandId());
                addCanonical(parts, path + ".qtyBase", line.getQtyBase());
            }
        }
        if (Boolean.TRUE.equals(request.getSurplusReturnRequested())) {
            addCanonical(parts, "header.surplusReturnRequested", true);
        }
        return CanonicalFingerprint.sha256(parts);
    }

    private static void addCanonical(
            List<String> parts, String path, Object value) {
        String canonical;
        if (value == null) {
            canonical = "NULL";
        } else if (value instanceof BigDecimal decimal) {
            canonical = "DECIMAL:"
                    + decimal.stripTrailingZeros().toPlainString();
        } else if (value instanceof String text) {
            canonical = "STRING:" + text;
        } else if (value instanceof UUID uuid) {
            canonical = "UUID:" + uuid;
        } else if (value instanceof LocalDate date) {
            canonical = "DATE:" + date;
        } else if (value instanceof Boolean bool) {
            canonical = "BOOLEAN:" + bool;
        } else if (value instanceof Number number) {
            canonical = "NUMBER:" + number;
        } else {
            canonical = "VALUE:" + value;
        }
        parts.add(path + "=" + canonical);
    }

    private void validateWorkerIds(List<UUID> workerIds) {
        if (workerIds.isEmpty()) return;
        List<UUID> lockOrder = List.copyOf(new TreeSet<>(workerIds));
        List<UUID> valid = NativeQueryResults.typedRows(
                em.createNativeQuery("""
                                WITH RECURSIVE production_department_tree AS (
                                    SELECT department.id
                                    FROM departments department
                                    WHERE department.code = 'DEPT_PROD'
                                      AND department.is_deleted = FALSE
                                    UNION ALL
                                    SELECT child.id
                                    FROM departments child
                                    JOIN production_department_tree parent
                                      ON parent.id = child.parent_id
                                    WHERE child.is_deleted = FALSE
                                )
                                SELECT employee.id
                                FROM employees employee
                                JOIN production_department_tree scope
                                  ON scope.id = employee.department_id
                                WHERE employee.id IN (:ids)
                                  AND employee.is_deleted = FALSE
                                  AND employee.status IN ('active', 'probation')
                                ORDER BY employee.id
                                FOR SHARE OF employee
                                """)
                        .setParameter("ids", lockOrder),
                UUID.class);
        if (valid.size() != lockOrder.size()) {
            throw new ApiException(
                    ErrorCode.VALIDATION_FAILED,
                    "生产日报参与人员必须是生产部组织树内未删除且在职或试用的员工");
        }
    }

    /**
     * 保存报工同页登记的「本次实际用料」(V583)。草稿态只落事实，不记账。
     *
     * <p>客户端只报需求 UUID 与基本量：计划、物料所属执行段都由服务端从需求行反查，
     * 并逐条验证该需求确实属于本单某个报工工单的合法用料来源
     * (分批生产时料常挂在前批原领料段上，所以不能简单比对报工行的执行段)。
     */
    private void syncMaterialUsages(
            ProductionDailyReport r, DailyReportSaveRequest req) {
        em.createNativeQuery("""
                        DELETE FROM production_daily_report_material_usages
                        WHERE report_id = :reportId
                        """)
                .setParameter("reportId", r.getId())
                .executeUpdate();
        List<DailyReportMaterialUsageLine> lines = req.getMaterialLines() == null
                ? List.of() : req.getMaterialLines();
        if (lines.isEmpty()) return;

        List<UUID> demandIds = new ArrayList<>();
        for (DailyReportMaterialUsageLine line : lines) {
            if (line == null || line.getDemandId() == null
                    || line.getQtyBase() == null) {
                throw new ApiException(
                        ErrorCode.VALIDATION_FAILED, "本次实际用料缺少物料需求或数量");
            }
            if (line.getQtyBase().signum() < 0) {
                throw new ApiException(
                        ErrorCode.VALIDATION_FAILED, "本次实际用料不能为负");
            }
            if (line.getQtyBase().stripTrailingZeros().scale() > 4) {
                throw new ApiException(
                        ErrorCode.VALIDATION_FAILED, "本次实际用料最多 4 位小数");
            }
            if (demandIds.contains(line.getDemandId())) {
                throw new ApiException(
                        ErrorCode.VALIDATION_FAILED,
                        "同一物料需求在本单出现多次，请合并为一行后再提交");
            }
            demandIds.add(line.getDemandId());
        }

        Map<UUID, UUID> demandPlans = new HashMap<>();
        Map<UUID, UUID> demandSegments = new HashMap<>();
        for (Object[] row : NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                        SELECT demand.id, demand.plan_id, demand.execution_segment_id
                        FROM production_material_demands demand
                        WHERE demand.id IN (:ids)
                          AND demand.is_deleted = FALSE
                          AND demand.status NOT IN ('RELEASED', 'REVERSED')
                          AND demand.execution_segment_id IS NOT NULL
                        """).setParameter("ids", demandIds))) {
            demandPlans.put((UUID) row[0], (UUID) row[1]);
            demandSegments.put((UUID) row[0], (UUID) row[2]);
        }
        if (demandPlans.size() != demandIds.size()) {
            throw new ApiException(
                    ErrorCode.CONFLICT,
                    "本次用料的物料需求已失效或不属于有效工单，请刷新报工页后重新核对");
        }

        // 本单每个报工工单的合法用料来源段(含沿用前批已领物料的原段)。
        Set<UUID> allowedSegments = new LinkedHashSet<>(NativeQueryResults.typedRows(
                em.createNativeQuery("""
                                SELECT DISTINCT source.segment_id
                                FROM production_daily_report_items item
                                CROSS JOIN LATERAL
                                    fn_production_material_usage_source_segments(
                                        item.execution_segment_id) source
                                WHERE item.report_id = :reportId
                                  AND item.execution_segment_id IS NOT NULL
                                """)
                        .setParameter("reportId", r.getId()), UUID.class));
        for (UUID demandId : demandIds) {
            if (!allowedSegments.contains(demandSegments.get(demandId))) {
                throw new ApiException(
                        ErrorCode.VALIDATION_FAILED,
                        "物料来源工单与本单报工工单不匹配，请重新选择报工来源");
            }
        }

        UUID actorId = currentUser.requireId();
        int lineNo = 1;
        for (DailyReportMaterialUsageLine line : lines) {
            em.createNativeQuery("""
                            INSERT INTO production_daily_report_material_usages(
                                report_id, line_no, plan_id, demand_id,
                                material_execution_segment_id, qty_base, created_by)
                            VALUES (:reportId, :lineNo, :planId, :demandId,
                                    :segmentId, :qty, :actorId)
                            """)
                    .setParameter("reportId", r.getId())
                    .setParameter("lineNo", lineNo++)
                    .setParameter("planId", demandPlans.get(line.getDemandId()))
                    .setParameter("demandId", line.getDemandId())
                    .setParameter("segmentId", demandSegments.get(line.getDemandId()))
                    .setParameter("qty", line.getQtyBase())
                    .setParameter("actorId", actorId)
                    .executeUpdate();
        }
    }

    /**
     * 审核同事务把本次实际用料记成材料消耗；车间在报工时勾了「余料退回仓库」的，
     * 结完实耗再按剩余可退量提交退仓申请。
     *
     * <p>顺序不可颠倒：退仓申请一提交就冻结领料过账额度，先冻后结会让实耗登记撞
     * 「超过准确原领料未耗用数量」。
     */
    private void settleMaterialUsageOnApprove(ProductionDailyReport r) {
        Map<List<UUID>, List<ProductionMaterialConsumptionWritePort.ConsumptionLine>>
                groups = new LinkedHashMap<>();
        for (Object[] row : NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                        SELECT plan_id, material_execution_segment_id, demand_id, qty_base
                        FROM production_daily_report_material_usages
                        WHERE report_id = :reportId
                        ORDER BY line_no
                        """).setParameter("reportId", r.getId()))) {
            groups.computeIfAbsent(
                            List.of((UUID) row[0], (UUID) row[1]),
                            ignored -> new ArrayList<>())
                    .add(new ProductionMaterialConsumptionWritePort.ConsumptionLine(
                            (UUID) row[2],
                            row[3] == null
                                    ? BigDecimal.ZERO
                                    : new BigDecimal(row[3].toString())));
        }
        if (groups.isEmpty()) return;

        String billNo = r.getBillNo() == null ? "" : r.getBillNo();
        for (var group : groups.entrySet()) {
            UUID planId = group.getKey().getFirst();
            UUID segmentId = group.getKey().get(1);
            materialConsumption.consumeForDailyReport(
                    planId, segmentId, r.getId(),
                    "DR-" + r.getId() + "-" + segmentId,
                    "生产日报 " + billNo + " 报工同步登记实际用料",
                    group.getValue());
        }
        if (!r.isSurplusReturnRequested()) return;
        for (var group : groups.entrySet()) {
            UUID planId = group.getKey().getFirst();
            UUID segmentId = group.getKey().get(1);
            materialConsumption.requestSurplusReturnForDailyReport(
                    planId, segmentId, r.getId(),
                    "DRRET-" + r.getId() + "-" + segmentId,
                    "生产日报 " + billNo + " 收尾余料退仓");
        }
    }

    /** 红冲同事务退掉本单审核时登记的实际用料；已提交的退仓申请不动(料确实已交回仓库)。 */
    private void reverseMaterialUsageOnReverse(ProductionDailyReport r) {
        List<UUID> planIds = NativeQueryResults.typedRows(em.createNativeQuery("""
                        SELECT DISTINCT plan_id
                        FROM production_daily_report_material_usages
                        WHERE report_id = :reportId
                        ORDER BY 1
                        """)
                .setParameter("reportId", r.getId()), UUID.class);
        String billNo = r.getBillNo() == null ? "" : r.getBillNo();
        for (UUID planId : planIds) {
            materialConsumption.reverseDailyReportConsumption(
                    planId, r.getId(), "DRREV-" + r.getId() + "-" + planId,
                    "生产日报 " + billNo + " 红冲，退回同单登记的实际用料");
        }
    }

    /** 日报已登记的本次实际用料(详情回看 / 编辑页回填)。 */
    private List<DailyReportMaterialUsageDto> materialUsages(UUID reportId) {
        return NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                        SELECT usage.id, usage.line_no, usage.plan_id, usage.demand_id,
                               usage.material_execution_segment_id, segment.segment_code,
                               demand.goods_id, goods.code, goods.name, color.name,
                               unit.name, usage.qty_base
                        FROM production_daily_report_material_usages usage
                        JOIN production_material_demands demand
                          ON demand.id = usage.demand_id
                        LEFT JOIN production_execution_segments segment
                          ON segment.id = usage.material_execution_segment_id
                        LEFT JOIN goods ON goods.id = demand.goods_id
                        LEFT JOIN colors color ON color.id = demand.color_id
                        LEFT JOIN units unit ON unit.id = demand.unit_id
                        WHERE usage.report_id = :reportId
                        ORDER BY usage.line_no
                        """).setParameter("reportId", reportId))
                .stream()
                .map(row -> new DailyReportMaterialUsageDto(
                        (UUID) row[0],
                        row[1] == null ? null : ((Number) row[1]).intValue(),
                        (UUID) row[2], (UUID) row[3], (UUID) row[4], (String) row[5],
                        (UUID) row[6], (String) row[7], (String) row[8],
                        (String) row[9], (String) row[10],
                        row[11] == null
                                ? BigDecimal.ZERO
                                : new BigDecimal(row[11].toString())))
                .toList();
    }

    private void syncReportWorkers(UUID reportId, List<UUID> workerIds) {
        em.createNativeQuery("""
                        DELETE FROM production_daily_report_workers
                        WHERE report_id = :reportId
                        """)
                .setParameter("reportId", reportId)
                .executeUpdate();
        for (int index = 0; index < workerIds.size(); index++) {
            em.createNativeQuery("""
                            INSERT INTO production_daily_report_workers(
                                report_id, employee_id, sort_order)
                            VALUES (:reportId, :employeeId, :sortOrder)
                            """)
                    .setParameter("reportId", reportId)
                    .setParameter("employeeId", workerIds.get(index))
                    .setParameter("sortOrder", index + 1)
                    .executeUpdate();
        }
    }

    private List<UUID> reportWorkerIds(
            UUID reportId, UUID primaryWorkerId) {
        List<UUID> workerIds = NativeQueryResults.typedRows(
                em.createNativeQuery("""
                                SELECT employee_id
                                FROM production_daily_report_workers
                                WHERE report_id = :reportId
                                ORDER BY sort_order, id
                                """)
                        .setParameter("reportId", reportId),
                UUID.class);
        if (workerIds.isEmpty() && primaryWorkerId != null) {
            throw new ApiException(ErrorCode.CONFLICT,
                    "生产日报参与人员记录不完整，请联系管理员核对原始人员记录");
        }
        return workerIds;
    }

    private void applyHeader(
            DailyReportSaveRequest req,
            ProductionDailyReport r,
            List<UUID> workerIds) {
        // 单据号系统自动生成（服务端权威）：仅新建（billNo 空）时取号；更新保留既有号，忽略客户端值。
        if (r.getBillNo() == null || r.getBillNo().isBlank()) {
            r.setBillNo(docNumberService.nextNumber(DocNumberPrefix.PRODUCTION_DAILY_REPORT));
        }
        r.setBillDate(req.getBillDate());
        // V476 运营红线：报工入仓必须落到具体叶子仓。
        if (warehouseScopes != null) {
            warehouseScopes.requireLeafWarehouse(req.getWarehouseId(), "仓库");
        }
        r.setWarehouseId(req.getWarehouseId());
        r.setDepartmentId(req.getDepartmentId());
        r.setWorkshopName(req.getWorkshopName());
        r.setWorkerId(workerIds.isEmpty() ? null : workerIds.getFirst());
        r.setSupplierId(req.getSupplierId());
        r.setRemark(req.getRemark());
        r.setSourceDocNo(req.getSourceDocNo());
        r.setSurplusReturnRequested(
                Boolean.TRUE.equals(req.getSurplusReturnRequested()));
    }

    private List<DailyReportItemDto> saveItems(ProductionDailyReport r, List<DailyReportItemLine> lines) {
        if (lines.stream().anyMatch(line -> line != null && (line.getPrice() != null
                || line.getTotal() != null || line.getStotal() != null))) {
            throw new ApiException(
                    ErrorCode.VALIDATION_FAILED,
                    "生产日报只记录数量事实；客户端单价/金额不是计件工资依据，已停止写入");
        }
        lines = outputAllocation.split(r.getId(), outputSupplements.expand(r.getId(),lines));
        outputAllocation.requireAllowance(r.getId(),lines);
        executionSegments.validateDraft(r.getId(), r.getDepartmentId(), lines);
        canonicalizeSourceSnapshots(lines);
        List<DailyReportItemDto> out = new ArrayList<>(lines.size());
        int auto = 1;
        for (DailyReportItemLine l : lines) {
            ProductionDailyReportItem it = new ProductionDailyReportItem();
            it.setReportId(r.getId());
            it.setOutputBatchId(l.getOutputBatchId());
            it.setOutputBatchQty(l.getOutputBatchQty());
            it.setPublicOutput(l.isPublicOutput());
            it.setActualSurplus(l.isActualSurplus());
            it.setSupplementProofId(l.getSupplementProofId());
            it.setBillNo(r.getBillNo());
            it.setBillDate(r.getBillDate());
            it.setLineNo(l.getLineNo() != null ? l.getLineNo() : auto);
            it.setGoodsId(l.getGoodsId());
            it.setColorId(l.getColorId());
            it.setUnitId(l.getUnitId());
            it.setUnitRate(l.getUnitRate());
            it.setQty(l.getQty());
            it.setSalesOrderItemId(l.getSalesOrderItemId());
            it.setSalesOrderNo(l.getSalesOrderNo());
            it.setPlanItemId(l.getPlanItemId());
            it.setExecutionSegmentId(l.getExecutionSegmentId());
            it.setExecutionSegmentSalesAllocationId(
                    l.getExecutionSegmentSalesAllocationId());
            it.setFqcRecoveryAuthorizationId(
                    l.getFqcRecoveryAuthorizationId());
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
            // V584/V585 产出去向。不传按送仓库处理，老客户端行为不变；
            // 选了转送车间就必须带接收需求，归属与同车间由 directTransfer 再逐条校验。
            String destination = l.getDestination() == null
                    ? "WAREHOUSE" : l.getDestination().strip().toUpperCase(Locale.ROOT);
            if (!List.of("WAREHOUSE", "WORKSHOP").contains(destination)) {
                throw new ApiException(
                        ErrorCode.VALIDATION_FAILED, "报工明细的产出去向无效");
            }
            it.setDestination(destination);
            it.setDirectTransferDemandId(
                    "WORKSHOP".equals(destination) ? l.getDirectTransferDemandId() : null);
            if ("WORKSHOP".equals(destination) && it.getDirectTransferDemandId() == null) {
                throw new ApiException(
                        ErrorCode.VALIDATION_FAILED,
                        "转送车间的报工行必须选择接收本批产出的上层工单");
            }
            itemRepo.save(it);
            out.add(toItemDto(it));
            auto++;
        }
        return out;
    }

    /**
     * Derive all readable source numbers from UUIDs. The request may not author
     * or retain an internal number without the corresponding UUID relation.
     */
    private void canonicalizeSourceSnapshots(List<DailyReportItemLine> lines) {
        List<UUID> planItemIds = lines.stream()
                .map(DailyReportItemLine::getPlanItemId)
                .filter(Objects::nonNull)
                .distinct()
                .toList();
        Map<UUID, String> planNos = new HashMap<>();
        if (!planItemIds.isEmpty()) {
            List<Object[]> rows = NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                    SELECT item.id, plan.bill_no
                    FROM production_plan_items item
                    JOIN production_plans plan ON plan.id = item.plan_id
                    WHERE item.id IN (:ids)
                      AND item.is_deleted = FALSE
                      AND plan.is_deleted = FALSE
                    """).setParameter("ids", planItemIds));
            for (Object[] row : rows) {
                planNos.put((UUID) row[0], (String) row[1]);
            }
            if (planNos.size() != planItemIds.size()) {
                throw new ApiException(
                        ErrorCode.VALIDATION_FAILED,
                        "报工来源计划行不存在或已删除");
            }
        }

        List<UUID> orderItemIds = lines.stream()
                .map(DailyReportItemLine::getSalesOrderItemId)
                .filter(Objects::nonNull)
                .distinct()
                .toList();
        Map<UUID, String> orderNos = new HashMap<>();
        if (!orderItemIds.isEmpty()) {
            List<Object[]> rows = NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                    SELECT item.id, sales_order.bill_no
                    FROM sales_order_items item
                    JOIN sales_orders sales_order ON sales_order.id = item.order_id
                    WHERE item.id IN (:ids)
                      AND item.is_deleted = FALSE
                      AND sales_order.is_deleted = FALSE
                    """).setParameter("ids", orderItemIds));
            for (Object[] row : rows) {
                orderNos.put((UUID) row[0], (String) row[1]);
            }
            if (orderNos.size() != orderItemIds.size()) {
                throw new ApiException(
                        ErrorCode.VALIDATION_FAILED,
                        "报工来源销售订单行不存在或已删除");
            }
        }

        for (DailyReportItemLine line : lines) {
            if (line.getPlanItemId() == null) {
                if (hasText(line.getPlanNo())) {
                    throw new ApiException(
                            ErrorCode.VALIDATION_FAILED,
                            "计划号不能单独建立关联，请选择来源子任务");
                }
                line.setPlanNo(null);
            } else {
                line.setPlanNo(planNos.get(line.getPlanItemId()));
            }
            if (line.getSalesOrderItemId() == null) {
                if (hasText(line.getSalesOrderNo())) {
                    throw new ApiException(
                            ErrorCode.VALIDATION_FAILED,
                            "销售订单号不能单独建立关联，请选择来源子任务");
                }
                line.setSalesOrderNo(null);
            } else {
                line.setSalesOrderNo(orderNos.get(line.getSalesOrderItemId()));
            }
        }
    }

    private DailyReportListItem toList(ProductionDailyReport r) {
        return new DailyReportListItem(r.getId(), r.getBillNo(), r.getBillDate(), r.getWarehouseId(),
                r.getDepartmentId(), r.getWorkshopName(), r.getWorkerId(), r.getSupplierId(),
                r.getStatus(), r.isClosed(), r.isCanceled(), r.getLegacyId());
    }

    /** 保存路径用：返回值不进响应，身份名称留空，避免多一次字典查询。 */
    private DailyReportItemDto toItemDto(ProductionDailyReportItem it) {
        return toItemDto(it, Map.of(), Map.of());
    }

    private DailyReportItemDto toItemDto(
            ProductionDailyReportItem it, Map<UUID, String> directTransferLabels,
            Map<UUID, String[]> goodsIdentities) {
        String[] identity = goodsIdentities.get(it.getId());
        return new DailyReportItemDto(it.getId(), it.getLineNo(), it.getGoodsId(), it.getColorId(),
                it.getUnitId(), it.getUnitRate(), it.getQty(), it.getPrice(), it.getTotal(), it.getStotal(),
                it.getSalesOrderItemId(), it.getSalesOrderNo(), it.getPlanItemId(),
                it.getExecutionSegmentId(),
                it.getExecutionSegmentSalesAllocationId(),
                it.getFqcRecoveryAuthorizationId(), it.getPlanNo(),
                it.getOutboundNo(), it.getOutboundQty(), it.getOrderQty(), it.getStepLegacyId(),
                it.getOrderDate(), it.getBoxes(), it.getPerBoxQty(), it.getWeight(),
                it.getClientName(), it.getSourceDocNo(), it.getRemark(), it.isFinal(),
                it.getDestination(), it.getDirectTransferDemandId(),
                directTransferLabels.get(it.getId()), null, null,
                identity == null ? null : identity[0],
                identity == null ? null : identity[1],
                identity == null ? null : identity[2],
                identity == null ? null : identity[3],
                it.getOutputBatchId(), it.getOutputBatchQty(), it.isPublicOutput(), it.isActualSurplus(),
                it.getExecutionSegmentId()!=null && it.getFqcRecoveryAuthorizationId()==null,
                it.getSupplementProofId(),null,null,null,null,null,null,null,null);
    }

    /** 直送行的接收方(父件产品名 编号 · 工单号)，详情页「转给工单」列用；非直送行不出现。 */
    private Map<UUID, String> directTransferTargetLabels(List<ProductionDailyReportItem> items) {
        List<UUID> demandIds = items.stream()
                .map(ProductionDailyReportItem::getDirectTransferDemandId)
                .filter(Objects::nonNull)
                .distinct()
                .toList();
        if (demandIds.isEmpty()) return Map.of();
        Map<UUID, String> byDemand = new HashMap<>();
        for (Object[] row : NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                        SELECT demand.id, goods.name, goods.code, receiving.segment_code
                        FROM production_material_demands demand
                        JOIN production_execution_segments receiving
                          ON receiving.id = demand.execution_segment_id
                        LEFT JOIN goods ON goods.id = receiving.product_goods_id
                        WHERE demand.id IN (:ids)
                        """).setParameter("ids", demandIds))) {
            String product = (Objects.toString(row[1], "") + " " + Objects.toString(row[2], "")).strip();
            String segment = Objects.toString(row[3], "").strip();
            byDemand.put((UUID) row[0], product.isEmpty() ? segment
                    : segment.isEmpty() ? product : product + " · " + segment);
        }
        Map<UUID, String> result = new HashMap<>();
        for (ProductionDailyReportItem item : items) {
            if (item.getDirectTransferDemandId() == null) continue;
            String label = byDemand.get(item.getDirectTransferDemandId());
            if (label != null) result.put(item.getId(), label);
        }
        return result;
    }

    /**
     * 持续生产：最后一次报工审核后，尚未投入或预留的物料需求就此释放——
     * 计划已按实际完工封顶，不会再有人送料，也不该让父件因为「需求没齐」永远结不了案。
     * 仓库与直送使用相同口径，只释放未预留的余量，已投入的料不变；需求状态随之刷新。
     */
    private void releaseContinuousMaterialRemainderOnFinal(UUID reportId, List<ProductionDailyReportItem> items) {
        List<UUID> segmentIds = items.stream()
                .filter(ProductionDailyReportItem::isFinal)
                .filter(item -> item.getFqcRecoveryAuthorizationId()==null)
                .map(ProductionDailyReportItem::getExecutionSegmentId)
                .filter(Objects::nonNull).distinct().sorted().toList();
        if (segmentIds.isEmpty() || fulfillmentLedger == null) return;
        List<UUID> released = NativeQueryResults.typedRows(em.createNativeQuery("""
                INSERT INTO production_daily_report_material_release_events(
                    report_id,demand_id,event_type,qty_base,created_by)
                SELECT :report,demand.id,'RELEASE',
                       demand.required_qty-demand.released_qty-fn_daily_report_open_material_commitment(demand.id),:actor
                FROM production_material_demands demand
                JOIN production_execution_segments segment ON segment.id=demand.execution_segment_id
                WHERE segment.id IN (:segments) AND segment.continuous_supply
                  AND NOT demand.is_deleted AND demand.status NOT IN ('RELEASED','REVERSED')
                  AND demand.required_qty-demand.released_qty>fn_daily_report_open_material_commitment(demand.id)
                ORDER BY demand.id
                RETURNING demand_id
                """).setParameter("report",reportId).setParameter("segments",segmentIds)
                .setParameter("actor",currentUser.requireId()), UUID.class);
        if (!released.isEmpty()) fulfillmentLedger.refreshDemandStatuses(released);
    }

    private void restoreContinuousMaterialRemainder(UUID reportId, List<ProductionDailyReportItem> items) {
        List<UUID> segmentIds=items.stream().filter(ProductionDailyReportItem::isFinal)
                .filter(item -> item.getFqcRecoveryAuthorizationId()==null)
                .map(ProductionDailyReportItem::getExecutionSegmentId)
                .filter(Objects::nonNull).distinct().sorted().toList();
        if(segmentIds.isEmpty() || fulfillmentLedger==null)return;
        Number ambiguous=(Number)em.createNativeQuery("""
                SELECT COUNT(*) FROM production_material_demands demand
                JOIN production_execution_segments segment ON segment.id=demand.execution_segment_id
                WHERE segment.id IN (:segments) AND segment.continuous_supply AND NOT demand.is_deleted
                  AND demand.released_qty>0 AND NOT EXISTS(
                      SELECT 1 FROM production_daily_report_material_release_events event
                      WHERE event.demand_id=demand.id)
                """).setParameter("segments",segmentIds).getSingleResult();
        if(ambiguous.longValue()>0)throw new ApiException(ErrorCode.CONFLICT,
                "历史完结释放缺少原日报物料事实，请先核对释放来源，不能按当前余额猜测恢复");
        List<UUID> restored=NativeQueryResults.typedRows(em.createNativeQuery("""
                INSERT INTO production_daily_report_material_release_events(
                    report_id,demand_id,event_type,qty_base,source_event_id,created_by)
                SELECT source.report_id,source.demand_id,'RESTORE',source.qty_base,source.id,:actor
                FROM production_daily_report_material_release_events source
                WHERE source.report_id=:report AND source.event_type='RELEASE'
                  AND NOT EXISTS(SELECT 1 FROM production_daily_report_material_release_events back
                                 WHERE back.source_event_id=source.id)
                ORDER BY source.demand_id RETURNING demand_id
                """).setParameter("report",reportId).setParameter("actor",currentUser.requireId()), UUID.class);
        if(!restored.isEmpty())fulfillmentLedger.refreshDemandStatuses(restored);
    }

    /**
     * 详情页可执行动作(permissions-15 规定：按钮只按服务端下发显隐)。审核要同时满足：
     * 草稿、有明细、持日报审核码且在审核对象范围内；含「转下一道工序」(车间直送)的行
     * 还必须持车间直送审核码、且是每个出料工单所属车间的成员——与审核写路径
     * {@code executeForApprovedReport} 同一口径，不会再出现点了才报「没有权限」的按钮。
     */
    private List<String> allowedActions(ProductionDailyReport r, List<ProductionDailyReportItem> rows) {
        List<String> actions = new ArrayList<>();
        boolean draft = r.getStatus() != null && r.getStatus() == STATUS_DRAFT;
        if (draft
                && !rows.isEmpty()
                && access.hasAuthority("production_daily_report:approve")
                && access.canWrite(r.getMakerId(), "production_daily_report:approve")
                && directTransfer.canApproveDirectTransfers(rows)) {
            actions.add("APPROVE");
        }
        return List.copyOf(actions);
    }

    private DailyReportDetail toDetail(ProductionDailyReport r, List<DailyReportItemDto> items,
                                       List<String> allowedActions) {
        List<UUID> workerIds = reportWorkerIds(r.getId(), r.getWorkerId());
        return new DailyReportDetail(r.getId(), r.getLegacyId(), r.getBillNo(), r.getBillDate(),
                r.getWarehouseId(), r.getDepartmentId(), r.getWorkshopName(), r.getWorkerId(),
                workerIds, r.getSupplierId(),
                r.getMakerId(), r.getApproverId(), r.getMakerLegacyId(), r.getApproverLegacyId(), r.getRemark(),
                r.getStatus(), r.isClosed(), r.isCanceled(), r.getSourceDocNo(), items,
                materialUsages(r.getId()), r.isSurplusReturnRequested(),
                nameResolver.nameOf(r.getMakerId()), r.getCreatedAt(), r.getRowVersion(),
                // 车间与参与人员同样随单下发，页面不再查部门字典、也不再逐个调员工档案接口
                // (那个接口要 employee:view 且会落人事查看审计)。
                departmentNameResolver.nameOf(r.getDepartmentId()),
                workerIds.stream().map(nameResolver::nameOf).toList(),
                allowedActions);
    }

    private ProductionDailyReport requireReport(UUID id) {
        return reportRepo.findById(id).filter(r -> !r.isDeleted())
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "生产日报单不存在"));
    }

    /** 单次数据库往返即取得写锁，避免普通读取与随后加锁之间的陈旧状态窗口。 */
    private ProductionDailyReport requireReportForUpdate(UUID id) {
        ProductionDailyReport report = em.find(
                ProductionDailyReport.class, id, jakarta.persistence.LockModeType.PESSIMISTIC_WRITE);
        if (report != null) em.refresh(report, jakarta.persistence.LockModeType.PESSIMISTIC_WRITE);
        if (report == null || report.isDeleted()) {
            throw new ApiException(ErrorCode.NOT_FOUND, "生产日报单不存在");
        }
        return report;
    }

    /** 日报命令账本的一行：同一把 (操作者, 幂等键) 永久绑定一种命令和一张日报。 */
    private record ReportCommand(
            String commandKind, String requestHash, UUID reportId) {
    }
}
