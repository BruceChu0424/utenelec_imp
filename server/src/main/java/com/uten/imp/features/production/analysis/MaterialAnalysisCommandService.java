package com.uten.imp.features.production.analysis;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.ProductionSubcontractRequestPort;
import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.util.NativeQueryResults;
import com.uten.imp.common.validation.RequestLimits;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.production.ProductionDocumentAccessPolicy;
import com.uten.imp.features.production.fulfillment.PlanningPackageFingerprint;
import com.uten.imp.features.production.mrp.ExecutionSegmentPreview;
import com.uten.imp.features.production.mrp.GeneratePlanningPackageRequest;
import com.uten.imp.features.production.mrp.MrpGenerateResult;
import com.uten.imp.features.production.mrp.PlanningPackageResult;
import com.uten.imp.features.production.mrp.PlanningPreviewResult;
import com.uten.imp.features.production.mrp.ProductionPlanningDraftService;
import com.uten.imp.features.production.mrp.ProductionPlanningDraftView;
import com.uten.imp.features.production.mrp.ProductionPlanningPackageService;
import com.uten.imp.features.production.plan.ProductionPlan;
import com.uten.imp.features.production.plan.ProductionPlanService;
import com.uten.imp.features.production.plan.dto.PlanDetail;
import com.uten.imp.features.production.plan.dto.PlanItemLine;
import com.uten.imp.features.production.plan.dto.PlanSaveRequest;
import com.uten.imp.features.purchase.request.ProductionPurchaseRequestFacade;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.math.RoundingMode;
import java.time.LocalDate;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.HashMap;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.Set;
import java.util.UUID;
import java.util.stream.Collectors;

import static com.uten.imp.features.production.analysis.MaterialAnalysisContracts.*;

/** Atomic write side for downstream pre-plan actions and formal plan creation. */
@Service
@RequiredArgsConstructor
public class MaterialAnalysisCommandService {

    private static final String OP_NOTIFY = "NOTIFY";
    private static final String OP_GENERATE = "GENERATE_PLAN";
    private static final String OP_CANCEL_ANALYSIS = "CANCEL_ANALYSIS";
    private static final String OP_CANCEL_ACTION = "CANCEL_ACTION";

    private final EntityManager em;
    private final MaterialAnalysisService analysisService;
    private final ProductionDocumentAccessPolicy access;
    private final ProductionPurchaseRequestFacade purchaseRequests;
    private final ProductionSubcontractRequestPort subcontractRequests;
    private final ProductionPlanService planService;
    private final ProductionPlanningPackageService planningPackages;
    private final ProductionPlanningDraftService planningDrafts;
    private final SecurityContextCurrentUser currentUser;
    private final TxSessionVars tx;
    private final ObjectMapper objectMapper;

    /**
     * 下达备料任务（采购/委外/自制）：先重算分配（库存与到货变化不触动分析头），再按操作组只补建「超过既有未结任务量」的增量，
     * 生成代际与外部单据；幂等键命中时重放既有结果。
     */
    @Transactional
    public AnalysisView notifySupply(UUID analysisId, NotifyRequest request) {
        tx.bind();
        MaterialAnalysisService.AnalysisHeader header = analysisService.lockHeader(analysisId);
        requireWritable(header, "只能下达本人负责的物料分析备料任务");
        String requestHash = notifyHash(analysisId, request);
        CommandReplay replay = commandReplay(analysisId, OP_NOTIFY,
                request.idempotencyKey(), requestHash);
        if (replay != null) {
            return analysisService.detailInternal(analysisId, false);
        }
        analysisService.requireCurrent(header, request.version(), request.fingerprint());
        // Stock, receipts and downstream document lifecycle can change without touching the
        // analysis header. Rebuild the authoritative allocation before calculating a delta.
        analysisService.refreshLocked(analysisId);
        AnalysisView view = analysisService.detailInternal(analysisId, false);
        List<ActionGroup> groups = selectedGroups(view, request);

        List<ActionDraft> created = new ArrayList<>();
        for (ActionGroup group : groups) {
            BigDecimal existingOpen = activeOpenActionQty(
                    analysisId, group);
            BigDecimal delta = group.requiredQty().subtract(existingOpen).max(BigDecimal.ZERO)
                    .setScale(4, RoundingMode.CEILING);
            if (delta.signum() == 0) {
                continue;
            }
            ActionSequence sequence = nextActionSequence(
                    analysisId, group.groupKey(), group.route());
            UUID actionId = UUID.randomUUID();
            String businessKey = PlanningPackageFingerprint.sha256(List.of(
                    "PREPLAN-SUPPLY-ACTION-V1", analysisId.toString(),
                    group.groupKey(), group.route(), Integer.toString(sequence.generation())));
            String actionIdempotency = "NOTIFY-" + PlanningPackageFingerprint.sha256(List.of(
                    request.idempotencyKey(), group.groupKey(), Integer.toString(sequence.generation())));
            em.createNativeQuery("""
                    INSERT INTO preplan_supply_actions (
                        id, analysis_id, warehouse_id, goods_id, color_id, unit_id,
                        need_date, route, requested_qty, status,
                        idempotency_key, action_group_key, request_business_key,
                        generation, predecessor_action_id, request_hash,
                        created_by
                    ) VALUES (
                        :id, :analysisId, :warehouseId, :goodsId, :colorId, :unitId,
                        :needDate, :route, :qty, 'OPEN',
                        :idempotencyKey, :actionGroupKey, :businessKey,
                        :generation, :predecessorId, :requestHash,
                        :actorId
                    )
                    """)
                    .setParameter("id", actionId)
                    .setParameter("analysisId", analysisId)
                    .setParameter("warehouseId", view.warehouseId())
                    .setParameter("goodsId", group.dimension().goodsId())
                    .setParameter("colorId", group.dimension().colorId())
                    .setParameter("unitId", group.dimension().unitId())
                    .setParameter("needDate", group.needDate())
                    .setParameter("route", group.route())
                    .setParameter("qty", delta)
                    .setParameter("idempotencyKey", actionIdempotency)
                    .setParameter("actionGroupKey", group.groupKey())
                    .setParameter("businessKey", businessKey)
                    .setParameter("generation", sequence.generation())
                    .setParameter("predecessorId", sequence.predecessorId())
                    .setParameter("requestHash", requestHash)
                    .setParameter("actorId", currentUser.requireId())
                    .executeUpdate();
            allocateAction(actionId, analysisId, group.materials(), delta);
            created.add(new ActionDraft(actionId, group, delta));
        }

        for (ActionDraft action : created) {
            createExternalDocument(analysisId, action);
        }
        if (!created.isEmpty()) {
            analysisService.refreshLocked(analysisId);
        }
        recordCommand(analysisId, OP_NOTIFY, request.idempotencyKey(), requestHash,
                Map.of("actionIds", created.stream().map(ActionDraft::actionId).toList()));
        return analysisService.detailInternal(analysisId, false);
    }

    /**
     * 由物料分析生成正式生产计划：临时路线须先经 saveRoutes 落库；联合预览指纹须与冻结结果一致且全部齐套方可生成；
     * approveNow 需独立的生产计划审核权限。幂等键命中时回放已生成的计划标识。
     */
    @Transactional
    public GenerateResult generatePlan(UUID analysisId, GeneratePlanRequest request) {
        tx.bind();
        MaterialAnalysisService.AnalysisHeader header = analysisService.lockHeader(analysisId);
        requireWritable(header, "只能从本人负责的物料分析生成生产计划");
        String requestHash = generateHash(analysisId, request);
        CommandReplay replay = commandReplay(analysisId, OP_GENERATE,
                request.idempotencyKey(), requestHash);
        if (replay != null) {
            List<UUID> planIds = replayIds(replay.payload(), "planIds");
            return new GenerateResult(analysisService.detailInternal(analysisId, false), true,
                    planIds.stream().map(this::generatedPlan).toList());
        }
        analysisService.requireCurrent(header, request.version(), request.fingerprint());
        if (request.routes() != null && !request.routes().isEmpty()) {
            throw validation("生成前必须先保存路线，generate-plan 不接受临时路线");
        }
        PlanPreview preview = analysisService.buildPlanPreviewLocked(
                analysisId, request.warehouseId(), request.items(), request.routes(),
                request.bomOverrides());
        if (!preview.previewFingerprint().equalsIgnoreCase(request.previewFingerprint())) {
            throw conflict("联合预览已过期，请重新计算可生成数量");
        }
        if (!preview.allReady() || preview.items().stream().anyMatch(item -> !item.canGenerate())) {
            throw conflict("所选批次数量尚未完整齐套，或 BOM/生产策略已阻断，不能生成正式计划");
        }
        if (request.approveNow() && !access.hasAuthority("production_plan:approve")) {
            throw new ApiException(ErrorCode.FORBIDDEN, "生成并审核需要独立的生产计划审核权限");
        }

        AnalysisView view = analysisService.detailInternal(analysisId, false);
        Map<UUID, ProductView> products = view.products().stream()
                .collect(Collectors.toMap(ProductView::analysisLineId, value -> value));
        Map<UUID, String> overrides = overrides(request.bomOverrides());
        List<GeneratedPlan> generated = new ArrayList<>();
        for (PlanQuantity quantity : request.items()) {
            ProductView product = products.get(quantity.analysisLineId());
            if (product == null) {
                throw validation("待生成计划产品不属于当前分析");
            }
            validatePlanSchedule(quantity, request);
            PlanDetail plan = createDraftPlan(analysisId, product, quantity, request,
                    overrides.get(product.analysisLineId()));
            ProductionPlanningDraftView draft = savePlanningDraft(
                    analysisId, product, plan, quantity, request);
            PlanningPackageResult applied = null;
            if (request.approveNow()) {
                planService.approve(plan.getId());
                applied = planningPackages.currentResult(plan.getId()).orElseThrow(() ->
                        conflict("生产计划已审核但正式计划包未生成，事务已回滚"));
            }
            generated.add(toGenerated(plan, draft, applied));
        }
        MaterialAnalysisService.AnalysisHeader postPlanHeader =
                analysisService.lockHeader(analysisId);
        if ("ACTIVE".equals(postPlanHeader.status())
                || "PARTIALLY_PLANNED".equals(postPlanHeader.status())) {
            analysisService.refreshLocked(analysisId);
        }
        recordCommand(analysisId, OP_GENERATE, request.idempotencyKey(), requestHash,
                Map.of("planIds", generated.stream().map(GeneratedPlan::planId).toList()));
        return new GenerateResult(analysisService.detailInternal(analysisId, false), false,
                List.copyOf(generated));
    }

    @Transactional
    public AnalysisView cancelAction(
            UUID analysisId, UUID actionId, CancelRequest request) {
        tx.bind();
        MaterialAnalysisService.AnalysisHeader header = analysisService.lockHeader(analysisId);
        requireWritable(header, "只能撤回本人负责的物料分析备料任务");
        String hash = PlanningPackageFingerprint.sha256(List.of(
                OP_CANCEL_ACTION, analysisId.toString(), actionId.toString(),
                Long.toString(request.version()), request.fingerprint(), request.reason()));
        CommandReplay replay = commandReplay(analysisId, OP_CANCEL_ACTION,
                request.idempotencyKey(), hash);
        if (replay != null) {
            return analysisService.detailInternal(analysisId, false);
        }
        analysisService.requireCurrent(header, request.version(), request.fingerprint());
        cancelActionLocked(analysisId, actionId, request.reason());
        analysisService.refreshLocked(analysisId);
        recordCommand(analysisId, OP_CANCEL_ACTION, request.idempotencyKey(), hash,
                Map.of("actionIds", List.of(actionId)));
        return analysisService.detailInternal(analysisId, false);
    }

    @Transactional
    public AnalysisView cancelAnalysis(UUID analysisId, CancelRequest request) {
        tx.bind();
        MaterialAnalysisService.AnalysisHeader header = analysisService.lockHeader(analysisId);
        requireWritable(header, "只能取消本人负责的物料分析");
        String hash = PlanningPackageFingerprint.sha256(List.of(
                OP_CANCEL_ANALYSIS, analysisId.toString(), Long.toString(request.version()),
                request.fingerprint(), request.reason()));
        CommandReplay replay = commandReplay(analysisId, OP_CANCEL_ANALYSIS,
                request.idempotencyKey(), hash);
        if (replay != null) {
            return analysisService.detailInternal(analysisId, false);
        }
        analysisService.requireCurrent(header, request.version(), request.fingerprint());
        Number planned = (Number) em.createNativeQuery("""
                SELECT COUNT(*) FROM production_material_analysis_plan_links
                WHERE analysis_id = :id
                  AND allocation_status IN ('SUBMITTED','APPROVED')
                """).setParameter("id", analysisId).getSingleResult();
        if (planned.longValue() > 0) {
            throw conflict("分析已有待审核或已审核生产计划，必须先删除、驳回或红冲计划");
        }
        @SuppressWarnings("unchecked")
        List<UUID> actionIds = (List<UUID>) em.createNativeQuery("""
                SELECT id FROM preplan_supply_actions
                WHERE analysis_id = :id AND status <> 'CANCELLED'
                ORDER BY created_at DESC, id DESC FOR UPDATE
                """).setParameter("id", analysisId).getResultList();
        for (UUID actionId : actionIds) {
            cancelActionLocked(analysisId, actionId, request.reason());
        }
        em.createNativeQuery("""
                UPDATE production_material_analyses
                SET status = 'CANCELLED', cancelled_by = :actorId,
                    cancelled_at = now(), cancellation_reason = :reason,
                    version = version + 1, preview_fingerprint = NULL,
                    updated_at = now(), updated_by = :actorId
                WHERE id = :id
                """)
                .setParameter("actorId", currentUser.requireId())
                .setParameter("reason", request.reason().strip())
                .setParameter("id", analysisId)
                .executeUpdate();
        recordCommand(analysisId, OP_CANCEL_ANALYSIS, request.idempotencyKey(), hash,
                Map.of("analysisId", analysisId));
        return analysisService.detailInternal(analysisId, false);
    }

    private List<ActionGroup> selectedGroups(AnalysisView view, NotifyRequest request) {
        Map<String, List<MaterialView>> allGroups = view.flatMaterials().stream()
                .filter(MaterialView::actionable)
                .collect(Collectors.groupingBy(MaterialView::actionGroupKey,
                        LinkedHashMap::new, Collectors.toList()));
        Set<String> selected = new LinkedHashSet<>();
        if (request.actionGroupKeys() != null) selected.addAll(request.actionGroupKeys());
        if (request.materialLineIds() != null) {
            Map<UUID, String> lineGroups = view.flatMaterials().stream()
                    .filter(MaterialView::actionable).collect(
                    Collectors.toMap(MaterialView::materialLineId,
                            MaterialView::actionGroupKey));
            for (UUID lineId : request.materialLineIds()) {
                String group = lineGroups.get(lineId);
                if (group == null) throw validation("通知物料节点不存在或已过期");
                selected.add(group);
            }
        }
        if (selected.isEmpty()) {
            throw validation("至少选择一个物料操作组");
        }
        if (selected.size() > RequestLimits.DOCUMENT_LINES) {
            throw validation("一次通知最多包含 " + RequestLimits.DOCUMENT_LINES
                    + " 个去重后的物料操作任务，当前为 " + selected.size()
                    + " 个；请分批选择后重试");
        }
        String target = request.target() == null ? null
                : MaterialAnalysisService.normalizeRoute(request.target());
        Map<UUID, LocalDate> needDates = new HashMap<>();
        Map<UUID, Integer> allocationPriorities = new HashMap<>();
        view.products().forEach(product ->
                needDates.put(product.analysisLineId(), product.deliveryDate()));
        view.products().forEach(product -> allocationPriorities.put(
                product.analysisLineId(), product.allocationPriority()));
        List<ActionGroup> result = new ArrayList<>();
        for (String key : selected) {
            List<MaterialView> lines = allGroups.get(key);
            if (lines == null || lines.isEmpty()) throw validation("物料操作组不存在或已过期");
            Set<String> routes = lines.stream().map(MaterialView::sourceConfirmed)
                    .filter(Objects::nonNull).collect(Collectors.toSet());
            if (routes.size() != 1 || lines.stream().anyMatch(line -> !line.routeConfirmed())) {
                throw conflict("通知前必须确认操作组内全部物料路线");
            }
            String route = routes.iterator().next();
            if ("MAKE".equals(route)
                    && lines.stream().anyMatch(MaterialView::lowerLevelPending)) {
                throw conflict("自制件的下层物料尚未齐套，请先完成底层备料再安排生产");
            }
            if (target != null && !target.equals(route)) {
                throw validation("所选物料路线与通知目标不一致");
            }
            MaterialView first = lines.getFirst();
            MaterialDimension dimension = new MaterialDimension(
                    first.goodsId(), first.colorId(), first.unitId());
            if (lines.stream().anyMatch(line -> !dimension.equals(new MaterialDimension(
                    line.goodsId(), line.colorId(), line.unitId())))) {
                throw conflict("物料操作组维度不一致，请刷新分析");
            }
            BigDecimal required = lines.stream().map(MaterialView::shortageQty)
                    .reduce(BigDecimal.ZERO, BigDecimal::add)
                    .setScale(4, RoundingMode.CEILING);
            result.add(new ActionGroup(key, route, dimension,
                    allocationPriorities.getOrDefault(first.analysisLineId(), Integer.MAX_VALUE),
                    needDates.get(first.analysisLineId()), required, List.copyOf(lines)));
        }
        result.sort(Comparator.comparingInt(ActionGroup::sourcePriority)
                .thenComparing(ActionGroup::needDate,
                        Comparator.nullsLast(Comparator.naturalOrder()))
                .thenComparing(ActionGroup::groupKey));
        return List.copyOf(result);
    }

    private void allocateAction(
            UUID actionId, UUID analysisId, List<MaterialView> materials, BigDecimal qty) {
        BigDecimal total = materials.stream().map(MaterialView::shortageQty)
                .reduce(BigDecimal.ZERO, BigDecimal::add);
        BigDecimal remaining = qty;
        List<MaterialView> positive = materials.stream()
                .filter(material -> material.shortageQty().signum() > 0).toList();
        for (int index = 0; index < positive.size(); index++) {
            MaterialView material = positive.get(index);
            BigDecimal allocated = index == positive.size() - 1
                    ? remaining
                    : qty.multiply(material.shortageQty()).divide(
                            total, 4, RoundingMode.DOWN).min(remaining);
            if (allocated.signum() <= 0) continue;
            em.createNativeQuery("""
                    INSERT INTO preplan_supply_action_allocations (
                        id, analysis_id, action_id, analysis_material_id,
                        allocated_qty, created_by
                    ) VALUES (
                        :id, :analysisId, :actionId, :materialId, :qty, :actorId
                    )
                    """)
                    .setParameter("id", UUID.randomUUID())
                    .setParameter("analysisId", analysisId)
                    .setParameter("actionId", actionId)
                    .setParameter("materialId", material.materialLineId())
                    .setParameter("qty", allocated)
                    .setParameter("actorId", currentUser.requireId())
                    .executeUpdate();
            remaining = remaining.subtract(allocated);
        }
        if (remaining.signum() != 0) {
            throw conflict("备料任务节点分摊数量不守恒");
        }
    }

    private void createExternalDocument(UUID analysisId, ActionDraft action) {
        UUID employeeId = currentUser.requireEmployeeId();
        // 来源单据展示可读标签（计划前物料分析 + 分析日期），不再把分析 UUID 暴露给单据号/备注；
        // 谱系回溯改走 materialAnalysisId，与展示解耦。analyzed_at 实时查（refreshLocked 会推进）。
        // analyzed_at 是 TIMESTAMPTZ：Hibernate 6 原生查询按配置可能返回
        // Timestamp/OffsetDateTime/Instant（Testcontainers 下实测返回 Instant），
        // 强转 java.sql.Timestamp 会 CCE——逐类型归一到 Instant 再转上海日期。
        Object rawAnalyzedAt = em.createNativeQuery("""
                SELECT analyzed_at FROM production_material_analyses WHERE id = :id
                """)
                .setParameter("id", analysisId)
                .getSingleResult();
        java.time.Instant analyzedInstant;
        if (rawAnalyzedAt instanceof java.sql.Timestamp t) {
            analyzedInstant = t.toInstant();
        } else if (rawAnalyzedAt instanceof java.time.OffsetDateTime o) {
            analyzedInstant = o.toInstant();
        } else if (rawAnalyzedAt instanceof java.time.Instant i) {
            analyzedInstant = i;
        } else {
            throw new IllegalStateException(
                    "analyzed_at 返回了未支持的类型：" + rawAnalyzedAt.getClass().getName());
        }
        String sourceLabel = "计划前物料分析 "
                + analyzedInstant.atZone(BusinessTime.ZONE).toLocalDate();
        if ("BUY".equals(action.group().route())) {
            ProductionPurchaseRequestFacade.DraftResult result =
                    purchaseRequests.createProductionDraft(
                            sourceLabel, analysisId, action.group().needDate(),
                            selectedWarehouse(analysisId),
                            List.of(new ProductionPurchaseRequestFacade.DraftLine(
                                    action.actionId(), action.group().dimension().goodsId(),
                                    action.group().dimension().colorId(),
                                    action.group().dimension().unitId(), action.qty(),
                                    action.group().needDate(), "计划前物料分析备料")),
                            employeeId, employeeId);
            ProductionPurchaseRequestFacade.DraftLineResult line = result.lines().getFirst();
            markCreated(action.actionId(), "PURCHASE_REQUEST", result.requestId(),
                    result.billNo(), line.requestItemId());
            return;
        }
        if ("SUBCONTRACT".equals(action.group().route())) {
            ProductionSubcontractRequestPort.DraftResult result =
                    subcontractRequests.createProductionDraft(
                            sourceLabel, analysisId, action.group().needDate(),
                            selectedWarehouse(analysisId),
                            List.of(new ProductionSubcontractRequestPort.DraftLine(
                                    action.actionId(), action.group().dimension().goodsId(),
                                    action.group().dimension().colorId(),
                                    action.group().dimension().unitId(), action.qty(),
                                    action.group().needDate(), "计划前物料分析委外备料")),
                            employeeId, employeeId);
            ProductionSubcontractRequestPort.DraftLineResult line = result.lines().getFirst();
            markCreated(action.actionId(), "SUBCONTRACT_APPLICATION",
                    result.applicationId(), result.billNo(), line.applicationItemId());
            return;
        }
        UUID childItemId = createOrIncrementMakeDemand(analysisId, action);
        markCreated(action.actionId(), "PREPLAN_MAKE_TASK", childItemId,
                makeDemandSourceRef(childItemId), childItemId);
    }

    /** 自制备料需求行的可读来源编号（自制备料 日期 尾码）：面向展示，禁止 UUID。 */
    private String makeDemandSourceRef(UUID itemId) {
        // 单列原生查询返回标量（String）而非 Object[]，不能走 oneRow 的
        // objectArrayRows 路径（会 CCE）；getResultList 空表时转业务 notFound。
        List<?> rows = em.createNativeQuery("""
                SELECT source_ref FROM production_material_analysis_items WHERE id = :id
                """).setParameter("id", itemId).getResultList();
        if (rows.isEmpty()) throw MaterialAnalysisService.notFound("自制备料需求不存在");
        return MaterialAnalysisService.string(rows.getFirst());
    }

    private UUID createOrIncrementMakeDemand(UUID analysisId, ActionDraft action) {
        UUID representative = action.group().materials().getFirst().materialLineId();
        List<Object[]> existing = NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT id, requested_qty
                FROM production_material_analysis_items
                WHERE analysis_id = :analysisId
                  AND source_type = 'MAKE_COMPONENT'
                  AND parent_analysis_material_id = :parentId
                  AND is_deleted = FALSE
                FOR UPDATE
                """).setParameter("analysisId", analysisId)
                .setParameter("parentId", representative));
        if (!existing.isEmpty()) {
            UUID itemId = (UUID) existing.getFirst()[0];
            em.createNativeQuery("""
                    UPDATE production_material_analysis_items
                    SET requested_qty = requested_qty + :qty,
                        delivery_date = COALESCE(:needDate, delivery_date),
                        updated_at = now(), updated_by = :actorId
                    WHERE id = :id
                    """)
                    .setParameter("qty", action.qty())
                    .setParameter("needDate", action.group().needDate())
                    .setParameter("actorId", currentUser.requireId())
                    .setParameter("id", itemId).executeUpdate();
            return itemId;
        }
        UUID itemId = UUID.randomUUID();
        // 可读来源编号「自制备料 <日期> <4位尾码>」：日期表意，尾码取自条目 id 仅作同日去重；
        // (source_type, source_ref) 有全局唯一索引，插入前查重避免碰撞（PG 唯一冲突会中止整个事务）。
        String sourceRef = nextMakeSourceRef(itemId);
        int linePriority = nextLinePriority(analysisId);
        em.createNativeQuery("""
                INSERT INTO production_material_analysis_items (
                    id, analysis_id, source_type, goods_id, color_id, unit_id,
                    source_ref, source_reason, requested_qty, delivery_date,
                    line_priority, parent_analysis_material_id,
                    created_by, updated_by
                ) VALUES (
                    :id, :analysisId, 'MAKE_COMPONENT', :goodsId, :colorId, :unitId,
                    :sourceRef, :sourceReason, :qty, :needDate,
                    :linePriority,
                    :parentId, :actorId, :actorId
                )
                """)
                .setParameter("id", itemId)
                .setParameter("analysisId", analysisId)
                .setParameter("goodsId", action.group().dimension().goodsId())
                .setParameter("colorId", action.group().dimension().colorId())
                .setParameter("unitId", action.group().dimension().unitId())
                .setParameter("sourceRef", sourceRef)
                .setParameter("sourceReason", "父级物料缺口确认自制备料")
                .setParameter("qty", action.qty())
                .setParameter("needDate", action.group().needDate())
                .setParameter("linePriority", linePriority)
                .setParameter("parentId", representative)
                .setParameter("actorId", currentUser.requireId())
                .executeUpdate();
        return itemId;
    }

    /** 分析内下一行序（与既有 line_priority 递增口径一致；行锁由调用方 lockHeader 保证串行）。 */
    private int nextLinePriority(UUID analysisId) {
        // 单列聚合原生查询恒返回一行标量（Integer），非 Object[]，不能走 oneRow（会 CCE）。
        Object value = em.createNativeQuery("""
                SELECT COALESCE(MAX(line_priority), 0) + 1
                FROM production_material_analysis_items
                WHERE analysis_id = :analysisId
                """).setParameter("analysisId", analysisId).getSingleResult();
        return ((Number) value).intValue();
    }

    /** 生成未占用的自制备料来源编号；尾码碰撞时换码重试（理论上限 8 次，4 位十六进制几乎不会连撞）。 */
    private String nextMakeSourceRef(UUID itemId) {
        String candidate = "自制备料 " + BusinessTime.today()
                + " " + itemId.toString().substring(0, 4);
        if (makeSourceRefAvailable(candidate)) return candidate;
        // 尾码撞车：换成随机码再试几次；仍撞则放弃（概率可忽略）。
        for (int attempt = 0; attempt < 8; attempt++) {
            candidate = "自制备料 " + BusinessTime.today()
                    + " " + UUID.randomUUID().toString().substring(0, 4);
            if (makeSourceRefAvailable(candidate)) return candidate;
        }
        throw conflict("自制备料来源编号生成冲突，请重试");
    }

    private boolean makeSourceRefAvailable(String ref) {
        return em.createNativeQuery("""
                SELECT 1
                FROM production_material_analysis_items
                WHERE source_type = 'MAKE_COMPONENT'
                  AND is_deleted = FALSE
                  AND lower(btrim(source_ref)) = lower(btrim(:ref))
                """).setParameter("ref", ref).getResultList().isEmpty();
    }

    private void markCreated(UUID actionId, String type, UUID documentId,
                             String documentNo, UUID externalItemId) {
        em.createNativeQuery("""
                UPDATE preplan_supply_actions
                SET status = 'CREATED', external_document_type = :type,
                    external_document_id = :documentId,
                    external_document_no = :documentNo,
                    updated_at = now()
                WHERE id = :id
                """)
                .setParameter("type", type)
                .setParameter("documentId", documentId)
                .setParameter("documentNo", documentNo)
                .setParameter("id", actionId).executeUpdate();
        em.createNativeQuery("""
                UPDATE preplan_supply_action_allocations
                SET external_item_id = :externalItemId
                WHERE action_id = :id
                """)
                .setParameter("externalItemId", externalItemId)
                .setParameter("id", actionId).executeUpdate();
    }

    private PlanDetail createDraftPlan(
            UUID analysisId, ProductView product, PlanQuantity quantity,
            GeneratePlanRequest request, String overrideReason) {
        BigDecimal qty = quantity.qty();
        LocalDate billDate = itemBillDate(quantity, request);
        LocalDate deliveryDate = itemDeliveryDate(quantity, request);
        UUID departmentId = itemDepartmentId(quantity, request);
        String workshopName = itemWorkshopName(quantity, request);
        UUID workerId = itemWorkerId(quantity, request);
        PlanItemLine line = new PlanItemLine();
        line.setLineNo(1);
        // Preserve an explicit business product number. Blank input remains
        // server-owned and is allocated by ProductionPlanService only after it
        // has the immutable plan UUID and server-issued bill number.
        line.setProductNo(quantity.productNo());
        line.setGoodsId(product.goodsId());
        line.setColorId(product.colorId());
        line.setUnitId(product.unitId());
        line.setUnitRate(product.unitRate());
        line.setSalesOrderItemId(product.salesOrderItemId());
        line.setSalesOrderNo(product.salesOrderNo());
        line.setClientName(product.clientName());
        line.setOqty(product.requestedQty());
        BigDecimal normalizedQty;
        try {
            normalizedQty = qty.setScale(4, RoundingMode.UNNECESSARY);
        } catch (ArithmeticException ex) {
            throw validation("生产计划数量最多保留四位小数");
        }
        line.setQty(normalizedQty);
        line.setOrderDate(product.orderDate());
        line.setOutboundDate(product.deliveryDate());
        line.setPlanBeginDate(billDate);
        line.setPlanEndDate(deliveryDate);
        line.setSourceDocNo(product.salesOrderNo());
        line.setRemark("由生产物料分析分批生成");

        PlanSaveRequest save = new PlanSaveRequest();
        save.setBillDate(billDate);
        save.setDeliveryDate(deliveryDate);
        save.setDepartmentId(departmentId);
        save.setWorkshopName(workshopName);
        save.setWorkerId(workerId);
        save.setSourceDocNo(product.salesOrderNo());
        save.setRemark("物料分析 " + analysisId + " 原子生成");
        save.setItems(List.of(line));
        PlanDetail plan = planService.create(save);
        // Resolve bom_override_by in Java, not via a SQL `CASE WHEN :overrideReason IS NULL`:
        // a null parameter used only in an IS-NUL check leaves PostgreSQL unable to infer its type
        // ("could not determine data type of parameter"), which would crash every generate-plan
        // call that carries no BOM override.
        UUID overrideBy = overrideReason == null ? null : currentUser.requireId();
        em.createNativeQuery("""
                UPDATE production_plans
                SET material_analysis_id = :analysisId,
                    material_analysis_item_id = :analysisItemId,
                    bom_override_reason = :overrideReason,
                    bom_override_by = :overrideBy,
                    updated_at = now(), updated_by = :actorId
                WHERE id = :planId
                """)
                .setParameter("analysisId", analysisId)
                .setParameter("analysisItemId", product.analysisLineId())
                .setParameter("overrideReason", overrideReason)
                .setParameter("overrideBy", overrideBy)
                .setParameter("actorId", currentUser.requireId())
                .setParameter("planId", plan.getId()).executeUpdate();
        ProductionPlan managedPlan = em.find(ProductionPlan.class, plan.getId());
        em.refresh(managedPlan);
        em.createNativeQuery("""
                INSERT INTO production_material_analysis_plan_links (
                    id, analysis_id, analysis_item_id, plan_id,
                    submitted_qty, allocation_status, created_by
                ) VALUES (
                    :id, :analysisId, :analysisItemId, :planId,
                    :qty, 'SUBMITTED', :actorId
                )
                """)
                .setParameter("id", UUID.randomUUID())
                .setParameter("analysisId", analysisId)
                .setParameter("analysisItemId", product.analysisLineId())
                .setParameter("planId", plan.getId())
                .setParameter("qty", qty)
                .setParameter("actorId", currentUser.requireId()).executeUpdate();
        return plan;
    }

    private ProductionPlanningDraftView savePlanningDraft(
            UUID analysisId, ProductView product, PlanDetail plan,
            PlanQuantity quantity, GeneratePlanRequest request) {
        LocalDate billDate = itemBillDate(quantity, request);
        LocalDate deliveryDate = itemDeliveryDate(quantity, request);
        UUID departmentId = itemDepartmentId(quantity, request);
        UUID workerId = itemWorkerId(quantity, request);
        PlanningPreviewResult preview = planningPackages.preview(
                plan.getId(), request.warehouseId());
        if (preview.executionSegments().isEmpty()) {
            throw conflict("正式生产计划未形成可下达的执行分段");
        }
        BigDecimal expectedQty = plan.getItems().stream()
                .map(item -> item.getQty() == null ? BigDecimal.ZERO : item.getQty())
                .reduce(BigDecimal.ZERO, BigDecimal::add);
        BigDecimal proposedQty = preview.executionSegments().stream()
                .map(ExecutionSegmentPreview::plannedQty)
                .reduce(BigDecimal.ZERO, BigDecimal::add);
        if (expectedQty.compareTo(proposedQty) != 0
                || preview.executionSegments().stream().anyMatch(segment ->
                        !"READY".equals(segment.suggestedStatus()))) {
            throw conflict("正式计划预览与分析齐套结论不一致，事务已回滚，请重新分析");
        }
        GeneratePlanningPackageRequest formal = new GeneratePlanningPackageRequest();
        formal.setWarehouseId(request.warehouseId());
        formal.setIdempotencyKey("ANALYSIS-" + analysisId + "-" + product.analysisLineId());
        formal.setPreviewFingerprint(preview.fingerprint());
        formal.setGeneratePurchaseRequest(false);
        formal.setRoutes(List.of());
        formal.setItems(List.of());
        List<GeneratePlanningPackageRequest.ExecutionSegment> segments = new ArrayList<>();
        for (ExecutionSegmentPreview proposal : preview.executionSegments()) {
            GeneratePlanningPackageRequest.ExecutionSegment segment =
                    new GeneratePlanningPackageRequest.ExecutionSegment();
            segment.setClientSegmentKey(proposal.clientSegmentKey());
            segment.setSourcePlanItemId(proposal.sourcePlanItemId());
            segment.setRequestedStatus("READY");
            segment.setDeferUntilManualRelease(false);
            segment.setPlannedQty(proposal.plannedQty());
            segment.setWorkshopDepartmentId(departmentId == null
                    ? proposal.workshopDepartmentId() : departmentId);
            segment.setTeamDepartmentId(quantity.teamDepartmentId() == null
                    ? proposal.teamDepartmentId() : quantity.teamDepartmentId());
            segment.setResponsibleEmployeeId(workerId == null
                    ? proposal.responsibleEmployeeId() : workerId);
            segment.setPlanBeginDate(billDate);
            segment.setPlanEndDate(deliveryDate);
            segment.setBomFingerprint(proposal.bomFingerprint());
            segments.add(segment);
        }
        formal.setSegments(List.copyOf(segments));
        return planningDrafts.save(plan.getId(), formal);
    }

    private static void validatePlanSchedule(
            PlanQuantity quantity, GeneratePlanRequest request) {
        LocalDate billDate = itemBillDate(quantity, request);
        LocalDate deliveryDate = itemDeliveryDate(quantity, request);
        if (deliveryDate != null && deliveryDate.isBefore(billDate)) {
            throw validation("计划完成日期不能早于计划开始日期");
        }
    }

    private static LocalDate itemBillDate(
            PlanQuantity quantity, GeneratePlanRequest request) {
        return quantity.billDate() == null ? request.billDate() : quantity.billDate();
    }

    private static LocalDate itemDeliveryDate(
            PlanQuantity quantity, GeneratePlanRequest request) {
        return quantity.deliveryDate() == null
                ? request.deliveryDate() : quantity.deliveryDate();
    }

    private static UUID itemDepartmentId(
            PlanQuantity quantity, GeneratePlanRequest request) {
        return quantity.departmentId() == null
                ? request.departmentId() : quantity.departmentId();
    }

    private static String itemWorkshopName(
            PlanQuantity quantity, GeneratePlanRequest request) {
        return quantity.workshopName() == null
                ? request.workshopName() : quantity.workshopName();
    }

    private static UUID itemWorkerId(
            PlanQuantity quantity, GeneratePlanRequest request) {
        return quantity.workerId() == null ? request.workerId() : quantity.workerId();
    }

    private GeneratedPlan toGenerated(
            PlanDetail plan, ProductionPlanningDraftView draft,
            PlanningPackageResult applied) {
        if (applied == null) {
            return new GeneratedPlan(plan.getId(), plan.getBillNo(), "DRAFT",
                    draft.draftId(), null, List.of(), List.of());
        }
        return new GeneratedPlan(plan.getId(), plan.getBillNo(), "APPROVED",
                draft.draftId(), applied.packageId(),
                applied.executionSegments().stream().map(value -> value.segmentId()).toList(),
                applied.drawDocuments().stream().map(MrpGenerateResult::requestId).toList());
    }

    private GeneratedPlan generatedPlan(UUID planId) {
        Object[] plan = one(em.createNativeQuery("""
                SELECT id, bill_no, status FROM production_plans
                WHERE id = :id AND is_deleted = FALSE
                """).setParameter("id", planId), "幂等结果中的生产计划不存在");
        UUID draftId = scalarUuid("""
                SELECT id FROM production_planning_drafts
                WHERE plan_id = :id ORDER BY planned_at DESC, id DESC LIMIT 1
                """, planId);
        UUID packageId = scalarUuid("""
                SELECT id FROM production_planning_packages
                WHERE plan_id = :id AND status = 'CONFIRMED' AND is_deleted = FALSE
                ORDER BY created_at DESC, id DESC LIMIT 1
                """, planId);
        List<UUID> segments = packageId == null ? List.of() : uuidList("""
                SELECT id FROM production_execution_segments
                WHERE package_id = :id AND is_deleted = FALSE ORDER BY segment_no, id
                """, packageId);
        List<UUID> draws = packageId == null ? List.of() : uuidList("""
                SELECT document_id FROM production_planning_package_documents
                WHERE package_id = :id AND document_type = 'DRAW' ORDER BY created_at, id
                """, packageId);
        return new GeneratedPlan((UUID) plan[0], Objects.toString(plan[1], null),
                ((Number) plan[2]).shortValue() == 1 ? "APPROVED" : "DRAFT",
                draftId, packageId, segments, draws);
    }

    private void cancelActionLocked(UUID analysisId, UUID actionId, String reason) {
        Object[] row = one(em.createNativeQuery("""
                SELECT id, status, route, requested_qty, external_document_type,
                       external_document_id
                FROM preplan_supply_actions
                WHERE id = :actionId AND analysis_id = :analysisId
                FOR UPDATE
                """).setParameter("actionId", actionId)
                .setParameter("analysisId", analysisId), "备料任务不存在");
        String status = Objects.toString(row[1], "");
        if ("CANCELLED".equals(status)) return;
        String type = Objects.toString(row[4], null);
        UUID documentId = (UUID) row[5];
        if ("PURCHASE_REQUEST".equals(type)) {
            purchaseRequests.cancelGeneratedDraft(documentId,
                    ProductionPurchaseRequestFacade.LifecycleAction.CANCEL);
        } else if ("SUBCONTRACT_APPLICATION".equals(type)) {
            subcontractRequests.closeGeneratedDraft(documentId,
                    ProductionSubcontractRequestPort.LifecycleAction.CANCEL);
        } else if ("PREPLAN_MAKE_TASK".equals(type)) {
            cancelMakeDemand(analysisId, actionId, documentId, decimal(row[3]));
        } else if (!"OPEN".equals(status)) {
            throw conflict("备料任务缺少可撤回的真实下游单据引用");
        }
        em.createNativeQuery("""
                UPDATE preplan_supply_actions
                SET status = 'CANCELLED', cancelled_by = :actorId,
                    cancelled_at = now(), cancellation_reason = :reason,
                    updated_at = now()
                WHERE id = :id
                """)
                .setParameter("actorId", currentUser.requireId())
                .setParameter("reason", reason.strip())
                .setParameter("id", actionId).executeUpdate();
    }

    private void cancelMakeDemand(
            UUID analysisId, UUID actionId, UUID itemId, BigDecimal qty) {
        Object[] item = one(em.createNativeQuery("""
                SELECT requested_qty, submitted_qty, approved_qty
                FROM production_material_analysis_items
                WHERE id = :id AND analysis_id = :analysisId
                  AND source_type = 'MAKE_COMPONENT' AND is_deleted = FALSE
                FOR UPDATE
                """).setParameter("id", itemId).setParameter("analysisId", analysisId),
                "自制备料需求不存在");
        BigDecimal minimum = decimal(item[1]).add(decimal(item[2]));
        BigDecimal next = decimal(item[0]).subtract(qty);
        if (next.compareTo(minimum) < 0) {
            throw conflict("自制备料需求已有待审核或已审核计划，不能撤回");
        }
        Number other = (Number) em.createNativeQuery("""
                SELECT COUNT(*) FROM preplan_supply_actions
                WHERE analysis_id = :analysisId AND id <> :actionId
                  AND external_document_type = 'PREPLAN_MAKE_TASK'
                  AND external_document_id = :itemId AND status <> 'CANCELLED'
                """).setParameter("analysisId", analysisId)
                .setParameter("actionId", actionId).setParameter("itemId", itemId)
                .getSingleResult();
        if (next.signum() == 0 && other.longValue() == 0) {
            em.createNativeQuery("""
                    UPDATE production_material_analysis_items
                    SET is_deleted = TRUE, deleted_at = now(), updated_at = now(),
                        updated_by = :actorId
                    WHERE id = :id
                    """).setParameter("actorId", currentUser.requireId())
                    .setParameter("id", itemId).executeUpdate();
        } else {
            em.createNativeQuery("""
                    UPDATE production_material_analysis_items
                    SET requested_qty = :qty, updated_at = now(), updated_by = :actorId
                    WHERE id = :id
                    """).setParameter("qty", next)
                    .setParameter("actorId", currentUser.requireId())
                    .setParameter("id", itemId).executeUpdate();
        }
    }

    /**
     * Finds open coverage by the material-node allocations as well as the
     * current V3 node key. Allocation lookup keeps actions created with the
     * legacy grouped key from being duplicated after the node model upgrade.
     */
    private BigDecimal activeOpenActionQty(UUID analysisId, ActionGroup group) {
        Set<String> groupKeys = new LinkedHashSet<>();
        groupKeys.add(group.groupKey());
        List<UUID> materialIds = group.materials().stream()
                .map(MaterialView::materialLineId).toList();
        if (!materialIds.isEmpty()) {
            @SuppressWarnings("unchecked")
            List<String> legacyKeys = (List<String>) em.createNativeQuery("""
                    SELECT DISTINCT action.action_group_key
                    FROM preplan_supply_action_allocations allocation
                    JOIN preplan_supply_actions action ON action.id = allocation.action_id
                    WHERE allocation.analysis_id = :analysisId
                      AND allocation.analysis_material_id IN (:materialIds)
                      AND action.route = :route
                      AND action.status IN ('OPEN','CREATED','IN_PROGRESS')
                    ORDER BY action.action_group_key
                    """)
                    .setParameter("analysisId", analysisId)
                    .setParameter("materialIds", materialIds)
                    .setParameter("route", group.route())
                    .getResultList();
            groupKeys.addAll(legacyKeys);
        }
        return groupKeys.stream()
                .map(key -> activeOpenActionQtyByGroup(
                        analysisId, key, group.route()))
                .reduce(BigDecimal.ZERO, BigDecimal::add);
    }

    private BigDecimal activeOpenActionQtyByGroup(
            UUID analysisId, String groupKey, String route) {
        if ("MAKE".equals(route)) {
            return activeOpenMakeActionQty(analysisId, groupKey);
        }
        return decimal(em.createNativeQuery("""
                SELECT COALESCE(SUM(CASE
                    WHEN action.external_document_type = 'PURCHASE_REQUEST'
                         AND EXISTS (
                             SELECT 1
                             FROM preplan_supply_action_allocations allocation
                             JOIN purchase_request_items request_item
                               ON request_item.id = allocation.external_item_id
                              AND request_item.is_deleted = FALSE
                             JOIN purchase_requests request
                               ON request.id = request_item.request_id
                              AND request.id = action.external_document_id
                              AND request.is_deleted = FALSE
                              AND request.status IN (0,1)
                              AND request.is_stopped = FALSE
                             WHERE allocation.action_id = action.id)
                        THEN GREATEST(action.requested_qty - LEAST(
                            action.requested_qty, COALESCE((
                                 SELECT SUM(GREATEST(
                                     COALESCE((
                                         SELECT SUM(CASE
                                             WHEN inspection.id IS NULL
                                             THEN receipt_item.qty * COALESCE(
                                                 receipt_item.unit_rate,1)
                                             WHEN inspection.status = 'RESOLVED'
                                             THEN inspection.passed_base_qty
                                             ELSE 0
                                         END)
                                         FROM purchase_receipt_items receipt_item
                                         JOIN purchase_receipts receipt
                                           ON receipt.id = receipt_item.receipt_id
                                          AND receipt.status = 1
                                          AND receipt.is_deleted = FALSE
                                         LEFT JOIN procurement_inspection_items inspection
                                           ON inspection.receipt_type = 'PURCHASE'
                                          AND inspection.receipt_item_id = receipt_item.id
                                         WHERE receipt_item.order_item_id = item.id
                                           AND receipt_item.is_deleted = FALSE
                                     ),0) - COALESCE(item.returned_qty,0)
                                         * COALESCE(item.unit_rate,1), 0))
                                FROM purchase_order_items item
                                JOIN purchase_orders purchase_order
                                  ON purchase_order.id = item.order_id
                                 AND purchase_order.status = 1
                                 AND purchase_order.is_deleted = FALSE
                                WHERE item.is_deleted = FALSE
                                  AND item.request_item_id IN (
                                      SELECT DISTINCT allocation.external_item_id
                                      FROM preplan_supply_action_allocations allocation
                                      WHERE allocation.action_id = action.id
                                        AND allocation.external_item_id IS NOT NULL)
                            ),0)), 0)
                    WHEN action.external_document_type = 'SUBCONTRACT_APPLICATION'
                         AND EXISTS (
                             SELECT 1
                             FROM preplan_supply_action_allocations allocation
                             JOIN subcontract_application_items application_item
                               ON application_item.id = allocation.external_item_id
                              AND application_item.is_deleted = FALSE
                             JOIN subcontract_applications application
                               ON application.id = application_item.application_id
                              AND application.id = action.external_document_id
                              AND application.is_deleted = FALSE
                              AND application.status IN (0,1)
                             WHERE allocation.action_id = action.id)
                        THEN GREATEST(action.requested_qty - LEAST(
                            action.requested_qty, COALESCE((
                                 SELECT SUM(GREATEST(
                                     COALESCE((
                                         SELECT SUM(CASE
                                             WHEN inspection.id IS NULL
                                             THEN receipt_item.qty * COALESCE(
                                                 receipt_item.unit_rate,1)
                                             WHEN inspection.status = 'RESOLVED'
                                             THEN inspection.passed_base_qty
                                             ELSE 0
                                         END)
                                         FROM subcontract_receipt_items receipt_item
                                         JOIN subcontract_receipts receipt
                                           ON receipt.id = receipt_item.receipt_id
                                          AND receipt.status = 1
                                          AND receipt.is_deleted = FALSE
                                         LEFT JOIN procurement_inspection_items inspection
                                           ON inspection.receipt_type = 'SUBCONTRACT'
                                          AND inspection.receipt_item_id = receipt_item.id
                                         WHERE receipt_item.order_item_id = item.id
                                           AND receipt_item.is_deleted = FALSE
                                     ),0) - COALESCE(item.returned_qty,0)
                                         * COALESCE(item.unit_rate,1), 0))
                                FROM subcontract_order_items item
                                JOIN subcontract_orders subcontract_order
                                  ON subcontract_order.id = item.order_id
                                 AND subcontract_order.status = 1
                                 AND subcontract_order.is_deleted = FALSE
                                WHERE item.is_deleted = FALSE
                                  AND item.application_item_id IN (
                                      SELECT DISTINCT allocation.external_item_id
                                      FROM preplan_supply_action_allocations allocation
                                      WHERE allocation.action_id = action.id
                                        AND allocation.external_item_id IS NOT NULL)
                            ),0)), 0)
                    ELSE 0
                END),0)
                FROM preplan_supply_actions action
                WHERE action.analysis_id = :analysisId
                  AND action.action_group_key = :groupKey
                  AND action.route = :route
                  AND action.status IN ('OPEN','CREATED','IN_PROGRESS')
                """).setParameter("analysisId", analysisId)
                .setParameter("groupKey", groupKey).setParameter("route", route)
                .getSingleResult());
    }

    /** MAKE coverage follows the child demand and unfinished approved child plans. */
    private BigDecimal activeOpenMakeActionQty(UUID analysisId, String groupKey) {
        return decimal(em.createNativeQuery("""
                WITH active_actions AS (
                    SELECT action.external_document_id AS child_item_id,
                           SUM(action.requested_qty) AS requested_qty
                    FROM preplan_supply_actions action
                    WHERE action.analysis_id = :analysisId
                      AND action.action_group_key = :groupKey
                      AND action.route = 'MAKE'
                      AND action.status IN ('OPEN','CREATED','IN_PROGRESS')
                      AND action.external_document_type = 'PREPLAN_MAKE_TASK'
                      AND action.external_document_id IS NOT NULL
                    GROUP BY action.external_document_id
                ), child_open AS (
                    SELECT active.child_item_id, active.requested_qty,
                           GREATEST(
                               child.requested_qty - child.approved_qty
                               + COALESCE((
                                   SELECT SUM(GREATEST(
                                       plan_item.qty - COALESCE(plan_item.iqty,0), 0))
                                   FROM production_material_analysis_plan_links analysis_link
                                   JOIN production_plans plan
                                     ON plan.id = analysis_link.plan_id
                                    AND plan.status = 1
                                    AND plan.is_deleted = FALSE
                                    AND plan.is_canceled = FALSE
                                   JOIN production_plan_items plan_item
                                     ON plan_item.plan_id = plan.id
                                    AND plan_item.is_deleted = FALSE
                                   WHERE analysis_link.analysis_item_id = child.id
                                     AND analysis_link.allocation_status = 'APPROVED'
                               ),0), 0) AS open_qty
                    FROM active_actions active
                    JOIN production_material_analysis_items child
                      ON child.id = active.child_item_id
                     AND child.analysis_id = :analysisId
                     AND child.source_type = 'MAKE_COMPONENT'
                     AND child.is_deleted = FALSE
                )
                SELECT COALESCE(SUM(LEAST(requested_qty, open_qty)),0)
                FROM child_open
                """).setParameter("analysisId", analysisId)
                .setParameter("groupKey", groupKey)
                .getSingleResult());
    }

    private ActionSequence nextActionSequence(UUID analysisId, String groupKey, String route) {
        List<Object[]> rows = NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT id, generation FROM preplan_supply_actions
                WHERE analysis_id = :analysisId AND action_group_key = :groupKey
                  AND route = :route
                ORDER BY generation DESC, id DESC LIMIT 1 FOR UPDATE
                """).setParameter("analysisId", analysisId)
                .setParameter("groupKey", groupKey).setParameter("route", route));
        return rows.isEmpty() ? new ActionSequence(1, null)
                : new ActionSequence(((Number) rows.getFirst()[1]).intValue() + 1,
                        (UUID) rows.getFirst()[0]);
    }

    private UUID selectedWarehouse(UUID analysisId) {
        Object value = em.createNativeQuery("""
                SELECT warehouse_id FROM production_material_analyses WHERE id = :id
                """).setParameter("id", analysisId).getSingleResult();
        if (value == null) throw conflict("物料分析未选择目标仓库");
        return (UUID) value;
    }

    private Map<UUID, String> overrides(List<BomOverride> values) {
        if (values == null) return Map.of();
        Map<UUID, String> result = new HashMap<>();
        values.forEach(value -> result.put(value.analysisLineId(), value.reason().strip()));
        return Map.copyOf(result);
    }

    private void requireWritable(MaterialAnalysisService.AnalysisHeader header, String message) {
        access.requireWritable(header.makerId(), message, access.scope());
    }

    private CommandReplay commandReplay(
            UUID analysisId, String operation, String key, String hash) {
        List<Object[]> rows = NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT request_hash, result_payload
                FROM production_material_analysis_commands
                WHERE analysis_id = :analysisId AND operation = :operation
                  AND idempotency_key = :key
                """).setParameter("analysisId", analysisId)
                .setParameter("operation", operation).setParameter("key", key));
        if (rows.isEmpty()) return null;
        if (!Objects.equals(hash, Objects.toString(rows.getFirst()[0], ""))) {
            throw conflict("同一幂等键已用于不同请求");
        }
        return new CommandReplay(Objects.toString(rows.getFirst()[1], "{}"));
    }

    private void recordCommand(
            UUID analysisId, String operation, String key, String hash,
            Map<String, ?> payload) {
        try {
            em.createNativeQuery("""
                    INSERT INTO production_material_analysis_commands (
                        id, analysis_id, operation, idempotency_key,
                        request_hash, result_payload, created_by
                    ) VALUES (
                        :id, :analysisId, :operation, :key,
                        :hash, CAST(:payload AS jsonb), :actorId
                    )
                    """)
                    .setParameter("id", UUID.randomUUID())
                    .setParameter("analysisId", analysisId)
                    .setParameter("operation", operation)
                    .setParameter("key", key)
                    .setParameter("hash", hash)
                    .setParameter("payload", objectMapper.writeValueAsString(payload))
                    .setParameter("actorId", currentUser.requireId()).executeUpdate();
        } catch (JsonProcessingException ex) {
            throw conflict("幂等结果序列化失败");
        }
    }

    private List<UUID> replayIds(String payload, String field) {
        try {
            JsonNode node = objectMapper.readTree(payload).path(field);
            List<UUID> result = new ArrayList<>();
            node.forEach(value -> result.add(UUID.fromString(value.asText())));
            return List.copyOf(result);
        } catch (JsonProcessingException | IllegalArgumentException ex) {
            throw conflict("幂等结果损坏，不能安全重放");
        }
    }

    private static String notifyHash(UUID analysisId, NotifyRequest request) {
        List<String> parts = new ArrayList<>(List.of(
                "NOTIFY-V1", analysisId.toString(), Long.toString(request.version()),
                request.fingerprint(), Objects.toString(request.target(), "")));
        if (request.actionGroupKeys() != null) request.actionGroupKeys().stream()
                .sorted().forEach(value -> parts.add("GROUP|" + value));
        if (request.materialLineIds() != null) request.materialLineIds().stream()
                .sorted().forEach(value -> parts.add("LINE|" + value));
        return PlanningPackageFingerprint.sha256(parts);
    }

    private static String generateHash(UUID analysisId, GeneratePlanRequest request) {
        List<String> parts = new ArrayList<>(List.of(
                "GENERATE-PLAN-V1", analysisId.toString(), Long.toString(request.version()),
                request.fingerprint(), request.previewFingerprint(),
                request.warehouseId().toString(), request.billDate().toString(),
                Objects.toString(request.deliveryDate(), ""),
                Objects.toString(request.departmentId(), ""),
                Objects.toString(request.workshopName(), ""),
                Objects.toString(request.workerId(), ""),
                Boolean.toString(request.approveNow())));
        request.items().forEach(item -> {
            String itemHash = "ITEM|" + item.analysisLineId()
                    + "|" + MaterialAnalysisService.decimalText(item.qty())
                    + "|" + Objects.toString(item.billDate(), "")
                    + "|" + Objects.toString(item.deliveryDate(), "")
                    + "|" + Objects.toString(item.departmentId(), "")
                    + "|" + Objects.toString(item.workshopName(), "")
                    + "|" + Objects.toString(item.workerId(), "")
                    + "|" + Objects.toString(item.teamDepartmentId(), "");
            String productNo = MaterialAnalysisService.blankToNull(item.productNo());
            if (productNo != null) {
                itemHash += "|PRODUCT_NO|" + productNo.length() + ":" + productNo;
            }
            parts.add(itemHash);
        });
        if (request.bomOverrides() != null) request.bomOverrides().forEach(value ->
                parts.add("BOM|" + value.analysisLineId() + "|" + value.reason().strip()));
        return PlanningPackageFingerprint.sha256(parts);
    }

    private UUID scalarUuid(String sql, UUID id) {
        List<?> rows = em.createNativeQuery(sql).setParameter("id", id).getResultList();
        return rows.isEmpty() ? null : (UUID) rows.getFirst();
    }

    @SuppressWarnings("unchecked")
    private List<UUID> uuidList(String sql, UUID id) {
        return (List<UUID>) em.createNativeQuery(sql).setParameter("id", id).getResultList();
    }

    private static Object[] one(jakarta.persistence.Query query, String message) {
        List<Object[]> rows = NativeQueryResults.objectArrayRows(query);
        if (rows.isEmpty()) throw new ApiException(ErrorCode.NOT_FOUND, message);
        return rows.getFirst();
    }

    private static BigDecimal decimal(Object value) {
        return value == null ? BigDecimal.ZERO : new BigDecimal(value.toString());
    }

    private static ApiException validation(String message) {
        return new ApiException(ErrorCode.VALIDATION_FAILED, message);
    }

    private static ApiException conflict(String message) {
        return new ApiException(ErrorCode.CONFLICT, message);
    }

    private record MaterialDimension(UUID goodsId, UUID colorId, UUID unitId) {
    }

    private record ActionGroup(
            String groupKey, String route, MaterialDimension dimension,
            int sourcePriority, LocalDate needDate, BigDecimal requiredQty,
            List<MaterialView> materials) {
    }

    private record ActionDraft(UUID actionId, ActionGroup group, BigDecimal qty) {
    }

    private record ActionSequence(int generation, UUID predecessorId) {
    }

    private record CommandReplay(String payload) {
    }
}
