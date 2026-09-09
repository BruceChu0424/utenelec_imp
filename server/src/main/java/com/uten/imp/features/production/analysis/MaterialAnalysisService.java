package com.uten.imp.features.production.analysis;

import com.uten.imp.application.port.SubcontractPreparationPort;
import com.uten.imp.application.port.ProductionMutationFootprintPort;
import com.uten.imp.application.concurrency.FulfillmentMutationLockPlan;
import com.uten.imp.application.concurrency.FulfillmentMutationLocks;
import com.uten.imp.common.util.NativeQueryResults;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.features.production.ProductionDocumentAccessPolicy;
import com.uten.imp.features.production.fulfillment.PlanningPackageFingerprint;
import com.uten.imp.security.OwnerVisibility;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.math.RoundingMode;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.time.ZoneOffset;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.HashMap;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Objects;
import java.util.Optional;
import java.util.PriorityQueue;
import java.util.Set;
import java.util.TreeSet;
import java.util.UUID;
import java.util.stream.Collectors;

import static com.uten.imp.features.production.analysis.MaterialAnalysisContracts.*;

/**
 * Persistent, non-authoritative pre-plan material analysis.
 *
 * <p>The original recursive tree retains each batch's material requirements.
 * Child items anchor plans without owning another copy of that tree. Qualified
 * stock and formal material reservations cover their original nodes only.</p>
 */
@Service
@RequiredArgsConstructor
public class MaterialAnalysisService {

    static final String STATUS_ACTIVE = "ACTIVE";
    static final String STATUS_PARTIAL = "PARTIALLY_PLANNED";
    static final String SOURCE_SALES = "SALES_ORDER_ITEM";
    static final String SOURCE_MAKE_COMPONENT = "MAKE_COMPONENT";
    static final String SOURCE_SUBCONTRACT_PREPARATION =
            "SUBCONTRACT_PREPARATION";
    static final String SOURCE_SUBCONTRACT_MAKE = "SUBCONTRACT_MAKE";
    static final String STAGE_START = "START";
    static final String STAGE_ASSEMBLY = "ASSEMBLY";
    static final String STAGE_FINISH = "FINISH";
    static final String STAGE_SHIP = "SHIP";
    static final String STAGE_REFERENCE = "REFERENCE";
    static final Set<String> HARD_COMMITMENT_STAGES = Set.of(
            STAGE_START, STAGE_ASSEMBLY, STAGE_FINISH);

    private final EntityManager em;
    private final SecurityContextCurrentUser currentUser;
    private final TxSessionVars tx;
    private final ProductionDocumentAccessPolicy access;
    private final OwnerVisibility ownerVisibility;
    private final SubcontractPreparationPort subcontractPreparation;
    private final com.uten.imp.features.notice.ChainNoticeService chainNotice;
    private final PreplanStockEntitlementService stockEntitlement;
    private final MaterialAnalysisFlowStageService flowStages;
    private final FulfillmentMutationLocks mutationLocks;
    private final ProductionMutationFootprintPort mutationFootprints;
    @org.springframework.beans.factory.annotation.Autowired
    private MaterialAnalysisRootSupplyService rootSupply;
    @org.springframework.beans.factory.annotation.Autowired
    private com.uten.imp.features.production.SubcontractDraftPreparationAccessPolicy draftPreparationAccess;

    OwnerVisibility.OwnerScope scopeForAnalysis(AnalysisHeader header){
        var normal=access.scope();
        if(normal==null||normal.seeAll()||normal.writableOwners().contains(header.makerId()))return normal;
        return draftPreparationAccess.canAccess(header.id())?new OwnerVisibility.OwnerScope(true,Set.of()):normal;
    }

    /**
     * 物料分析的创建与刷新入口：按来源重算分配树。幂等键命中既有分析时直接重放；新建走 per(员工+幂等键) advisory 锁，
     * 可复用来源相同的进行中分析；刷新时来源、仓库变化须一并重算。
     */
    @Transactional
    public AnalysisView preview(PreviewRequest request) {
        return previewInternal(request, false);
    }

    /** System-only entry used by the same-package subcontract preparation coordinator. */
    @Transactional
    AnalysisView previewSubcontractPreparation(PreviewRequest request) {
        return previewInternal(request, true);
    }

    private AnalysisView previewInternal(
            PreviewRequest request, boolean allowSubcontractPreparation) {
        tx.bind();
        if (request == null || request.items() == null || request.items().isEmpty()) {
            throw validation("至少选择一个生产需求来源");
        }
        List<UUID> participatingWarehouses = normalizeParticipatingWarehouses(
                request.warehouseId(), request.warehouseIds());
        List<PreviewItem> normalized = normalizePreviewItems(
                request.items(), allowSubcontractPreparation, request.analysisId());
        if (!allowSubcontractPreparation && normalized.stream().anyMatch(item ->
                SOURCE_SUBCONTRACT_PREPARATION.equals(sourceType(item)))) {
            requireSubcontractPreparationRefresh(request, normalized);
        }
        String requestHash = previewRequestHash(
                request, normalized, participatingWarehouses);
        var previewGuard = mutationLocks.acquire(() -> previewMutationFootprint(
                request,normalized,participatingWarehouses));
        UUID completedPreview = request.analysisId()==null
                ? analysisByInitialIdempotencyKey(request.idempotencyKey()) : request.analysisId();
        if (completedPreview!=null && isCommandReplay(completedPreview,"PREVIEW",request.idempotencyKey(),requestHash)) {
            AnalysisHeader replayHeader = readHeader(completedPreview,false);
            access.requireWritable(replayHeader.makerId(),"只能打开本人负责的物料分析",scopeForAnalysis(replayHeader));
            return detailInternal(completedPreview,false);
        }
        previewGuard.verifyUnchanged();
        for(var item:normalized)if(SOURCE_SUBCONTRACT_PREPARATION.equals(sourceType(item))&&item.sourceRef().startsWith("SC-ORDER:"))
            requireDirectSubcontractSource(request,item);
        lockSourceIdentities(normalized);
        lockSalesSources(normalized.stream()
                .filter(item -> SOURCE_SALES.equals(sourceType(item)))
                .map(PreviewItem::salesOrderItemId)
                .toList());

        UUID analysisId = request.analysisId();
        if (analysisId == null) {
            String lockKey = currentUser.requireEmployeeId() + ":" + request.idempotencyKey();
            em.createNativeQuery("SELECT pg_advisory_xact_lock(hashtextextended(:key,0))")
                    .setParameter("key", lockKey).getSingleResult();
            UUID initialReplay = analysisByInitialIdempotencyKey(request.idempotencyKey());
            if (initialReplay != null) {
                AnalysisHeader replayHeader = lockHeader(initialReplay);
                access.requireWritable(replayHeader.makerId(),
                        "只能打开本人负责的物料分析", scopeForAnalysis(replayHeader));
                if (!isCommandReplay(initialReplay, "PREVIEW",
                        request.idempotencyKey(), requestHash)) {
                    throw conflict("首次预览幂等锚缺少结果，不能安全重放");
                }
                return detailInternal(initialReplay, false);
            }
        }
        if (analysisId != null) {
            AnalysisHeader requestedHeader = lockHeader(analysisId);
            access.requireWritable(requestedHeader.makerId(), "只能刷新本人负责的物料分析",
                    scopeForAnalysis(requestedHeader));
            if (isCommandReplay(analysisId, "PREVIEW", request.idempotencyKey(), requestHash)) {
                return detailInternal(analysisId, false);
            }
            requireCurrent(requestedHeader, request.version(), request.fingerprint());
            requireSameSources(analysisId, normalized);
        } else {
            if (request.version() != null || request.fingerprint() != null) {
                throw validation("新建分析不能携带旧版本；刷新时 analysisId/version/fingerprint 必须同时提交");
            }
            analysisId = findReusableAnalysis(normalized);
            if (analysisId != null) {
                AnalysisHeader reusable = lockHeader(analysisId);
                access.requireWritable(reusable.makerId(),
                        "只能打开本人负责的进行中物料分析", scopeForAnalysis(reusable));
                requireReusablePayloadMatches(
                        analysisId, reusable, request.warehouseId(),
                        participatingWarehouses, normalized);
                if (!isCommandReplay(analysisId, "PREVIEW",
                        request.idempotencyKey(), requestHash)) {
                    recordSimpleCommand(analysisId, "PREVIEW",
                            request.idempotencyKey(), requestHash);
                }
                return detailInternal(analysisId, false);
            }
        }
        Map<UUID, BigDecimal> previousMakeAnchorRequirements = Map.of();
        if (analysisId == null) {
            analysisId = UUID.randomUUID();
            mutationLocks.expectCreatedAnalysis(analysisId);
            em.createNativeQuery("""
                    INSERT INTO production_material_analyses (
                        id, warehouse_id, participating_warehouse_ids,
                        status, version, fingerprint,
                        initial_idempotency_key, analyzed_at, maker_id,
                        created_by, updated_by
                    ) VALUES (
                        :id, :warehouseId,
                        CAST(string_to_array(:warehouseIds, ',') AS uuid[]),
                        'ACTIVE', 0, :fingerprint,
                        :idempotencyKey, now(), :makerId, :actorId, :actorId
                    )
                    """)
                    .setParameter("id", analysisId)
                    .setParameter("warehouseId", request.warehouseId())
                    .setParameter("warehouseIds", warehouseIdsParameter(
                            participatingWarehouses))
                    .setParameter("fingerprint", PlanningPackageFingerprint.sha256(
                            List.of("MATERIAL-ANALYSIS-PENDING", analysisId.toString())))
                    .setParameter("idempotencyKey", request.idempotencyKey())
                    .setParameter("makerId", currentUser.requireEmployeeId())
                    .setParameter("actorId", currentUser.requireId())
                    .executeUpdate();
            insertSourceItems(analysisId, normalized);
            UUID mainWarehouseId = (UUID) em.createNativeQuery("SELECT fn_warehouse_main_id(:warehouseId)",UUID.class)
                    .setParameter("warehouseId",request.warehouseId()).getSingleResult();
            mutationLocks.registerCreatedAnalysis(analysisId,mainWarehouseId);
            // V477 办结闭环：分析创建即视为生产部已接手——按订单撤回
            // 「新订单待物料分析」待办（幂等；刷新/重放分支不会走到这里）。
            resolvePendingMaterialAnalysisNotices(normalized);
        } else {
            AnalysisHeader header = lockHeader(analysisId);
            access.requireWritable(header.makerId(), "只能刷新本人负责的物料分析",
                    scopeForAnalysis(header));
            previousMakeAnchorRequirements = makeAnchorParentRequirements(analysisId);
            boolean sameWarehouseScope = samePlanningWarehouseScope(header.warehouseId(),
                    participatingWarehouseIds(analysisId, header.warehouseId()),
                    request.warehouseId(), participatingWarehouses);
            syncRequestedQuantities(analysisId, normalized, sameWarehouseScope);
            em.createNativeQuery("""
                    UPDATE production_material_analyses
                    SET warehouse_id = :warehouseId,
                        participating_warehouse_ids =
                            CAST(string_to_array(:warehouseIds, ',') AS uuid[]),
                        updated_at = now(),
                        updated_by = :actorId
                    WHERE id = :id
                    """)
                    .setParameter("warehouseId", request.warehouseId())
                    .setParameter("warehouseIds", warehouseIdsParameter(
                            participatingWarehouses))
                    .setParameter("actorId", currentUser.requireId())
                    .setParameter("id", analysisId)
                    .executeUpdate();
        }
        validateSourceCapacity(loadSourceLines(analysisId, false));
        refreshLocked(analysisId);
        if (growMakeAnchorQuotasAfterSourcePreview(analysisId, previousMakeAnchorRequirements)) {
            refreshLocked(analysisId);
        }
        recordSimpleCommand(analysisId, "PREVIEW", request.idempotencyKey(), requestHash);
        return detailInternal(analysisId, false);
    }

    /**
     * 新建分析后按销售订单办结「新订单待物料分析」通知（V477）。
     *
     * <p>通知发布时绑定 (SALES_ORDER, orderId) 聚合（见 ChainNoticeService
     * #notifyOrderApproved 与 ReviewNoticeCatalog 的 SALES_ORDER_APPROVED
     * 注册）；此处把来源销售订单逐个 resolve——弹卡停止展示、通知中心灰显
     * 「已办结」。幂等（UPDATE 只命中 resolved_at IS NULL），刷新/重放不触发。
     */
    private void resolvePendingMaterialAnalysisNotices(List<PreviewItem> normalized) {
        List<UUID> salesOrderItemIds = normalized.stream()
                .filter(item -> SOURCE_SALES.equals(sourceType(item)))
                .map(PreviewItem::salesOrderItemId)
                .filter(java.util.Objects::nonNull)
                .toList();
        if (salesOrderItemIds.isEmpty()) return;
        @SuppressWarnings("unchecked")
        List<UUID> orderIds = em.createNativeQuery(
                """
                SELECT DISTINCT i.order_id FROM sales_order_items i
                WHERE i.id IN (:ids)
                """)
                .setParameter("ids", salesOrderItemIds)
                .getResultList();
        for (UUID orderId : orderIds) {
            chainNotice.resolveReviewNotices("SALES_ORDER", orderId,
                    "MATERIAL_ANALYSIS_STARTED");
        }
    }

    @Transactional(readOnly = true)
    public AnalysisView detail(UUID analysisId) {
        return detailInternal(analysisId, true);
    }

    /**
     * 货品 → 最近一次分析确认的供应路线（路线「学习预填」）：同一货品按
     * 颜色+单位维度各取最新一条 confirmed_route（无建议路线或上次确认与建议
     * 不同的物料，前端用记忆默认带出并提醒核对）。只读、无行级隔离——
     * 路线选择是计划口径知识，跨分析共享。
     */
    @Transactional(readOnly = true)
    public java.util.Map<String, java.util.List<LastRoutePerGoods>> lastRoutesPerGoods(
            java.util.Set<UUID> goodsIds) {
        if (goodsIds.isEmpty()) {
            return java.util.Map.of();
        }
        var query = em.createNativeQuery("""
                WITH history AS (
                    SELECT m.goods_id,m.color_id,m.unit_id,m.confirmed_route,m.route_reason,
                      DENSE_RANK() OVER (
                        PARTITION BY m.goods_id,m.color_id,m.unit_id
                        ORDER BY COALESCE(m.route_confirmed_at,m.created_at) DESC) AS recency
                    FROM production_material_analysis_materials m
                    JOIN production_material_analyses a ON a.id=m.analysis_id
                    WHERE m.goods_id IN (:goodsIds) AND m.confirmed_route IS NOT NULL
                      AND a.is_deleted=FALSE AND a.status<>'CANCELLED'
                )
                SELECT goods_id,color_id,unit_id,MIN(confirmed_route),
                  CASE WHEN COUNT(DISTINCT route_reason)=1 THEN MIN(route_reason) ELSE NULL END
                FROM history WHERE recency=1
                GROUP BY goods_id,color_id,unit_id
                HAVING COUNT(DISTINCT confirmed_route)=1
                ORDER BY goods_id,color_id,unit_id
                """);
        query.setParameter("goodsIds", goodsIds);
        java.util.Map<String, java.util.List<LastRoutePerGoods>> result = new java.util.LinkedHashMap<>();
        for (Object[] row : NativeQueryResults.objectArrayRows(query)) {
            UUID goodsId = (UUID) row[0];
            result.computeIfAbsent(goodsId.toString(), key -> new java.util.ArrayList<>())
                    .add(new LastRoutePerGoods((UUID) row[1], (UUID) row[2],
                            (String) row[3], (String) row[4]));
        }
        return result;
    }

    /** 货品一个颜色+单位维度的最近确认路线（route 为 BUY/SUBCONTRACT/MAKE）。 */
    public record LastRoutePerGoods(UUID colorId, UUID unitId, String route, String reason) {}

    /**
     * 物料分析分页列表：按关键字/状态/来源筛选，结果按 maker_id 行级隔离，仅返回当前用户有权可见的分析。
     */
    @Transactional(readOnly = true)
    public PageResponse<AnalysisListItem> list(
            String keyword, String status, String sourceType, int page, int size) {
        int safePage = Math.max(1, page);
        int safeSize = Math.min(Math.max(1, size), 100);
        String normalizedKeyword = blankToNull(keyword) == null
                ? "" : keyword.strip().toLowerCase(Locale.ROOT);
        String normalizedStatus = blankToNull(status) == null
                ? "" : status.strip().toUpperCase(Locale.ROOT);
        String normalizedSource = blankToNull(sourceType) == null
                ? "" : sourceType.strip().toUpperCase(Locale.ROOT);
        if (!normalizedStatus.isEmpty()
                && !Set.of("ACTIVE", "PARTIALLY_PLANNED", "COMPLETED", "CANCELLED")
                .contains(normalizedStatus)) {
            throw validation("物料分析状态筛选值无效");
        }
        if (!normalizedSource.isEmpty()
                && !Set.of(SOURCE_SALES, "REWORK", "TRIAL", "SAMPLE", "STOCK",
                        "OTHER", SOURCE_MAKE_COMPONENT,
                        SOURCE_SUBCONTRACT_PREPARATION,
                        SOURCE_SUBCONTRACT_MAKE).contains(normalizedSource)) {
            throw validation("生产需求来源筛选值无效");
        }
        var ownerScope = access.nativeReadScope(
                "analysis.maker_id", "analysisOwners", access.scope());
        String filters = """
                FROM production_material_analyses analysis
                WHERE analysis.is_deleted = FALSE
                  AND (:status = '' OR analysis.status = :status)
                  AND (%s)

                  AND EXISTS (
                      SELECT 1
                      FROM production_material_analysis_items source
                      JOIN goods goods ON goods.id = source.goods_id
                      LEFT JOIN sales_order_items sales_item
                        ON sales_item.id = source.sales_order_item_id
                      LEFT JOIN sales_orders sales_order
                        ON sales_order.id = sales_item.order_id
                      WHERE source.analysis_id = analysis.id
                        AND source.is_deleted = FALSE
                        AND (:sourceType = '' OR source.source_type = :sourceType)
                        AND (:keyword = '' OR
                             lower(COALESCE(source.source_ref,'')) LIKE :keywordLike OR
                             lower(COALESCE(goods.code,'')) LIKE :keywordLike OR
                             lower(COALESCE(goods.name,'')) LIKE :keywordLike OR
                             lower(COALESCE(sales_order.bill_no,'')) LIKE :keywordLike)
                  )
                """.formatted(draftPreparationAccess.readPredicate("analysis.id",ownerScope.predicate()));
        Query countQuery = em.createNativeQuery("SELECT COUNT(*) " + filters)
                .setParameter("status", normalizedStatus)
                .setParameter("sourceType", normalizedSource)
                .setParameter("keyword", normalizedKeyword)
                .setParameter("keywordLike", "%" + normalizedKeyword + "%");
        ownerScope.bind(countQuery);
        long total = ((Number) countQuery.getSingleResult()).longValue();
        int totalPages = total == 0 ? 0 : (int) ((total + safeSize - 1) / safeSize);
        if (totalPages > 0 && safePage > totalPages) safePage = totalPages;

        Query dataQuery = em.createNativeQuery("""
                SELECT analysis.id, analysis.status, analysis.version,
                       analysis.fingerprint, analysis.warehouse_id,
                       warehouse.code, warehouse.name, analysis.analyzed_at,
                       analysis.updated_at, analysis.maker_id, maker.full_name,
                       COUNT(source.id),
                       string_agg(DISTINCT source.source_type, chr(31)),
                       string_agg(DISTINCT COALESCE(
                           NULLIF(btrim(source.source_ref),''), sales_order.bill_no), chr(31)),
                       string_agg(DISTINCT concat_ws(' ', goods.code, goods.name), chr(31)),
                       COALESCE(SUM(source.requested_qty),0),
                       COALESCE(SUM(source.submitted_qty),0),
                       COALESCE(SUM(source.approved_qty),0),
                       COALESCE(SUM(GREATEST(source.requested_qty
                           -source.submitted_qty-source.approved_qty,0)),0),
                       COALESCE(SUM(source.ready_now_qty),0),
                       COALESCE(SUM(source.ready_by_date_qty),0)
                FROM production_material_analyses analysis
                JOIN warehouses warehouse ON warehouse.id = analysis.warehouse_id
                LEFT JOIN employees maker ON maker.id = analysis.maker_id
                JOIN production_material_analysis_items source
                  ON source.analysis_id = analysis.id AND source.is_deleted = FALSE
                JOIN goods goods ON goods.id = source.goods_id
                LEFT JOIN sales_order_items sales_item
                  ON sales_item.id = source.sales_order_item_id
                LEFT JOIN sales_orders sales_order
                  ON sales_order.id = sales_item.order_id
                WHERE analysis.id IN (
                    SELECT analysis.id
                    """ + filters + """
                )
                GROUP BY analysis.id, warehouse.code, warehouse.name, maker.full_name
                ORDER BY analysis.analyzed_at DESC, analysis.id DESC
                LIMIT :limit OFFSET :offset
                """)
                .setParameter("status", normalizedStatus)
                .setParameter("sourceType", normalizedSource)
                .setParameter("keyword", normalizedKeyword)
                .setParameter("keywordLike", "%" + normalizedKeyword + "%")
                .setParameter("limit", safeSize)
                .setParameter("offset", (safePage - 1) * safeSize);
        ownerScope.bind(dataQuery);
        List<AnalysisListItem> items = NativeQueryResults.objectArrayRows(dataQuery).stream()
                .map(row -> new AnalysisListItem(
                        uuid(row[0]), string(row[1]), ((Number) row[2]).longValue(),
                        string(row[3]), uuid(row[4]), string(row[5]), string(row[6]),
                        offsetDateTime(row[7]), offsetDateTime(row[8]), uuid(row[9]),
                        string(row[10]), integer(row[11]), splitAggregate(string(row[12])),
                        splitAggregate(string(row[13])), splitAggregate(string(row[14])),
                        decimal(row[15]), decimal(row[16]), decimal(row[17]),
                        decimal(row[18]), decimal(row[19]), decimal(row[20])))
                .toList();
        return new PageResponse<>(items, safePage, safeSize, total, totalPages);
    }

    /**
     * 保存物料供给路线（按操作组）：幂等重放 + 乐观版本校验。操作组已有不同路线的下游任务时禁止改路线（须先撤回）；
     * 原因可选；确认人和确认时间始终保留，已有下游的路线仍须先撤回。
     */
    @Transactional
    public AnalysisView saveRoutes(UUID analysisId, RouteRequest request) {
        tx.bind();
        AnalysisHeader header = lockHeader(analysisId);
        access.requireWritable(header.makerId(), "只能维护本人负责的物料分析",
                scopeForAnalysis(header));
        String requestHash = routeRequestHash(analysisId, request);
        if (isCommandReplay(analysisId, "ROUTE", request.idempotencyKey(), requestHash)) {
            return detailInternal(analysisId, false);
        }
        requireCurrent(header, request.version(), request.fingerprint());
        Set<String> seen = new HashSet<>();
        List<MaterialRow> currentMaterials = loadMaterialRows(analysisId);
        List<RouteDecision> decisions = request.decisions() == null
                ? List.of() : request.decisions();
        List<SourceLine> routeSources = loadSourceLines(analysisId, false);
        for (RouteDecision decision : decisions) {
            List<MaterialRow> group = resolveMaterialGroup(currentMaterials, decision);
            requirePlanningSources(routeSources, group.stream()
                    .map(MaterialRow::analysisItemId).collect(Collectors.toSet()));
            String groupKey = group.getFirst().actionGroupKey();
            if (!seen.add(groupKey)) throw validation("物料路线操作组重复");
            String route = normalizeRoute(decision.route());
            String reason = normalizeRouteReason(decision.reason());
            List<UUID> groupMaterialIds = group.stream().map(MaterialRow::id).toList();
            Number downstream = (Number) em.createNativeQuery("""
                    SELECT COUNT(*)
                    FROM preplan_supply_actions action
                    WHERE action.analysis_id = :analysisId
                      AND action.status <> 'CANCELLED'
                      AND action.route IS DISTINCT FROM :route
                      AND (
                          action.action_group_key = :groupKey
                          OR EXISTS (
                              SELECT 1
                              FROM preplan_supply_action_allocations allocation
                              WHERE allocation.action_id = action.id
                                AND allocation.analysis_material_id IN (:materialIds)
                          )
                      )
                    """)
                    .setParameter("analysisId", analysisId)
                    .setParameter("groupKey", groupKey)
                    .setParameter("materialIds", groupMaterialIds)
                    .setParameter("route", route)
                    .getSingleResult();
            if (downstream.longValue() > 0) {
                throw conflict("物料操作组已有不同路线的下游任务，请先撤回后再改路线");
            }
            for (MaterialRow material : group) {
                em.createNativeQuery("""
                        UPDATE production_material_analysis_materials
                        SET confirmed_route = :route,
                            route_reason = :reason,
                            route_confirmed_by = :actorId,
                            route_confirmed_at = now(),
                            updated_at = now(), updated_by = :actorId
                        WHERE id = :materialId AND analysis_id = :analysisId
                          AND active = TRUE
                        """)
                        .setParameter("route", route)
                        .setParameter("reason", reason)
                        .setParameter("actorId", currentUser.requireId())
                        .setParameter("materialId", material.id())
                        .setParameter("analysisId", analysisId)
                        .executeUpdate();
            }
        }
        refreshLocked(analysisId);
        recordSimpleCommand(analysisId, "ROUTE", request.idempotencyKey(), requestHash);
        return detailInternal(analysisId, false);
    }

    /**
     * 设置产品分配优先级：必须为当前全部产品的 1..N 完整排列且取值唯一，产品集合变化即拒绝，
     * 以保证齐套分配的消耗顺序可被稳定复算。
     */
    @Transactional
    public AnalysisView saveAllocationPriorities(
            UUID analysisId, AllocationPriorityRequest request) {
        tx.bind();
        AnalysisHeader header = lockHeader(analysisId);
        access.requireWritable(header.makerId(),
                "只能调整本人负责的物料分析分配顺序", scopeForAnalysis(header));
        String requestHash = allocationPriorityRequestHash(analysisId, request);
        if (isCommandReplay(
                analysisId, "REALLOCATE", request.idempotencyKey(), requestHash)) {
            return detailInternal(analysisId, false);
        }
        requireCurrent(header, request.version(), request.fingerprint());

        @SuppressWarnings("unchecked")
        List<UUID> currentIds = (List<UUID>) em.createNativeQuery("""
                SELECT id
                FROM production_material_analysis_items
                WHERE analysis_id = :analysisId AND is_deleted = FALSE
                ORDER BY id
                FOR UPDATE
                """).setParameter("analysisId", analysisId).getResultList();
        Set<UUID> currentSet = Set.copyOf(currentIds);
        Map<UUID, Integer> priorities = new LinkedHashMap<>();
        Set<Integer> priorityValues = new HashSet<>();
        for (AllocationPriorityItem item : request.items()) {
            if (item == null || item.analysisLineId() == null
                    || !currentSet.contains(item.analysisLineId())) {
                throw conflict("产品集合已变化，请重新加载物料分析");
            }
            if (priorities.putIfAbsent(item.analysisLineId(), item.priority()) != null) {
                throw validation("同一产品不能重复提交分配优先级");
            }
            if (!priorityValues.add(item.priority())) {
                throw validation("产品分配优先级必须唯一");
            }
        }
        if (priorities.size() != currentIds.size()
                || !priorities.keySet().containsAll(currentSet)) {
            throw conflict("产品集合已变化，请重新加载物料分析");
        }
        Set<Integer> expectedPriorities = new HashSet<>();
        for (int i = 1; i <= currentIds.size(); i++) expectedPriorities.add(i);
        if (!priorityValues.equals(expectedPriorities)) {
            throw validation("产品分配优先级必须是 1 到 N 的完整序列");
        }
        priorities.forEach((lineId, priority) -> em.createNativeQuery("""
                UPDATE production_material_analysis_items
                SET line_priority = :priority, updated_at = now(), updated_by = :actorId
                WHERE id = :lineId AND analysis_id = :analysisId AND is_deleted = FALSE
                """)
                .setParameter("priority", priority)
                .setParameter("actorId", currentUser.requireId())
                .setParameter("lineId", lineId)
                .setParameter("analysisId", analysisId)
                .executeUpdate());
        refreshLocked(analysisId);
        recordSimpleCommand(
                analysisId, "REALLOCATE", request.idempotencyKey(), requestHash);
        return detailInternal(analysisId, false);
    }

    /**
     * 现货层借用（调货）：把借出节点已分配的合格现货覆盖量调拨给同一分析内
     * 另一产品的同物料直接组件路径。只影响分析软分配与齐套投影；已下达
     * 采购/委外/自制任务或已委派 MAKE 子任务的节点不允许调拨。
     */
    @Transactional
    public AnalysisView createBorrow(UUID analysisId, BorrowRequest request) {
        tx.bind();
        AnalysisHeader header = lockHeader(analysisId);
        access.requireWritable(header.makerId(),
                "只能调整本人负责的物料分析分配", scopeForAnalysis(header));
        String requestHash = borrowRequestHash(analysisId, request);
        if (isCommandReplay(
                analysisId, "BORROW", request.idempotencyKey(), requestHash)) {
            return detailInternal(analysisId, false);
        }
        requireCurrent(header, request.version(), request.fingerprint());
        if (request.fromMaterialLineId().equals(request.toMaterialLineId())) {
            throw validation("借出与借入不能是同一条物料路径");
        }

        List<MaterialRow> materials = loadMaterialRows(analysisId);
        MaterialRow from = materials.stream()
                .filter(row -> row.id().equals(request.fromMaterialLineId()))
                .findFirst()
                .orElseThrow(() -> validation("借出物料路径不存在或已失效，请刷新后重试"));
        MaterialRow to = materials.stream()
                .filter(row -> row.id().equals(request.toMaterialLineId()))
                .findFirst()
                .orElseThrow(() -> validation("借入物料路径不存在或已失效，请刷新后重试"));
        validateBorrowEndpoints(analysisId, from, to);
        requirePlanningSources(analysisId, Set.of(to.analysisItemId()));
        BigDecimal qty = request.qty().setScale(4, RoundingMode.DOWN);
        if (qty.signum() <= 0) {
            throw validation("调拨数量必须大于 0");
        }
        if (from.allocatedAvailableQty().compareTo(qty) < 0) {
            throw conflict("借出方当前已分配现货不足，最多可调 "
                    + from.allocatedAvailableQty().stripTrailingZeros().toPlainString());
        }
        if (to.shortageQty().compareTo(qty) < 0) {
            throw conflict("调拨数量不能超过借入方当前缺口(缺 "
                    + to.shortageQty().stripTrailingZeros().toPlainString() + ")");
        }

        UUID borrowId = UUID.randomUUID();
        em.createNativeQuery("""
                INSERT INTO production_material_analysis_borrows (
                    id, analysis_id, from_material_id, to_material_id,
                    goods_id, color_id, unit_id, qty, reason,
                    status, last_effective_qty, idempotency_key,
                    created_by, updated_at
                ) VALUES (
                    :id, :analysisId, :fromId, :toId,
                    :goodsId, :colorId, :unitId, :qty, :reason,
                    'ACTIVE', 0, :idempotencyKey,
                    :actorId, now()
                )
                """)
                .setParameter("id", borrowId)
                .setParameter("analysisId", analysisId)
                .setParameter("fromId", from.id())
                .setParameter("toId", to.id())
                .setParameter("goodsId", from.goodsId())
                .setParameter("colorId", from.colorId())
                .setParameter("unitId", from.unitId())
                .setParameter("qty", qty)
                .setParameter("reason", request.reason().strip())
                .setParameter("idempotencyKey", request.idempotencyKey())
                .setParameter("actorId", currentUser.requireId())
                .executeUpdate();
        refreshLocked(analysisId);
        recordSimpleCommand(
                analysisId, "BORROW", request.idempotencyKey(), requestHash);
        return detailInternal(analysisId, false);
    }

    /** 撤销一笔 ACTIVE 借用：恢复基线分配投影，追加式留痕不物理删除。 */
    @Transactional
    public AnalysisView revokeBorrow(
            UUID analysisId, UUID borrowId, CancelRequest request) {
        tx.bind();
        AnalysisHeader header = lockHeader(analysisId);
        access.requireWritable(header.makerId(),
                "只能调整本人负责的物料分析分配", scopeForAnalysis(header));
        String requestHash = PlanningPackageFingerprint.sha256(List.of(
                "BORROW_REVOKE", analysisId.toString(), borrowId.toString(),
                request.reason().strip()));
        if (isCommandReplay(analysisId, "BORROW_REVOKE",
                request.idempotencyKey(), requestHash)) {
            return detailInternal(analysisId, false);
        }
        requireCurrent(header, request.version(), request.fingerprint());
        List<?> existing = em.createNativeQuery("""
                SELECT status
                FROM production_material_analysis_borrows
                WHERE id = :borrowId AND analysis_id = :analysisId
                """)
                .setParameter("borrowId", borrowId)
                .setParameter("analysisId", analysisId)
                .getResultList();
        if (existing.isEmpty()) {
            throw validation("借用记录不存在，请刷新后重试");
        }
        if (!"ACTIVE".equals(Objects.toString(existing.getFirst(), ""))) {
            throw conflict("该借用已被撤销，不能重复操作");
        }
        em.createNativeQuery("""
                UPDATE production_material_analysis_borrows
                SET status = 'REVOKED', revoked_by = :actorId, revoked_at = now(),
                    revoke_reason = :reason
                WHERE id = :borrowId AND analysis_id = :analysisId
                  AND status = 'ACTIVE'
                """)
                .setParameter("actorId", currentUser.requireId())
                .setParameter("reason", request.reason().strip())
                .setParameter("borrowId", borrowId)
                .setParameter("analysisId", analysisId)
                .executeUpdate();
        refreshLocked(analysisId);
        recordSimpleCommand(analysisId, "BORROW_REVOKE",
                request.idempotencyKey(), requestHash);
        return detailInternal(analysisId, false);
    }

    /** 借用端点校验：同维度、跨产品、直接组件层、无在途任务、无 MAKE 委派。 */
    private void validateBorrowEndpoints(
            UUID analysisId, MaterialRow from, MaterialRow to) {
        if (from.depth() != 1 || to.depth() != 1) {
            throw validation("目前只支持直接组件层的现货调拨");
        }
        if (!Objects.equals(from.goodsId(), to.goodsId())
                || !Objects.equals(from.colorId(), to.colorId())
                || !Objects.equals(from.unitId(), to.unitId())) {
            throw validation("只能调拨完全相同(货品+颜色+单位)的物料");
        }
        if (from.analysisItemId().equals(to.analysisItemId())) {
            throw validation("同一产品内的路径共享同一分配，不需要调拨");
        }
        if (STAGE_SHIP.equals(from.controlStage())
                || STAGE_REFERENCE.equals(from.controlStage())
                || STAGE_SHIP.equals(to.controlStage())
                || STAGE_REFERENCE.equals(to.controlStage())) {
            throw validation("发货参考类物料不参与生产齐套，不需要调拨");
        }
        List<UUID> pair = List.of(from.id(), to.id());
        Number activeActions = (Number) em.createNativeQuery("""
                SELECT COUNT(*)
                FROM preplan_supply_action_allocations allocation
                JOIN preplan_supply_actions action ON action.id = allocation.action_id
                WHERE action.status <> 'CANCELLED'
                  AND allocation.analysis_material_id IN (:ids)
                """).setParameter("ids", pair).getSingleResult();
        if (activeActions.longValue() > 0) {
            throw conflict("已下达采购/委外/自制任务的节点不能调拨，请先撤回对应任务");
        }
        Set<String> delegated = Set.<String>of();
        if (delegated.contains(from.analysisItemId() + "|" + from.path())
                || delegated.contains(to.analysisItemId() + "|" + to.path())) {
            throw conflict("已委派给自制子任务的节点不能调拨");
        }
    }

    /**
     * Fail closed after the current BOM has been upserted but before allocation is
     * recomputed. An ACTIVE borrow is historical evidence tied to two exact endpoint
     * rows and one immutable material dimension. Silently skipping an endpoint that a
     * refresh made inactive would leave stale effective quantities and hide the revoke
     * path; reusing the row after a BOM dimension change would move coverage between
     * different materials. Throwing here rolls the whole refresh back, preserving the
     * previous snapshot so the operator can revoke the borrow and retry.
     */
    void validateActiveBorrowEndpointsAfterRefresh(UUID analysisId) {
        Number invalid = (Number) em.createNativeQuery("""
                SELECT COUNT(*)
                FROM production_material_analysis_borrows borrow
                LEFT JOIN production_material_analysis_materials fromMaterial
                  ON fromMaterial.id = borrow.from_material_id
                LEFT JOIN production_material_analysis_materials toMaterial
                  ON toMaterial.id = borrow.to_material_id
                LEFT JOIN production_material_analysis_items fromItem
                  ON fromItem.id = fromMaterial.analysis_item_id
                LEFT JOIN production_material_analysis_items toItem
                  ON toItem.id = toMaterial.analysis_item_id
                WHERE borrow.analysis_id = :analysisId
                  AND borrow.status = 'ACTIVE'
                  AND (
                    fromMaterial.id IS NULL OR toMaterial.id IS NULL
                    OR fromMaterial.analysis_id <> borrow.analysis_id
                    OR toMaterial.analysis_id <> borrow.analysis_id
                    OR fromMaterial.active IS DISTINCT FROM TRUE
                    OR toMaterial.active IS DISTINCT FROM TRUE
                    OR fromItem.id IS NULL OR toItem.id IS NULL
                    OR fromItem.analysis_id <> borrow.analysis_id
                    OR toItem.analysis_id <> borrow.analysis_id
                    OR fromItem.is_deleted IS DISTINCT FROM FALSE
                    OR toItem.is_deleted IS DISTINCT FROM FALSE
                    OR fromMaterial.analysis_item_id = toMaterial.analysis_item_id
                    OR fromMaterial.depth <> 1 OR toMaterial.depth <> 1
                    OR fromMaterial.control_stage IN ('SHIP', 'REFERENCE')
                    OR toMaterial.control_stage IN ('SHIP', 'REFERENCE')
                    OR fromMaterial.goods_id IS DISTINCT FROM toMaterial.goods_id
                    OR fromMaterial.color_id IS DISTINCT FROM toMaterial.color_id
                    OR fromMaterial.unit_id IS DISTINCT FROM toMaterial.unit_id
                    OR fromMaterial.goods_id IS DISTINCT FROM borrow.goods_id
                    OR fromMaterial.color_id IS DISTINCT FROM borrow.color_id
                    OR fromMaterial.unit_id IS DISTINCT FROM borrow.unit_id
                  )
                """)
                .setParameter("analysisId", analysisId)
                .getSingleResult();
        if (invalid.longValue() > 0) {
            throw conflict("当前 BOM 已改变有效调拨的路径、产品或物料维度；"
                    + "本次刷新已安全回滚，请先撤销相关调拨后再刷新");
        }
    }

    private String borrowRequestHash(UUID analysisId, BorrowRequest request) {
        return PlanningPackageFingerprint.sha256(List.of(
                "BORROW", analysisId.toString(),
                request.fromMaterialLineId().toString(),
                request.toMaterialLineId().toString(),
                request.qty().stripTrailingZeros().toPlainString(),
                request.reason().strip()));
    }

    /** 读取 ACTIVE 借用记录及其两侧节点定位（itemId + nodeKey）与维度快照。 */
    private List<BorrowRecord> loadActiveBorrows(UUID analysisId) {
        List<Object[]> rows = NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT borrow.id, borrow.from_material_id, borrow.to_material_id,
                       fromMaterial.analysis_item_id, fromMaterial.node_key,
                       toMaterial.analysis_item_id, toMaterial.node_key,
                       borrow.goods_id, borrow.color_id, borrow.unit_id, borrow.qty
                FROM production_material_analysis_borrows borrow
                JOIN production_material_analysis_materials fromMaterial
                  ON fromMaterial.id = borrow.from_material_id
                 AND fromMaterial.active = TRUE
                JOIN production_material_analysis_materials toMaterial
                  ON toMaterial.id = borrow.to_material_id
                 AND toMaterial.active = TRUE
                WHERE borrow.analysis_id = :analysisId AND borrow.status = 'ACTIVE'
                ORDER BY borrow.created_at, borrow.id
                """).setParameter("analysisId", analysisId));
        List<BorrowRecord> records = new ArrayList<>();
        for (Object[] row : rows) {
            records.add(new BorrowRecord(
                    uuid(row[0]), uuid(row[1]), uuid(row[2]),
                    uuid(row[3]), string(row[4]), uuid(row[5]), string(row[6]),
                    new MaterialDimension(uuid(row[7]), uuid(row[8]), uuid(row[9])),
                    decimal(row[10])));
        }
        return records;
    }

    /**
     * V309 生效权益。V307 永久保存来源谱系，append-only entitlement events
     * 决定当前受益节点；物理数量真相仍只有 stock_reservations。
     */
    private List<ExactPegRecord> loadExactPegs(UUID analysisId, UUID warehouseId) {
        jakarta.persistence.Query query = em.createNativeQuery("""
                SELECT lot.entitlement_event_id,
                       lot.beneficiary_analysis_material_id,
                       material.analysis_item_id, material.node_key,
                       reservation.goods_id, reservation.color_id, material.unit_id,
                       lot.remaining_qty,reservation.warehouse_id
                FROM v_preplan_stock_entitlement_lot_balance lot
                JOIN stock_reservations reservation
                  ON reservation.id = lot.stock_reservation_id
                 AND reservation.is_deleted = FALSE
                 AND reservation.status = 0
                JOIN production_material_analysis_materials material
                  ON material.id = lot.beneficiary_analysis_material_id
                 AND material.analysis_id = lot.beneficiary_analysis_id
                WHERE lot.beneficiary_analysis_id = :analysisId
                  AND lot.remaining_qty > 0
                  AND (CAST(:warehouseId AS uuid) IS NULL
                       OR fn_warehouse_same_main(reservation.warehouse_id,CAST(:warehouseId AS uuid))
                       OR fn_preplan_reservation_has_qualified_origin(reservation.id))
                ORDER BY lot.created_at, lot.entitlement_event_id
                """)
                .setParameter("analysisId", analysisId)
                .setParameter("warehouseId", warehouseId);
        List<Object[]> rows = NativeQueryResults.objectArrayRows(query);
        List<ExactPegRecord> result = new ArrayList<>();
        for (Object[] row : rows) {
            BigDecimal effectiveQty = decimal(row[7]);
            if (effectiveQty.signum() <= 0) continue;
            result.add(new ExactPegRecord(
                    uuid(row[0]), uuid(row[1]), uuid(row[2]), string(row[3]),
                    new MaterialDimension(uuid(row[4]), uuid(row[5]), uuid(row[6])),
                    effectiveQty,uuid(row[8])));
        }
        return List.copyOf(result);
    }

    /**
     * Refresh must not orphan or silently retarget an effective exact entitlement.
     * The physical dimension comes from the immutable reservation/IQC lineage, while
     * the beneficiary identity remains the stable analysis-item + node key.
     */
    private void validateExactPegRefreshCompatibility(
            UUID analysisId, List<BomNode> nodes) {
        Map<String, MaterialDimension> current = new LinkedHashMap<>();
        for (BomNode node : nodes) {
            current.put(nodeAllocationKey(node), node.dimension());
        }
        // Root supply has its own physical node and is intentionally absent
        // from the BOM expansion. A deferred sales handoff must retain it.
        for (Object[] row : NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT item.id,root.node_key,item.goods_id,item.color_id,goods.unit_id
                FROM production_material_analysis_items item
                JOIN production_material_analysis_materials root ON root.id=item.root_material_id
                    AND root.analysis_id=item.analysis_id AND root.analysis_item_id=item.id
                    AND root.node_role='ROOT_SUPPLY'
                JOIN goods ON goods.id=item.goods_id
                WHERE item.analysis_id=:id AND NOT item.is_deleted
                """).setParameter("id", analysisId))) {
            current.put(uuid(row[0]) + "|" + string(row[1]),
                    new MaterialDimension(uuid(row[2]), uuid(row[3]), uuid(row[4])));
        }
        requireExactPegRefreshCompatible(loadExactPegs(analysisId, null), current);
    }

    static void requireExactPegRefreshCompatible(
            List<ExactPegRecord> exactPegs,
            Map<String, MaterialDimension> currentNodes) {
        for (ExactPegRecord peg : exactPegs) {
            MaterialDimension current = currentNodes.get(
                    peg.analysisItemId() + "|" + peg.nodeKey());
            if (!Objects.equals(current, peg.dimension())) {
                throw conflict("这批已入库的货还归属于原来的产品，不能直接删除或换成别的物料；"
                        + "请先核对并处理原库存的用途");
            }
        }
    }

    /** 把本次重算得出的每笔实际生效量回写借用记录（身份与申请量不可变）。 */
    private void persistBorrowEffectiveQuantities(Map<UUID, BigDecimal> effectiveByBorrow) {
        effectiveByBorrow.forEach((borrowId, effective) -> em.createNativeQuery("""
                UPDATE production_material_analysis_borrows
                SET last_effective_qty = :qty
                WHERE id = :id AND status = 'ACTIVE'
                """)
                .setParameter("qty", effective)
                .setParameter("id", borrowId)
                .executeUpdate());
    }

    /**
     * 双向可见的借用投影：每个物料行得到自己的借出/借入明细。
     * 数量取最近一次重算回写的 last_effective_qty，与节点分配快照同源。
     */
    private Map<UUID, List<BorrowRef>> activeBorrowRefsByMaterial(UUID analysisId) {
        List<Object[]> rows = NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT borrow.id, borrow.from_material_id, borrow.to_material_id,
                       borrow.last_effective_qty, borrow.qty, borrow.reason,
                       fromGoods.code, fromGoods.name, toGoods.code, toGoods.name
                FROM production_material_analysis_borrows borrow
                JOIN production_material_analysis_materials fromMaterial
                  ON fromMaterial.id = borrow.from_material_id
                JOIN production_material_analysis_materials toMaterial
                  ON toMaterial.id = borrow.to_material_id
                JOIN production_material_analysis_items fromItem
                  ON fromItem.id = fromMaterial.analysis_item_id
                JOIN production_material_analysis_items toItem
                  ON toItem.id = toMaterial.analysis_item_id
                LEFT JOIN goods fromGoods ON fromGoods.id = fromItem.goods_id
                LEFT JOIN goods toGoods ON toGoods.id = toItem.goods_id
                WHERE borrow.analysis_id = :analysisId AND borrow.status = 'ACTIVE'
                ORDER BY borrow.created_at, borrow.id
                """).setParameter("analysisId", analysisId));
        Map<UUID, List<BorrowRef>> result = new HashMap<>();
        for (Object[] row : rows) {
            UUID borrowId = uuid(row[0]);
            BigDecimal effective = decimal(row[3]);
            BigDecimal requested = decimal(row[4]);
            String reason = string(row[5]);
            String fromLabel = displayLabel(string(row[6]), string(row[7]));
            String toLabel = displayLabel(string(row[8]), string(row[9]));
            result.computeIfAbsent(uuid(row[1]), ignored -> new ArrayList<>()).add(
                    new BorrowRef(borrowId, "OUT", effective, requested,
                            toLabel, reason));
            result.computeIfAbsent(uuid(row[2]), ignored -> new ArrayList<>()).add(
                    new BorrowRef(borrowId, "IN", effective, requested,
                            fromLabel, reason));
        }
        return result;
    }

    private boolean isSubcontractPreparationAnalysis(UUID analysisId) {
        Number count = (Number) em.createNativeQuery("""
                SELECT COUNT(*)
                FROM production_material_analysis_items
                WHERE analysis_id = :analysisId
                  AND source_type = 'SUBCONTRACT_PREPARATION'
                  AND is_deleted = FALSE
                """).setParameter("analysisId", analysisId).getSingleResult();
        return count.longValue() > 0;
    }

    /**
     * 可纳入物料分析的销售订单候选：可生产量 = 未发 + 退回 − 标记 − 预留 − 超计划完工 − 在制草稿，
     * 仅保留仍有缺口的明细。
     */
    @Transactional(readOnly = true)
    public SalesCandidatePage salesCandidates(
            String keyword, int rawPage, int rawSize) {
        int page = Math.max(rawPage, 1);
        int size = Math.min(Math.max(rawSize, 1), 100);
        String kw = keyword == null ? "" : keyword.strip().toLowerCase(Locale.ROOT);
        String predicate = """
                o.status = 1 AND o.is_deleted = FALSE
                AND o.finance_confirmed = TRUE
                AND COALESCE(o.is_stopped, FALSE) = FALSE
                AND o.is_closed = FALSE
                AND i.is_deleted = FALSE
                AND g.is_deleted = FALSE
                AND GREATEST(
                    COALESCE(i.qty,0) - COALESCE(i.shipped_qty,0)
                    + COALESCE(i.returned_qty,0) - COALESCE(i.flag_qty,0)
                    - COALESCE(i.reserved_qty,0)
                    - GREATEST(COALESCE(i.planned_qty,0)
                               - COALESCE(i.produced_qty,0),0)
                    - COALESCE(draft.qty,0), 0) > 0
                """;
        if (!kw.isEmpty()) {
            predicate += " AND (lower(o.bill_no) LIKE :kw OR lower(COALESCE(c.name,'')) LIKE :kw"
                    + " OR lower(COALESCE(g.code,'')) LIKE :kw OR lower(COALESCE(g.name,'')) LIKE :kw)\n";
        }
        Query countQuery = em.createNativeQuery("""
                SELECT COUNT(DISTINCT o.id)
                FROM sales_orders o
                JOIN sales_order_items i ON i.order_id = o.id
                JOIN goods g ON g.id = i.goods_id
                LEFT JOIN clients c ON c.id = o.client_id
                LEFT JOIN LATERAL (
                    SELECT SUM(pi.qty) AS qty
                    FROM production_plan_items pi
                    JOIN production_plans p ON p.id = pi.plan_id
                    WHERE pi.sales_order_item_id = i.id
                      AND pi.is_deleted = FALSE AND p.is_deleted = FALSE
                      AND p.status = 0 AND p.is_canceled = FALSE
                ) draft ON TRUE
                WHERE
                """ + predicate);
        if (!kw.isEmpty()) countQuery.setParameter("kw", "%" + kw + "%");
        long total = ((Number) countQuery.getSingleResult()).longValue();
        Query idsQuery = em.createNativeQuery("""
                SELECT o.id
                FROM sales_orders o
                JOIN sales_order_items i ON i.order_id = o.id
                JOIN goods g ON g.id = i.goods_id
                LEFT JOIN clients c ON c.id = o.client_id
                LEFT JOIN LATERAL (
                    SELECT SUM(pi.qty) AS qty
                    FROM production_plan_items pi
                    JOIN production_plans p ON p.id = pi.plan_id
                    WHERE pi.sales_order_item_id = i.id
                      AND pi.is_deleted = FALSE AND p.is_deleted = FALSE
                      AND p.status = 0 AND p.is_canceled = FALSE
                ) draft ON TRUE
                WHERE
                """ + predicate + """
                GROUP BY o.id, o.deliver_date, o.bill_date, o.bill_no
                ORDER BY o.deliver_date NULLS LAST, o.bill_date, o.bill_no, o.id
                """);
        if (!kw.isEmpty()) idsQuery.setParameter("kw", "%" + kw + "%");
        idsQuery.setFirstResult((page - 1) * size).setMaxResults(size);
        @SuppressWarnings("unchecked")
        List<UUID> orderIds = (List<UUID>) idsQuery.getResultList();
        if (orderIds.isEmpty()) {
            return new SalesCandidatePage(List.of(), page, size, total,
                    total == 0 ? 0 : (int) ((total + size - 1) / size));
        }
        List<Object[]> rows = NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT o.id, o.bill_no, o.bill_date, o.deliver_date, c.name,
                       i.id, i.line_no, i.goods_id, g.code, g.name, g.spec,
                       i.color_id, col.name, i.unit_id, u.name,
                       COALESCE(i.qty,0), COALESCE(i.planned_qty,0),
                       GREATEST(COALESCE(draft.qty,0),0),
                       GREATEST(
                           COALESCE(i.qty,0) - COALESCE(i.shipped_qty,0)
                           + COALESCE(i.returned_qty,0) - COALESCE(i.flag_qty,0)
                           - COALESCE(i.reserved_qty,0)
                           - GREATEST(COALESCE(i.planned_qty,0)-COALESCE(i.produced_qty,0),0)
                           - COALESCE(draft.qty,0), 0),
                       COALESCE(i.deliver_date,o.deliver_date),
                       active_analysis.analysis_id,
                       active_analysis.status,
                       active_analysis.version
                FROM sales_orders o
                JOIN sales_order_items i ON i.order_id = o.id AND i.is_deleted = FALSE
                JOIN goods g ON g.id = i.goods_id AND g.is_deleted = FALSE
                LEFT JOIN clients c ON c.id = o.client_id
                LEFT JOIN colors col ON col.id = i.color_id
                LEFT JOIN units u ON u.id = i.unit_id
                LEFT JOIN LATERAL (
                    SELECT SUM(pi.qty) AS qty
                    FROM production_plan_items pi
                    JOIN production_plans p ON p.id = pi.plan_id
                    WHERE pi.sales_order_item_id = i.id
                      AND pi.is_deleted = FALSE
                      AND p.is_deleted = FALSE AND p.status = 0
                      AND p.is_canceled = FALSE
                ) draft ON TRUE
                LEFT JOIN LATERAL (
                    SELECT a.id AS analysis_id, a.status, a.version
                    FROM production_material_analysis_items ai
                    JOIN production_material_analyses a ON a.id = ai.analysis_id
                    WHERE ai.sales_order_item_id = i.id
                      AND ai.is_deleted = FALSE AND a.is_deleted = FALSE
                      AND a.status IN ('ACTIVE','PARTIALLY_PLANNED')
                    ORDER BY a.analyzed_at DESC, a.id
                    LIMIT 1
                ) active_analysis ON TRUE
                WHERE o.id IN (:orderIds)
                  AND o.status = 1 AND o.is_deleted = FALSE
                  AND o.finance_confirmed = TRUE
                  AND COALESCE(o.is_stopped,FALSE) = FALSE AND o.is_closed = FALSE
                  AND GREATEST(
                      COALESCE(i.qty,0) - COALESCE(i.shipped_qty,0)
                      + COALESCE(i.returned_qty,0) - COALESCE(i.flag_qty,0)
                      - COALESCE(i.reserved_qty,0)
                      - GREATEST(COALESCE(i.planned_qty,0)
                                 - COALESCE(i.produced_qty,0),0)
                      - COALESCE(draft.qty,0), 0) > 0
                ORDER BY o.deliver_date NULLS LAST, o.bill_date, o.bill_no,
                         COALESCE(i.line_no,0), i.id
                """).setParameter("orderIds", orderIds));
        Map<UUID, CandidateOrderBuilder> builders = new LinkedHashMap<>();
        for (Object[] row : rows) {
            UUID orderId = uuid(row[0]);
            CandidateOrderBuilder builder = builders.computeIfAbsent(orderId,
                    ignored -> new CandidateOrderBuilder(
                            orderId, string(row[1]), date(row[2]), date(row[3]), string(row[4])));
            builder.lines.add(new SalesCandidateLine(
                    uuid(row[5]), integer(row[6]), uuid(row[7]), string(row[8]),
                    string(row[9]), string(row[10]), uuid(row[11]), string(row[12]),
                    uuid(row[13]), string(row[14]), decimal(row[15]), decimal(row[16]),
                    decimal(row[17]), decimal(row[18]), date(row[19]),
                    uuid(row[20]), string(row[21]), longValue(row[22])));
        }
        List<SalesCandidateOrder> items = builders.values().stream()
                .map(CandidateOrderBuilder::build).toList();
        return new SalesCandidatePage(items, page, size, total,
                (int) ((total + size - 1) / size));
    }

    /** Fail closed when the direct production structure changed after the analysis snapshot. */
    public void requireCurrentBomSnapshot(UUID analysisId, Set<UUID> analysisItemIds) {
        if (analysisItemIds == null || analysisItemIds.isEmpty()) {
            throw validation("必须指定要校验的物料分析产品");
        }
        List<SourceLine> allSources = loadSourceLines(analysisId, false);
        Map<UUID, SourceLine> sources = allSources.stream()
                .filter(source -> analysisItemIds.contains(source.analysisItemId()))
                .collect(Collectors.toMap(SourceLine::analysisItemId, source -> source));
        if (!sources.keySet().equals(analysisItemIds)) {
            throw conflict("待生成计划的产品已不属于当前物料分析");
        }
        // 新安排按所选产品及其来源父行校验；已有任务的实物进度另行刷新。
        requirePlanningSources(allSources, analysisItemIds);
        for (SourceLine source : sources.values()) {
            // 子件锚点行无 BOM 快照可比（料行保持在原树）——锚点本身只需
            // 仍属于本分析（上面的集合校验已覆盖）。
            if ("MAKE_COMPONENT".equals(source.sourceType())
                    || "SUBCONTRACT_MAKE".equals(source.sourceType())) {
                continue;
            }
            Set<String> current = loadBomTree(source).stream()
                    .filter(node -> node.depth() == 1)
                    .map(MaterialAnalysisService::bomSignaturePart)
                    .collect(Collectors.toCollection(TreeSet::new));
            Set<String> snapshotted = NativeQueryResults.objectArrayRows(
                    em.createNativeQuery("""
                            SELECT bom_item_id, goods_id, color_id, unit_id,
                                   parent_per_product_qty, bom_qty, per_product_qty,
                                   control_stage, consumption_basis, basis_output_qty,
                                   allow_partial_package, hard_gate, source_suggestion,
                                   calculation_mode
                            FROM production_material_analysis_materials
                            WHERE analysis_id = :analysisId
                              AND analysis_item_id = :analysisItemId
                              AND active = TRUE AND depth = 1
                            ORDER BY node_key
                            """)
                            .setParameter("analysisId", analysisId)
                            .setParameter("analysisItemId", source.analysisItemId()))
                    .stream().map(row -> {
                        if (!"EDGE_RULE".equals(string(row[13]))) {
                            throw conflict("历史物料快照必须先刷新，才能生成生产计划");
                        }
                        return bomSignaturePart(
                                uuid(row[0]), uuid(row[1]), uuid(row[2]), uuid(row[3]),
                                decimal(row[4]), decimal(row[5]), decimal(row[6]),
                                string(row[7]), string(row[8]), decimal(row[9]),
                                Boolean.TRUE.equals(row[10]),
                                Boolean.TRUE.equals(row[11]), string(row[12]));
                    })
                    .collect(Collectors.toCollection(TreeSet::new));
            if (!current.equals(snapshotted)) {
                throw conflict("BOM 直接层已变更，必须刷新物料分析并重新联合预览");
            }
        }
    }

    private static String bomSignaturePart(BomNode node) {
        return bomSignaturePart(node.bomItemId(), node.goodsId(), node.colorId(),
                node.unitId(), node.parentPerProductQty(), node.bomQty(),
                node.perProductQty(), node.controlStage(), node.consumptionBasis(),
                node.basisOutputQty(), node.allowPartialPackage(), node.hardGate(),
                node.suggestion());
    }

    private static String bomSignaturePart(
            UUID bomItemId, UUID goodsId, UUID colorId, UUID unitId,
            BigDecimal parentPerProductQty, BigDecimal bomQty,
            BigDecimal perProductQty, String controlStage,
            String consumptionBasis, BigDecimal basisOutputQty,
            boolean allowPartialPackage, boolean hardGate, String suggestion) {
        return String.join("|", Objects.toString(bomItemId, ""),
                Objects.toString(goodsId, ""), Objects.toString(colorId, ""),
                Objects.toString(unitId, ""), decimalText(parentPerProductQty),
                decimalText(bomQty), decimalText(perProductQty),
                Objects.toString(controlStage, ""),
                Objects.toString(consumptionBasis, ""), decimalText(basisOutputQty),
                Boolean.toString(allowPartialPackage), Boolean.toString(hardGate),
                Objects.toString(suggestion, ""));
    }

    AnalysisHeader lockHeader(UUID analysisId) {
        var guard = mutationLocks.acquire(() -> mutationFootprints.forAnalyses(List.of(analysisId)));
        AnalysisHeader header=readHeader(analysisId,true);
        guard.verifyUnchanged();
        return header;
    }

    /** Already-held A permits an immutable command replay before rejecting a stale write fingerprint. */
    AnalysisHeader headerAfterPrelock(UUID analysisId) {
        mutationLocks.requireCovered(new FulfillmentMutationLockPlan(Set.of(),Set.of(),Set.of(),
                Set.of(analysisId),"analysis-header-read"));
        return readHeader(analysisId,true);
    }

    private AnalysisHeader readHeader(UUID analysisId,boolean forUpdate) {
        Object[] row = oneRow(em.createNativeQuery("""
                SELECT id, warehouse_id, status, version, fingerprint,
                       analyzed_at, maker_id, is_deleted
                FROM production_material_analyses
                WHERE id = :id
                """ + (forUpdate ? " FOR UPDATE" : "")).setParameter("id", analysisId), "物料分析不存在");
        if (Boolean.TRUE.equals(row[7])) {
            throw notFound("物料分析不存在");
        }
        return new AnalysisHeader(uuid(row[0]), uuid(row[1]), string(row[2]),
                ((Number) row[3]).longValue(), string(row[4]), offsetDateTime(row[5]),
                uuid(row[6]));
    }

    private boolean isOpenForFulfillment(AnalysisHeader header) {
        if (List.of(STATUS_ACTIVE, STATUS_PARTIAL).contains(header.status())) return true;
        if (!"COMPLETED".equals(header.status())) return false;
        // Historical COMPLETED meant all quantities were planned. Only a live,
        // unfulfilled linked plan permits reopening through an authorized command.
        return Boolean.TRUE.equals(em.createNativeQuery("""
                SELECT EXISTS (
                    SELECT 1 FROM production_plans plan
                    JOIN production_plan_items item ON item.plan_id=plan.id
                    WHERE plan.material_analysis_id=:analysisId
                      AND plan.is_deleted=FALSE AND plan.is_canceled=FALSE
                      AND plan.status IN (0,1) AND item.is_deleted=FALSE
                      AND item.qty>COALESCE(item.iqty,0))
                """).setParameter("analysisId", header.id()).getSingleResult());
    }

    void requireCurrent(AnalysisHeader header, Long version, String fingerprint) {
        if (!isOpenForFulfillment(header)) {
            throw conflict("物料分析已结束，不能继续修改");
        }
        if (version == null || version != header.version()
                || fingerprint == null
                || !fingerprint.equalsIgnoreCase(header.fingerprint())) {
            throw conflict("物料分析已被刷新或修改，请重新加载");
        }
        if ("COMPLETED".equals(header.status())) reopenHistoricallyPlannedAnalysis(header.id());
    }

    private void reopenHistoricallyPlannedAnalysis(UUID analysisId) {
        em.createNativeQuery("""
                UPDATE production_material_analyses analysis
                SET status='PARTIALLY_PLANNED',updated_at=now()
                WHERE analysis.id=:analysisId AND analysis.status='COMPLETED'
                  AND EXISTS (
                    SELECT 1 FROM production_plans plan
                    JOIN production_plan_items item ON item.plan_id=plan.id
                    WHERE plan.material_analysis_id=analysis.id
                      AND plan.is_deleted=FALSE AND plan.is_canceled=FALSE
                      AND plan.status IN (0,1) AND item.is_deleted=FALSE
                      AND item.qty>COALESCE(item.iqty,0))
                """).setParameter("analysisId",analysisId).executeUpdate();
    }

    void refreshLocked(UUID analysisId) {
        AnalysisHeader header = lockHeader(analysisId);
        if (!isOpenForFulfillment(header)) {
            throw conflict("物料分析已结束，不能刷新");
        }
        if ("COMPLETED".equals(header.status())) reopenHistoricallyPlannedAnalysis(analysisId);
        if (header.warehouseId() == null) {
            throw conflict("物料分析未选择目标仓库");
        }
        // All main-warehouse coordinators precede every analysis header in the
        // common prefix. Never take W after A while refreshing multiple analyses.
        // 2026-09-05 简化：旧模式遗留的 MAKE 权益委托先整体归还（新模式不再
        // 委托；归还后 exact 权益回到原始物料节点，投影保持单份数据）。
        stockEntitlement.restoreAllMakeDelegations(analysisId);
        reconcileSupplyActionStatuses(analysisId);
        if (rootSupply != null) rootSupply.ensureRootNodes(analysisId);
        List<SourceLine> sources = loadSourceLines(analysisId, true);
        // Existing fulfillment belongs to the admitted analysis snapshot. A later
        // sales amendment must not roll back a real receipt merely because new
        // planning now needs another finance review. Commands check admission
        // for their selected source lines before creating any new commitment.
        List<BomNode> nodes = new ArrayList<>();
        for (SourceLine source : sources) {
            // 子件锚点行（MAKE_COMPONENT / SUBCONTRACT_MAKE）不展开自己的
            // BOM：物料需求保持在原树单一份数据，计划员照常在采购/委外桶对
            // 原行下达；计划自身的物料需求由执行段按计划 BOM 生成并等料。
            if ("MAKE_COMPONENT".equals(source.sourceType())
                    || "SUBCONTRACT_MAKE".equals(source.sourceType())) {
                continue;
            }
            nodes.addAll(loadBomTree(source));
        }
        Map<UUID, SourceLine> sourcesById = sources.stream()
                .collect(Collectors.toMap(SourceLine::analysisItemId, source -> source));
        Map<String,List<BigDecimal>> plannedBatches = plannedMaterialBatches(analysisId);
        nodes = nodes.stream().map(node -> {
            BomNode batched = node.withOutputBatches(plannedBatches.getOrDefault(
                    node.analysisItemId()+"|"+Objects.toString(node.parentNodeKey(),""),List.of()));
            return node.depth()==1 ? batched.withSnapshotRequiredQty(batched.requiredForOutput(
                    sourcesById.get(node.analysisItemId()).materialRequirementQty())) : batched;
        }).toList();
        validateExactPegRefreshCompatibility(analysisId, nodes);
        em.createNativeQuery("""
                UPDATE production_material_analysis_materials
                SET active = FALSE, updated_at = now(), updated_by = :actorId
                WHERE analysis_id = :analysisId AND active = TRUE
                """)
                .setParameter("actorId", currentUser.requireId())
                .setParameter("analysisId", analysisId)
                .executeUpdate();
        AvailabilitySnapshot availability = availability(
                analysisId, header.warehouseId(), nodes, sources);
        for (BomNode node : nodes) {
            MaterialDimension key = node.dimension();
            StockValue stock = availability.stock().getOrDefault(key, StockValue.ZERO);
            SourceLine source = Optional.ofNullable(
                    sourcesById.get(node.analysisItemId())).orElseThrow();
            InboundValue inbound = availability.inboundOnOrBefore(
                    key, source.deliveryDate());
            BigDecimal available = stock.availableAfterSafety(node.safetyStock());
            BigDecimal required = node.snapshotRequiredQty();
            BigDecimal shortage = required.subtract(available)
                    .max(BigDecimal.ZERO).setScale(4, RoundingMode.CEILING);
            // 初始快照与 persistAllocationSnapshot 权威口径一致：MAKE 与有子层
            // SUBCONTRACT（先自制链）都可能下层未齐；随后权威重算会覆盖本值。
            boolean lowerPending = node.hasChildren()
                    && ("MAKE".equals(node.suggestion())
                        || "SUBCONTRACT".equals(node.suggestion()))
                    && shortage.signum() > 0;
            em.createNativeQuery("""
                    INSERT INTO production_material_analysis_materials (
                        id, analysis_id, analysis_item_id, node_key, parent_node_key,
                        bom_item_id, goods_id, color_id, unit_id, depth, path,
                        per_product_qty, required_qty, available_qty, reserved_qty,
                        allocated_available_qty, safety_stock_qty, inbound_qty,
                        allocated_start_qty, allocated_finish_qty, allocated_ship_qty,
                        shortage_qty, expected_ready_date,
                        control_stage, consumption_basis, basis_output_qty,
                        allow_partial_package, hard_gate, bom_qty,
                        parent_per_product_qty, calculation_mode,
                        source_suggestion, lower_level_pending, active,
                        created_by, updated_by
                    ) VALUES (
                        :id, :analysisId, :analysisItemId, :nodeKey, :parentNodeKey,
                        :bomItemId, :goodsId, :colorId, :unitId, :depth, :path,
                        :perProductQty, :requiredQty, :availableQty, :reservedQty,
                        :allocatedAvailableQty, :safetyStockQty, :inboundQty,
                        :allocatedAvailableQty, :allocatedAvailableQty,
                        :allocatedAvailableQty,
                        :shortageQty, :expectedReadyDate,
                        :controlStage, :consumptionBasis, :basisOutputQty,
                        :allowPartialPackage, :hardGate, :bomQty,
                        :parentPerProductQty, 'EDGE_RULE',
                        :suggestion, :lowerPending, TRUE, :actorId, :actorId
                    )
                    ON CONFLICT (analysis_item_id, node_key) DO UPDATE SET
                        parent_node_key = EXCLUDED.parent_node_key,
                        bom_item_id = EXCLUDED.bom_item_id,
                        goods_id = EXCLUDED.goods_id,
                        color_id = EXCLUDED.color_id,
                        unit_id = EXCLUDED.unit_id,
                        depth = EXCLUDED.depth,
                        path = EXCLUDED.path,
                        per_product_qty = EXCLUDED.per_product_qty,
                        required_qty = EXCLUDED.required_qty,
                        available_qty = EXCLUDED.available_qty,
                        allocated_available_qty = EXCLUDED.allocated_available_qty,
                        allocated_start_qty = EXCLUDED.allocated_start_qty,
                        allocated_finish_qty = EXCLUDED.allocated_finish_qty,
                        allocated_ship_qty = EXCLUDED.allocated_ship_qty,
                        reserved_qty = EXCLUDED.reserved_qty,
                        safety_stock_qty = EXCLUDED.safety_stock_qty,
                        inbound_qty = EXCLUDED.inbound_qty,
                        shortage_qty = EXCLUDED.shortage_qty,
                        expected_ready_date = EXCLUDED.expected_ready_date,
                        control_stage = EXCLUDED.control_stage,
                        consumption_basis = EXCLUDED.consumption_basis,
                        basis_output_qty = EXCLUDED.basis_output_qty,
                        allow_partial_package = EXCLUDED.allow_partial_package,
                        hard_gate = EXCLUDED.hard_gate,
                        bom_qty = EXCLUDED.bom_qty,
                        parent_per_product_qty = EXCLUDED.parent_per_product_qty,
                        calculation_mode = EXCLUDED.calculation_mode,
                        source_suggestion = EXCLUDED.source_suggestion,
                        lower_level_pending = EXCLUDED.lower_level_pending,
                        confirmed_route = CASE WHEN
                            production_material_analysis_materials.goods_id
                                IS DISTINCT FROM EXCLUDED.goods_id
                            OR production_material_analysis_materials.color_id
                                IS DISTINCT FROM EXCLUDED.color_id
                            OR production_material_analysis_materials.unit_id
                                IS DISTINCT FROM EXCLUDED.unit_id
                            OR production_material_analysis_materials.parent_node_key
                                IS DISTINCT FROM EXCLUDED.parent_node_key
                            OR production_material_analysis_materials.path
                                IS DISTINCT FROM EXCLUDED.path
                            OR production_material_analysis_materials.per_product_qty
                                IS DISTINCT FROM EXCLUDED.per_product_qty
                            OR production_material_analysis_materials.control_stage
                                IS DISTINCT FROM EXCLUDED.control_stage
                            OR production_material_analysis_materials.consumption_basis
                                IS DISTINCT FROM EXCLUDED.consumption_basis
                            OR production_material_analysis_materials.basis_output_qty
                                IS DISTINCT FROM EXCLUDED.basis_output_qty
                            OR production_material_analysis_materials.allow_partial_package
                                IS DISTINCT FROM EXCLUDED.allow_partial_package
                            OR production_material_analysis_materials.hard_gate
                                IS DISTINCT FROM EXCLUDED.hard_gate
                            OR production_material_analysis_materials.bom_qty
                                IS DISTINCT FROM EXCLUDED.bom_qty
                            OR production_material_analysis_materials.source_suggestion
                                IS DISTINCT FROM EXCLUDED.source_suggestion
                            THEN NULL
                            ELSE production_material_analysis_materials.confirmed_route END,
                        route_reason = CASE WHEN
                            production_material_analysis_materials.goods_id
                                IS DISTINCT FROM EXCLUDED.goods_id
                            OR production_material_analysis_materials.color_id
                                IS DISTINCT FROM EXCLUDED.color_id
                            OR production_material_analysis_materials.unit_id
                                IS DISTINCT FROM EXCLUDED.unit_id
                            OR production_material_analysis_materials.parent_node_key
                                IS DISTINCT FROM EXCLUDED.parent_node_key
                            OR production_material_analysis_materials.path
                                IS DISTINCT FROM EXCLUDED.path
                            OR production_material_analysis_materials.per_product_qty
                                IS DISTINCT FROM EXCLUDED.per_product_qty
                            OR production_material_analysis_materials.control_stage
                                IS DISTINCT FROM EXCLUDED.control_stage
                            OR production_material_analysis_materials.consumption_basis
                                IS DISTINCT FROM EXCLUDED.consumption_basis
                            OR production_material_analysis_materials.basis_output_qty
                                IS DISTINCT FROM EXCLUDED.basis_output_qty
                            OR production_material_analysis_materials.allow_partial_package
                                IS DISTINCT FROM EXCLUDED.allow_partial_package
                            OR production_material_analysis_materials.hard_gate
                                IS DISTINCT FROM EXCLUDED.hard_gate
                            OR production_material_analysis_materials.bom_qty
                                IS DISTINCT FROM EXCLUDED.bom_qty
                            OR production_material_analysis_materials.source_suggestion
                                IS DISTINCT FROM EXCLUDED.source_suggestion
                            THEN NULL
                            ELSE production_material_analysis_materials.route_reason END,
                        route_confirmed_by = CASE WHEN
                            production_material_analysis_materials.goods_id
                                IS DISTINCT FROM EXCLUDED.goods_id
                            OR production_material_analysis_materials.color_id
                                IS DISTINCT FROM EXCLUDED.color_id
                            OR production_material_analysis_materials.unit_id
                                IS DISTINCT FROM EXCLUDED.unit_id
                            OR production_material_analysis_materials.parent_node_key
                                IS DISTINCT FROM EXCLUDED.parent_node_key
                            OR production_material_analysis_materials.path
                                IS DISTINCT FROM EXCLUDED.path
                            OR production_material_analysis_materials.per_product_qty
                                IS DISTINCT FROM EXCLUDED.per_product_qty
                            OR production_material_analysis_materials.control_stage
                                IS DISTINCT FROM EXCLUDED.control_stage
                            OR production_material_analysis_materials.consumption_basis
                                IS DISTINCT FROM EXCLUDED.consumption_basis
                            OR production_material_analysis_materials.basis_output_qty
                                IS DISTINCT FROM EXCLUDED.basis_output_qty
                            OR production_material_analysis_materials.allow_partial_package
                                IS DISTINCT FROM EXCLUDED.allow_partial_package
                            OR production_material_analysis_materials.hard_gate
                                IS DISTINCT FROM EXCLUDED.hard_gate
                            OR production_material_analysis_materials.bom_qty
                                IS DISTINCT FROM EXCLUDED.bom_qty
                            OR production_material_analysis_materials.source_suggestion
                                IS DISTINCT FROM EXCLUDED.source_suggestion
                            THEN NULL
                            ELSE production_material_analysis_materials.route_confirmed_by END,
                        route_confirmed_at = CASE WHEN
                            production_material_analysis_materials.goods_id
                                IS DISTINCT FROM EXCLUDED.goods_id
                            OR production_material_analysis_materials.color_id
                                IS DISTINCT FROM EXCLUDED.color_id
                            OR production_material_analysis_materials.unit_id
                                IS DISTINCT FROM EXCLUDED.unit_id
                            OR production_material_analysis_materials.parent_node_key
                                IS DISTINCT FROM EXCLUDED.parent_node_key
                            OR production_material_analysis_materials.path
                                IS DISTINCT FROM EXCLUDED.path
                            OR production_material_analysis_materials.per_product_qty
                                IS DISTINCT FROM EXCLUDED.per_product_qty
                            OR production_material_analysis_materials.control_stage
                                IS DISTINCT FROM EXCLUDED.control_stage
                            OR production_material_analysis_materials.consumption_basis
                                IS DISTINCT FROM EXCLUDED.consumption_basis
                            OR production_material_analysis_materials.basis_output_qty
                                IS DISTINCT FROM EXCLUDED.basis_output_qty
                            OR production_material_analysis_materials.allow_partial_package
                                IS DISTINCT FROM EXCLUDED.allow_partial_package
                            OR production_material_analysis_materials.hard_gate
                                IS DISTINCT FROM EXCLUDED.hard_gate
                            OR production_material_analysis_materials.bom_qty
                                IS DISTINCT FROM EXCLUDED.bom_qty
                            OR production_material_analysis_materials.source_suggestion
                                IS DISTINCT FROM EXCLUDED.source_suggestion
                            THEN NULL
                            ELSE production_material_analysis_materials.route_confirmed_at END,
                        active = TRUE,
                        updated_at = now(), updated_by = EXCLUDED.updated_by
                    """)
                    .setParameter("id", UUID.randomUUID())
                    .setParameter("analysisId", analysisId)
                    .setParameter("analysisItemId", node.analysisItemId())
                    .setParameter("nodeKey", node.nodeKey())
                    .setParameter("parentNodeKey", node.parentNodeKey())
                    .setParameter("bomItemId", node.bomItemId())
                    .setParameter("goodsId", node.goodsId())
                    .setParameter("colorId", node.colorId())
                    .setParameter("unitId", node.unitId())
                    .setParameter("depth", node.depth())
                    .setParameter("path", node.path())
                    .setParameter("perProductQty", node.perProductQty())
                    .setParameter("requiredQty", required)
                    .setParameter("availableQty", available)
                    .setParameter("reservedQty", stock.reserved())
                    .setParameter("allocatedAvailableQty", BigDecimal.ZERO)
                    .setParameter("safetyStockQty", node.safetyStock())
                    .setParameter("inboundQty", inbound.qty())
                    .setParameter("shortageQty", shortage)
                    .setParameter("expectedReadyDate", inbound.expectedDate())
                    .setParameter("controlStage", node.controlStage())
                    .setParameter("consumptionBasis", node.consumptionBasis())
                    .setParameter("basisOutputQty", node.basisOutputQty())
                    .setParameter("allowPartialPackage", node.allowPartialPackage())
                    .setParameter("hardGate", node.hardGate())
                    .setParameter("bomQty", node.bomQty())
                    .setParameter("parentPerProductQty", node.parentPerProductQty())
                    .setParameter("suggestion", node.suggestion())
                    .setParameter("lowerPending", lowerPending)
                    .setParameter("actorId", currentUser.requireId())
                    .executeUpdate();
        }
        validateActiveBorrowEndpointsAfterRefresh(analysisId);
        persistAllocationSnapshot(
                analysisId, header.warehouseId(), sources, nodes, availability);
        if (rootSupply != null) rootSupply.refreshRootNodes(analysisId,activeFutureCoverageByMaterial(analysisId));
        bumpFingerprint(analysisId);
    }

    /** Reconcile actionable coverage from authoritative downstream lifecycle facts. */
    private void reconcileSupplyActionStatuses(UUID analysisId) {
        UUID actorId = currentUser.requireId();
        em.createNativeQuery("""
                UPDATE preplan_supply_actions action
                SET status = 'CANCELLED', cancelled_by = :actorId,
                    cancelled_at = now(),
                    cancellation_reason = '下游单据已删除、红冲或中止，刷新物料分析时自动失效',
                    updated_at = now()
                WHERE action.analysis_id = :analysisId
                  AND action.status IN ('CREATED','IN_PROGRESS')
                  AND (
                    (action.external_document_type = 'PURCHASE_REQUEST' AND NOT EXISTS (
                        SELECT 1
                        FROM v_preplan_buy_action_slice_progress progress
                        WHERE progress.action_id = action.id
                          AND progress.demand_source_valid = TRUE
                          AND progress.safety_source_valid = TRUE))
                    OR
                    (action.external_document_type = 'SUBCONTRACT_APPLICATION' AND NOT EXISTS (
                        SELECT 1
                        FROM preplan_supply_action_allocations allocation
                        JOIN subcontract_application_items item
                          ON item.id = allocation.external_item_id
                         AND item.is_deleted = FALSE
                        JOIN subcontract_applications application
                          ON application.id = item.application_id
                         AND application.id = action.external_document_id
                         AND application.is_deleted = FALSE
                         AND application.status IN (0,1)
                        WHERE allocation.action_id = action.id))
                    OR
                    (action.external_document_type = 'PREPLAN_MAKE_TASK' AND NOT EXISTS (
                        SELECT 1 FROM production_material_analysis_items child
                        WHERE child.id = action.external_document_id
                          AND child.analysis_id = action.analysis_id
                          AND child.source_type IN ('MAKE_COMPONENT','SUBCONTRACT_MAKE')
                          AND child.is_deleted = FALSE))
                    OR
                    (action.external_document_type = 'SUBCONTRACT_MAKE_TASK' AND NOT EXISTS (
                        SELECT 1 FROM production_material_analysis_items child
                        WHERE child.id = action.external_document_id
                          AND child.analysis_id = action.analysis_id
                          AND child.source_type = 'SUBCONTRACT_MAKE'
                          AND child.is_deleted = FALSE))
                  )
                """).setParameter("actorId", actorId)
                .setParameter("analysisId", analysisId).executeUpdate();

        // V420 BUY split actions reconcile demand-exact and public-safety slices
        // independently. Terminal FAIL releases only the planning projection;
        // every commercial, IQC and already-qualified inventory fact remains.
        em.createNativeQuery("""
                UPDATE preplan_supply_actions action
                SET status = 'CANCELLED', cancelled_by = :actorId,
                    cancelled_at = now(),
                    cancellation_reason =
                        '需求或公共安全补库存在终态不合格且已无未来供给，需按失败切片重新通知',
                    updated_at = now()
                FROM v_preplan_buy_action_slice_progress progress
                WHERE action.id = progress.action_id
                  AND action.analysis_id = :analysisId
                  AND action.status IN ('CREATED','IN_PROGRESS','DONE')
                  AND action.external_document_type = 'PURCHASE_REQUEST'
                  AND action.safety_replenishment_qty > 0
                  AND EXISTS (
                      SELECT 1 FROM purchase_requests request
                      WHERE request.id = action.external_document_id
                        AND request.is_deleted = FALSE
                        AND request.status IN (0,1)
                        AND request.is_stopped = FALSE
                        AND request.is_closed = TRUE)
                  AND (
                      progress.demand_qualified_qty
                          < progress.demand_requested_qty
                      OR progress.safety_qualified_qty
                          < progress.safety_requested_qty)
                  AND progress.demand_failed_qty + progress.safety_failed_qty > 0
                  AND progress.demand_future_qty = 0
                  AND progress.safety_future_qty = 0
                """).setParameter("actorId", actorId)
                .setParameter("analysisId", analysisId).executeUpdate();

        // A physically completed order with rejected IQC quantity cannot satisfy the
        // planning action. The upstream request/application is already closed by the
        // approved order, so retaining the action as IN_PROGRESS would permanently cover
        // the shortage and prevent a replacement notification. Keep every commercial and
        // inspection fact, but release only the planning projection after every linked
        // receipt is terminal and no approved order quantity remains in transit.
        em.createNativeQuery("""
                UPDATE preplan_supply_actions action
                SET status = 'CANCELLED', cancelled_by = :actorId,
                    cancelled_at = now(),
                    cancellation_reason = '到货质检存在不合格且原采购需求已无在途，需重新通知补采',
                    updated_at = now()
                WHERE action.analysis_id = :analysisId
                  AND action.status IN ('CREATED','IN_PROGRESS','DONE')
                  AND action.external_document_type = 'PURCHASE_REQUEST'
                  AND action.safety_replenishment_qty = 0
                  AND EXISTS (
                      SELECT 1
                      FROM purchase_requests request
                      WHERE request.id = action.external_document_id
                        AND request.is_deleted = FALSE
                        AND request.status IN (0,1)
                        AND request.is_stopped = FALSE
                        AND request.is_closed = TRUE)
                  AND action.requested_qty > COALESCE((
                      -- V463：合并订货行按来源 FIFO 分摊到各申请行后再汇总。
                      SELECT SUM(fn_purchase_order_source_share(
                          order_item.id, src.request_item_id,
                          GREATEST(
                              COALESCE((
                                  SELECT SUM(CASE
                                      WHEN inspection.id IS NULL
                                      THEN receipt_item.qty
                                          * COALESCE(receipt_item.unit_rate,1)
                                      WHEN inspection.status IN ('PARTIAL','RESOLVED')
                                      THEN inspection.warehouse_stocked_base_qty
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
                                  WHERE receipt_item.order_item_id = order_item.id
                                    AND receipt_item.is_deleted = FALSE
                              ),0) - COALESCE(order_item.returned_qty,0)
                                  * COALESCE(order_item.unit_rate,1), 0)))
                      FROM purchase_order_item_sources src
                      JOIN purchase_order_items order_item
                        ON order_item.id = src.order_item_id
                       AND order_item.is_deleted = FALSE
                      JOIN purchase_orders purchase_order
                        ON purchase_order.id = order_item.order_id
                       AND purchase_order.status = 1
                       AND purchase_order.is_deleted = FALSE
                      WHERE src.request_item_id IN (
                          SELECT allocation.external_item_id
                          FROM preplan_supply_action_allocations allocation
                          WHERE allocation.action_id = action.id
                            AND allocation.external_item_id IS NOT NULL)
                  ),0)
                  AND EXISTS (
                      SELECT 1
                      FROM preplan_supply_action_allocations allocation
                      JOIN purchase_order_item_sources src
                        ON src.request_item_id = allocation.external_item_id
                      JOIN purchase_order_items order_item
                        ON order_item.id = src.order_item_id
                       AND order_item.is_deleted = FALSE
                      JOIN purchase_orders purchase_order
                        ON purchase_order.id = order_item.order_id
                       AND purchase_order.status = 1
                       AND purchase_order.is_deleted = FALSE
                      JOIN purchase_receipt_items receipt_item
                        ON receipt_item.order_item_id = order_item.id
                       AND receipt_item.is_deleted = FALSE
                      JOIN purchase_receipts receipt
                        ON receipt.id = receipt_item.receipt_id
                       AND receipt.status = 1
                       AND receipt.is_deleted = FALSE
                      JOIN procurement_inspection_items inspection
                        ON inspection.receipt_type = 'PURCHASE'
                       AND inspection.receipt_item_id = receipt_item.id
                       AND inspection.status = 'RESOLVED'
                       AND inspection.failed_base_qty > 0
                      WHERE allocation.action_id = action.id)
                  AND NOT EXISTS (
                      SELECT 1
                      FROM preplan_supply_action_allocations allocation
                      JOIN purchase_order_item_sources src
                        ON src.request_item_id = allocation.external_item_id
                      JOIN purchase_order_items order_item
                        ON order_item.id = src.order_item_id
                       AND order_item.is_deleted = FALSE
                      JOIN purchase_orders purchase_order
                        ON purchase_order.id = order_item.order_id
                       AND purchase_order.status = 1
                       AND purchase_order.is_deleted = FALSE
                      WHERE allocation.action_id = action.id
                        AND fn_purchase_order_source_share(
                            order_item.id, src.request_item_id,
                            GREATEST(
                                COALESCE(order_item.qty,0)
                                - COALESCE(order_item.received_qty,0)
                                + COALESCE(order_item.returned_qty,0), 0)
                            * COALESCE(order_item.unit_rate,1)
                            + COALESCE((
                                SELECT SUM(rejection.failed_base_qty)
                                FROM procurement_iqc_rejection_cases rejection
                                WHERE rejection.receipt_type='PURCHASE'
                                  AND rejection.order_item_id=order_item.id
                                  AND rejection.is_deleted=FALSE
                                  AND rejection.return_recorded_at IS NOT NULL
                                  AND rejection.status IN (
                                      'RETURN_RECORDED','CREDIT_CONFIRMED',
                                      'CLOSED_NO_CREDIT','FINANCE_EXCEPTION')
                              ),0)) > 0)
                  AND NOT EXISTS (
                      SELECT 1
                      FROM preplan_supply_action_allocations allocation
                      JOIN purchase_order_item_sources src
                        ON src.request_item_id = allocation.external_item_id
                      JOIN purchase_order_items order_item
                        ON order_item.id = src.order_item_id
                       AND order_item.is_deleted = FALSE
                      JOIN purchase_receipt_items receipt_item
                        ON receipt_item.order_item_id = order_item.id
                       AND receipt_item.is_deleted = FALSE
                      JOIN purchase_receipts receipt
                        ON receipt.id = receipt_item.receipt_id
                       AND receipt.status = 1
                       AND receipt.is_deleted = FALSE
                      JOIN procurement_inspection_items inspection
                        ON inspection.receipt_type = 'PURCHASE'
                       AND inspection.receipt_item_id = receipt_item.id
                       AND (
                           inspection.status NOT IN ('RESOLVED','REVERSED')
                           OR (
                               inspection.status <> 'REVERSED'
                               AND inspection.passed_base_qty
                                   > inspection.warehouse_stocked_base_qty
                           )
                       )
                      WHERE allocation.action_id = action.id)
                """).setParameter("actorId", actorId)
                .setParameter("analysisId", analysisId).executeUpdate();

        em.createNativeQuery("""
                UPDATE preplan_supply_actions action
                SET status = 'CANCELLED', cancelled_by = :actorId,
                    cancelled_at = now(),
                    cancellation_reason = '到货质检存在不合格且原委外需求已无在途，需重新通知补委外',
                    updated_at = now()
                WHERE action.analysis_id = :analysisId
                  AND action.status IN ('CREATED','IN_PROGRESS','DONE')
                  AND action.external_document_type = 'SUBCONTRACT_APPLICATION'
                  AND EXISTS (
                      SELECT 1
                      FROM subcontract_applications application
                      WHERE application.id = action.external_document_id
                        AND application.is_deleted = FALSE
                        AND application.status IN (0,1)
                        AND application.is_closed = TRUE)
                  AND action.requested_qty > COALESCE((
                      -- V463：合并订货行按来源 FIFO 分摊到各申请行后再汇总。
                      SELECT SUM(fn_subcontract_order_source_share(
                          order_item.id, src.application_item_id,
                          GREATEST(
                              COALESCE((
                                  SELECT SUM(CASE
                                      WHEN inspection.id IS NULL
                                      THEN receipt_item.qty
                                          * COALESCE(receipt_item.unit_rate,1)
                                      WHEN inspection.status IN ('PARTIAL','RESOLVED')
                                      THEN inspection.warehouse_stocked_base_qty
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
                                  WHERE receipt_item.order_item_id = order_item.id
                                    AND receipt_item.is_deleted = FALSE
                              ),0) - COALESCE(order_item.returned_qty,0)
                                  * COALESCE(order_item.unit_rate,1), 0)))
                      FROM subcontract_order_item_sources src
                      JOIN subcontract_order_items order_item
                        ON order_item.id = src.order_item_id
                       AND order_item.is_deleted = FALSE
                      JOIN subcontract_orders subcontract_order
                        ON subcontract_order.id = order_item.order_id
                       AND subcontract_order.status = 1
                       AND subcontract_order.is_deleted = FALSE
                      WHERE src.application_item_id IN (
                          SELECT allocation.external_item_id
                          FROM preplan_supply_action_allocations allocation
                          WHERE allocation.action_id = action.id
                            AND allocation.external_item_id IS NOT NULL)
                  ),0)
                  AND EXISTS (
                      SELECT 1
                      FROM preplan_supply_action_allocations allocation
                      JOIN subcontract_order_item_sources src
                        ON src.application_item_id = allocation.external_item_id
                      JOIN subcontract_order_items order_item
                        ON order_item.id = src.order_item_id
                       AND order_item.is_deleted = FALSE
                      JOIN subcontract_orders subcontract_order
                        ON subcontract_order.id = order_item.order_id
                       AND subcontract_order.status = 1
                       AND subcontract_order.is_deleted = FALSE
                      JOIN subcontract_receipt_items receipt_item
                        ON receipt_item.order_item_id = order_item.id
                       AND receipt_item.is_deleted = FALSE
                      JOIN subcontract_receipts receipt
                        ON receipt.id = receipt_item.receipt_id
                       AND receipt.status = 1
                       AND receipt.is_deleted = FALSE
                      JOIN procurement_inspection_items inspection
                        ON inspection.receipt_type = 'SUBCONTRACT'
                       AND inspection.receipt_item_id = receipt_item.id
                       AND inspection.status = 'RESOLVED'
                       AND inspection.failed_base_qty > 0
                      WHERE allocation.action_id = action.id)
                  AND NOT EXISTS (
                      SELECT 1
                      FROM preplan_supply_action_allocations allocation
                      JOIN subcontract_order_item_sources src
                        ON src.application_item_id = allocation.external_item_id
                      JOIN subcontract_order_items order_item
                        ON order_item.id = src.order_item_id
                       AND order_item.is_deleted = FALSE
                      JOIN subcontract_orders subcontract_order
                        ON subcontract_order.id = order_item.order_id
                       AND subcontract_order.status = 1
                       AND subcontract_order.is_deleted = FALSE
                      WHERE allocation.action_id = action.id
                        AND fn_subcontract_order_source_share(
                            order_item.id, src.application_item_id,
                            GREATEST(
                                COALESCE(order_item.qty,0)
                                - COALESCE(order_item.received_qty,0)
                                + COALESCE(order_item.returned_qty,0), 0)
                            * COALESCE(order_item.unit_rate,1)
                            + COALESCE((
                                SELECT SUM(rejection.failed_base_qty)
                                FROM procurement_iqc_rejection_cases rejection
                                WHERE rejection.receipt_type='SUBCONTRACT'
                                  AND rejection.order_item_id=order_item.id
                                  AND rejection.is_deleted=FALSE
                                  AND rejection.return_recorded_at IS NOT NULL
                                  AND rejection.status IN (
                                      'RETURN_RECORDED','CREDIT_CONFIRMED',
                                      'CLOSED_NO_CREDIT','FINANCE_EXCEPTION')
                              ),0)) > 0)
                  AND NOT EXISTS (
                      SELECT 1
                      FROM preplan_supply_action_allocations allocation
                      JOIN subcontract_order_item_sources src
                        ON src.application_item_id = allocation.external_item_id
                      JOIN subcontract_order_items order_item
                        ON order_item.id = src.order_item_id
                       AND order_item.is_deleted = FALSE
                      JOIN subcontract_receipt_items receipt_item
                        ON receipt_item.order_item_id = order_item.id
                       AND receipt_item.is_deleted = FALSE
                      JOIN subcontract_receipts receipt
                        ON receipt.id = receipt_item.receipt_id
                       AND receipt.status = 1
                       AND receipt.is_deleted = FALSE
                      JOIN procurement_inspection_items inspection
                        ON inspection.receipt_type = 'SUBCONTRACT'
                       AND inspection.receipt_item_id = receipt_item.id
                       AND (
                           inspection.status NOT IN ('RESOLVED','REVERSED')
                           OR (
                               inspection.status <> 'REVERSED'
                               AND inspection.passed_base_qty
                                   > inspection.warehouse_stocked_base_qty
                           )
                       )
                      WHERE allocation.action_id = action.id)
                """).setParameter("actorId", actorId)
                .setParameter("analysisId", analysisId).executeUpdate();

        em.createNativeQuery("""
                UPDATE preplan_supply_actions action
                SET status = 'IN_PROGRESS', updated_at = now()
                FROM v_preplan_buy_action_slice_progress progress
                WHERE action.id = progress.action_id
                  AND action.analysis_id = :analysisId
                  AND action.status IN ('CREATED','DONE')
                  AND action.external_document_type = 'PURCHASE_REQUEST'
                  AND action.safety_replenishment_qty > 0
                  AND (
                      progress.demand_qualified_qty
                          < progress.demand_requested_qty
                      OR progress.safety_qualified_qty
                          < progress.safety_requested_qty)
                  AND (progress.demand_order_exists OR progress.safety_order_exists)
                """).setParameter("analysisId", analysisId).executeUpdate();

        em.createNativeQuery("""
                UPDATE preplan_supply_actions action
                SET status = 'IN_PROGRESS', updated_at = now()
                WHERE action.analysis_id = :analysisId
                  AND action.status IN ('CREATED','DONE')
                  AND action.external_document_type = 'PURCHASE_REQUEST'
                  AND action.safety_replenishment_qty = 0
                  AND action.requested_qty > COALESCE((
                      -- V463：合并订货行按来源 FIFO 分摊到各申请行后再汇总。
                      SELECT SUM(fn_purchase_order_source_share(
                          item.id, src.request_item_id,
                          GREATEST(
                              COALESCE((
                                  SELECT SUM(CASE
                                      WHEN inspection.id IS NULL
                                      THEN receipt_item.qty * COALESCE(
                                          receipt_item.unit_rate,1)
                                      WHEN inspection.status IN ('PARTIAL','RESOLVED')
                                      THEN inspection.warehouse_stocked_base_qty
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
                                  * COALESCE(item.unit_rate,1), 0)))
                      FROM purchase_order_item_sources src
                      JOIN purchase_order_items item
                        ON item.id = src.order_item_id
                       AND item.is_deleted = FALSE
                      JOIN purchase_orders purchase_order
                        ON purchase_order.id = item.order_id
                       AND purchase_order.status = 1
                       AND purchase_order.is_deleted = FALSE
                      WHERE src.request_item_id IN (
                          SELECT allocation.external_item_id
                          FROM preplan_supply_action_allocations allocation
                          WHERE allocation.action_id = action.id
                            AND allocation.external_item_id IS NOT NULL)
                  ),0)
                  AND (action.status = 'DONE' OR EXISTS (
                      SELECT 1 FROM purchase_order_item_sources src
                      JOIN purchase_order_items item
                        ON item.id = src.order_item_id
                       AND item.is_deleted = FALSE
                      JOIN purchase_orders purchase_order
                        ON purchase_order.id = item.order_id
                       AND purchase_order.status = 1
                       AND purchase_order.is_deleted = FALSE
                      WHERE src.request_item_id IN (
                          SELECT allocation.external_item_id
                          FROM preplan_supply_action_allocations allocation
                          WHERE allocation.action_id = action.id
                            AND allocation.external_item_id IS NOT NULL)))
                """).setParameter("analysisId", analysisId).executeUpdate();

        em.createNativeQuery("""
                UPDATE preplan_supply_actions action
                SET status = 'IN_PROGRESS', updated_at = now()
                WHERE action.analysis_id = :analysisId
                  AND action.status IN ('CREATED','DONE')
                  AND action.external_document_type = 'SUBCONTRACT_APPLICATION'
                  AND action.requested_qty > COALESCE((
                      -- V463：合并订货行按来源 FIFO 分摊到各申请行后再汇总。
                      SELECT SUM(fn_subcontract_order_source_share(
                          item.id, src.application_item_id,
                          GREATEST(
                              COALESCE((
                                  SELECT SUM(CASE
                                      WHEN inspection.id IS NULL
                                      THEN receipt_item.qty * COALESCE(
                                          receipt_item.unit_rate,1)
                                      WHEN inspection.status IN ('PARTIAL','RESOLVED')
                                      THEN inspection.warehouse_stocked_base_qty
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
                                  * COALESCE(item.unit_rate,1), 0)))
                      FROM subcontract_order_item_sources src
                      JOIN subcontract_order_items item
                        ON item.id = src.order_item_id
                       AND item.is_deleted = FALSE
                      JOIN subcontract_orders subcontract_order
                        ON subcontract_order.id = item.order_id
                       AND subcontract_order.status = 1
                       AND subcontract_order.is_deleted = FALSE
                      WHERE src.application_item_id IN (
                          SELECT allocation.external_item_id
                          FROM preplan_supply_action_allocations allocation
                          WHERE allocation.action_id = action.id
                            AND allocation.external_item_id IS NOT NULL)
                  ),0)
                  AND (action.status = 'DONE' OR EXISTS (
                      SELECT 1 FROM subcontract_order_item_sources src
                      JOIN subcontract_order_items item
                        ON item.id = src.order_item_id
                       AND item.is_deleted = FALSE
                      JOIN subcontract_orders subcontract_order
                        ON subcontract_order.id = item.order_id
                       AND subcontract_order.status = 1
                       AND subcontract_order.is_deleted = FALSE
                      WHERE src.application_item_id IN (
                          SELECT allocation.external_item_id
                          FROM preplan_supply_action_allocations allocation
                          WHERE allocation.action_id = action.id
                            AND allocation.external_item_id IS NOT NULL)))
                """).setParameter("analysisId", analysisId).executeUpdate();

        em.createNativeQuery("""
                UPDATE preplan_supply_actions action
                SET status = 'IN_PROGRESS', updated_at = now()
                WHERE action.analysis_id = :analysisId
                  AND action.status IN ('CREATED','DONE')
                  AND action.external_document_type IN (
                      'PREPLAN_MAKE_TASK','SUBCONTRACT_MAKE_TASK')
                  AND EXISTS (
                      SELECT 1
                      FROM production_material_analysis_items child
                      WHERE child.id = action.external_document_id
                        AND child.analysis_id = action.analysis_id
                        AND child.source_type IN ('MAKE_COMPONENT','SUBCONTRACT_MAKE')
                        AND child.is_deleted = FALSE
                        AND (action.status = 'DONE'
                             OR child.submitted_qty + child.approved_qty > 0)
                        AND GREATEST(
                            child.requested_qty-child.approved_qty
                            + COALESCE((
                                SELECT SUM(GREATEST(
                                    plan_item.qty-COALESCE(plan_item.iqty,0),0))
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
                            ),0), 0) > 0
                  )
                """).setParameter("analysisId", analysisId).executeUpdate();

        em.createNativeQuery("""
                UPDATE preplan_supply_actions action
                SET status = 'DONE', updated_at = now()
                FROM v_preplan_buy_action_slice_progress progress
                WHERE action.id = progress.action_id
                  AND action.analysis_id = :analysisId
                  AND action.status IN ('CREATED','IN_PROGRESS')
                  AND action.external_document_type = 'PURCHASE_REQUEST'
                  AND action.safety_replenishment_qty > 0
                  AND progress.demand_qualified_qty
                      >= progress.demand_requested_qty
                  AND progress.safety_qualified_qty
                      >= progress.safety_requested_qty
                """).setParameter("analysisId", analysisId).executeUpdate();

        em.createNativeQuery("""
                UPDATE preplan_supply_actions action
                SET status = 'DONE', updated_at = now()
                WHERE action.analysis_id = :analysisId
                  AND action.status IN ('CREATED','IN_PROGRESS')
                  AND action.external_document_type = 'PURCHASE_REQUEST'
                  AND action.safety_replenishment_qty = 0
                  AND action.requested_qty <= COALESCE((
                      -- V463：合并订货行按来源 FIFO 分摊到各申请行后再汇总。
                      SELECT SUM(fn_purchase_order_source_share(
                          item.id, src.request_item_id,
                          GREATEST(
                              COALESCE((
                                  SELECT SUM(CASE
                                      WHEN inspection.id IS NULL
                                      THEN receipt_item.qty * COALESCE(
                                          receipt_item.unit_rate,1)
                                      WHEN inspection.status IN ('PARTIAL','RESOLVED')
                                      THEN inspection.warehouse_stocked_base_qty
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
                                  * COALESCE(item.unit_rate,1), 0)))
                      FROM purchase_order_item_sources src
                      JOIN purchase_order_items item
                        ON item.id = src.order_item_id
                       AND item.is_deleted = FALSE
                      JOIN purchase_orders purchase_order
                        ON purchase_order.id = item.order_id
                       AND purchase_order.status = 1
                       AND purchase_order.is_deleted = FALSE
                      WHERE src.request_item_id IN (
                          SELECT allocation.external_item_id
                          FROM preplan_supply_action_allocations allocation
                          WHERE allocation.action_id = action.id
                            AND allocation.external_item_id IS NOT NULL)
                  ),0)
                """).setParameter("analysisId", analysisId).executeUpdate();

        em.createNativeQuery("""
                UPDATE preplan_supply_actions action
                SET status = 'DONE', updated_at = now()
                WHERE action.analysis_id = :analysisId
                  AND action.status IN ('CREATED','IN_PROGRESS')
                  AND action.external_document_type = 'SUBCONTRACT_APPLICATION'
                  AND action.requested_qty <= COALESCE((
                      -- V463：合并订货行按来源 FIFO 分摊到各申请行后再汇总。
                      SELECT SUM(fn_subcontract_order_source_share(
                          item.id, src.application_item_id,
                          GREATEST(
                              COALESCE((
                                  SELECT SUM(CASE
                                      WHEN inspection.id IS NULL
                                      THEN receipt_item.qty * COALESCE(
                                          receipt_item.unit_rate,1)
                                      WHEN inspection.status IN ('PARTIAL','RESOLVED')
                                      THEN inspection.warehouse_stocked_base_qty
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
                                  * COALESCE(item.unit_rate,1), 0)))
                      FROM subcontract_order_item_sources src
                      JOIN subcontract_order_items item
                        ON item.id = src.order_item_id
                       AND item.is_deleted = FALSE
                      JOIN subcontract_orders subcontract_order
                        ON subcontract_order.id = item.order_id
                       AND subcontract_order.status = 1
                       AND subcontract_order.is_deleted = FALSE
                      WHERE src.application_item_id IN (
                          SELECT allocation.external_item_id
                          FROM preplan_supply_action_allocations allocation
                          WHERE allocation.action_id = action.id
                            AND allocation.external_item_id IS NOT NULL)
                  ),0)
                """).setParameter("analysisId", analysisId).executeUpdate();

        em.createNativeQuery("""
                UPDATE preplan_supply_actions action
                SET status = 'DONE', updated_at = now()
                WHERE action.analysis_id = :analysisId
                  AND action.status IN ('CREATED','IN_PROGRESS')
                  AND action.external_document_type IN (
                      'PREPLAN_MAKE_TASK','SUBCONTRACT_MAKE_TASK')
                  AND EXISTS (
                      SELECT 1
                      FROM production_material_analysis_items child
                      WHERE child.id = action.external_document_id
                        AND child.analysis_id = action.analysis_id
                        AND child.source_type IN ('MAKE_COMPONENT','SUBCONTRACT_MAKE')
                        AND child.is_deleted = FALSE
                        AND GREATEST(
                            child.requested_qty-child.approved_qty
                            + COALESCE((
                                SELECT SUM(GREATEST(
                                    plan_item.qty-COALESCE(plan_item.iqty,0),0))
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
                            ),0), 0) = 0
                  )
                """).setParameter("analysisId", analysisId).executeUpdate();
    }

    /**
     * Persists the single authoritative pre-plan allocation snapshot.
     *
     * <p>Existing production hard commitments are reserved first. Current production kits are
     * allocated next and additional START capacity last. SHIP/REFERENCE rows are warning-only
     * and cannot reserve this pool, so every actionable depth-one readiness projection and
     * production hard-gate allocation uses one conserved pool.</p>
     */
    private void persistAllocationSnapshot(
            UUID analysisId,
            UUID warehouseId,
            List<SourceLine> sources,
            List<BomNode> nodes,
            AvailabilitySnapshot availability) {
        Map<UUID, List<BomNode>> directBySource = nodes.stream()
                .filter(node -> node.depth() == 1)
                .collect(Collectors.groupingBy(BomNode::analysisItemId,
                        LinkedHashMap::new, Collectors.toList()));
        Map<MaterialDimension, BigDecimal> stockAfterSafety = availableAfterSafety(
                nodes, availability.stock());
        Set<MaterialDimension> dimensions = Set.copyOf(stockAfterSafety.keySet());
        Map<MaterialDimension, BigDecimal> externalHardCommitments = softCommittedStock(
                analysisId, warehouseId, dimensions, HARD_COMMITMENT_STAGES);
        Map<String, String> effectiveRoutes = loadEffectiveRoutes(analysisId);
        // 2026-09-05 简化：子件不再接管子树需求（delegated 清零口径废除）。
        Set<String> delegatedMakeNodes = Set.of();
        Map<String, BigDecimal> subcontractTakeoverByNode =
                loadSubcontractTakeoverByNode(analysisId);
        // V307 精确到货归属：先在扣除安全库存后的真实可分配池内，为原供应
        // 分摊行锁定 secured coverage；同分析兄弟产品只能看到扣除后的共享池。
        // 没有 exact 子账的历史 V298 预留仍留在共享池，维持兼容语义。
        List<ExactPegRecord> exactPegs = loadExactPegs(analysisId, warehouseId);
        BorrowTuning exactTuning = planExactPegs(exactPegs, nodes, stockAfterSafety,
                availability.usableByWarehouse())
                .combinedWith(planFormalCoverage(
                        formalMaterialCoverage(analysisId, warehouseId), nodes));
        // 现货层借用（调货）：存在 ACTIVE 借用记录时，先按当前库存跑一次
        // 无借用的基线投影，据此计算每笔的精确生效量 m（min(申请, 借出方
        // 基线分配, 借入方基线缺口)），再用 cap+secured 重跑主投影：
        // 借出方精确减少 m、借入方精确增加 m、第三方路径完全不变。
        List<BorrowRecord> borrows = loadActiveBorrows(analysisId);
        BorrowTuning borrowTuning = BorrowTuning.NONE;
        Map<UUID, BigDecimal> borrowEffective = Map.of();
        if (!borrows.isEmpty()) {
            Map<MaterialDimension, BigDecimal> exactStock = subtractCommitments(
                    stockAfterSafety, exactTuning.earmarkedByDimension());
            AllocationProjection baseline = computeAllocationProjection(
                    sources, nodes, exactStock, externalHardCommitments,
                    effectiveRoutes, delegatedMakeNodes,
                    subcontractTakeoverByNode, exactTuning.fresh());
            BorrowPlanOutcome outcome = BorrowTuning.plan(borrows, baseline.allocations());
            borrowTuning = outcome.tuning();
            borrowEffective = outcome.effectiveByBorrow();
        }
        ensureExactPegBorrowCompatibility(exactPegs, borrows, borrowEffective);
        BorrowTuning tuning = exactTuning.combinedWith(borrowTuning);
        Map<MaterialDimension, BigDecimal> tunedStock = tuning.isEmpty()
                ? stockAfterSafety
                : subtractCommitments(stockAfterSafety, tuning.earmarkedByDimension());
        AllocationProjection projection = computeAllocationProjection(
                sources, nodes, tunedStock, externalHardCommitments,
                effectiveRoutes, delegatedMakeNodes,
                subcontractTakeoverByNode, tuning);
        if (!borrows.isEmpty()) {
            persistBorrowEffectiveQuantities(borrowEffective);
        }
        NestedDiagnosticPlan nestedDiagnostic = projection.nestedDiagnostic();
        nodes = projection.nodes();
        StagePlan stagePlan = projection.stagePlan();
        StageAllocation finishAllocation = stagePlan.finish();
        StageExtension shipAllocation = stagePlan.ship();
        StageExtension startAllocation = stagePlan.start();
        TimePhasedPool readyByPool = new TimePhasedPool(
                finishAllocation.remainingPool(), availability.inbound());
        for (SourceLine source : orderedSources(sources)) {
            BigDecimal demand = source.materialRequirementQty();
            List<BomNode> direct = directBySource.getOrDefault(
                    source.analysisItemId(), List.of());
            List<BomNode> productionGates = direct.stream()
                    .filter(MaterialAnalysisService::productionGate).toList();
            BigDecimal readyStart = startAllocation.readyByItem().getOrDefault(
                    source.analysisItemId(), BigDecimal.ZERO.setScale(4));
            BigDecimal readyFinish = finishAllocation.readyByItem().getOrDefault(
                    source.analysisItemId(), BigDecimal.ZERO.setScale(4));
            BigDecimal readyShip = shipAllocation.readyByItem().getOrDefault(
                    source.analysisItemId(), BigDecimal.ZERO.setScale(4));
            BigDecimal readyByDate = readyByPool.maxReadyFromBaseExact(
                    readyFinish, demand, productionGates,
                    source.deliveryDate());
            readyByPool.consumeIncrementExact(
                    readyFinish, readyByDate, productionGates,
                    source.deliveryDate());
            em.createNativeQuery("""
                    UPDATE production_material_analysis_items
                    SET ready_now_qty=:readyFinish,
                        ready_start_qty=:readyStart,
                        ready_finish_qty=:readyFinish,
                        ready_ship_qty=:readyShip,
                        ready_by_date_qty=:readyByDate,
                        updated_at=now(), updated_by=:actorId
                    WHERE id=:itemId AND analysis_id=:analysisId AND is_deleted=FALSE
                    """)
                    .setParameter("readyStart", source.unplannedReadyQty(readyStart))
                    .setParameter("readyFinish", source.unplannedReadyQty(readyFinish))
                    .setParameter("readyShip", source.unplannedReadyQty(readyShip))
                    .setParameter("readyByDate", source.unplannedReadyQty(readyByDate))
                    .setParameter("actorId", currentUser.requireId())
                    .setParameter("itemId", source.analysisItemId())
                    .setParameter("analysisId", analysisId)
                    .executeUpdate();
        }

        Map<String, NodeAllocation> hardAllocations = projection.hardAllocations();
        Map<String, NodeAllocation> allocations = projection.allocations();

        for (BomNode node : nodes) {
            NodeAllocation allocation = allocations.getOrDefault(
                    nodeAllocationKey(node), NodeAllocation.ZERO);
            BigDecimal startAllocated = node.depth() == 1 && node.hardGate()
                    && STAGE_START.equals(node.controlStage())
                    ? hardAllocations.getOrDefault(
                            nodeAllocationKey(node), NodeAllocation.ZERO).allocatedQty()
                    : BigDecimal.ZERO.setScale(4);
            BigDecimal finishAllocated = node.depth() == 1 && productionGate(node)
                    ? finishAllocation.nodeAllocations().getOrDefault(
                            nodeAllocationKey(node), NodeAllocation.ZERO).allocatedQty()
                    : BigDecimal.ZERO.setScale(4);
            BigDecimal shipAllocated = node.depth() == 1 && node.hardGate()
                    && HARD_COMMITMENT_STAGES.contains(node.controlStage())
                    ? node.requiredForOutput(shipAllocation.readyByItem().getOrDefault(
                            node.analysisItemId(), BigDecimal.ZERO.setScale(4)))
                    : BigDecimal.ZERO.setScale(4);
            if (node.depth() > 1) {
                startAllocated = allocation.allocatedQty();
                finishAllocated = allocation.allocatedQty();
                shipAllocated = allocation.allocatedQty();
            }
            String nodeKey = nodeAllocationKey(node);
            // V458/ADR-062 修订一②：有子层级的委外件与自制完全同构——下层未齐套时
            // lower_level_pending=TRUE（进「暂不可安排」），齐套前禁止「下达委外」。
            String effectiveRoute = effectiveRoutes.getOrDefault(
                    nodeKey, node.suggestion());
            boolean lowerPending = node.hasChildren()
                    && ("MAKE".equals(effectiveRoute)
                        || "SUBCONTRACT".equals(effectiveRoute))
                    && !delegatedMakeNodes.contains(nodeKey)
                    && !STAGE_REFERENCE.equals(node.controlStage())
                    && nestedDiagnostic.hasUncoveredDirectChild(node);
            em.createNativeQuery("""
                    UPDATE production_material_analysis_materials
                    SET required_qty=:required,
                        allocated_available_qty=:allocated,
                        allocated_start_qty=:allocatedStart,
                        allocated_finish_qty=:allocatedFinish,
                        allocated_ship_qty=:allocatedShip,
                        shortage_qty=:shortage,
                        lower_level_pending=:lowerPending,
                        updated_at=now(), updated_by=:actorId
                    WHERE analysis_id=:analysisId AND analysis_item_id=:analysisItemId
                      AND node_key=:nodeKey AND active=TRUE
                    """)
                    .setParameter("required", node.snapshotRequiredQty())
                    .setParameter("allocated", allocation.allocatedQty())
                    .setParameter("allocatedStart", startAllocated)
                    .setParameter("allocatedFinish", finishAllocated)
                    .setParameter("allocatedShip", shipAllocated)
                    .setParameter("shortage", allocation.shortageQty())
                    .setParameter("lowerPending", lowerPending)
                    .setParameter("actorId", currentUser.requireId())
                    .setParameter("analysisId", analysisId)
                    .setParameter("analysisItemId", node.analysisItemId())
                    .setParameter("nodeKey", node.nodeKey())
                    .executeUpdate();
        }
    }

    /**
     * Cross-analysis soft commitments come from other analyses' batch snapshots.
     * Draft-plan quantities are already included in those snapshots. Formal
     * reservations and issued quantities are netted out because neither belongs
     * to the public pool exposed by {@code v_stock_available}.
     * V298：其它分析已收货绑定的量（owner_type='PREPLAN_ANALYSIS' 生效预留）已被
     * {@code v_stock_available} 物理扣除，其快照承诺须按绑定量净额扣除，避免重复扣减。
     */
    private Map<MaterialDimension, BigDecimal> softCommittedStock(
            UUID analysisId, UUID warehouseId, Set<MaterialDimension> dimensions,
            Set<String> includedStages) {
        if (dimensions.isEmpty()) return Map.of();
        Set<String> effectiveStages = includedStages.stream()
                .filter(HARD_COMMITMENT_STAGES::contains)
                .collect(Collectors.toUnmodifiableSet());
        if (effectiveStages.isEmpty()) return Map.of();
        Set<UUID> goodsIds = dimensions.stream().map(MaterialDimension::goodsId)
                .collect(Collectors.toSet());
        List<Object[]> rows = NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                WITH raw_commitments AS (
                    SELECT analysis.id AS claim_analysis_id,
                           material.goods_id, material.color_id, material.unit_id,
                           SUM(LEAST(
                               material.allocated_available_qty,
                               material.required_qty
                           ))::numeric AS qty
                    FROM production_material_analysis_materials material
                    JOIN production_material_analyses analysis
                      ON analysis.id = material.analysis_id
                    JOIN production_material_analysis_items source
                      ON source.id = material.analysis_item_id
                     AND source.analysis_id = material.analysis_id
                     AND source.is_deleted = FALSE
                    WHERE fn_warehouse_same_main(analysis.warehouse_id,:warehouseId)
                      AND analysis.id <> :analysisId
                      AND analysis.is_deleted = FALSE
                      AND analysis.status IN ('ACTIVE','PARTIALLY_PLANNED')
                      AND material.active = TRUE AND material.depth = 1
                      AND material.hard_gate = TRUE
                      AND material.control_stage IN (:includedStages)
                      AND material.goods_id IN (:goodsIds)
                    GROUP BY analysis.id, material.goods_id, material.color_id, material.unit_id
                ),
                commitments AS (
                    SELECT claim_analysis_id, goods_id, color_id, unit_id,
                           SUM(qty)::numeric AS qty
                    FROM raw_commitments
                    GROUP BY claim_analysis_id, goods_id, color_id, unit_id
                ),
                netted AS (
                    SELECT c.goods_id, c.color_id, c.unit_id,
                           GREATEST(c.qty - COALESCE((
                               SELECT SUM(GREATEST(formal.qty-formal.released_qty,0))
                               FROM stock_reservations formal
                               JOIN production_material_demands demand
                                 ON formal.owner_type='PRODUCTION_MATERIAL_DEMAND'
                                 AND formal.owner_id=demand.id AND demand.is_deleted=FALSE
                                 AND demand.status NOT IN ('RELEASED','REVERSED')
                               JOIN production_plans plan ON plan.id=demand.plan_id
                                 AND plan.material_analysis_id=c.claim_analysis_id
                                 AND plan.status=1 AND plan.is_deleted=FALSE
                                 AND plan.is_canceled=FALSE
                               WHERE formal.is_deleted=FALSE
                                 AND fn_warehouse_same_main(formal.warehouse_id,:warehouseId)
                                 AND demand.goods_id=c.goods_id
                                 AND demand.color_id IS NOT DISTINCT FROM c.color_id
                                 AND demand.unit_id=c.unit_id
                                 AND EXISTS (
                                   SELECT 1 FROM production_material_analysis_materials original
                                   WHERE original.analysis_id=c.claim_analysis_id
                                     AND original.depth=1 AND original.active=TRUE
                                     AND original.goods_id=demand.goods_id
                                     AND original.color_id IS NOT DISTINCT FROM demand.color_id
                                     AND fn_analysis_plan_material_matches(
                                       plan.material_analysis_item_id,original.id))
                           ),0) - COALESCE((
                               SELECT SUM(LEAST(leaf.qty,GREATEST(
                                   COALESCE(available.available_qty,0)+leaf.qty
                                     -GREATEST(COALESCE(goods.min_qty,0)::numeric,0)::numeric,0)))
                               FROM (
                               SELECT r.warehouse_id,SUM(CASE
                                   WHEN EXISTS (
                                       SELECT 1
                                       FROM preplan_stock_entitlement_events tracked
                                       WHERE tracked.stock_reservation_id = r.id
                                   ) THEN COALESCE((
                                       SELECT SUM(balance.effective_qty)
                                       FROM v_preplan_stock_entitlement_beneficiary_balance
                                            balance
                                       JOIN production_material_analysis_materials eligible
                                         ON eligible.id=balance.beneficiary_analysis_material_id
                                        AND eligible.analysis_id=balance.beneficiary_analysis_id
                                        AND eligible.active=TRUE AND eligible.depth=1
                                        AND eligible.hard_gate=TRUE
                                        AND eligible.control_stage IN (:includedStages)
                                       WHERE balance.stock_reservation_id = r.id
                                         AND balance.beneficiary_analysis_id =
                                             c.claim_analysis_id
                                   ), 0)
                                   WHEN r.owner_id = c.claim_analysis_id
                                   THEN r.qty - r.consumed_qty - r.released_qty
                                   ELSE 0
                               END) AS qty
                               FROM stock_reservations r
                               WHERE r.is_deleted = FALSE
                                 AND r.status = 0
                                 AND r.owner_type = 'PREPLAN_ANALYSIS'
                                 AND fn_warehouse_same_main(r.warehouse_id,:warehouseId)
                                 AND r.goods_id = c.goods_id
                                 AND r.color_id IS NOT DISTINCT FROM c.color_id
                               GROUP BY r.warehouse_id
                               ) leaf
                               JOIN goods ON goods.id=c.goods_id
                               LEFT JOIN v_stock_available available
                                 ON available.warehouse_id=leaf.warehouse_id
                                AND available.goods_id=c.goods_id
                                AND available.color_id IS NOT DISTINCT FROM c.color_id
                           ), 0), 0)::numeric AS qty
                    FROM commitments c
                )
                SELECT goods_id, color_id, unit_id, SUM(qty)::numeric
                FROM netted
                GROUP BY goods_id, color_id, unit_id
                """).setParameter("analysisId", analysisId)
                .setParameter("warehouseId", warehouseId)
                .setParameter("includedStages", effectiveStages)
                .setParameter("goodsIds", goodsIds));
        Map<MaterialDimension, BigDecimal> result = new LinkedHashMap<>();
        for (Object[] row : rows) {
            MaterialDimension dimension = new MaterialDimension(
                    uuid(row[0]), uuid(row[1]), uuid(row[2]));
            if (dimensions.contains(dimension)) {
                result.put(dimension, decimal(row[3]));
            }
        }
        return Map.copyOf(result);
    }

    private Map<String, String> loadEffectiveRoutes(UUID analysisId) {
        Map<String, String> result = new LinkedHashMap<>();
        for (Object[] row : NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT analysis_item_id, node_key,
                       COALESCE(confirmed_route, source_suggestion)
                FROM production_material_analysis_materials
                WHERE analysis_id=:analysisId AND active=TRUE
                ORDER BY analysis_item_id, depth, node_key
                """).setParameter("analysisId", analysisId))) {
            result.put(uuid(row[0]) + "|" + string(row[1]), string(row[2]));
        }
        return Map.copyOf(result);
    }

    /**
     * MAKE nodes already promoted to a dedicated MAKE_COMPONENT analysis item.
     * Their descendants are owned by that child item and must not remain an
     * actionable duplicate in the parent's diagnostic tree.
     */
    private Set<String> loadDelegatedMakeNodes(UUID analysisId) {
        return loadDelegatedRequirementOwners(analysisId).keySet().stream()
                .map(MaterialNodeIdentity::allocationKey)
                .collect(Collectors.toUnmodifiableSet());
    }

    /**
     * V447 parent-output quantities whose recursive SUBCONTRACT descendants
     * are owned by an independent preparation analysis.  The parent demand
     * itself remains in the source analysis until the subcontracted item
     * returns and is physically stocked by the warehouse.
     */
    private Map<String, BigDecimal> loadSubcontractTakeoverByNode(
            UUID analysisId) {
        Map<String, BigDecimal> result = new LinkedHashMap<>();
        for (Object[] row : NativeQueryResults.objectArrayRows(
                em.createNativeQuery("""
                        SELECT material.analysis_item_id, material.node_key,
                               claim.active_parent_output_qty
                        FROM v_preplan_subcontract_parent_output_claim_balance claim
                        JOIN production_material_analysis_materials material
                          ON material.id = claim.source_parent_material_id
                         AND material.analysis_id = claim.source_analysis_id
                         AND material.active = TRUE
                        WHERE claim.source_analysis_id = :analysisId
                        ORDER BY material.analysis_item_id, material.node_key
                        """).setParameter("analysisId", analysisId))) {
            String key = uuid(row[0]) + "|" + string(row[1]);
            BigDecimal previous = result.putIfAbsent(key, decimal(row[2]));
            if (previous != null) {
                result.put(key, previous.add(decimal(row[2])));
            }
        }
        return Map.copyOf(result);
    }

    /**
     * Exact MAKE ownership relation for the read model. The child is resolved
     * exclusively through {@code parent_analysis_material_id}; goods identity
     * is deliberately not used because the same goods can occur on multiple
     * independent BOM paths.
     */
    private Map<MaterialNodeIdentity, DelegatedRequirementOwner>
            loadDelegatedRequirementOwners(UUID analysisId) {
        Map<MaterialNodeIdentity, DelegatedRequirementOwner> result =
                new LinkedHashMap<>();
        for (Object[] row : NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT parent_material.id,
                       parent_material.analysis_item_id,
                       parent_material.node_key,
                       child.id, child.source_ref, child.requested_qty
                FROM production_material_analysis_items child
                JOIN production_material_analysis_materials parent_material
                  ON parent_material.id = child.parent_analysis_material_id
                 AND parent_material.analysis_id = child.analysis_id
                WHERE child.analysis_id = :analysisId
                  AND child.source_type IN ('MAKE_COMPONENT','SUBCONTRACT_MAKE')
                  AND child.is_deleted = FALSE
                  AND parent_material.active = TRUE
                ORDER BY parent_material.analysis_item_id,
                         parent_material.node_key, child.id
                """).setParameter("analysisId", analysisId))) {
            MaterialNodeIdentity parent = new MaterialNodeIdentity(
                    uuid(row[1]), string(row[2]));
            DelegatedRequirementOwner owner = new DelegatedRequirementOwner(
                    uuid(row[0]), uuid(row[3]), string(row[4]), decimal(row[5]));
            DelegatedRequirementOwner previous = result.putIfAbsent(parent, owner);
            if (previous != null && !previous.equals(owner)) {
                throw conflict("同一自制节点存在多个有效子件需求，请先修复物料分析归属");
            }
        }
        return Map.copyOf(result);
    }

    /**
     * Explains a material row's current requirement without changing any
     * quantity. Positive requirements are always ACTIVE. For zero rows, an
     * exact MAKE child relation wins; otherwise the source/ancestor facts
     * explain why recursive demand is inactive.
     */
    static RequirementProjection requirementProjection(
            MaterialRow row,
            Map<MaterialNodeIdentity, MaterialRow> materialsByNode,
            Map<MaterialNodeIdentity, DelegatedRequirementOwner> delegatedOwners,
            SourceLine source) {
        return requirementProjection(
                row, materialsByNode, delegatedOwners, Set.of(), source);
    }

    static RequirementProjection requirementProjection(
            MaterialRow row,
            Map<MaterialNodeIdentity, MaterialRow> materialsByNode,
            Map<MaterialNodeIdentity, DelegatedRequirementOwner> delegatedOwners,
            Set<MaterialNodeIdentity> subcontractPreparationOwners,
            SourceLine source) {
        if (row.requiredQty().signum() > 0) {
            return RequirementProjection.active();
        }

        MaterialRow cursor = row;
        Set<MaterialNodeIdentity> visited = new HashSet<>();
        while (cursor.parentNodeKey() != null) {
            MaterialNodeIdentity parentIdentity = new MaterialNodeIdentity(
                    cursor.analysisItemId(), cursor.parentNodeKey());
            if (!visited.add(parentIdentity)) {
                return RequirementProjection.inactive();
            }
            DelegatedRequirementOwner owner = delegatedOwners.get(parentIdentity);
            if (owner != null) {
                return RequirementProjection.delegated(owner);
            }
            if (subcontractPreparationOwners.contains(parentIdentity)) {
                return RequirementProjection.delegatedToSubcontractPreparation();
            }
            MaterialRow parent = materialsByNode.get(parentIdentity);
            if (parent == null) break;
            cursor = parent;
        }

        if (source != null
                && source.requestedQty().signum() > 0
                && source.submittedQty().add(source.approvedQty()).signum() > 0
                && source.remainingAnalysisQty().signum() == 0) {
            return RequirementProjection.transferredToPlan();
        }

        cursor = row;
        visited.clear();
        while (cursor.parentNodeKey() != null) {
            MaterialNodeIdentity parentIdentity = new MaterialNodeIdentity(
                    cursor.analysisItemId(), cursor.parentNodeKey());
            if (!visited.add(parentIdentity)) {
                return RequirementProjection.inactive();
            }
            MaterialRow parent = materialsByNode.get(parentIdentity);
            if (parent == null) return RequirementProjection.inactive();
            if (STAGE_REFERENCE.equals(parent.controlStage())) {
                return RequirementProjection.inactiveReference();
            }
            cursor = parent;
        }

        cursor = row;
        visited.clear();
        while (cursor.parentNodeKey() != null) {
            MaterialNodeIdentity parentIdentity = new MaterialNodeIdentity(
                    cursor.analysisItemId(), cursor.parentNodeKey());
            if (!visited.add(parentIdentity)) {
                return RequirementProjection.inactive();
            }
            MaterialRow parent = materialsByNode.get(parentIdentity);
            if (parent == null) return RequirementProjection.inactive();
            if (parent.requiredQty().signum() > 0) {
                String route = blankToNull(parent.confirmedRoute());
                if (route == null) route = parent.suggestion();
                if (!Set.of("MAKE", "SUBCONTRACT").contains(route)) {
                    return RequirementProjection.inactiveParentRoute();
                }
                if (parent.shortageQty().signum() == 0) {
                    return RequirementProjection.inactiveParentCovered();
                }
                return RequirementProjection.inactive();
            }
            cursor = parent;
        }
        return RequirementProjection.inactive();
    }

    private static Map<MaterialDimension, BigDecimal> subtractCommitments(
            Map<MaterialDimension, BigDecimal> stock,
            Map<MaterialDimension, BigDecimal> commitments) {
        Map<MaterialDimension, BigDecimal> result = new LinkedHashMap<>();
        stock.forEach((dimension, qty) -> result.put(
                dimension,
                qty.subtract(commitments.getOrDefault(dimension, BigDecimal.ZERO))
                        .max(BigDecimal.ZERO).setScale(4, RoundingMode.DOWN)));
        return Map.copyOf(result);
    }

    private static Map<MaterialDimension, BigDecimal> availableAfterSafety(
            List<BomNode> nodes,
            Map<MaterialDimension, StockValue> stock) {
        Map<MaterialDimension, BigDecimal> safetyByDimension = new LinkedHashMap<>();
        nodes.forEach(node -> safetyByDimension.merge(
                node.dimension(), node.safetyStock(), BigDecimal::max));
        Map<MaterialDimension, BigDecimal> result = new LinkedHashMap<>();
        safetyByDimension.forEach((dimension, safety) -> result.put(
                dimension,
                stock.getOrDefault(dimension, StockValue.ZERO).availableAfterSafety(safety)));
        return Map.copyOf(result);
    }

    /** 单仓展示与主重算共用的安全库存次序：先还原本分析归属，再扣安全库存。 */
    static BigDecimal availableIncludingOwnAfterSafety(
            BigDecimal publicAvailable, BigDecimal ownPegged, BigDecimal safetyStock) {
        return publicAvailable.max(BigDecimal.ZERO)
                .add(ownPegged.max(BigDecimal.ZERO))
                .subtract(safetyStock.max(BigDecimal.ZERO))
                .max(BigDecimal.ZERO)
                .setScale(4, RoundingMode.DOWN);
    }

    static BigDecimal availableWithQualifiedOwnAfterSafety(
            BigDecimal publicAvailable, BigDecimal ownPegged, BigDecimal qualifiedOwn,
            BigDecimal safetyStock) {
        BigDecimal qualified = qualifiedOwn.max(BigDecimal.ZERO).min(ownPegged.max(BigDecimal.ZERO));
        return availableIncludingOwnAfterSafety(publicAvailable,
                ownPegged.subtract(qualified).max(BigDecimal.ZERO), safetyStock)
                .add(qualified).setScale(4, RoundingMode.DOWN);
    }

    /**
     * 公共安全库存补库只看公共未预留量与仍会到货的公共补库切片。
     * 本分析 exact peg 是生产需求权益，不能被误当成公共安全库存。
     */
    static BigDecimal publicSafetyReplenishmentGap(
            BigDecimal safetyStock,
            BigDecimal publicAvailable,
            BigDecimal openSafetySupply) {
        return safetyStock.max(BigDecimal.ZERO)
                .subtract(publicAvailable.max(BigDecimal.ZERO))
                .subtract(openSafetySupply.max(BigDecimal.ZERO))
                .max(BigDecimal.ZERO)
                .setScale(4, RoundingMode.CEILING);
    }

    /**
     * 仍需绑定到分析节点的生产需求。已经 exact 到该节点但暂时被安全库存
     * 阻挡的合格量不能再次采购；普通已分配现货与 exact 覆盖取较大者，
     * 因为 allocatedAvailableQty 已可能包含 exact 份额。
     */
    static BigDecimal unboundDemandSupplyGap(
            BigDecimal requiredQty,
            BigDecimal allocatedAvailableQty,
            BigDecimal exactPeggedQty) {
        return unboundDemandSupplyGap(requiredQty, allocatedAvailableQty,
                exactPeggedQty, BigDecimal.ZERO);
    }

    static BigDecimal unboundDemandSupplyGap(
            BigDecimal requiredQty,
            BigDecimal allocatedAvailableQty,
            BigDecimal exactPeggedQty,
            BigDecimal subcontractHandoffFutureQty) {
        return requiredQty.max(BigDecimal.ZERO)
                .subtract(allocatedAvailableQty.max(BigDecimal.ZERO)
                        .max(exactPeggedQty.max(BigDecimal.ZERO).add(
                                subcontractHandoffFutureQty.max(BigDecimal.ZERO))))
                .max(BigDecimal.ZERO)
                .setScale(4, RoundingMode.CEILING);
    }

    /**
     * 把生效 exact peg 变成节点 secured coverage。
     *
     * <p>容量只取 {@code stockAfterSafety}，因此即使原分析的预留量大于可动用量，
     * 安全库存也不会被 exact 身份绕过。目标节点当前需求之外的超收量不锁到该行，
     * 仍是本分析内部共享余量；历史无 exact 子账的 V298 数量全部维持共享。</p>
     */
    static BorrowTuning planExactPegs(
            List<ExactPegRecord> exactPegs,
            List<BomNode> nodes,
            Map<MaterialDimension, BigDecimal> stockAfterSafety) {
        return planExactPegs(exactPegs,nodes,stockAfterSafety,Map.of());
    }

    static BorrowTuning planExactPegs(
            List<ExactPegRecord> exactPegs,
            List<BomNode> nodes,
            Map<MaterialDimension, BigDecimal> stockAfterSafety,
            Map<WarehouseMaterialDimension,BigDecimal> usableByWarehouse) {
        if (exactPegs == null || exactPegs.isEmpty()) return BorrowTuning.NONE;
        Map<String, BigDecimal> requiredByNode = nodes.stream().collect(
                Collectors.toMap(
                        MaterialAnalysisService::nodeAllocationKey,
                        BomNode::snapshotRequiredQty,
                        BigDecimal::max,
                        LinkedHashMap::new));
        Map<MaterialDimension, BigDecimal> capacity = new LinkedHashMap<>();
        stockAfterSafety.forEach((dimension, qty) -> capacity.put(
                dimension, qty.max(BigDecimal.ZERO).setScale(4, RoundingMode.DOWN)));
        Map<String, BigDecimal> secured = new LinkedHashMap<>();
        Map<MaterialDimension, BigDecimal> earmarked = new LinkedHashMap<>();
        Map<WarehouseMaterialDimension,BigDecimal> leafCapacity = new HashMap<>(usableByWarehouse);
        for (ExactPegRecord peg : exactPegs) {
            String nodeKey = peg.analysisItemId() + "|" + peg.nodeKey();
            BigDecimal targetHeadroom = requiredByNode
                    .getOrDefault(nodeKey, BigDecimal.ZERO)
                    .subtract(secured.getOrDefault(nodeKey, BigDecimal.ZERO))
                    .max(BigDecimal.ZERO);
            BigDecimal dimensionCapacity = capacity.getOrDefault(
                    peg.dimension(), BigDecimal.ZERO);
            WarehouseMaterialDimension leaf = peg.warehouseId()==null ? null
                    : new WarehouseMaterialDimension(peg.warehouseId(),peg.dimension());
            if (leaf!=null) dimensionCapacity=dimensionCapacity.min(
                    leafCapacity.getOrDefault(leaf,BigDecimal.ZERO));
            BigDecimal take = peg.effectiveQty()
                    .min(targetHeadroom)
                    .min(dimensionCapacity)
                    .max(BigDecimal.ZERO)
                    .setScale(4, RoundingMode.DOWN);
            if (take.signum() <= 0) continue;
            secured.merge(nodeKey, take, BigDecimal::add);
            earmarked.merge(peg.dimension(), take, BigDecimal::add);
            capacity.put(peg.dimension(), capacity.get(peg.dimension()).subtract(take));
            if (leaf!=null) leafCapacity.merge(leaf,take.negate(),BigDecimal::add);
        }
        return BorrowTuning.securedOnly(secured, earmarked);
    }

    private List<FormalMaterialCoverage> formalMaterialCoverage(
            UUID analysisId, UUID warehouseId) {
        // A completed MAKE output covers its parent directly. An assembled
        // subcontract target is still waiting for external processing, so its
        // consumed inputs must keep covering the original tree until return.
        List<Object[]> rows = NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT demand.id, material.analysis_item_id, material.node_key,
                       SUM(GREATEST(reservation.qty-reservation.released_qty,0))::numeric,
                       CASE WHEN source.source_type = 'MAKE_COMPONENT'
                         THEN GREATEST(COALESCE(segment.planned_qty,plan_item.qty)
                           - CASE WHEN segment.id IS NULL THEN COALESCE(plan_item.iqty,0)
                               ELSE COALESCE(finished.qty,0) END,0)
                           * COALESCE(segment.product_unit_rate,plan_item.unit_rate,1) ELSE NULL END
                FROM production_material_demands demand
                JOIN production_plans plan ON plan.id=demand.plan_id
                  AND plan.material_analysis_id=:analysisId
                  AND plan.status=1 AND plan.is_deleted=FALSE AND plan.is_canceled=FALSE
                JOIN production_material_analysis_items source
                  ON source.id=plan.material_analysis_item_id AND source.is_deleted=FALSE
                JOIN production_plan_items plan_item ON plan_item.plan_id=plan.id
                  AND plan_item.is_deleted=FALSE
                  AND (demand.source_plan_item_id IS NULL OR plan_item.id=demand.source_plan_item_id)
                LEFT JOIN production_execution_segments segment ON segment.id=demand.execution_segment_id
                LEFT JOIN LATERAL (
                  SELECT SUM(item.qty) AS qty FROM stock_document_items item
                  JOIN stock_documents document ON document.id=item.doc_id
                    AND document.doc_type='FINISHED_IN' AND document.status=1
                    AND document.is_deleted=FALSE
                  WHERE item.execution_segment_id=segment.id AND item.is_deleted=FALSE
                ) finished ON TRUE
                JOIN stock_reservations reservation
                  ON reservation.owner_type='PRODUCTION_MATERIAL_DEMAND'
                  AND reservation.owner_id=demand.id AND reservation.is_deleted=FALSE
                  AND (fn_warehouse_same_main(reservation.warehouse_id,:warehouseId)
                       OR reservation.requires_qualified_origin)
                JOIN production_material_analysis_materials material
                  ON material.analysis_id=:analysisId AND material.active=TRUE
                  AND fn_analysis_plan_material_matches(plan.material_analysis_item_id,material.id)
                  AND material.goods_id=demand.goods_id
                  AND material.color_id IS NOT DISTINCT FROM demand.color_id
                  AND material.unit_id=demand.unit_id
                WHERE demand.is_deleted=FALSE AND demand.status NOT IN ('RELEASED','REVERSED')
                GROUP BY demand.id,material.analysis_item_id,material.node_key,material.path,
                         source.source_type,segment.id,segment.planned_qty,segment.product_unit_rate,
                         plan_item.qty,plan_item.iqty,plan_item.unit_rate,finished.qty
                ORDER BY demand.id,material.path,material.node_key
                """).setParameter("analysisId", analysisId)
                .setParameter("warehouseId", warehouseId));
        return rows.stream().map(row -> new FormalMaterialCoverage(
                uuid(row[0]), uuid(row[1]), string(row[2]), decimal(row[3]),
                row[4]==null ? null : decimal(row[4]))).toList();
    }

    private Map<String,List<BigDecimal>> plannedMaterialBatches(UUID analysisId) {
        Map<String,List<BigDecimal>> result = new LinkedHashMap<>();
        for (Object[] row : NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT COALESCE(parent.analysis_item_id,source.id),
                       CASE WHEN parent.node_role='ROOT_SUPPLY' THEN NULL ELSE parent.node_key END,
                       CASE WHEN source.source_type = 'MAKE_COMPONENT'
                         THEN GREATEST(COALESCE(segment.planned_qty,item.qty)
                           -COALESCE(finished.qty,item.iqty,0),0)
                         ELSE COALESCE(segment.planned_qty,item.qty) END * COALESCE(item.unit_rate,1)
                FROM production_plans plan
                JOIN production_plan_items item ON item.plan_id=plan.id AND item.is_deleted=FALSE
                JOIN production_material_analysis_items source
                  ON source.id=plan.material_analysis_item_id AND source.is_deleted=FALSE
                LEFT JOIN production_material_analysis_materials parent
                  ON parent.id=source.parent_analysis_material_id
                LEFT JOIN production_execution_segments segment
                  ON segment.source_plan_item_id=item.id AND segment.is_deleted=FALSE
                  AND segment.status NOT IN ('CANCELLED','REVERSED')
                LEFT JOIN LATERAL (
                  SELECT COALESCE(SUM(output.qty),0) AS qty
                  FROM stock_document_items output
                  JOIN stock_documents document ON document.id=output.doc_id
                    AND document.doc_type='FINISHED_IN' AND document.status=1
                    AND document.is_deleted=FALSE
                  WHERE segment.id IS NOT NULL AND output.execution_segment_id=segment.id
                    AND output.is_deleted=FALSE
                ) finished ON segment.id IS NOT NULL
                WHERE plan.material_analysis_id=:analysisId
                  AND plan.status IN (0,1) AND plan.is_deleted=FALSE AND plan.is_canceled=FALSE
                ORDER BY plan.created_at,plan.id,segment.segment_no
                """).setParameter("analysisId",analysisId))) {
            BigDecimal qty = decimal(row[2]);
            if (qty.signum()>0) result.computeIfAbsent(
                    uuid(row[0])+"|"+Objects.toString(row[1],""),ignored -> new ArrayList<>()).add(qty);
        }
        return Map.copyOf(result);
    }

    /** A formal reservation or issued material covers only its original batch. */
    static BorrowTuning planFormalCoverage(
            List<FormalMaterialCoverage> coverage, List<BomNode> nodes) {
        Map<String, BomNode> byKey = nodes.stream().collect(Collectors.toMap(
                MaterialAnalysisService::nodeAllocationKey, node -> node));
        Map<UUID, BigDecimal> usedByDemand = new HashMap<>();
        Map<String, BigDecimal> secured = new LinkedHashMap<>();
        for (FormalMaterialCoverage row : coverage) {
            String key = row.analysisItemId() + "|" + row.nodeKey();
            BomNode node = byKey.get(key);
            if (node==null) continue;
            BigDecimal headroom = node.snapshotRequiredQty()
                    .subtract(secured.getOrDefault(key, BigDecimal.ZERO)).max(BigDecimal.ZERO);
            if (row.remainingParentOutputQty()!=null) {
                headroom = headroom.min(node.requiredForSingleParentOutput(row.remainingParentOutputQty()));
            }
            BigDecimal available = row.coveredQty()
                    .subtract(usedByDemand.getOrDefault(row.demandId(), BigDecimal.ZERO))
                    .max(BigDecimal.ZERO);
            BigDecimal take = available.min(headroom);
            if (take.signum() <= 0) continue;
            secured.merge(key, take, BigDecimal::add);
            usedByDemand.merge(row.demandId(), take, BigDecimal::add);
        }
        // Formal reservations are already absent from public stock, and issued
        // quantities are no longer in stock at all. Never debit the pool again.
        return BorrowTuning.securedOnly(secured, Map.of());
    }

    record FormalMaterialCoverage(
            UUID demandId, UUID analysisItemId, String nodeKey, BigDecimal coveredQty,
            BigDecimal remainingParentOutputQty) {
        FormalMaterialCoverage(UUID demandId, UUID analysisItemId, String nodeKey, BigDecimal coveredQty) {
            this(demandId,analysisItemId,nodeKey,coveredQty,null);
        }
    }

    /**
     * V288 是人工软借用，V307 是 IQC 来源硬归属；二者若落在同一物料维度，
     * 未经显式“变更受益方”业务不能隐式互相抵消，故刷新 fail closed。
     */
    static void ensureExactPegBorrowCompatibility(
            List<ExactPegRecord> exactPegs, List<BorrowRecord> borrows,
            Map<UUID, BigDecimal> effectiveByBorrow) {
        if (exactPegs == null || exactPegs.isEmpty()
                || borrows == null || borrows.isEmpty()) return;
        Set<MaterialDimension> exactDimensions = exactPegs.stream()
                .filter(peg -> peg.effectiveQty().signum() > 0)
                .map(ExactPegRecord::dimension)
                .collect(Collectors.toSet());
        boolean overlaps = borrows.stream()
                .filter(borrow -> effectiveByBorrow.getOrDefault(
                        borrow.id(), BigDecimal.ZERO).signum() > 0)
                .anyMatch(borrow -> exactDimensions.contains(borrow.dimension()));
        if (overlaps) {
            throw conflict("该物料已有按原计划行锁定的合格入库，不能再用旧版分析内调货"
                    + "静默改变归属；请先走显式受益方变更/归还流程");
        }
    }

    /**
     * 借用（调货）对共享池分配的精确调节。
     *
     * <p>一笔生效借用把借出节点基线分配中的 m 件 earmark 给借入节点：
     * cap（借出节点覆盖上限 = 基线 − Σm出）保证借出方精确减少；
     * secured（借入节点池外锁定 Σm入）保证借入方精确增加；池总量按 Σm
     * earmark 后，第三方路径看到的可用量与基线完全一致，不产生连锁漂移。
     * 数量守恒：pool' + Σsecured = pool。</p>
     *
     * <p>主线（finish→ship→start→top-up 共用同一剩余池血脉）与诊断投影
     * （nested 独立池投影）分别记 secured 消耗，互不串扰。</p>
     */
    static final class BorrowTuning {
        static final BorrowTuning NONE = new BorrowTuning(Map.of(), Map.of(), Map.of());

        /** nodeAllocKey → 覆盖上限（仅借出节点有）。 */
        private final Map<String, BigDecimal> caps;
        /** nodeAllocKey → 池外锁定覆盖量（仅借入节点有）。 */
        private final Map<String, BigDecimal> secured;
        /** 维度 → earmark 总量（从自由池取出，专供借入节点）。 */
        private final Map<MaterialDimension, BigDecimal> earmarked;
        private final Map<String, BigDecimal> securedUsedMain = new HashMap<>();
        private final Map<String, BigDecimal> securedUsedDiagnostic = new HashMap<>();

        private BorrowTuning(Map<String, BigDecimal> caps,
                             Map<String, BigDecimal> secured,
                             Map<MaterialDimension, BigDecimal> earmarked) {
            this.caps = caps;
            this.secured = secured;
            this.earmarked = earmarked;
        }

        static BorrowTuning securedOnly(
                Map<String, BigDecimal> secured,
                Map<MaterialDimension, BigDecimal> earmarked) {
            if (secured.isEmpty() && earmarked.isEmpty()) return NONE;
            return new BorrowTuning(
                    Map.of(), Map.copyOf(secured), Map.copyOf(earmarked));
        }

        /** 新投影使用新的消费游标；固定 cap/secured/earmark 身份不变。 */
        BorrowTuning fresh() {
            if (isEmpty()) return NONE;
            return new BorrowTuning(caps, secured, earmarked);
        }

        /**
         * 合并互不重叠的 exact 与 borrow 调节。调用方已对同维冲突 fail closed；
         * 此处仍按加法守恒合并 earmark/secured，并保留借出 cap。
         */
        BorrowTuning combinedWith(BorrowTuning other) {
            if (other == null || other.isEmpty()) return fresh();
            if (isEmpty()) return other.fresh();
            Map<String, BigDecimal> mergedCaps = new LinkedHashMap<>(caps);
            other.caps.forEach((key, value) -> mergedCaps.merge(
                    key, value, BigDecimal::min));
            Map<String, BigDecimal> mergedSecured = new LinkedHashMap<>(secured);
            other.secured.forEach((key, value) -> mergedSecured.merge(
                    key, value, BigDecimal::add));
            Map<MaterialDimension, BigDecimal> mergedEarmarked =
                    new LinkedHashMap<>(earmarked);
            other.earmarked.forEach((key, value) -> mergedEarmarked.merge(
                    key, value, BigDecimal::add));
            return new BorrowTuning(
                    Map.copyOf(mergedCaps), Map.copyOf(mergedSecured),
                    Map.copyOf(mergedEarmarked));
        }

        boolean isEmpty() {
            return secured.isEmpty() && caps.isEmpty() && earmarked.isEmpty();
        }

        Map<MaterialDimension, BigDecimal> earmarkedByDimension() {
            return earmarked;
        }

        /** 借出节点的覆盖上限；无上限返回 null。 */
        BigDecimal capOrNull(String nodeKey) {
            return caps.get(nodeKey);
        }

        BigDecimal securedTotal(String nodeKey) {
            return secured.getOrDefault(nodeKey, BigDecimal.ZERO);
        }

        BigDecimal securedHeadroomMain(String nodeKey) {
            return securedTotal(nodeKey)
                    .subtract(securedUsedMain.getOrDefault(nodeKey, BigDecimal.ZERO))
                    .max(BigDecimal.ZERO);
        }

        BigDecimal securedUsedMain(String nodeKey) {
            return securedUsedMain.getOrDefault(nodeKey, BigDecimal.ZERO);
        }

        void consumeSecuredMain(String nodeKey, BigDecimal qty) {
            if (qty.signum() <= 0) return;
            securedUsedMain.merge(nodeKey, qty, BigDecimal::add);
        }

        BigDecimal securedHeadroomDiagnostic(String nodeKey) {
            return securedTotal(nodeKey)
                    .subtract(securedUsedDiagnostic.getOrDefault(nodeKey, BigDecimal.ZERO))
                    .max(BigDecimal.ZERO);
        }

        void consumeSecuredDiagnostic(String nodeKey, BigDecimal qty) {
            if (qty.signum() <= 0) return;
            securedUsedDiagnostic.merge(nodeKey, qty, BigDecimal::add);
        }

        /**
         * 按基线分配计算每笔借用的实际生效量并构造调节参数。
         * m = min(申请量, 借出方剩余可借出量, 借入方剩余可借入缺口)，按创建
         * 顺序逐笔扣减两侧容量，多笔叠加时不会超借。
         */
        static BorrowPlanOutcome plan(List<BorrowRecord> borrows,
                                      Map<String, NodeAllocation> baseline) {
            Map<String, BigDecimal> outCapacity = new LinkedHashMap<>();
            Map<String, BigDecimal> inCapacity = new LinkedHashMap<>();
            Map<String, BigDecimal> totalOut = new LinkedHashMap<>();
            Map<String, BigDecimal> secured = new LinkedHashMap<>();
            Map<MaterialDimension, BigDecimal> earmarked = new LinkedHashMap<>();
            Map<UUID, BigDecimal> effective = new LinkedHashMap<>();
            for (BorrowRecord borrow : borrows) {
                String fromKey = borrow.fromItemId() + "|" + borrow.fromNodeKey();
                String toKey = borrow.toItemId() + "|" + borrow.toNodeKey();
                BigDecimal outRoom = outCapacity.computeIfAbsent(fromKey,
                        key -> baseline.getOrDefault(key, NodeAllocation.ZERO)
                                .allocatedQty());
                BigDecimal inRoom = inCapacity.computeIfAbsent(toKey,
                        key -> baseline.getOrDefault(key, NodeAllocation.ZERO)
                                .shortageQty());
                BigDecimal moved = borrow.qty().min(outRoom).min(inRoom)
                        .max(BigDecimal.ZERO).setScale(4, RoundingMode.DOWN);
                effective.put(borrow.id(), moved);
                if (moved.signum() <= 0) continue;
                outCapacity.put(fromKey, outRoom.subtract(moved));
                inCapacity.put(toKey, inRoom.subtract(moved));
                totalOut.merge(fromKey, moved, BigDecimal::add);
                secured.merge(toKey, moved, BigDecimal::add);
                earmarked.merge(borrow.dimension(), moved, BigDecimal::add);
            }
            Map<String, BigDecimal> caps = new LinkedHashMap<>();
            totalOut.forEach((fromKey, out) -> caps.put(fromKey,
                    baseline.getOrDefault(fromKey, NodeAllocation.ZERO)
                            .allocatedQty().subtract(out).max(BigDecimal.ZERO)));
            return new BorrowPlanOutcome(
                    new BorrowTuning(Map.copyOf(caps), Map.copyOf(secured),
                            Map.copyOf(earmarked)),
                    effective);
        }
    }

    record BorrowPlanOutcome(BorrowTuning tuning,
                                     Map<UUID, BigDecimal> effectiveByBorrow) {
    }

    /** 一条 ACTIVE 借用记录的节点定位与维度快照。 */
    record BorrowRecord(
            UUID id, UUID fromMaterialId, UUID toMaterialId,
            UUID fromItemId, String fromNodeKey, UUID toItemId, String toNodeKey,
            MaterialDimension dimension, BigDecimal qty) {
    }

    /** 生效 exact peg 的最小纯算法输入；物理有效量已由 reservation 派生。 */
    record ExactPegRecord(
            UUID id, UUID beneficiaryMaterialId,
            UUID analysisItemId, String nodeKey,
            MaterialDimension dimension, BigDecimal effectiveQty,UUID warehouseId) {
        ExactPegRecord(UUID id,UUID beneficiaryMaterialId,UUID analysisItemId,String nodeKey,
                       MaterialDimension dimension,BigDecimal effectiveQty) {
            this(id,beneficiaryMaterialId,analysisItemId,nodeKey,dimension,effectiveQty,null);
        }
    }

    record CrossProjection(
            BigDecimal incomingQty,
            BigDecimal outgoingQty,
            BigDecimal priorityPendingQty,
            BigDecimal priorityFulfilledQty,
            List<CrossReallocationRef> refs) {
        static final CrossProjection NONE = new CrossProjection(
                BigDecimal.ZERO, BigDecimal.ZERO,
                BigDecimal.ZERO, BigDecimal.ZERO, List.of());
    }

    /** 一次完整的内存分配投影：嵌套诊断 + 阶段齐套 + 硬门槛合并 + 逐节点最终分配。 */
    private record AllocationProjection(
            NestedDiagnosticPlan nestedDiagnostic,
            StagePlan stagePlan,
            Map<String, NodeAllocation> hardAllocations,
            Map<String, NodeAllocation> allocations,
            List<BomNode> nodes) {
    }

    /**
     * 纯内存分配投影：不重排任何持久化事实，供基线（无借用）与借用调节
     * 两趟复用。Recursive node tasks use a separate, single analysis pool:
     * a child's demand is exploded from its parent's actual shortage, and
     * shared stock is consumed only once across paths in this projection.
     */
    private static AllocationProjection computeAllocationProjection(
            List<SourceLine> sources,
            List<BomNode> nodes,
            Map<MaterialDimension, BigDecimal> stockAfterSafety,
            Map<MaterialDimension, BigDecimal> externalHardCommitments,
            Map<String, String> effectiveRoutes,
            Set<String> delegatedMakeNodes,
            Map<String, BigDecimal> subcontractTakeoverByNode,
            BorrowTuning tuning) {
        Map<UUID, List<BomNode>> directBySource = nodes.stream()
                .filter(node -> node.depth() == 1)
                .collect(Collectors.groupingBy(BomNode::analysisItemId,
                        LinkedHashMap::new, Collectors.toList()));
        StagePlan stagePlan = allocateNestedStages(
                sources, directBySource, stockAfterSafety,
                externalHardCommitments, tuning);
        Map<String, NodeAllocation> hardAllocations = new LinkedHashMap<>(
                stagePlan.finish().nodeAllocations());
        mergeAllocations(hardAllocations, stagePlan.ship().nodeAllocations());
        mergeAllocations(hardAllocations, stagePlan.start().nodeAllocations());
        Map<String, NodeAllocation> allocations = allocateDirectMaterials(
                sources, directBySource, stagePlan.start().remainingPool(),
                hardAllocations, tuning);
        // Formal kit allocations are authoritative. Reserve their public share
        // before diagnosing descendants, otherwise separate pools can display
        // the same stock on a direct material and another product's child.
        Map<String, NodeAllocation> fixedDirectAllocations = new LinkedHashMap<>();
        nodes.stream().filter(node -> node.depth() == 1
                        && node.hardGate() && !STAGE_REFERENCE.equals(node.controlStage()))
                .forEach(node -> fixedDirectAllocations.put(nodeAllocationKey(node),
                        allocations.getOrDefault(nodeAllocationKey(node), NodeAllocation.ZERO)));
        NestedDiagnosticPlan nestedDiagnostic = allocateNestedDiagnostics(
                sources, nodes,
                subtractCommitments(stockAfterSafety, externalHardCommitments),
                effectiveRoutes, delegatedMakeNodes,
                subcontractTakeoverByNode, tuning, fixedDirectAllocations);
        List<BomNode> adjustedNodes = nestedDiagnostic.nodes();
        nestedDiagnostic.nodeAllocations().forEach((key, allocation) -> {
            if (!fixedDirectAllocations.containsKey(key)) {
                allocations.put(key, allocation);
            }
        });
        return new AllocationProjection(
                nestedDiagnostic, stagePlan, Map.copyOf(hardAllocations),
                allocations, adjustedNodes);
    }


    static NestedDiagnosticPlan allocateNestedDiagnostics(
            List<SourceLine> sources,
            List<BomNode> nodes,
            Map<MaterialDimension, BigDecimal> rawStock) {
        Map<String, String> suggestedRoutes = nodes.stream().collect(Collectors.toMap(
                MaterialAnalysisService::nodeAllocationKey,
                BomNode::suggestion,
                (left, right) -> left,
                LinkedHashMap::new));
        return allocateNestedDiagnostics(sources, nodes, rawStock, suggestedRoutes);
    }

    static NestedDiagnosticPlan allocateNestedDiagnostics(
            List<SourceLine> sources,
            List<BomNode> nodes,
            Map<MaterialDimension, BigDecimal> rawStock,
            Map<String, String> effectiveRoutes) {
        return allocateNestedDiagnostics(
                sources, nodes, rawStock, effectiveRoutes, Set.of());
    }

    /**
     * Builds the recursive shortage diagnosis from a single stock pool. The gross depth-one
     * requirement is retained, while a descendant is exploded only from the unfilled quantity
     * of a parent whose effective route is MAKE or supplied SUBCONTRACT. Once a MAKE node is
     * promoted, its descendants are delegated to the child analysis item. Hard production gates consume first and
     * warning/reference rows last. SHIP and REFERENCE are never hard gates. This is a
     * diagnostic projection;
     * formal-plan conservation still uses only depth-one rows in
     * {@link #allocateNestedStages(List, Map, Map, Map)}.
     */
    static NestedDiagnosticPlan allocateNestedDiagnostics(
            List<SourceLine> sources,
            List<BomNode> nodes,
            Map<MaterialDimension, BigDecimal> rawStock,
            Map<String, String> effectiveRoutes,
            Set<String> delegatedMakeNodes) {
        return allocateNestedDiagnostics(
                sources, nodes, rawStock, effectiveRoutes, delegatedMakeNodes,
                Map.of(), BorrowTuning.NONE);
    }

    static NestedDiagnosticPlan allocateNestedDiagnostics(
            List<SourceLine> sources,
            List<BomNode> nodes,
            Map<MaterialDimension, BigDecimal> rawStock,
            Map<String, String> effectiveRoutes,
            Set<String> delegatedMakeNodes,
            BorrowTuning tuning) {
        return allocateNestedDiagnostics(
                sources, nodes, rawStock, effectiveRoutes,
                delegatedMakeNodes, Map.of(), tuning);
    }

    static NestedDiagnosticPlan allocateNestedDiagnostics(
            List<SourceLine> sources,
            List<BomNode> nodes,
            Map<MaterialDimension, BigDecimal> rawStock,
            Map<String, String> effectiveRoutes,
            Set<String> delegatedMakeNodes,
            Map<String, BigDecimal> subcontractTakeoverByNode,
            BorrowTuning tuning) {
        return allocateNestedDiagnostics(sources, nodes, rawStock, effectiveRoutes,
                delegatedMakeNodes, subcontractTakeoverByNode, tuning, Map.of());
    }

    private static NestedDiagnosticPlan allocateNestedDiagnostics(
            List<SourceLine> sources,
            List<BomNode> nodes,
            Map<MaterialDimension, BigDecimal> rawStock,
            Map<String, String> effectiveRoutes,
            Set<String> delegatedMakeNodes,
            Map<String, BigDecimal> subcontractTakeoverByNode,
            BorrowTuning tuning,
            Map<String, NodeAllocation> fixedDirectAllocations) {
        Map<MaterialDimension, BigDecimal> pool = new LinkedHashMap<>();
        rawStock.forEach((dimension, qty) -> pool.put(
                dimension, qty.max(BigDecimal.ZERO).setScale(4, RoundingMode.DOWN)));
        for (BomNode node : nodes) {
            String key = nodeAllocationKey(node);
            NodeAllocation fixed = fixedDirectAllocations.get(key);
            if (fixed == null) continue;
            BigDecimal securedUse = tuning.securedUsedMain(key).min(fixed.allocatedQty());
            BigDecimal publicUse = fixed.allocatedQty().subtract(securedUse);
            pool.computeIfPresent(node.dimension(), (dimension, qty) ->
                    qty.subtract(publicUse).max(BigDecimal.ZERO));
            tuning.consumeSecuredDiagnostic(key, securedUse);
        }
        Map<UUID, Integer> sourceRank = new HashMap<>();
        List<SourceLine> orderedSources = orderedSources(sources);
        for (int index = 0; index < orderedSources.size(); index++) {
            sourceRank.put(orderedSources.get(index).analysisItemId(), index);
        }
        Comparator<BomNode> allocationOrder = Comparator
                .comparingInt(MaterialAnalysisService::diagnosticAllocationPriority)
                .thenComparingInt(node -> sourceRank.getOrDefault(
                        node.analysisItemId(), Integer.MAX_VALUE))
                .thenComparingInt(BomNode::depth)
                .thenComparing(BomNode::nodeKey);
        Map<String, List<BomNode>> childrenByParent = new HashMap<>();
        PriorityQueue<BomNode> ready = new PriorityQueue<>(allocationOrder);
        for (BomNode node : nodes) {
            if (node.depth() == 1) {
                ready.add(node);
            } else {
                childrenByParent.computeIfAbsent(
                        node.analysisItemId() + "|" + node.parentNodeKey(),
                        ignored -> new ArrayList<>()).add(node);
            }
        }
        Map<String, BomNode> adjustedByKey = new LinkedHashMap<>();
        Map<String, NodeAllocation> allocations = new LinkedHashMap<>();
        // Keep the existing priority order while visiting each edge once. A
        // child enters the queue only after its own analysis item's parent.
        while (!ready.isEmpty()) {
            BomNode node = ready.remove();
            BigDecimal required = node.snapshotRequiredQty();
            if (node.depth() > 1) {
                String parentKey = node.analysisItemId() + "|" + node.parentNodeKey();
                NodeAllocation parent = allocations.get(parentKey);
                BomNode parentNode = adjustedByKey.get(parentKey);
                String parentRoute = effectiveRoutes.getOrDefault(
                        parentKey, parentNode.suggestion());
                boolean suppliedSubcontract = "SUBCONTRACT".equals(parentRoute)
                        && !delegatedMakeNodes.contains(parentKey);
                boolean undelegatedMake = "MAKE".equals(parentRoute)
                        && !delegatedMakeNodes.contains(parentKey);
                BigDecimal parentOutput = parent.shortageQty();
                if (suppliedSubcontract) {
                    parentOutput = parentOutput.subtract(
                            subcontractTakeoverByNode.getOrDefault(
                                    parentKey, BigDecimal.ZERO))
                            .max(BigDecimal.ZERO);
                }
                required = (undelegatedMake || suppliedSubcontract)
                        && !STAGE_REFERENCE.equals(parentNode.controlStage())
                        ? node.requiredForParentOutput(parentOutput)
                        : BigDecimal.ZERO.setScale(4);
            }
            BomNode adjusted = node.withSnapshotRequiredQty(required);
            String key = nodeAllocationKey(adjusted);
            NodeAllocation fixed = fixedDirectAllocations.getOrDefault(key, NodeAllocation.ZERO);
            BigDecimal protectedAllocation = fixed.allocatedQty();
            BigDecimal residual = required.subtract(protectedAllocation).max(BigDecimal.ZERO);
            BigDecimal available = pool.getOrDefault(
                    adjusted.dimension(), BigDecimal.ZERO.setScale(4));
            // 借用调节：借入节点先用池外锁定量（secured），再用池中余量；
            // 借出节点受 cap 封顶，精确让出被借走的数量。
            BigDecimal securedUse = tuning.securedHeadroomDiagnostic(key).min(residual);
            BigDecimal allocated = protectedAllocation.add(
                    residual.min(securedUse.add(available)));
            BigDecimal cap = tuning.capOrNull(key);
            if (cap != null) {
                allocated = allocated.min(cap);
            }
            BigDecimal additionalAllocation = allocated.subtract(protectedAllocation)
                    .max(BigDecimal.ZERO);
            pool.put(adjusted.dimension(), available.subtract(
                    additionalAllocation.subtract(additionalAllocation.min(securedUse)))
                    .max(BigDecimal.ZERO));
            tuning.consumeSecuredDiagnostic(key, additionalAllocation.min(securedUse));
            adjustedByKey.put(key, adjusted);
            allocations.put(key, new NodeAllocation(
                    allocated, required.subtract(allocated).max(BigDecimal.ZERO)));
            ready.addAll(childrenByParent.getOrDefault(key, List.of()));
        }
        if (adjustedByKey.size() != nodes.size()) {
            throw conflict("BOM 层级路径不完整，无法按父件短缺展开子件需求");
        }
        List<BomNode> adjustedNodes = nodes.stream()
                .map(node -> adjustedByKey.get(nodeAllocationKey(node)))
                .toList();
        return new NestedDiagnosticPlan(
                List.copyOf(adjustedNodes), Map.copyOf(allocations));
    }

    private static int diagnosticAllocationPriority(BomNode node) {
        if (productionGate(node)) return 0;
        return 1;
    }

    private static boolean productionGate(BomNode node) {
        return node.hardGate() && Set.of(
                STAGE_START, STAGE_ASSEMBLY, STAGE_FINISH)
                .contains(node.controlStage());
    }

    private static boolean productionGate(MaterialView material) {
        return material.hardGate() && Set.of(
                STAGE_START, STAGE_ASSEMBLY, STAGE_FINISH)
                .contains(material.controlStage());
    }

    private static BigDecimal requiredForOutput(
            MaterialView material, BigDecimal productQty) {
        try {
            return MaterialConsumptionMath.required(
                    productQty.multiply(material.parentPerProductQty()),
                    material.bomQty(), material.consumptionBasis(),
                    material.basisOutputQty(), material.allowPartialPackage());
        } catch (IllegalArgumentException ex) {
            throw conflict("BOM 包装/批次计量数据无效，不能预览生产计划");
        }
    }

    /**
     * Allocates actionable depth-one rows against one physical pool. Existing production
     * hard commitments are reserved before the current analysis. Current complete kits come
     * first and extra START capacity last. readyShip remains an analysis reference equal to
     * the finish projection; SHIP/REFERENCE rows never reserve stock or block production.
     */
    static StagePlan allocateNestedStages(
            List<SourceLine> sources,
            Map<UUID, List<BomNode>> directBySource,
            Map<MaterialDimension, BigDecimal> stockAfterSafety,
            Map<MaterialDimension, BigDecimal> externalHardCommitments) {
        return allocateNestedStages(sources, directBySource, stockAfterSafety,
                externalHardCommitments, BorrowTuning.NONE);
    }

    static StagePlan allocateNestedStages(
            List<SourceLine> sources,
            Map<UUID, List<BomNode>> directBySource,
            Map<MaterialDimension, BigDecimal> stockAfterSafety,
            Map<MaterialDimension, BigDecimal> externalHardCommitments,
            BorrowTuning tuning) {
        Map<MaterialDimension, BigDecimal> finishStock = subtractCommitments(
                stockAfterSafety, externalHardCommitments);
        StageAllocation finish = allocateStageReadiness(
                sources, directBySource, finishStock,
                Set.of(STAGE_START, STAGE_ASSEMBLY, STAGE_FINISH), tuning);
        StageExtension ship = allocateStageExtension(
                sources, directBySource, finish.remainingPool(),
                STAGE_SHIP, Map.of(), finish.readyByItem(), tuning);
        Map<UUID, BigDecimal> demandByItem = sources.stream().collect(
                Collectors.toMap(SourceLine::analysisItemId,
                        SourceLine::materialRequirementQty));
        StageExtension start = allocateStageExtension(
                sources, directBySource, ship.remainingPool(),
                STAGE_START, finish.readyByItem(), demandByItem, tuning);
        return new StagePlan(finish, ship, start);
    }

    static StageAllocation allocateStageReadiness(
            List<SourceLine> sources,
            Map<UUID, List<BomNode>> directBySource,
            Map<MaterialDimension, BigDecimal> rawStock,
            Set<String> includedStages) {
        return allocateStageReadiness(sources, directBySource, rawStock,
                includedStages, BorrowTuning.NONE);
    }

    static StageAllocation allocateStageReadiness(
            List<SourceLine> sources,
            Map<UUID, List<BomNode>> directBySource,
            Map<MaterialDimension, BigDecimal> rawStock,
            Set<String> includedStages,
            BorrowTuning tuning) {
        Map<MaterialDimension, BigDecimal> pool = new LinkedHashMap<>();
        rawStock.forEach((key, qty) -> pool.put(
                key, qty.max(BigDecimal.ZERO).setScale(4, RoundingMode.DOWN)));
        List<SourceLine> ordered = orderedSources(sources);
        Map<UUID, BigDecimal> readiness = new LinkedHashMap<>();
        Map<String, NodeAllocation> allocations = new LinkedHashMap<>();
        for (SourceLine source : ordered) {
            List<BomNode> gates = directBySource.getOrDefault(
                            source.analysisItemId(), List.of()).stream()
                    .filter(BomNode::hardGate)
                    .filter(node -> includedStages.contains(node.controlStage()))
                    .sorted(Comparator.comparing(BomNode::nodeKey))
                    .toList();
            // 子件锚点行（MAKE_COMPONENT / SUBCONTRACT_MAKE）无直接料行——齐套
            // 与否由其生产计划的执行段判定，分析侧不预设「无门槛即全可产」。
            boolean anchorChild = "MAKE_COMPONENT".equals(source.sourceType())
                    || "SUBCONTRACT_MAKE".equals(source.sourceType());
            BigDecimal ready = anchorChild
                    ? BigDecimal.ZERO.setScale(4)
                    : maxReadyExact(source.materialRequirementQty(), gates, pool, tuning);
            readiness.put(source.analysisItemId(), ready);
            for (BomNode node : gates) {
                String nodeKey = nodeAllocationKey(node);
                BigDecimal required = node.requiredForOutput(ready);
                // 借入节点：secured 覆盖量优先抵扣，池只承担剩余部分。
                BigDecimal securedUse = tuning.securedHeadroomMain(nodeKey)
                        .min(required);
                BigDecimal poolTake = required.subtract(securedUse);
                BigDecimal available = pool.getOrDefault(
                        node.dimension(), BigDecimal.ZERO);
                if (poolTake.compareTo(available) > 0) {
                    throw new IllegalStateException(
                            "complete-kit allocation exceeded the verified material pool");
                }
                pool.put(node.dimension(), available.subtract(poolTake)
                        .max(BigDecimal.ZERO));
                tuning.consumeSecuredMain(nodeKey, securedUse);
                allocations.put(nodeKey, new NodeAllocation(
                        required, node.snapshotRequiredQty().subtract(required)
                                .max(BigDecimal.ZERO)));
            }
        }
        return new StageAllocation(
                Map.copyOf(readiness), Map.copyOf(allocations), Map.copyOf(pool));
    }

    static BigDecimal maxReadyExact(
            BigDecimal demand,
            List<BomNode> nodes,
            Map<MaterialDimension, BigDecimal> pool) {
        return maxReadyExact(demand, nodes, pool, BorrowTuning.NONE);
    }

    static BigDecimal maxReadyExact(
            BigDecimal demand,
            List<BomNode> nodes,
            Map<MaterialDimension, BigDecimal> pool,
            BorrowTuning tuning) {
        BigDecimal normalizedDemand = demand.max(BigDecimal.ZERO)
                .setScale(4, RoundingMode.DOWN);
        if (nodes.isEmpty()) return normalizedDemand;
        long low = 0;
        long high;
        try {
            high = normalizedDemand.movePointRight(4).longValueExact();
        } catch (ArithmeticException ex) {
            throw conflict("生产数量超出齐套计算范围");
        }
        while (low < high) {
            long middle = low + (high - low + 1) / 2;
            BigDecimal candidate = BigDecimal.valueOf(middle, 4);
            if (canConsumeExact(candidate, nodes, pool, tuning)) {
                low = middle;
            } else {
                high = middle - 1;
            }
        }
        return BigDecimal.valueOf(low, 4);
    }

    private static BigDecimal maxReadyIncrementExact(
            BigDecimal base,
            BigDecimal upper,
            List<BomNode> nodes,
            Map<MaterialDimension, BigDecimal> pool) {
        return maxReadyIncrementExact(base, upper, nodes, pool, BorrowTuning.NONE);
    }

    private static BigDecimal maxReadyIncrementExact(
            BigDecimal base,
            BigDecimal upper,
            List<BomNode> nodes,
            Map<MaterialDimension, BigDecimal> pool,
            BorrowTuning tuning) {
        BigDecimal normalizedUpper = upper.max(BigDecimal.ZERO)
                .setScale(4, RoundingMode.DOWN);
        BigDecimal normalizedBase = base.max(BigDecimal.ZERO)
                .min(normalizedUpper).setScale(4, RoundingMode.DOWN);
        if (nodes.isEmpty()) return normalizedUpper;
        long low = normalizedBase.movePointRight(4).longValueExact();
        long high = normalizedUpper.movePointRight(4).longValueExact();
        while (low < high) {
            long middle = low + (high - low + 1) / 2;
            BigDecimal candidate = BigDecimal.valueOf(middle, 4);
            boolean feasible = incrementalRequirements(
                    normalizedBase, candidate, nodes, tuning).entrySet().stream()
                    .allMatch(entry -> entry.getValue().compareTo(
                            pool.getOrDefault(entry.getKey(), BigDecimal.ZERO)) <= 0)
                    && withinBorrowCaps(candidate, nodes, tuning);
            if (feasible) {
                low = middle;
            } else {
                high = middle - 1;
            }
        }
        return BigDecimal.valueOf(low, 4);
    }

    static StageExtension allocateStageExtension(
            List<SourceLine> sources,
            Map<UUID, List<BomNode>> directBySource,
            Map<MaterialDimension, BigDecimal> rawStock,
            String stage,
            Map<UUID, BigDecimal> baseByItem,
            Map<UUID, BigDecimal> upperByItem) {
        return allocateStageExtension(sources, directBySource, rawStock, stage,
                baseByItem, upperByItem, BorrowTuning.NONE);
    }

    static StageExtension allocateStageExtension(
            List<SourceLine> sources,
            Map<UUID, List<BomNode>> directBySource,
            Map<MaterialDimension, BigDecimal> rawStock,
            String stage,
            Map<UUID, BigDecimal> baseByItem,
            Map<UUID, BigDecimal> upperByItem,
            BorrowTuning tuning) {
        Map<MaterialDimension, BigDecimal> pool = new LinkedHashMap<>();
        rawStock.forEach((dimension, qty) -> pool.put(
                dimension, qty.max(BigDecimal.ZERO).setScale(4, RoundingMode.DOWN)));
        Map<UUID, BigDecimal> readiness = new LinkedHashMap<>();
        Map<String, NodeAllocation> allocations = new LinkedHashMap<>();
        for (SourceLine source : orderedSources(sources)) {
            List<BomNode> allDirect = directBySource.getOrDefault(
                    source.analysisItemId(), List.of());
            List<BomNode> gates = allDirect.stream()
                    .filter(BomNode::hardGate)
                    .filter(MaterialAnalysisService::productionGate)
                    .filter(node -> stage.equals(node.controlStage()))
                    .sorted(Comparator.comparing(BomNode::nodeKey)).toList();
            BigDecimal base = baseByItem.getOrDefault(
                    source.analysisItemId(), BigDecimal.ZERO.setScale(4));
            BigDecimal upper = upperByItem.getOrDefault(
                    source.analysisItemId(), source.materialRequirementQty());
            BigDecimal ready = maxReadyIncrementExact(
                    base, upper, gates, pool, tuning);
            readiness.put(source.analysisItemId(), ready);
            for (BomNode node : gates) {
                String nodeKey = nodeAllocationKey(node);
                BigDecimal additional = node.requiredForOutput(ready)
                        .subtract(node.requiredForOutput(base)).max(BigDecimal.ZERO);
                // 借入节点：secured 按"当前 ready 下的应耗量 − 主线已耗量"
                // 递增消耗，增量部分优先用 secured 抵扣，池只承担剩余。
                BigDecimal securedDelta = tuning.securedTotal(nodeKey)
                        .min(node.requiredForOutput(ready))
                        .subtract(tuning.securedUsedMain(nodeKey))
                        .max(BigDecimal.ZERO)
                        .min(additional);
                BigDecimal poolTake = additional.subtract(securedDelta);
                BigDecimal available = pool.getOrDefault(
                        node.dimension(), BigDecimal.ZERO);
                if (poolTake.compareTo(available) > 0) {
                    throw new IllegalStateException(
                            "stage extension exceeded the verified material pool");
                }
                pool.put(node.dimension(), available.subtract(poolTake)
                        .max(BigDecimal.ZERO));
                tuning.consumeSecuredMain(nodeKey, securedDelta);
                allocations.put(nodeKey, new NodeAllocation(
                        additional, BigDecimal.ZERO.setScale(4)));
            }
        }
        return new StageExtension(
                Map.copyOf(readiness), Map.copyOf(allocations), Map.copyOf(pool));
    }

    private static void mergeAllocations(
            Map<String, NodeAllocation> target,
            Map<String, NodeAllocation> additions) {
        additions.forEach((key, addition) -> target.merge(
                key, addition,
                (left, right) -> new NodeAllocation(
                        left.allocatedQty().add(right.allocatedQty()),
                        BigDecimal.ZERO.setScale(4))));
    }

    private static boolean canConsumeExact(
            BigDecimal productQty,
            List<BomNode> nodes,
            Map<MaterialDimension, BigDecimal> pool,
            BorrowTuning tuning) {
        return exactRequirements(productQty, nodes, tuning).entrySet().stream()
                .allMatch(entry -> entry.getValue().compareTo(
                        pool.getOrDefault(entry.getKey(), BigDecimal.ZERO)) <= 0)
                && withinBorrowCaps(productQty, nodes, tuning);
    }

    private static boolean canConsumeExact(
            BigDecimal productQty,
            List<BomNode> nodes,
            Map<MaterialDimension, BigDecimal> pool) {
        return canConsumeExact(productQty, nodes, pool, BorrowTuning.NONE);
    }

    private static Map<MaterialDimension, BigDecimal> exactRequirements(
            BigDecimal productQty, List<BomNode> nodes) {
        return exactRequirements(productQty, nodes, BorrowTuning.NONE);
    }

    /** 池内净需求：借入节点的需求先被池外锁定的 secured 量抵扣。 */
    private static Map<MaterialDimension, BigDecimal> exactRequirements(
            BigDecimal productQty, List<BomNode> nodes, BorrowTuning tuning) {
        Map<MaterialDimension, BigDecimal> result = new LinkedHashMap<>();
        nodes.forEach(node -> {
            BigDecimal required = node.requiredForOutput(productQty);
            BigDecimal poolNeed = required
                    .subtract(tuning == null
                            ? BigDecimal.ZERO
                            : tuning.securedTotal(nodeAllocationKey(node)))
                    .max(BigDecimal.ZERO);
            result.merge(node.dimension(), poolNeed, BigDecimal::add);
        });
        return result;
    }

    private static Map<MaterialDimension, BigDecimal> incrementalRequirements(
            BigDecimal baseProductQty,
            BigDecimal totalProductQty,
            List<BomNode> nodes,
            BorrowTuning tuning) {
        Map<MaterialDimension, BigDecimal> base = exactRequirements(
                baseProductQty, nodes, tuning);
        Map<MaterialDimension, BigDecimal> total = exactRequirements(
                totalProductQty, nodes, tuning);
        Map<MaterialDimension, BigDecimal> result = new LinkedHashMap<>();
        total.forEach((dimension, required) -> result.put(
                dimension,
                required.subtract(base.getOrDefault(dimension, BigDecimal.ZERO))
                        .max(BigDecimal.ZERO)));
        return result;
    }

    /** 借出节点的覆盖封顶：目标产量下该节点的需求不得超过其借用后上限。 */
    private static boolean withinBorrowCaps(
            BigDecimal productQty, List<BomNode> nodes, BorrowTuning tuning) {
        if (tuning == null || tuning.isEmpty()) return true;
        for (BomNode node : nodes) {
            BigDecimal cap = tuning.capOrNull(nodeAllocationKey(node));
            if (cap != null
                    && node.requiredForOutput(productQty).compareTo(cap) > 0) {
                return false;
            }
        }
        return true;
    }

    private static Map<MaterialDimension, BigDecimal> incrementalRequirements(
            BigDecimal baseProductQty,
            BigDecimal totalProductQty,
            List<BomNode> nodes) {
        return incrementalRequirements(
                baseProductQty, totalProductQty, nodes, BorrowTuning.NONE);
    }

    static Map<String, NodeAllocation> allocateDirectMaterials(
            List<SourceLine> sources,
            Map<UUID, List<BomNode>> directBySource,
            Map<MaterialDimension, BigDecimal> remainingStock,
            Map<String, NodeAllocation> kitAllocations) {
        return allocateDirectMaterials(sources, directBySource, remainingStock,
                kitAllocations, BorrowTuning.NONE);
    }

    static Map<String, NodeAllocation> allocateDirectMaterials(
            List<SourceLine> sources,
            Map<UUID, List<BomNode>> directBySource,
            Map<MaterialDimension, BigDecimal> remainingStock,
            Map<String, NodeAllocation> kitAllocations,
            BorrowTuning tuning) {
        Map<MaterialDimension, BigDecimal> pool = new LinkedHashMap<>();
        remainingStock.forEach((key, qty) -> pool.put(
                key, qty.max(BigDecimal.ZERO).setScale(4, RoundingMode.DOWN)));
        List<SourceLine> ordered = orderedSources(sources);
        Map<String, NodeAllocation> result = new LinkedHashMap<>(kitAllocations);
        for (SourceLine source : ordered) {
            List<BomNode> nodes = directBySource.getOrDefault(
                            source.analysisItemId(), List.of()).stream()
                    .sorted(Comparator.comparing(BomNode::nodeKey)).toList();
            for (BomNode node : nodes) {
                String nodeKey = nodeAllocationKey(node);
                if (node.hardGate()
                        && !STAGE_REFERENCE.equals(node.controlStage())) {
                    NodeAllocation existing = result.getOrDefault(
                            nodeKey, NodeAllocation.ZERO);
                    // 硬门槛节点：套件阶段已消耗池中份额；这里只叠加借入节点
                    // 尚未用尽的 secured 余量，并按借出上限封顶。
                    BigDecimal required = node.snapshotRequiredQty();
                    BigDecimal securedTopUp = tuning == null
                            ? BigDecimal.ZERO
                            : tuning.securedHeadroomMain(nodeKey).min(
                                    required.subtract(existing.allocatedQty())
                                            .max(BigDecimal.ZERO));
                    tuning.consumeSecuredMain(nodeKey, securedTopUp);
                    BigDecimal allocated = existing.allocatedQty()
                            .add(securedTopUp).min(required);
                    BigDecimal cap = tuning == null ? null : tuning.capOrNull(nodeKey);
                    if (cap != null) {
                        allocated = allocated.min(cap);
                    }
                    result.put(nodeKey, new NodeAllocation(
                            allocated, required.subtract(allocated)
                                    .max(BigDecimal.ZERO)));
                    continue;
                }
                BigDecimal required = node.snapshotRequiredQty();
                NodeAllocation existing = result.getOrDefault(
                        nodeKey, NodeAllocation.ZERO);
                BigDecimal residual = required.subtract(existing.allocatedQty())
                        .max(BigDecimal.ZERO);
                // 借入节点先落池外 secured 余量，再按序从池中补足；借出节点
                // 的池中补足受 cap 封顶，保证精确让出被借数量。
                BigDecimal securedTopUp = tuning == null
                        ? BigDecimal.ZERO
                        : tuning.securedHeadroomMain(nodeKey).min(residual);
                tuning.consumeSecuredMain(nodeKey, securedTopUp);
                BigDecimal available = pool.getOrDefault(
                        node.dimension(), BigDecimal.ZERO);
                BigDecimal extra = residual.subtract(securedTopUp)
                        .max(BigDecimal.ZERO).min(available);
                BigDecimal cap = tuning == null ? null : tuning.capOrNull(nodeKey);
                if (cap != null) {
                    BigDecimal capRoom = cap.subtract(
                            existing.allocatedQty().add(securedTopUp))
                            .max(BigDecimal.ZERO);
                    extra = extra.min(capRoom);
                }
                BigDecimal allocated = existing.allocatedQty()
                        .add(securedTopUp).add(extra).min(required);
                pool.put(node.dimension(), available.subtract(extra)
                        .max(BigDecimal.ZERO));
                result.put(nodeKey, new NodeAllocation(
                        allocated, required.subtract(allocated).max(BigDecimal.ZERO)));
            }
        }
        return result;
    }

    private static String nodeAllocationKey(BomNode node) {
        return node.analysisItemId() + "|" + node.nodeKey();
    }

    private static List<SourceLine> orderedSources(List<SourceLine> sources) {
        return sources.stream()
                .sorted(Comparator.comparingInt(SourceLine::allocationPriority)
                        .thenComparing(value -> value.analysisItemId().toString()))
                .toList();
    }

    AnalysisView detailInternal(UUID analysisId, boolean enforceAccess) {
        AnalysisHeader header = readHeader(analysisId);
        if (enforceAccess) {
            access.requireReadable(header.makerId(), "物料分析不存在",scopeForAnalysis(header));
        }
        List<SourceLine> sources = loadSourceLines(analysisId, false);
        List<MaterialRow> materialRows = loadMaterialRows(analysisId);
        SharedFutureIndex sharedFuture = sharedFutureSupply(
                analysisId, header.warehouseId(), materialRows);
        Map<UUID, BigDecimal> claimedFuture = sharedFutureClaimedByMaterial(analysisId);
        Map<UUID, BigDecimal> activeFuture = activeFutureCoverageByMaterial(analysisId);
        Map<UUID, SourceLine> sourcesById = sources.stream().collect(
                Collectors.toMap(SourceLine::analysisItemId, source -> source));
        Map<MaterialNodeIdentity, MaterialRow> materialRowsByNode =
                materialRows.stream().collect(Collectors.toMap(
                        MaterialRow::nodeIdentity, row -> row));
        // 2026-09-05 简化：不再投影「需求已转交自制子任务」——子件只做计划
        // 锚点，物料行保持原位（进度由子件行的计划/执行段展示）。
        Map<MaterialNodeIdentity, DelegatedRequirementOwner> delegatedOwners =
                Map.of();
        Set<MaterialNodeIdentity> subcontractPreparationOwners =
                loadSubcontractTakeoverByNode(analysisId).keySet().stream()
                        .map(key -> {
                            int separator = key.indexOf('|');
                            return new MaterialNodeIdentity(
                                    UUID.fromString(key.substring(0, separator)),
                                    key.substring(separator + 1));
                        })
                        .collect(Collectors.toUnmodifiableSet());
        List<UUID> participatingWarehouseIds = participatingWarehouseIds(
                analysisId, header.warehouseId());
        Set<UUID> participatingWarehouseSet = Set.copyOf(
                participatingWarehouseIds);
        Map<WarehouseMaterialDimension, BigDecimal> qualifiedOwned = qualifiedOwnedStock(analysisId,
                materialRows.stream().map(row -> row.analysisItemId()+"|"+row.nodeKey()).collect(Collectors.toSet()));
        Set<UUID> operationalWarehouseIds = Set.copyOf(NativeQueryResults.typedRows(
                em.createNativeQuery("""
                        SELECT warehouse.id FROM warehouses warehouse
                        WHERE warehouse.is_deleted=FALSE AND warehouse.is_accountable=TRUE
                          AND fn_warehouse_same_main(warehouse.id,:warehouseId)
                        """).setParameter("warehouseId",header.warehouseId()), UUID.class));
        List<WarehouseView> warehouses = warehouses(
                header.warehouseId(), participatingWarehouseSet);
        Map<MaterialDimension, List<WarehouseBreakdown>> breakdown =
                warehouseBreakdown(analysisId, materialRows, sharedFuture, qualifiedOwned);
        Map<StockIdentity, BigDecimal> mainOpenSafety = mainWarehouseOpenSafetySupply(
                header.warehouseId(), materialRows.stream().map(MaterialRow::goodsId).collect(Collectors.toSet()));
        Map<UUID, List<DownstreamReference>> references = downstreamReferences(analysisId);
        if (rootSupply != null) rootSupply.addOutputReferences(analysisId,references);
        Map<UUID, ProductPlanState> productPlanStates = productPlanStates(analysisId);
        // 行级流程阶段（表格进度/待办列唯一口径）：锚点子件的执行状态 + 行路线/缺口
        // + 采购/委外单据链，全部在服务端一次批量推导。
        Map<UUID, UUID> anchorChildByParentLine = anchorChildByParentLine(analysisId);
        Map<UUID, String> childStatusByLine = new LinkedHashMap<>();
        Map<UUID, Boolean> childZeroByLine = new LinkedHashMap<>();
        anchorChildByParentLine.forEach((parentLine, childItem) -> {
            ProductPlanState childState = productPlanStates.getOrDefault(
                    childItem, ProductPlanState.NONE);
            childStatusByLine.put(parentLine, childState.status());
            childZeroByLine.put(parentLine, childState.zeroMaterial());
        });
        Map<UUID, String> routeByLine = new LinkedHashMap<>();
        Map<UUID, BigDecimal> shortageByLine = new LinkedHashMap<>();
        Map<UUID, BigDecimal> requiredByLine = new LinkedHashMap<>();
        for (MaterialRow row : materialRows) {
            routeByLine.put(row.id(), row.confirmedRoute() != null
                    ? row.confirmedRoute() : row.suggestion());
            shortageByLine.put(row.id(), row.shortageQty());
            requiredByLine.put(row.id(), row.requiredQty());
        }
        Map<UUID, String> lineFlowStages = flowStages.lineFlowStages(
                analysisId, routeByLine, shortageByLine, requiredByLine,
                childStatusByLine, childZeroByLine);
        Set<UUID> productIdsWithMaterialChildren = materialRows.stream()
                .filter(row -> row.depth() > 0)
                .map(MaterialRow::analysisItemId)
                .collect(Collectors.toSet());
        if (rootSupply != null) productIdsWithMaterialChildren.addAll(rootSupply.rootProductsWithBom(analysisId));
        Map<UUID, List<BorrowRef>> borrowRefs = activeBorrowRefsByMaterial(analysisId);
        Map<UUID, CrossProjection> crossProjections =
                crossReallocationProjections(analysisId);
        Map<UUID, BigDecimal> exactPegged = exactPeggedByMaterial(
                analysisId, header.warehouseId());
        Map<UUID, BigDecimal> subcontractHandoffFuture =
                subcontractHandoffFutureByMaterial(analysisId);
        Map<UUID, String> sourceLabels = sources.stream().collect(Collectors.toMap(
                SourceLine::analysisItemId,
                source -> displayLabel(source.goodsCode(), source.goodsName())));
        List<MaterialView> materials = materialRows.stream()
                .map(row -> {
                    List<BorrowRef> rowBorrows =
                            borrowRefs.getOrDefault(row.id(), List.of());
                    BigDecimal borrowedIn = rowBorrows.stream()
                            .filter(ref -> "IN".equals(ref.direction()))
                            .map(BorrowRef::qty)
                            .reduce(BigDecimal.ZERO, BigDecimal::add);
                    BigDecimal borrowedOut = rowBorrows.stream()
                            .filter(ref -> "OUT".equals(ref.direction()))
                            .map(BorrowRef::qty)
                            .reduce(BigDecimal.ZERO, BigDecimal::add);
                    CrossProjection cross = crossProjections.getOrDefault(
                            row.id(), CrossProjection.NONE);
                    RequirementProjection requirement = requirementProjection(
                            row, materialRowsByNode, delegatedOwners,
                            subcontractPreparationOwners,
                            sourcesById.get(row.analysisItemId()));
                    SourceLine materialSource = sourcesById.get(row.analysisItemId());
                    String futureRoute = row.confirmedRoute() != null
                            ? row.confirmedRoute() : row.suggestion();
                    SharedFutureAggregate shared = sharedFuture.forMaterial(
                            header.warehouseId(), row.dimension(), futureRoute,
                            materialSource == null ? null
                                    : materialSource.deliveryDate());
                    WarehouseSelectionSummary selectedWarehouses =
                            selectedWarehouseSummaryWithQualifiedSources(
                                    breakdown.getOrDefault(
                                            row.dimension(), List.of()),
                                    java.util.stream.Stream.concat(participatingWarehouseSet.stream(), operationalWarehouseIds.stream())
                                            .collect(Collectors.toSet()),
                                    operationalWarehouseIds, qualifiedOwned, row.dimension());
                    MainWarehouseSafetySummary mainSafety = mainWarehouseSafetySummary(
                            breakdown.getOrDefault(row.dimension(), List.of()), operationalWarehouseIds, row.safetyStockQty(),
                            mainOpenSafety.getOrDefault(new StockIdentity(row.goodsId(), row.colorId()), BigDecimal.ZERO));
                    return row.toView(
                            breakdown.getOrDefault(row.dimension(), List.of()),
                            references.getOrDefault(row.id(), List.of()),
                            displayPath(row, materialRowsByNode, sourceLabels),
                            parentLabel(row, materialRowsByNode, sourceLabels),
                            exactPegged.getOrDefault(row.id(), BigDecimal.ZERO),
                            subcontractHandoffFuture.getOrDefault(
                                    row.id(), BigDecimal.ZERO),
                            borrowedIn, borrowedOut, rowBorrows, cross, requirement,
                            shared,
                            claimedFuture.getOrDefault(row.id(), BigDecimal.ZERO),
                            activeFuture.getOrDefault(row.id(), BigDecimal.ZERO),
                            selectedWarehouses.totalAvailableQty(),
                            selectedWarehouses.otherTransferableQty(),
                            lineFlowStages.get(row.id()),
                            anchorChildByParentLine.get(row.id()), mainSafety);
                })
                .toList();
        Map<UUID, String> planningBlocks = planningBlockedReasons(sources);
        List<ProductView> products = sources.stream().map(source -> {
            BigDecimal remaining = source.remainingAnalysisQty();
            BigDecimal ratio = remaining.signum() == 0
                    ? BigDecimal.ONE
                    : source.readyNowQty().divide(remaining, 4, RoundingMode.DOWN)
                        .min(BigDecimal.ONE);
            return source.toView(
                    ratio,
                    productIdsWithMaterialChildren.contains(source.analysisItemId()),
                    productPlanStates.getOrDefault(
                            source.analysisItemId(), ProductPlanState.NONE),
                    planningBlocks.get(source.analysisItemId()));
        }).toList();
        UUID fqcRecoveryAuthorizationId = fqcRecoveryAuthorizationId(analysisId);
        boolean fqcReplenishmentOnly = fqcRecoveryAuthorizationId != null;
        return new AnalysisView(
                header.id(), header.status(), header.version(), header.fingerprint(),
                header.fingerprint(),
                header.warehouseId(), participatingWarehouseIds,
                header.analyzedAt(), products, materials,
                warehouses, supplyActions(analysisId),
                allowedActions(analysisId, header, fqcReplenishmentOnly),
                fqcReplenishmentOnly, fqcRecoveryAuthorizationId, planningBlocks);
    }

    static BigDecimal authoritativeReadyQty(
            BigDecimal selectedQty, BigDecimal persistedReadyNow) {
        return persistedReadyNow.min(selectedQty)
                .setScale(4, RoundingMode.DOWN);
    }

    static boolean canGenerateReadyBatch(
            BigDecimal selectedQty, BigDecimal persistedReadyQty) {
        return selectedQty != null
                && persistedReadyQty != null
                && persistedReadyQty.compareTo(selectedQty) >= 0;
    }

    void bumpFingerprint(UUID analysisId) {
        String fingerprint = fingerprintForAnalysis(analysisId);
        em.createNativeQuery("""
                UPDATE production_material_analyses
                SET fingerprint = :fingerprint, version = version + 1,
                    preview_fingerprint = NULL,
                    analyzed_at = now(), updated_at = now(), updated_by = :actorId
                WHERE id = :id
                """)
                .setParameter("fingerprint", fingerprint)
                .setParameter("actorId", currentUser.requireId())
                .setParameter("id", analysisId)
                .executeUpdate();
    }

    private String fingerprintForAnalysis(UUID analysisId) {
        List<String> parts = new ArrayList<>(List.of(
                "MATERIAL-ANALYSIS-V3", analysisId.toString()));
        Object[] warehouseScope = oneRow(em.createNativeQuery("""
                SELECT warehouse_id,
                       array_to_string(participating_warehouse_ids, ',')
                FROM production_material_analyses
                WHERE id = :analysisId
                """).setParameter("analysisId", analysisId), "物料分析不存在");
        parts.add(String.join("|", "WAREHOUSE_SCOPE",
                Objects.toString(warehouseScope[0], ""),
                Objects.toString(warehouseScope[1], "")));
        NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT id, source_type, sales_order_item_id, goods_id, color_id,
                       unit_id, requested_qty, submitted_qty, approved_qty,
                       delivery_date, source_ref, source_reason, line_priority,
                       ready_now_qty, ready_by_date_qty,
                       ready_start_qty, ready_finish_qty, ready_ship_qty
                FROM production_material_analysis_items
                WHERE analysis_id = :id AND is_deleted = FALSE
                ORDER BY line_priority, id
                """).setParameter("id", analysisId)).forEach(row -> parts.add(String.join("|",
                "SOURCE", Objects.toString(row[0], ""), Objects.toString(row[1], ""),
                Objects.toString(row[2], ""), Objects.toString(row[3], ""),
                Objects.toString(row[4], ""), Objects.toString(row[5], ""),
                decimalText(decimal(row[6])), decimalText(decimal(row[7])),
                decimalText(decimal(row[8])), Objects.toString(row[9], ""),
                Objects.toString(row[10], ""), Objects.toString(row[11], ""),
                Objects.toString(row[12], ""), decimalText(decimal(row[13])),
                decimalText(decimal(row[14])), decimalText(decimal(row[15])),
                decimalText(decimal(row[16])), decimalText(decimal(row[17])))));
        NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT analysis_item_id, node_key, parent_node_key, goods_id,
                       color_id, unit_id, depth, per_product_qty, required_qty,
                       available_qty, allocated_available_qty, inbound_qty,
                       shortage_qty, expected_ready_date,
                       source_suggestion, confirmed_route, route_reason, lower_level_pending,
                       control_stage, consumption_basis, basis_output_qty,
                       allow_partial_package, hard_gate, bom_qty, parent_per_product_qty,
                       calculation_mode, allocated_start_qty,
                       allocated_finish_qty, allocated_ship_qty
                FROM production_material_analysis_materials
                WHERE analysis_id = :id AND active = TRUE
                ORDER BY analysis_item_id, path, id
                """).setParameter("id", analysisId)).forEach(row -> parts.add(
                "NODE|" + java.util.Arrays.stream(row)
                        .map(value -> Objects.toString(value, ""))
                        .collect(Collectors.joining("|"))));
        NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT action_group_key, generation, route, requested_qty,
                       safety_replenishment_qty, safety_stock_snapshot_qty,
                       public_available_snapshot_qty,
                       open_safety_supply_snapshot_qty,
                       safety_external_item_id, status,
                       external_document_type, external_document_id,
                       predecessor_action_id, public_surplus_qty,
                       public_surplus_external_item_id, operation_type,
                       claim_source_action_id
                FROM preplan_supply_actions
                WHERE analysis_id = :id
                ORDER BY action_group_key, generation, id
                """).setParameter("id", analysisId)).forEach(row -> parts.add(
                "ACTION|" + java.util.Arrays.stream(row)
                        .map(value -> Objects.toString(value, ""))
                        .collect(Collectors.joining("|"))));
        return PlanningPackageFingerprint.sha256(parts);
    }

    private FulfillmentMutationLockPlan previewMutationFootprint(
            PreviewRequest request,List<PreviewItem> normalized,List<UUID> warehouses) {
        UUID existing = request.analysisId();
        if (existing==null) existing=analysisByInitialIdempotencyKey(request.idempotencyKey());
        if (existing==null) existing=findReusableAnalysis(normalized);
        List<UUID> sales = normalized.stream().filter(item -> SOURCE_SALES.equals(sourceType(item)))
                .map(PreviewItem::salesOrderItemId).toList();
        List<UUID> subcontract = new ArrayList<>();
        for (PreviewItem item : normalized) if (SOURCE_SUBCONTRACT_PREPARATION.equals(sourceType(item))) {
            try { subcontract.add(UUID.fromString(item.sourceRef().substring(item.sourceRef().indexOf(':')+1))); }
            catch (IllegalArgumentException error) { throw validation("委外前置自制来源编号无效，请刷新后重试"); }
        }
        List<ProductionMutationFootprintPort.WarehouseDimension> roots = normalized.stream()
                .filter(item -> item.goodsId()!=null)
                .map(item -> new ProductionMutationFootprintPort.WarehouseDimension(
                        request.warehouseId(),item.goodsId(),item.colorId())).toList();
        return mutationFootprints.forPreview(sales,subcontract,roots,warehouses,
                existing==null ? List.of() : List.of(existing));
    }

    private List<PreviewItem> normalizePreviewItems(
            List<PreviewItem> raw, boolean allowSubcontractPreparation,
            UUID requestedAnalysisId) {
        List<PreviewItem> result = new ArrayList<>();
        Set<String> keys = new HashSet<>();
        for (PreviewItem item : raw) {
            if (item == null || item.requestedQty() == null
                    || item.requestedQty().signum() <= 0) {
                throw validation("生产需求数量必须大于零");
            }
            String source = sourceType(item);
            if (SOURCE_MAKE_COMPONENT.equals(source)) {
                throw new ApiException(ErrorCode.FORBIDDEN,
                        "MAKE_COMPONENT 只能由系统备料任务生成");
            }
            if (SOURCE_SUBCONTRACT_MAKE.equals(source)) {
                throw new ApiException(ErrorCode.FORBIDDEN,
                        "SUBCONTRACT_MAKE 只能由有子层级委外件的备料任务生成");
            }
            if (SOURCE_SUBCONTRACT_PREPARATION.equals(source)
                    && !allowSubcontractPreparation
                    && requestedAnalysisId == null) {
                throw new ApiException(ErrorCode.FORBIDDEN,
                        "SUBCONTRACT_PREPARATION 新建只能由委外前置自制任务生成");
            }
            if (!Set.of(SOURCE_SALES, "REWORK", "TRIAL", "SAMPLE", "STOCK", "OTHER",
                    SOURCE_SUBCONTRACT_PREPARATION)
                    .contains(source)) {
                throw validation("生产需求来源类型无效");
            }
            if (SOURCE_SALES.equals(source)) {
                if (item.salesOrderItemId() == null
                        || item.goodsId() != null || item.colorId() != null
                        || item.unitId() != null
                        || blankToNull(item.sourceRef()) != null
                        || blankToNull(item.sourceReason()) != null) {
                    throw validation("销售来源只允许提交销售订单行和数量");
                }
            } else if (item.salesOrderItemId() != null
                    || item.goodsId() == null || item.unitId() == null
                    || blankToNull(item.sourceRef()) == null
                    || blankToNull(item.sourceReason()) == null
                    || blankToNull(item.sourceReason()).length() < 2) {
                throw validation("手工生产来源必须填写需求编号、货品、单位和原因");
            }
            if (SOURCE_SUBCONTRACT_PREPARATION.equals(source)
                    && (blankToNull(item.sourceRef()) == null
                    || !item.sourceRef().matches(
                            "SC-(?:PREP|ORDER):[0-9a-fA-F-]{36}"))) {
                throw validation("委外前置自制来源必须绑定真实订货行 UUID");
            }
            String key = SOURCE_SALES.equals(source)
                    ? source + ":" + item.salesOrderItemId()
                    : source + ":" + item.goodsId() + ":" + Objects.toString(item.colorId(), "")
                        + ":" + item.unitId() + ":" + Objects.toString(item.sourceRef(), "");
            if (!keys.add(key)) throw validation("生产需求来源重复");
            result.add(new PreviewItem(source, item.salesOrderItemId(), item.goodsId(),
                    item.colorId(), item.unitId(), blankToNull(item.sourceRef()),
                    blankToNull(item.sourceReason()), item.deliveryDate(),
                    scaleQty(item.requestedQty())));
        }
        return List.copyOf(result);
    }

    private void requireSubcontractPreparationRefresh(
            PreviewRequest request, List<PreviewItem> normalized) {
        if (request.analysisId() == null || normalized.size() != 1) {
            throw new ApiException(ErrorCode.FORBIDDEN,
                    "委外前置自制分析只能刷新既有单一任务来源");
        }
        PreviewItem item = normalized.getFirst();
        if(item.sourceRef().startsWith("SC-ORDER:"))return;
        subcontractPreparation.requireRefresh(
                request.analysisId(), request.warehouseId(), item.sourceRef(),
                item.goodsId(), item.colorId(), item.unitId(), item.requestedQty());
    }

    private UUID findReusableAnalysis(List<PreviewItem> items) {
        Set<UUID> analyses = new LinkedHashSet<>();
        for (PreviewItem item : items) {
            boolean sales = SOURCE_SALES.equals(sourceType(item));
            List<Object[]> matches = NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                    SELECT DISTINCT analysis.id, analysis.status
                    FROM production_material_analysis_items source
                    JOIN production_material_analyses analysis
                      ON analysis.id = source.analysis_id
                     AND analysis.is_deleted = FALSE
                    WHERE source.is_deleted = FALSE
                      AND NOT(source.source_type='SUBCONTRACT_PREPARATION' AND source.source_ref LIKE 'SC-ORDER:%' AND analysis.status='CANCELLED')
                      AND ((:sales = TRUE
                            AND source.source_type = 'SALES_ORDER_ITEM'
                            AND source.sales_order_item_id = :salesOrderItemId
                            AND analysis.status IN ('ACTIVE','PARTIALLY_PLANNED'))
                           OR
                           (:sales = FALSE
                            AND source.source_type = :sourceType
                            AND lower(btrim(source.source_ref)) = lower(btrim(:sourceRef))))
                    ORDER BY analysis.id
                    """)
                    .setParameter("sales", sales)
                    .setParameter("salesOrderItemId", item.salesOrderItemId())
                    .setParameter("sourceType", sourceType(item))
                    .setParameter("sourceRef", item.sourceRef()));
            for (Object[] match : matches) {
                if (!sales && !List.of(STATUS_ACTIVE, STATUS_PARTIAL)
                        .contains(string(match[1]))) {
                    throw conflict("手工需求编号已有历史物料分析，请打开历史记录或使用新的需求编号");
                }
                analyses.add(uuid(match[0]));
            }
        }
        if (analyses.isEmpty()) return null;
        if (analyses.size() != 1) {
            throw conflict("所选来源已分别存在进行中的物料分析，请先处理原分析");
        }
        UUID analysisId = analyses.iterator().next();
        List<SourceIdentity> existing = NativeQueryResults.objectArrayRows(
                em.createNativeQuery("""
                SELECT source_type, sales_order_item_id, goods_id, color_id,
                       unit_id, source_ref
                FROM production_material_analysis_items
                WHERE analysis_id = :id AND is_deleted = FALSE
                  AND source_type NOT IN ('MAKE_COMPONENT','SUBCONTRACT_MAKE')
                """).setParameter("id", analysisId)).stream()
                .map(row -> new SourceIdentity(
                        string(row[0]), uuid(row[1]), uuid(row[2]), uuid(row[3]),
                        uuid(row[4]), blankToNull(string(row[5]))))
                .sorted().toList();
        List<SourceIdentity> requested = items.stream()
                .map(this::sourceIdentity).sorted().toList();
        if (!existing.equals(requested)) {
            throw conflict("来源已有进行中的物料分析，不能用不同来源集合覆盖");
        }
        return analysisId;
    }

    private void requireDirectSubcontractSource(PreviewRequest request,PreviewItem item){
        UUID orderItem=UUID.fromString(item.sourceRef().substring("SC-ORDER:".length()));
        Number matches=(Number)em.createNativeQuery("""
                SELECT count(*) FROM subcontract_order_items item JOIN subcontract_orders orders ON orders.id=item.order_id
                JOIN goods ON goods.id=item.goods_id
                WHERE item.id=:item AND item.application_item_id IS NULL AND item.is_deleted=FALSE
                  AND orders.is_deleted=FALSE AND orders.status=0 AND orders.warehouse_id=:warehouse
                  AND item.goods_id=:goods AND item.color_id IS NOT DISTINCT FROM CAST(:color AS uuid)
                  AND goods.unit_id=:unit AND :qty>0 AND :qty<=round(item.qty*COALESCE(item.unit_rate,1),4)
                  AND NOT EXISTS(SELECT 1 FROM subcontract_order_item_sources source WHERE source.order_item_id=item.id)
                  AND (CAST(:analysis AS uuid) IS NULL OR EXISTS(SELECT 1 FROM production_material_analysis_items source
                      WHERE source.analysis_id=:analysis AND source.source_ref=:ref AND source.source_type='SUBCONTRACT_PREPARATION'
                        AND source.goods_id=:goods AND source.color_id IS NOT DISTINCT FROM CAST(:color AS uuid)
                        AND source.unit_id=:unit AND source.requested_qty=:qty AND source.is_deleted=FALSE))
                """).setParameter("item",orderItem).setParameter("warehouse",request.warehouseId()).setParameter("goods",item.goodsId())
                .setParameter("color",item.colorId()).setParameter("unit",item.unitId()).setParameter("qty",item.requestedQty())
                .setParameter("analysis",request.analysisId()).setParameter("ref",item.sourceRef()).getSingleResult();
        if(matches.longValue()!=1)throw conflict("直接委外准备必须对应原草稿行、基本单位、仓库和真实缺口；不能改挂申请或旧准备任务");
    }

    private void requireReusablePayloadMatches(
            UUID analysisId, AnalysisHeader header, UUID warehouseId,
            List<UUID> warehouseIds,
            List<PreviewItem> requestedItems) {
        if (!samePlanningWarehouseScope(header.warehouseId(),
                participatingWarehouseIds(analysisId, header.warehouseId()), warehouseId, warehouseIds)) {
            throw reusablePayloadConflict();
        }
        List<Object[]> rows = NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT source_type, sales_order_item_id, goods_id, color_id,
                       unit_id, source_ref, requested_qty, delivery_date, source_reason
                FROM production_material_analysis_items
                WHERE analysis_id = :analysisId AND is_deleted = FALSE
                  AND source_type NOT IN ('MAKE_COMPONENT','SUBCONTRACT_MAKE')
                """).setParameter("analysisId", analysisId));
        if (rows.size() != requestedItems.size()) throw reusablePayloadConflict();
        Map<SourceIdentity, Object[]> existingBySource = rows.stream()
                .collect(Collectors.toMap(row -> new SourceIdentity(
                        string(row[0]), uuid(row[1]), uuid(row[2]), uuid(row[3]),
                        uuid(row[4]), blankToNull(string(row[5]))), row -> row));
        for (PreviewItem item : requestedItems) {
            Object[] existing = existingBySource.get(sourceIdentity(item));
            LocalDate expectedDelivery = item.deliveryDate();
            if (SOURCE_SALES.equals(sourceType(item)) && expectedDelivery == null) {
                expectedDelivery = salesSourceMaster(item.salesOrderItemId()).deliveryDate();
            }
            if (existing == null
                    || decimal(existing[6]).compareTo(item.requestedQty()) != 0
                    || !Objects.equals(date(existing[7]), expectedDelivery)
                    || !Objects.equals(blankToNull(string(existing[8])),
                            blankToNull(item.sourceReason()))) {
                throw reusablePayloadConflict();
            }
        }
    }

    private ApiException reusablePayloadConflict() {
        return conflict("所选来源已有进行中的物料分析，但数量、交期、主仓或参与仓不同；"
                + "请打开原分析并携带 analysisId/version/fingerprint 刷新");
    }

    private UUID analysisByInitialIdempotencyKey(String key) {
        List<?> rows = em.createNativeQuery("""
                SELECT id FROM production_material_analyses
                WHERE maker_id = :makerId AND initial_idempotency_key = :key
                  AND is_deleted = FALSE
                """)
                .setParameter("makerId", currentUser.requireEmployeeId())
                .setParameter("key", key)
                .getResultList();
        return rows.isEmpty() ? null : (UUID) rows.getFirst();
    }

    private void insertSourceItems(UUID analysisId, List<PreviewItem> items) {
        int priority = 0;
        for (PreviewItem item : items) {
            priority++;
            SourceMaster master = SOURCE_SALES.equals(sourceType(item))
                    ? salesSourceMaster(item.salesOrderItemId())
                    : manualSourceMaster(item.goodsId(), item.colorId(), item.unitId());
            em.createNativeQuery("""
                    INSERT INTO production_material_analysis_items (
                        id, analysis_id, source_type, sales_order_item_id,
                        goods_id, color_id, unit_id, source_ref, source_reason,
                        requested_qty, delivery_date, line_priority,
                        created_by, updated_by
                    ) VALUES (
                        :id, :analysisId, :sourceType, :salesOrderItemId,
                        :goodsId, :colorId, :unitId, :sourceRef, :sourceReason,
                        :requestedQty, :deliveryDate, :priority,
                        :actorId, :actorId
                    )
                    """)
                    .setParameter("id", UUID.randomUUID())
                    .setParameter("analysisId", analysisId)
                    .setParameter("sourceType", sourceType(item))
                    .setParameter("salesOrderItemId", item.salesOrderItemId())
                    .setParameter("goodsId", master.goodsId())
                    .setParameter("colorId", master.colorId())
                    .setParameter("unitId", master.unitId())
                    .setParameter("sourceRef", item.sourceRef())
                    .setParameter("sourceReason", item.sourceReason())
                    .setParameter("requestedQty", item.requestedQty())
                    .setParameter("deliveryDate", item.deliveryDate() == null
                            ? master.deliveryDate() : item.deliveryDate())
                    .setParameter("priority", priority)
                    .setParameter("actorId", currentUser.requireId())
                    .executeUpdate();
        }
    }

    /** Snapshot the exact nodes before an explicit source/BOM preview, never before a GET or issue command. */
    private Map<UUID, BigDecimal> makeAnchorParentRequirements(UUID analysisId) {
        Map<UUID, BigDecimal> result = new LinkedHashMap<>();
        for (Object[] row : NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT parent.id, parent.required_qty
                FROM production_material_analysis_materials parent
                WHERE parent.analysis_id=:analysis AND parent.active=TRUE
                  AND EXISTS(SELECT 1 FROM production_material_analysis_items child
                      WHERE child.analysis_id=parent.analysis_id
                        AND child.parent_analysis_material_id=parent.id
                        AND child.source_type='MAKE_COMPONENT' AND child.is_deleted=FALSE)
                """).setParameter("analysis",analysisId))) {
            result.put(uuid(row[0]),decimal(row[1]));
        }
        return result;
    }

    /** Admit only new source demand into an existing MAKE quota; old physical shortage cannot enlarge it. */
    private boolean growMakeAnchorQuotasAfterSourcePreview(
            UUID analysisId, Map<UUID, BigDecimal> previousRequirements) {
        if (previousRequirements.isEmpty()) return false;
        AnalysisView view=detailInternal(analysisId,false);
        Map<UUID,ProductView> products=view.products().stream()
                .collect(Collectors.toMap(ProductView::analysisLineId,product->product));
        boolean changed=false;
        for (MaterialView material:view.flatMaterials()) {
            BigDecimal previous=previousRequirements.get(material.materialLineId());
            if (previous==null || material.planAnchorAnalysisLineId()==null) continue;
            BigDecimal admittedIncrease=material.requiredQty().subtract(previous).max(BigDecimal.ZERO);
            if (admittedIncrease.signum()==0) continue;
            ProductView anchor=products.get(material.planAnchorAnalysisLineId());
            if (anchor==null || !SOURCE_MAKE_COMPONENT.equals(anchor.sourceType())
                    || !Objects.equals(anchor.goodsId(),material.goodsId())
                    || !Objects.equals(anchor.colorId(),material.colorId())
                    || !Objects.equals(anchor.unitId(),material.unitId())) {
                throw conflict("来源变化后的物料与原计划锚点不一致，请先核对原任务");
            }
            String blocked=view.planningBlockedReasons().get(material.analysisLineId());
            if (blocked!=null) throw conflict(blocked);
            // Unplanned, submitted and approved-but-not-inbound quantities are one quota,
            // including old action-backed anchors. Do not add the action quantity a second time.
            BigDecimal openQuota=anchor.requestedQty().subtract(anchor.planExecutionInboundQty()).max(BigDecimal.ZERO);
            BigDecimal increase=material.demandSupplyGapQty().subtract(openQuota).max(BigDecimal.ZERO)
                    .min(admittedIncrease).setScale(4,RoundingMode.CEILING);
            if (increase.signum()==0) continue;
            int updated=em.createNativeQuery("""
                    UPDATE production_material_analysis_items
                    SET requested_qty=requested_qty+:increase,updated_by=:actor,updated_at=now()
                    WHERE id=:child AND analysis_id=:analysis AND parent_analysis_material_id=:parent
                      AND source_type='MAKE_COMPONENT' AND is_deleted=FALSE AND requested_qty=:previous
                    """).setParameter("increase",increase).setParameter("actor",currentUser.requireId())
                    .setParameter("child",anchor.analysisLineId()).setParameter("analysis",analysisId)
                    .setParameter("parent",material.materialLineId()).setParameter("previous",anchor.requestedQty())
                    .executeUpdate();
            if (updated!=1) throw conflict("计划锚点需求已变化，请刷新后重试");
            changed=true;
        }
        return changed;
    }

    private void syncRequestedQuantities(
            UUID analysisId, List<PreviewItem> items, boolean sameWarehouseScope) {
        Map<SourceIdentity, PreviewItem> requestedByIdentity = items.stream()
                .collect(Collectors.toMap(this::sourceIdentity, item -> item));
        List<Object[]> rows = NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT id, source_type, sales_order_item_id, goods_id, color_id,
                       unit_id, source_ref, submitted_qty, approved_qty, requested_qty
                FROM production_material_analysis_items
                WHERE analysis_id = :id AND is_deleted = FALSE
                  AND source_type NOT IN ('MAKE_COMPONENT','SUBCONTRACT_MAKE')
                ORDER BY id FOR UPDATE
                """).setParameter("id", analysisId));
        if (rows.size() != requestedByIdentity.size()) throw conflict("分析来源集合已变化");
        Set<UUID> committedIncreases = new LinkedHashSet<>();
        for (Object[] row : rows) {
            SourceIdentity identity = new SourceIdentity(
                    string(row[1]), uuid(row[2]), uuid(row[3]), uuid(row[4]),
                    uuid(row[5]), blankToNull(string(row[6])));
            PreviewItem requested = requestedByIdentity.get(identity);
            if (requested == null) throw conflict("刷新不能改变物料分析的来源集合");
            if (decimal(row[7]).add(decimal(row[8])).signum() > 0
                    && requested.requestedQty().compareTo(decimal(row[9])) > 0) {
                committedIncreases.add(uuid(row[0]));
            }
        }
        if (!committedIncreases.isEmpty()) {
            if (!sameWarehouseScope) {
                throw conflict("已有待审批或已批准批次后，增加需求不能同时更改主仓或参与仓");
            }
            // PREVIEW carries a cumulative source quantity. A pure increase admits a new
            // remainder only; preserve the existing plan/package and require its BOM source
            // to remain current. The updated quantity still passes finance/source capacity below.
            requireCurrentBomSnapshot(analysisId, committedIncreases);
            for (SourceLine source : loadSourceLines(analysisId, false)) {
                if (!committedIncreases.contains(source.analysisItemId())
                        || !SOURCE_SALES.equals(source.sourceType())) continue;
                BigDecimal requested = requestedByIdentity.get(new SourceIdentity(
                        SOURCE_SALES, source.salesOrderItemId(), null, null, null, null)).requestedQty();
                BigDecimal additionalCapacity = source.salesQty().subtract(source.shippedQty())
                        .add(source.returnedQty()).subtract(source.flagQty()).subtract(source.reservedQty())
                        .subtract(source.plannedQty().subtract(source.producedQty()).max(BigDecimal.ZERO))
                        .subtract(source.activeDraftQty()).subtract(source.remainingAnalysisQty());
                if (requested.subtract(source.requestedQty()).compareTo(additionalCapacity) > 0) {
                    throw conflict("新增需求超过销售订单尚未安排的有效数量，请核对已批准订单与现有计划");
                }
            }
        }
        for (Object[] row : rows) {
            SourceIdentity identity = new SourceIdentity(
                    string(row[1]), uuid(row[2]), uuid(row[3]), uuid(row[4]),
                    uuid(row[5]), blankToNull(string(row[6])));
            PreviewItem requestedItem = requestedByIdentity.get(identity);
            if (requestedItem == null) {
                throw conflict("刷新不能改变物料分析的来源集合");
            }
            LocalDate deliveryDate = requestedItem.deliveryDate();
            if (!SOURCE_SALES.equals(identity.sourceType())) {
                manualSourceMaster(identity.goodsId(), identity.colorId(), identity.unitId());
            } else if (deliveryDate == null) {
                deliveryDate = salesSourceMaster(identity.salesOrderItemId()).deliveryDate();
            }
            BigDecimal requested = requestedItem.requestedQty();
            BigDecimal committed = decimal(row[7]).add(decimal(row[8]));
            if (requested.compareTo(committed) < 0) {
                throw conflict("新需求量不能小于已提交和已审核计划数量");
            }
            em.createNativeQuery("""
                    UPDATE production_material_analysis_items
                    SET requested_qty = :qty,
                        delivery_date = :deliveryDate,
                        source_reason = :sourceReason,
                        updated_at = now(), updated_by = :actorId
                    WHERE id = :id
                    """)
                    .setParameter("qty", requested)
                    .setParameter("deliveryDate", deliveryDate)
                    .setParameter("sourceReason", requestedItem.sourceReason())
                    .setParameter("actorId", currentUser.requireId())
                    .setParameter("id", row[0])
                    .executeUpdate();
        }
    }

    private void requireSameSources(UUID analysisId, List<PreviewItem> items) {
        List<SourceIdentity> existing = NativeQueryResults.objectArrayRows(
                em.createNativeQuery("""
                SELECT source_type, sales_order_item_id, goods_id, color_id,
                       unit_id, source_ref
                FROM production_material_analysis_items
                WHERE analysis_id = :id AND is_deleted = FALSE
                  AND source_type NOT IN ('MAKE_COMPONENT','SUBCONTRACT_MAKE')
                ORDER BY source_type, sales_order_item_id NULLS FIRST,
                         goods_id, color_id NULLS FIRST, unit_id, source_ref NULLS FIRST
                """).setParameter("id", analysisId)).stream()
                .map(row -> new SourceIdentity(
                        string(row[0]), uuid(row[1]), uuid(row[2]), uuid(row[3]),
                        uuid(row[4]), blankToNull(string(row[5]))))
                .sorted()
                .toList();
        List<SourceIdentity> requested = items.stream()
                .map(this::sourceIdentity).sorted().toList();
        if (!existing.equals(requested)) {
            throw conflict("刷新不能改变物料分析的来源集合");
        }
    }

    private SourceIdentity sourceIdentity(PreviewItem item) {
        String source = sourceType(item);
        return SOURCE_SALES.equals(source)
                ? new SourceIdentity(source, item.salesOrderItemId(), null, null, null, null)
                : new SourceIdentity(source, null, item.goodsId(), item.colorId(),
                        item.unitId(), blankToNull(item.sourceRef()));
    }

    private void lockSourceIdentities(List<PreviewItem> items) {
        items.stream().map(this::sourceIdentity).distinct().sorted()
                .forEach(identity -> em.createNativeQuery("""
                        SELECT pg_advisory_xact_lock(hashtextextended(:lockKey,0))
                        """).setParameter("lockKey",
                                "MATERIAL-ANALYSIS-SOURCE:" + identity.canonical())
                        .getSingleResult());
    }

    private void lockSalesSources(List<UUID> ids) {
        if (ids == null || ids.isEmpty()) return;
        List<UUID> sorted = ids.stream().filter(Objects::nonNull).distinct().sorted().toList();
        List<?> locked = em.createNativeQuery("""
                SELECT i.id
                FROM sales_order_items i
                JOIN sales_orders o ON o.id = i.order_id
                WHERE i.id IN (:ids)
                ORDER BY o.id, i.id
                FOR UPDATE OF o, i
                """).setParameter("ids", sorted).getResultList();
        if (locked.size() != sorted.size()) throw notFound("销售订单行不存在");
    }

    private List<SourceLine> loadSourceLines(UUID analysisId, boolean lockSales) {
        if (lockSales) {
            @SuppressWarnings("unchecked")
            List<UUID> salesIds = (List<UUID>) em.createNativeQuery("""
                    SELECT sales_order_item_id
                    FROM production_material_analysis_items
                    WHERE analysis_id = :id AND source_type = 'SALES_ORDER_ITEM'
                      AND is_deleted = FALSE
                    ORDER BY sales_order_item_id
                    """).setParameter("id", analysisId).getResultList();
            lockSalesSources(salesIds);
        }
        List<Object[]> rows = NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT ai.id, ai.source_type, ai.sales_order_item_id,
                       so.id, so.bill_no, so.bill_date,
                       ai.delivery_date, c.name,
                       ai.goods_id, g.code, g.name, g.spec,
                       ai.color_id, col.name, ai.unit_id, u.name,
                       COALESCE(soi.unit_rate,1), ai.requested_qty,
                       ai.submitted_qty, ai.approved_qty,
                       COALESCE(soi.qty, ai.requested_qty),
                       COALESCE(soi.shipped_qty,0), COALESCE(soi.returned_qty,0),
                       COALESCE(soi.flag_qty,0), COALESCE(soi.reserved_qty,0),
                       COALESCE(soi.planned_qty,0), COALESCE(soi.produced_qty,0),
                       COALESCE(draft.qty,0), so.status, so.is_stopped,
                       so.is_closed, so.is_deleted, soi.is_deleted,
                       ai.source_ref, ai.source_reason, ai.line_priority,
                       ai.ready_now_qty, ai.ready_by_date_qty,
                       ai.ready_start_qty, ai.ready_finish_qty, ai.ready_ship_qty,
                       parent_item.id, parent_goods.name,
                       COALESCE(so.finance_confirmed, FALSE),
                       ai.root_material_id, ai.root_fulfilled_qty, root_material.confirmed_route
                FROM production_material_analysis_items ai
                JOIN goods g ON g.id = ai.goods_id
                JOIN units u ON u.id = ai.unit_id
                LEFT JOIN colors col ON col.id = ai.color_id
                LEFT JOIN sales_order_items soi ON soi.id = ai.sales_order_item_id
                LEFT JOIN sales_orders so ON so.id = soi.order_id
                LEFT JOIN clients c ON c.id = so.client_id
                LEFT JOIN LATERAL (
                    SELECT SUM(pi.qty) AS qty
                    FROM production_plan_items pi
                    JOIN production_plans p ON p.id = pi.plan_id
                    WHERE pi.sales_order_item_id = soi.id
                      AND pi.is_deleted = FALSE
                      AND p.is_deleted = FALSE AND p.status = 0
                      AND p.is_canceled = FALSE
                ) draft ON TRUE
                LEFT JOIN production_material_analysis_materials parent_material
                  ON parent_material.id = ai.parent_analysis_material_id
                LEFT JOIN production_material_analysis_items parent_item
                  ON parent_item.id = parent_material.analysis_item_id
                LEFT JOIN goods parent_goods ON parent_goods.id = parent_item.goods_id
                LEFT JOIN production_material_analysis_materials root_material ON root_material.id=ai.root_material_id
                WHERE ai.analysis_id = :id AND ai.is_deleted = FALSE
                ORDER BY ai.line_priority, ai.delivery_date NULLS LAST, ai.id
                """).setParameter("id", analysisId));
        return rows.stream().map(SourceLine::from).toList();
    }

    private void validateSourceCapacity(List<SourceLine> sources) {
        requirePlanningSources(sources, sources.stream()
                .map(SourceLine::analysisItemId).collect(Collectors.toSet()));
    }

    void requirePlanningSources(UUID analysisId, Set<UUID> selectedItemIds) {
        requirePlanningSources(loadSourceLines(analysisId, false), selectedItemIds);
    }

    private static void requirePlanningSources(
            List<SourceLine> sources, Set<UUID> selectedItemIds) {
        Set<UUID> known = sources.stream().map(SourceLine::analysisItemId)
                .collect(Collectors.toSet());
        if (selectedItemIds.isEmpty() || !known.containsAll(selectedItemIds)) {
            throw conflict("待安排产品已变化，请刷新后重试");
        }
        Map<UUID, String> reasons = planningBlockedReasons(sources);
        for (UUID id : selectedItemIds.stream().sorted().toList()) {
            String reason = reasons.get(id);
            if (reason != null) throw conflict(reason);
        }
    }

    /** Resolve each source once, including nested make anchors, without recursive calls. */
    static Map<UUID, String> planningBlockedReasons(List<SourceLine> sources) {
        Map<UUID, SourceLine> byId = sources.stream().collect(Collectors.toMap(
                SourceLine::analysisItemId, source -> source));
        Map<UUID, String> blocked = new LinkedHashMap<>();
        Set<UUID> resolved = new HashSet<>();
        for (SourceLine start : sources) {
            if (resolved.contains(start.analysisItemId())) continue;
            Set<UUID> path = new LinkedHashSet<>();
            SourceLine current = start;
            String reason;
            while (true) {
                UUID id = current.analysisItemId();
                if (resolved.contains(id)) {
                    reason = blocked.get(id);
                    break;
                }
                if (!path.add(id)) {
                    reason = "产品来源关联异常，请先核对父子关系";
                    break;
                }
                reason = current.planningBlockedReason();
                if (reason != null || current.parentAnalysisLineId() == null) break;
                current = byId.get(current.parentAnalysisLineId());
                if (current == null) {
                    reason = "产品来源已变化，请先核对对应的上层产品";
                    break;
                }
            }
            for (UUID id : path) {
                resolved.add(id);
                if (reason != null) blocked.put(id, reason);
            }
        }
        return Map.copyOf(blocked);
    }

    private List<BomNode> loadBomTree(SourceLine source) {
        // An outsourced root still needs its original BOM for in-house preparation.
        // Its SUBCONTRACT_MAKE item is only a plan anchor and never duplicates that tree.
        if ("BUY".equals(source.rootRoute())) return List.of();
        validateBomGraph(source.goodsId(), source.unitRate());
        List<Object[]> rows = NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                WITH RECURSIVE exp AS (
                    SELECT b.id AS bom_item_id, b.goods_id AS parent_goods_id,
                           b.component_goods_id AS goods_id,
                           resolved_color.id AS color_id,
                           component_unit.id AS unit_id,
                           1 AS depth, ARRAY[b.id]::uuid[] AS bom_path,
                           CAST(:unitRate AS numeric) AS parent_per_product_qty,
                           b.qty AS bom_qty,
                           (CAST(:unitRate AS numeric) * b.qty /
                                CASE WHEN b.consumption_basis = 'PER_UNIT' THEN 1
                                     ELSE b.basis_output_qty END
                           )::numeric AS per_product_qty,
                           component.code, component.name, component.spec,
                           resolved_color.name AS color_name,
                           component_unit.name AS unit_name,
                           GREATEST(COALESCE(component.min_qty,0),0)::numeric AS safety_stock,
                           component.source_type,
                           EXISTS (SELECT 1 FROM goods_bom_items child
                                   WHERE child.goods_id = b.component_goods_id
                                     AND child.is_deleted = FALSE) AS has_children,
                           b.control_stage, b.consumption_basis,
                           b.basis_output_qty, b.allow_partial_package, b.hard_gate
                    FROM goods_bom_items b
                    JOIN goods component ON component.id = b.component_goods_id
                                         AND component.is_deleted = FALSE
                    LEFT JOIN colors resolved_color ON resolved_color.id =
                        COALESCE(b.color_id, component.color_id)
                                                    AND resolved_color.is_deleted = FALSE
                    LEFT JOIN units component_unit ON component_unit.id = component.unit_id
                                                   AND component_unit.is_deleted = FALSE
                    WHERE b.goods_id = :goodsId AND b.is_deleted = FALSE
                    UNION ALL
                    SELECT b.id, b.goods_id, b.component_goods_id,
                           resolved_color.id,
                           component_unit.id,
                           exp.depth + 1, exp.bom_path || b.id,
                           exp.per_product_qty,
                           b.qty,
                           (exp.per_product_qty * b.qty /
                                CASE WHEN b.consumption_basis = 'PER_UNIT' THEN 1
                                     ELSE b.basis_output_qty END
                           )::numeric,
                           component.code, component.name, component.spec,
                           resolved_color.name,
                           component_unit.name,
                           GREATEST(COALESCE(component.min_qty,0),0)::numeric,
                           component.source_type,
                           EXISTS (SELECT 1 FROM goods_bom_items child
                                   WHERE child.goods_id = b.component_goods_id
                                     AND child.is_deleted = FALSE),
                           b.control_stage, b.consumption_basis,
                           b.basis_output_qty, b.allow_partial_package, b.hard_gate
                    FROM exp
                    JOIN goods_bom_items b ON b.goods_id = exp.goods_id
                                          AND b.is_deleted = FALSE
                    JOIN goods component ON component.id = b.component_goods_id
                                         AND component.is_deleted = FALSE
                    LEFT JOIN colors resolved_color ON resolved_color.id =
                        COALESCE(b.color_id, component.color_id)
                                                    AND resolved_color.is_deleted = FALSE
                    LEFT JOIN units component_unit ON component_unit.id = component.unit_id
                                                   AND component_unit.is_deleted = FALSE
                    WHERE exp.depth < 10 AND NOT b.id = ANY(exp.bom_path)
                )
                SELECT bom_item_id, parent_goods_id, goods_id, color_id, unit_id,
                       depth, array_to_string(bom_path, '/'),
                        CASE WHEN depth = 1 THEN NULL
                             ELSE array_to_string(trim_array(bom_path, 1), '/') END,
                       parent_per_product_qty, bom_qty, per_product_qty,
                       code, name, spec, color_name, unit_name,
                       safety_stock, source_type, has_children,
                       control_stage, consumption_basis, basis_output_qty,
                       allow_partial_package, hard_gate
                FROM exp
                ORDER BY bom_path
                """)
                .setParameter("unitRate", source.unitRate())
                .setParameter("goodsId", source.goodsId()));
        List<BomNode> result = new ArrayList<>();
        Map<String, BomNode> byNodeKey = new LinkedHashMap<>();
        for (Object[] row : rows) {
            if (row[4] == null) {
                throw conflict("BOM 组件未维护有效基本单位，不能进行物料分析");
            }
            int depth = integer(row[5]);
            String nodeKey = string(row[6]);
            String parentNodeKey = string(row[7]);
            BigDecimal parentOutputQty;
            if (depth == 1) {
                parentOutputQty = source.materialRequirementQty().multiply(source.unitRate());
            } else {
                BomNode parent = byNodeKey.get(parentNodeKey);
                if (parent == null) {
                    throw conflict("BOM 层级路径不完整，无法计算子件需求");
                }
                // Gross first pass: this discovers every downstream stock dimension. The
                // persisted tree is rebased from each parent's stock-backed shortage later.
                parentOutputQty = parent.snapshotRequiredQty();
            }
            BigDecimal snapshotRequired;
            try {
                snapshotRequired = MaterialConsumptionMath.required(
                        parentOutputQty, decimal(row[9]), string(row[20]),
                        decimal(row[21]), Boolean.TRUE.equals(row[22]));
            } catch (IllegalArgumentException ex) {
                throw conflict("BOM 包装/批次计量数据无效，不能进行物料分析");
            }
            BomNode node = new BomNode(
                    source.analysisItemId(), uuid(row[0]), uuid(row[1]),
                    uuid(row[2]), uuid(row[3]), uuid(row[4]), depth,
                    nodeKey, parentNodeKey, decimal(row[8]), decimal(row[9]),
                    decimal(row[10]), snapshotRequired,
                    string(row[11]), string(row[12]), string(row[13]), string(row[14]),
                    string(row[15]), decimal(row[16]), suggestion(string(row[17])),
                    Boolean.TRUE.equals(row[18]), string(row[19]), string(row[20]),
                    decimal(row[21]), Boolean.TRUE.equals(row[22]),
                    Boolean.TRUE.equals(row[23]));
            result.add(node);
            byNodeKey.put(nodeKey, node);
        }
        return List.copyOf(result);
    }

    private void validateBomGraph(UUID goodsId, BigDecimal unitRate) {
        if (unitRate == null || unitRate.signum() <= 0) {
            throw conflict("生产需求单位换算率必须大于零");
        }
        Object[] row = oneRow(em.createNativeQuery("""
                WITH RECURSIVE walk AS (
                    SELECT b.id, b.component_goods_id AS goods_id, 1 AS depth,
                           ARRAY[b.id]::uuid[] AS path, FALSE AS cycle,
                            (b.qty <= 0 OR component.is_deleted
                             OR component.unit_id IS NULL OR component_unit.id IS NULL
                             OR (COALESCE(b.color_id, component.color_id) IS NOT NULL
                                 AND resolved_color.id IS NULL)
                             OR (b.color_id IS NULL
                                 AND NULLIF(b.color_legacy_id,0) IS NOT NULL)
                             OR (component.color_id IS NULL
                                 AND NULLIF(component.color_legacy_id,0) IS NOT NULL)) AS invalid
                    FROM goods_bom_items b
                    JOIN goods component ON component.id = b.component_goods_id
                    LEFT JOIN units component_unit ON component_unit.id = component.unit_id
                                                   AND component_unit.is_deleted = FALSE
                    LEFT JOIN colors resolved_color ON resolved_color.id =
                        COALESCE(b.color_id, component.color_id)
                                                    AND resolved_color.is_deleted = FALSE
                    WHERE b.goods_id = :goodsId AND b.is_deleted = FALSE
                    UNION ALL
                    SELECT b.id, b.component_goods_id, walk.depth + 1,
                           walk.path || b.id, b.id = ANY(walk.path),
                            (walk.invalid OR b.qty <= 0 OR component.is_deleted
                             OR component.unit_id IS NULL OR component_unit.id IS NULL
                             OR (COALESCE(b.color_id, component.color_id) IS NOT NULL
                                 AND resolved_color.id IS NULL)
                             OR (b.color_id IS NULL
                                 AND NULLIF(b.color_legacy_id,0) IS NOT NULL)
                             OR (component.color_id IS NULL
                                 AND NULLIF(component.color_legacy_id,0) IS NOT NULL))
                    FROM walk
                    JOIN goods_bom_items b ON b.goods_id = walk.goods_id
                                          AND b.is_deleted = FALSE
                    JOIN goods component ON component.id = b.component_goods_id
                    LEFT JOIN units component_unit ON component_unit.id = component.unit_id
                                                   AND component_unit.is_deleted = FALSE
                    LEFT JOIN colors resolved_color ON resolved_color.id =
                        COALESCE(b.color_id, component.color_id)
                                                    AND resolved_color.is_deleted = FALSE
                    WHERE walk.depth <= 10 AND walk.cycle = FALSE
                )
                SELECT COALESCE(bool_or(cycle),FALSE),
                       COALESCE(bool_or(depth > 10),FALSE),
                       COALESCE(bool_or(invalid),FALSE)
                FROM walk
                """).setParameter("goodsId", goodsId), "BOM 图校验失败");
        if (Boolean.TRUE.equals(row[0])) throw conflict("BOM 存在循环引用，不能进行物料分析");
        if (Boolean.TRUE.equals(row[1])) throw conflict("BOM 超过十层，不能静默截断分析");
        if (Boolean.TRUE.equals(row[2])) {
            throw conflict("BOM 存在非正用量、失效组件、颜色或基本单位异常");
        }
    }

    /** Exact, qualified origin balances grouped by the actual physical warehouse. */
    private Map<WarehouseMaterialDimension, BigDecimal> qualifiedOwnedStock(
            UUID analysisId, Set<String> currentNodeKeys) {
        if (currentNodeKeys.isEmpty()) return Map.of();
        Map<WarehouseMaterialDimension, BigDecimal> result = new LinkedHashMap<>();
        for (Object[] row : NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT reservation.warehouse_id,reservation.goods_id,reservation.color_id,
                       material.unit_id,SUM(balance.effective_qty)::numeric
                FROM v_preplan_stock_entitlement_beneficiary_balance balance
                JOIN stock_reservations reservation ON reservation.id=balance.stock_reservation_id
                  AND reservation.is_deleted=FALSE AND reservation.status=0
                  AND reservation.owner_type='PREPLAN_ANALYSIS'
                JOIN production_material_analysis_materials material
                  ON material.id=balance.beneficiary_analysis_material_id
                 AND material.analysis_id=balance.beneficiary_analysis_id
                JOIN warehouses warehouse ON warehouse.id=reservation.warehouse_id
                  AND warehouse.is_deleted=FALSE AND warehouse.is_accountable=TRUE
                  AND COALESCE(warehouse.status,'')<>'禁用'
                  AND NOT EXISTS(SELECT 1 FROM warehouses child
                      WHERE child.parent_id=warehouse.id AND child.is_deleted=FALSE)
                WHERE balance.beneficiary_analysis_id=:analysisId AND balance.effective_qty>0
                  -- Refresh temporarily deactivates the old rows before upserting
                  -- this exact current BOM. The admitted node keys, not that
                  -- transient flag, determine which existing source lots apply.
                  AND (material.analysis_item_id::text||'|'||material.node_key) IN (:nodeKeys)
                  AND fn_preplan_reservation_has_qualified_origin(reservation.id)
                GROUP BY reservation.warehouse_id,reservation.goods_id,reservation.color_id,material.unit_id
                """).setParameter("analysisId", analysisId).setParameter("nodeKeys", currentNodeKeys))) {
            result.put(new WarehouseMaterialDimension(uuid(row[0]),
                    new MaterialDimension(uuid(row[1]),uuid(row[2]),uuid(row[3]))),decimal(row[4]));
        }
        return Map.copyOf(result);
    }

    private AvailabilitySnapshot availability(
            UUID analysisId, UUID warehouseId,
            List<BomNode> nodes, List<SourceLine> sources) {
        Set<UUID> goodsIds = nodes.stream().map(BomNode::goodsId)
                .collect(Collectors.toCollection(TreeSet::new));
        if (goodsIds.isEmpty()) return new AvailabilitySnapshot(Map.of(), List.of());
        Set<String> currentNodeKeys = nodes.stream()
                .map(MaterialAnalysisService::nodeAllocationKey)
                .collect(Collectors.toSet());
        Map<WarehouseMaterialDimension, BigDecimal> qualifiedOwn = qualifiedOwnedStock(analysisId, currentNodeKeys);
        String qualifiedWarehouseIds = qualifiedOwn.keySet().stream().map(WarehouseMaterialDimension::warehouseId)
                .distinct().map(UUID::toString).sorted().collect(Collectors.joining(","));
        List<Object[]> stockRows = NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT v.warehouse_id, w.code, w.name, v.goods_id, v.color_id,
                       COALESCE(v.on_hand_qty,0), COALESCE(v.reserved_qty,0),
                       GREATEST(COALESCE(v.available_qty,0),0),
                       COALESCE(own.own_qty,0),
                       (NOT w.is_defective AND COALESCE(w.status,'')<>'禁用'
                        AND NOT EXISTS(SELECT 1 FROM warehouses child
                            WHERE child.parent_id=w.id AND child.is_deleted=FALSE)
                        AND (CAST(:warehouseId AS uuid) IS NULL
                             OR fn_warehouse_same_main(v.warehouse_id,CAST(:warehouseId AS uuid)))) AS public_allowed
                FROM v_stock_available v
                JOIN warehouses w ON w.id = v.warehouse_id
                LEFT JOIN LATERAL (
                    SELECT SUM(CASE
                        WHEN EXISTS (
                            SELECT 1
                            FROM preplan_stock_entitlement_events tracked
                            WHERE tracked.stock_reservation_id = r.id
                        ) THEN COALESCE((
                            SELECT SUM(balance.effective_qty)
                            FROM v_preplan_stock_entitlement_beneficiary_balance balance
                            JOIN production_material_analysis_materials beneficiary
                              ON beneficiary.id =
                                 balance.beneficiary_analysis_material_id
                             AND beneficiary.analysis_id =
                                 balance.beneficiary_analysis_id
                            WHERE balance.stock_reservation_id = r.id
                              AND balance.beneficiary_analysis_id = :analysisId
                              AND (beneficiary.analysis_item_id::text || '|'
                                   || beneficiary.node_key) IN (:currentNodeKeys)
                        ), 0)
                        WHEN r.owner_id = :analysisId
                        THEN r.qty - r.consumed_qty - r.released_qty
                        ELSE 0
                    END) AS own_qty
                    FROM stock_reservations r
                    WHERE r.is_deleted = FALSE
                      AND r.status = 0
                      AND r.owner_type = 'PREPLAN_ANALYSIS'
                      AND r.warehouse_id = v.warehouse_id
                      AND r.goods_id = v.goods_id
                      AND r.color_id IS NOT DISTINCT FROM v.color_id
                ) own ON TRUE
                WHERE v.goods_id IN (:goodsIds)
                  AND w.is_deleted = FALSE AND w.is_accountable = TRUE
                  AND (CAST(:warehouseId AS uuid) IS NULL
                       OR fn_warehouse_same_main(v.warehouse_id,CAST(:warehouseId AS uuid))
                       OR v.warehouse_id=ANY(CAST(string_to_array(:qualifiedWarehouses,',') AS uuid[])))
                ORDER BY v.warehouse_id, v.goods_id, v.color_id NULLS FIRST
                """)
                .setParameter("goodsIds", goodsIds)
                .setParameter("currentNodeKeys", currentNodeKeys)
                .setParameter("analysisId", analysisId)
                .setParameter("qualifiedWarehouses", qualifiedWarehouseIds)
                .setParameter("warehouseId", warehouseId));
        Map<MaterialDimension, StockValue> stock = new LinkedHashMap<>();
        Map<MaterialDimension, BigDecimal> publicAvailable = new LinkedHashMap<>();
        Map<MaterialDimension,BigDecimal> safetyByDimension = new HashMap<>();
        nodes.forEach(node -> safetyByDimension.merge(node.dimension(),node.safetyStock(),BigDecimal::max));
        Map<WarehouseMaterialDimension,BigDecimal> usableByWarehouse = new LinkedHashMap<>();
        Map<MaterialDimension, List<com.uten.imp.common.inventory.MainWarehouseStockBudget.Leaf<WarehouseMaterialDimension>>> budgetLeaves = new LinkedHashMap<>();
        Map<WarehouseMaterialDimension, StockValue> physicalByWarehouse = new LinkedHashMap<>();
        Map<StockIdentity, MaterialDimension> dimensionsByStock = nodes.stream()
                .collect(Collectors.toMap(
                        node -> new StockIdentity(node.goodsId(), node.colorId()),
                        BomNode::dimension, (first, ignored) -> first,
                        LinkedHashMap::new));
        for (Object[] row : stockRows) {
            MaterialDimension dimension = dimensionsByStock.get(
                    new StockIdentity(uuid(row[3]), uuid(row[4])));
            if (dimension == null) continue;
            // 分析备料绑定（V298）：本分析已收货被绑定的量从公共"预留"中还原为
            // 本分析的可用量——其它分析的可用口径不含它（v_stock_available 已扣）。
            WarehouseMaterialDimension location = new WarehouseMaterialDimension(uuid(row[0]), dimension);
            BigDecimal qualified = qualifiedOwn.getOrDefault(location, BigDecimal.ZERO);
            boolean publicAllowed = Boolean.TRUE.equals(row[9]);
            BigDecimal ownReserved = publicAllowed ? decimal(row[8]) : qualified;
            BigDecimal reserved = decimal(row[6]).subtract(ownReserved).max(BigDecimal.ZERO);
            ownReserved = ownReserved.min(decimal(row[5]).subtract(reserved).max(BigDecimal.ZERO));
            BigDecimal publicQty = publicAllowed ? decimal(row[7]).max(BigDecimal.ZERO) : BigDecimal.ZERO;
            budgetLeaves.computeIfAbsent(dimension, ignored -> new ArrayList<>()).add(
                    new com.uten.imp.common.inventory.MainWarehouseStockBudget.Leaf<>(
                            location, publicQty, ownReserved, qualified));
            physicalByWarehouse.put(location, new StockValue(decimal(row[5]), reserved, BigDecimal.ZERO, true));
            publicAvailable.merge(dimension, publicQty, BigDecimal::add);
        }
        for (var entry : budgetLeaves.entrySet()) {
            var distributed = com.uten.imp.common.inventory.MainWarehouseStockBudget.distribute(
                    entry.getValue(), safetyByDimension.getOrDefault(entry.getKey(), BigDecimal.ZERO));
            for (var usable : distributed.entrySet()) {
                StockValue physical = physicalByWarehouse.get(usable.getKey());
                usableByWarehouse.put(usable.getKey(), usable.getValue());
                stock.merge(entry.getKey(), new StockValue(physical.onHand(), physical.reserved(),
                        usable.getValue(), true), StockValue::add);
            }
        }
        List<Object[]> inboundRows = NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                WITH action_caps AS (
                    SELECT action.external_document_type, action.warehouse_id,
                           allocation.external_item_id,
                           material.goods_id, material.color_id, material.unit_id,
                           SUM(GREATEST(
                               allocation.allocated_qty - COALESCE((
                                   SELECT SUM(claim.claimed_qty)
                                   FROM preplan_subcontract_requirement_supply_claims
                                        claim
                                   JOIN preplan_subcontract_requirement_handoff_items
                                        mapped ON mapped.id = claim.handoff_item_id
                                   JOIN v_preplan_subcontract_requirement_handoff_state
                                        handoff ON handoff.id = mapped.handoff_id
                                       AND handoff.state = 'ACTIVE'
                                   WHERE claim.source_supply_action_allocation_id =
                                         allocation.id
                               ), 0) - COALESCE((
                                   SELECT SUM(CASE
                                       WHEN reservation.release_reason =
                                            'TRANSFERRED_TO_PLAN' THEN exact.qty
                                       ELSE GREATEST(reservation.qty
                                           - reservation.consumed_qty
                                           - reservation.released_qty, 0)
                                   END)
                                   FROM preplan_analysis_stock_exact_pegs exact
                                   JOIN stock_reservations reservation
                                     ON reservation.id = exact.stock_reservation_id
                                    AND reservation.is_deleted = FALSE
                                   WHERE exact.supply_action_allocation_id =
                                         allocation.id
                                     AND (reservation.status = 0 OR
                                          reservation.release_reason =
                                            'TRANSFERRED_TO_PLAN')
                               ), 0), 0))::numeric AS allocated_qty
                    FROM preplan_supply_actions action
                    JOIN preplan_supply_action_allocations allocation
                      ON allocation.action_id = action.id
                     AND allocation.analysis_id = action.analysis_id
                    JOIN production_material_analysis_materials material
                      ON material.id = allocation.analysis_material_id
                     AND material.analysis_id = allocation.analysis_id
                    WHERE action.analysis_id = :analysisId
                      AND action.status IN ('CREATED','IN_PROGRESS','DONE')
                      AND allocation.external_item_id IS NOT NULL
                    GROUP BY action.external_document_type, action.warehouse_id,
                             allocation.external_item_id,
                             material.goods_id, material.color_id, material.unit_id
                    UNION ALL
                    SELECT 'PURCHASE_SAFETY', action.warehouse_id,
                           action.safety_external_item_id,
                           action.goods_id, action.color_id, action.unit_id,
                           action.safety_replenishment_qty
                    FROM preplan_supply_actions action
                    WHERE action.analysis_id = :analysisId
                      AND action.route = 'BUY'
                      AND action.status IN ('CREATED','IN_PROGRESS','DONE')
                      AND action.safety_replenishment_qty > 0
                      AND action.safety_external_item_id IS NOT NULL
                )
                , confirmed_supply AS (
                    SELECT cap.external_document_type AS document_type,
                           cap.external_item_id, cap.goods_id, cap.color_id,
                           cap.unit_id, cap.allocated_qty,
                           COALESCE(i.deliver_date,o.deliver_date) AS eta,
                           i.id AS supply_item_id,
                           -- V463：合并订货行在途量按来源 FIFO 分摊。
                           fn_purchase_order_source_share(
                               i.id, src.request_item_id,
                               GREATEST(COALESCE(i.qty,0)-COALESCE(i.received_qty,0)
                                        +COALESCE(i.returned_qty,0),0)
                               * COALESCE(i.unit_rate,1))::numeric AS open_qty
                    FROM action_caps cap
                    JOIN purchase_request_items request_item
                      ON request_item.id = cap.external_item_id
                     AND request_item.is_deleted = FALSE
                    JOIN purchase_requests request
                      ON request.id = request_item.request_id
                     AND request.is_deleted = FALSE
                     AND request.status IN (0,1)
                     AND request.is_stopped = FALSE
                    JOIN purchase_order_item_sources src
                      ON src.request_item_id = cap.external_item_id
                    JOIN purchase_order_items i ON i.id = src.order_item_id
                    JOIN purchase_orders o ON o.id = i.order_id
                    WHERE cap.external_document_type IN (
                              'PURCHASE_REQUEST','PURCHASE_SAFETY')
                      AND o.status = 1 AND o.is_deleted = FALSE AND o.is_closed = FALSE
                      AND i.is_deleted = FALSE
                      AND COALESCE(i.deliver_date,o.deliver_date) IS NOT NULL
                      AND (CAST(:warehouseId AS uuid) IS NULL
                           OR fn_warehouse_same_main(cap.warehouse_id,CAST(:warehouseId AS uuid)))
                    UNION ALL
                    SELECT cap.external_document_type, cap.external_item_id,
                           cap.goods_id, cap.color_id, cap.unit_id,
                           cap.allocated_qty,
                           COALESCE(i.deliver_date,o.deliver_date), i.id,
                           fn_subcontract_order_source_share(
                               i.id, src.application_item_id,
                               GREATEST(COALESCE(i.qty,0)-COALESCE(i.received_qty,0)
                                        +COALESCE(i.returned_qty,0),0)
                               * COALESCE(i.unit_rate,1))::numeric
                    FROM action_caps cap
                    JOIN subcontract_application_items application_item
                      ON application_item.id = cap.external_item_id
                     AND application_item.is_deleted = FALSE
                    JOIN subcontract_applications application
                      ON application.id = application_item.application_id
                     AND application.is_deleted = FALSE
                     AND application.status IN (0,1)
                    JOIN subcontract_order_item_sources src
                      ON src.application_item_id = cap.external_item_id
                    JOIN subcontract_order_items i
                      ON i.id = src.order_item_id
                    JOIN subcontract_orders o ON o.id = i.order_id
                    WHERE cap.external_document_type = 'SUBCONTRACT_APPLICATION'
                      AND o.status = 1 AND o.is_deleted = FALSE AND o.is_closed = FALSE
                      AND i.is_deleted = FALSE
                      AND COALESCE(i.deliver_date,o.deliver_date) IS NOT NULL
                      AND (CAST(:warehouseId AS uuid) IS NULL
                           OR fn_warehouse_same_main(cap.warehouse_id,CAST(:warehouseId AS uuid)))
                    UNION ALL
                    SELECT cap.external_document_type, cap.external_item_id,
                           cap.goods_id, cap.color_id, cap.unit_id,
                           cap.allocated_qty,
                           COALESCE(plan_item.plan_end_date, plan.delivery_date),
                           plan_item.id,
                           GREATEST(COALESCE(plan_item.qty,0)-COALESCE(plan_item.iqty,0),0)::numeric
                    FROM action_caps cap
                    JOIN production_material_analysis_plan_links analysis_link
                      ON analysis_link.analysis_item_id = cap.external_item_id
                     AND analysis_link.allocation_status = 'APPROVED'
                    JOIN production_plans plan
                      ON plan.id = analysis_link.plan_id
                     AND plan.status = 1
                     AND plan.is_deleted = FALSE
                     AND plan.is_canceled = FALSE
                    JOIN production_plan_items plan_item
                      ON plan_item.plan_id = plan.id
                     AND plan_item.is_deleted = FALSE
                    WHERE cap.external_document_type = 'PREPLAN_MAKE_TASK'
                      AND COALESCE(plan_item.plan_end_date, plan.delivery_date) IS NOT NULL
                ), ranked_supply AS (
                    SELECT confirmed_supply.*,
                           COALESCE(SUM(open_qty) OVER (
                               PARTITION BY document_type, external_item_id
                               ORDER BY eta, supply_item_id
                               ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
                           ),0)::numeric AS prior_open_qty
                    FROM confirmed_supply
                    WHERE open_qty > 0
                ), capped_supply AS (
                    SELECT goods_id, color_id, unit_id, eta,
                           GREATEST(LEAST(
                               open_qty,
                               allocated_qty - prior_open_qty
                           ),0)::numeric AS open_qty
                    FROM ranked_supply
                ), target_claim_supply AS (
                    SELECT claim.id AS claim_id,
                           mapped.goods_id,
                           mapped.color_id,
                           mapped.unit_id,
                           claim.future_qty AS claimed_qty,
                           COALESCE(order_item.deliver_date, order_header.deliver_date)
                               AS eta,
                           order_item.id AS supply_item_id,
                           fn_purchase_order_source_share(
                               order_item.id, src.request_item_id,
                               GREATEST(COALESCE(order_item.qty,0)
                                   - COALESCE(order_item.received_qty,0)
                                   + COALESCE(order_item.returned_qty,0),0)
                               * COALESCE(order_item.unit_rate,1))::numeric AS open_qty
                    FROM v_preplan_subcontract_requirement_supply_claim_state claim
                    JOIN preplan_subcontract_requirement_handoff_items mapped
                      ON mapped.id = claim.handoff_item_id
                    JOIN preplan_supply_action_allocations allocation
                      ON allocation.id = claim.source_supply_action_allocation_id
                     AND allocation.analysis_id = claim.source_analysis_id
                    JOIN preplan_supply_actions source_action
                      ON source_action.id = claim.source_supply_action_id
                     AND source_action.analysis_id = claim.source_analysis_id
                     AND source_action.status <> 'CANCELLED'
                    JOIN purchase_request_items request_item
                      ON request_item.id = allocation.external_item_id
                     AND request_item.is_deleted = FALSE
                    JOIN purchase_requests request_header
                      ON request_header.id = request_item.request_id
                     AND request_header.is_deleted = FALSE
                     AND request_header.status IN (0,1)
                     AND request_header.is_stopped = FALSE
                    JOIN purchase_order_item_sources src
                      ON src.request_item_id = request_item.id
                    JOIN purchase_order_items order_item
                      ON order_item.id = src.order_item_id
                     AND order_item.is_deleted = FALSE
                    JOIN purchase_orders order_header
                      ON order_header.id = order_item.order_id
                     AND order_header.status = 1
                     AND order_header.is_deleted = FALSE
                     AND order_header.is_closed = FALSE
                    WHERE mapped.target_analysis_id = :analysisId
                      AND claim.future_qty > 0
                      AND source_action.external_document_type = 'PURCHASE_REQUEST'
                      AND COALESCE(order_item.deliver_date,
                                   order_header.deliver_date) IS NOT NULL
                      AND (:warehouseId IS NULL
                           OR fn_warehouse_same_main(source_action.warehouse_id,:warehouseId))
                    UNION ALL
                    SELECT claim.id, mapped.goods_id,
                           mapped.color_id, mapped.unit_id,
                           claim.future_qty,
                           COALESCE(order_item.deliver_date, order_header.deliver_date),
                           order_item.id,
                           fn_subcontract_order_source_share(
                               order_item.id, src.application_item_id,
                               GREATEST(COALESCE(order_item.qty,0)
                                   - COALESCE(order_item.received_qty,0)
                                   + COALESCE(order_item.returned_qty,0),0)
                               * COALESCE(order_item.unit_rate,1))::numeric
                    FROM v_preplan_subcontract_requirement_supply_claim_state claim
                    JOIN preplan_subcontract_requirement_handoff_items mapped
                      ON mapped.id = claim.handoff_item_id
                    JOIN preplan_supply_action_allocations allocation
                      ON allocation.id = claim.source_supply_action_allocation_id
                     AND allocation.analysis_id = claim.source_analysis_id
                    JOIN preplan_supply_actions source_action
                      ON source_action.id = claim.source_supply_action_id
                     AND source_action.analysis_id = claim.source_analysis_id
                     AND source_action.status <> 'CANCELLED'
                    JOIN subcontract_application_items application_item
                      ON application_item.id = allocation.external_item_id
                     AND application_item.is_deleted = FALSE
                    JOIN subcontract_applications application_header
                      ON application_header.id = application_item.application_id
                     AND application_header.is_deleted = FALSE
                     AND application_header.status IN (0,1)
                    JOIN subcontract_order_item_sources src
                      ON src.application_item_id = application_item.id
                    JOIN subcontract_order_items order_item
                      ON order_item.id = src.order_item_id
                     AND order_item.is_deleted = FALSE
                    JOIN subcontract_orders order_header
                      ON order_header.id = order_item.order_id
                     AND order_header.status = 1
                     AND order_header.is_deleted = FALSE
                     AND order_header.is_closed = FALSE
                    WHERE mapped.target_analysis_id = :analysisId
                      AND claim.future_qty > 0
                      AND source_action.external_document_type =
                          'SUBCONTRACT_APPLICATION'
                      AND COALESCE(order_item.deliver_date,
                                   order_header.deliver_date) IS NOT NULL
                      AND (:warehouseId IS NULL
                           OR fn_warehouse_same_main(source_action.warehouse_id,:warehouseId))
                    UNION ALL
                    SELECT claim.id, mapped.goods_id,
                           mapped.color_id, mapped.unit_id,
                           claim.future_qty,
                           COALESCE(plan_item.plan_end_date, plan.delivery_date),
                           plan_item.id,
                           GREATEST(COALESCE(plan_item.qty,0)
                               - COALESCE(plan_item.iqty,0),0)::numeric
                    FROM v_preplan_subcontract_requirement_supply_claim_state claim
                    JOIN preplan_subcontract_requirement_handoff_items mapped
                      ON mapped.id = claim.handoff_item_id
                    JOIN preplan_supply_action_allocations allocation
                      ON allocation.id = claim.source_supply_action_allocation_id
                     AND allocation.analysis_id = claim.source_analysis_id
                    JOIN preplan_supply_actions source_action
                      ON source_action.id = claim.source_supply_action_id
                     AND source_action.analysis_id = claim.source_analysis_id
                     AND source_action.status <> 'CANCELLED'
                    JOIN production_material_analysis_plan_links analysis_link
                      ON analysis_link.analysis_item_id = allocation.external_item_id
                     AND analysis_link.allocation_status = 'APPROVED'
                    JOIN production_plans plan
                      ON plan.id = analysis_link.plan_id
                     AND plan.status = 1
                     AND plan.is_deleted = FALSE
                     AND plan.is_canceled = FALSE
                    JOIN production_plan_items plan_item
                      ON plan_item.plan_id = plan.id
                     AND plan_item.is_deleted = FALSE
                    WHERE mapped.target_analysis_id = :analysisId
                      AND claim.future_qty > 0
                      AND source_action.external_document_type = 'PREPLAN_MAKE_TASK'
                      AND COALESCE(plan_item.plan_end_date,
                                   plan.delivery_date) IS NOT NULL
                ), target_claim_ranked AS (
                    SELECT target_claim_supply.*,
                           COALESCE(SUM(open_qty) OVER (
                               PARTITION BY claim_id
                               ORDER BY eta, supply_item_id
                               ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
                           ),0)::numeric AS prior_open_qty
                    FROM target_claim_supply
                    WHERE open_qty > 0
                ), target_handoff_supply AS (
                    SELECT goods_id, color_id, unit_id, eta,
                           GREATEST(LEAST(
                               open_qty, claimed_qty - prior_open_qty
                           ),0)::numeric AS open_qty
                    FROM target_claim_ranked
                ), all_supply AS (
                    SELECT goods_id, color_id, unit_id, eta, open_qty
                    FROM capped_supply
                    UNION ALL
                    SELECT goods_id, color_id, unit_id, eta, open_qty
                    FROM target_handoff_supply
                )
                SELECT goods_id, color_id, unit_id, eta,
                       SUM(open_qty)::numeric
                FROM all_supply
                WHERE open_qty > 0
                GROUP BY goods_id, color_id, unit_id, eta
                ORDER BY goods_id, color_id NULLS FIRST, unit_id, eta
                """)
                .setParameter("analysisId", analysisId)
                .setParameter("warehouseId", warehouseId));
        List<InboundLot> inbound = new ArrayList<>();
        Map<MaterialDimension, BomNode> nodesByDimension = nodes.stream()
                .collect(Collectors.toMap(BomNode::dimension, node -> node,
                        (first, ignored) -> first, LinkedHashMap::new));
        for (Object[] row : inboundRows) {
            BomNode matching = nodesByDimension.get(new MaterialDimension(
                    uuid(row[0]), uuid(row[1]), uuid(row[2])));
            if (matching != null) inbound.add(new InboundLot(
                    matching.dimension(), date(row[3]), decimal(row[4])));
        }
        Map<MaterialDimension, BigDecimal> safetyGaps = new LinkedHashMap<>();
        nodes.forEach(node -> safetyGaps.merge(
                node.dimension(), node.safetyStock(), BigDecimal::max));
        safetyGaps.replaceAll((dimension, safety) -> safety
                .subtract(publicAvailable.getOrDefault(
                        dimension, BigDecimal.ZERO))
                .max(BigDecimal.ZERO));
        List<InboundLot> demandUsableInbound =
                netFutureSupplyAfterSafety(inbound, safetyGaps);
        return new AvailabilitySnapshot(
                Map.copyOf(stock), List.copyOf(demandUsableInbound),Map.copyOf(usableByWarehouse));
    }

    /** Earliest future supply restores public safety stock before demand ETA. */
    static List<InboundLot> netFutureSupplyAfterSafety(
            List<InboundLot> inbound,
            Map<MaterialDimension, BigDecimal> safetyGaps) {
        Map<MaterialDimension, BigDecimal> remainingGap = new LinkedHashMap<>();
        safetyGaps.forEach((dimension, gap) -> remainingGap.put(
                dimension, gap.max(BigDecimal.ZERO)));
        List<InboundLot> ordered = inbound.stream()
                .sorted(Comparator
                        .comparing(InboundLot::expectedDate,
                                Comparator.nullsLast(Comparator.naturalOrder()))
                        .thenComparing(lot -> lot.dimension().goodsId().toString())
                        .thenComparing(lot -> Objects.toString(
                                lot.dimension().colorId(), "")))
                .toList();
        List<InboundLot> result = new ArrayList<>();
        for (InboundLot lot : ordered) {
            BigDecimal qty = lot.qty().max(BigDecimal.ZERO);
            BigDecimal gap = remainingGap.getOrDefault(
                    lot.dimension(), BigDecimal.ZERO);
            BigDecimal safetyUse = qty.min(gap);
            remainingGap.put(lot.dimension(), gap.subtract(safetyUse));
            BigDecimal usable = qty.subtract(safetyUse).max(BigDecimal.ZERO)
                    .setScale(4, RoundingMode.DOWN);
            if (usable.signum() > 0) {
                result.add(new InboundLot(
                        lot.dimension(), lot.expectedDate(), usable));
            }
        }
        return List.copyOf(result);
    }

    private List<MaterialRow> loadMaterialRows(UUID analysisId) {
        return NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT m.id, m.analysis_item_id, m.node_key,
                       m.goods_id, g.code, g.name, g.spec,
                       m.color_id, c.name, m.unit_id, u.name, m.depth, m.path,
                       m.parent_node_key,
                       parent_material.goods_id AS parent_goods_id,
                       m.control_stage, m.consumption_basis, m.basis_output_qty,
                       m.allow_partial_package, m.hard_gate,
                       m.bom_qty, m.parent_per_product_qty,
                       m.per_product_qty, m.required_qty, m.available_qty,
                       m.allocated_available_qty, m.reserved_qty,
                       m.safety_stock_qty, m.inbound_qty,
                       m.shortage_qty, m.expected_ready_date, m.source_suggestion,
                       m.confirmed_route, m.route_reason,
                       m.lower_level_pending
                FROM production_material_analysis_materials m
                JOIN goods g ON g.id = m.goods_id
                JOIN units u ON u.id = m.unit_id
                LEFT JOIN colors c ON c.id = m.color_id
                LEFT JOIN production_material_analysis_materials parent_material
                  ON parent_material.analysis_item_id = m.analysis_item_id
                 AND parent_material.node_key = m.parent_node_key
                WHERE m.analysis_id = :id AND m.active = TRUE
                ORDER BY m.analysis_item_id, m.path, m.id
                """).setParameter("id", analysisId)).stream()
                .map(MaterialRow::from).toList();
    }

    /** 物料行 → 其计划锚点子件行（MAKE_COMPONENT / SUBCONTRACT_MAKE）。 */
    private Map<UUID, UUID> anchorChildByParentLine(UUID analysisId) {
        Map<UUID, UUID> result = new LinkedHashMap<>();
        for (Object[] row : NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT item.parent_analysis_material_id, item.id
                FROM production_material_analysis_items item
                WHERE item.analysis_id = :analysisId
                  AND item.is_deleted = FALSE
                  AND item.source_type IN ('MAKE_COMPONENT', 'SUBCONTRACT_MAKE')
                  AND item.parent_analysis_material_id IS NOT NULL
                ORDER BY item.parent_analysis_material_id, item.created_at, item.id
                """).setParameter("analysisId", analysisId))) {
            result.putIfAbsent((UUID) row[0], (UUID) row[1]);
        }
        return result;
    }

    /** Real plan/execution projection shown beside MAKE node tasks. */
    private Map<UUID, ProductPlanState> productPlanStates(UUID analysisId) {        Map<UUID, ProductPlanState> result = new LinkedHashMap<>();
        for (Object[] row : NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                WITH active_links AS (
                    SELECT link.analysis_item_id, link.plan_id,
                           MAX(link.created_at) AS created_at,
                           BOOL_OR(link.allocation_status = 'APPROVED') AS approved
                    FROM production_material_analysis_plan_links link
                    JOIN production_plans plan
                      ON plan.id = link.plan_id
                     AND plan.is_deleted = FALSE
                     AND plan.is_canceled = FALSE
                     AND plan.status IN (0,1)
                    WHERE link.analysis_id = :analysisId
                      AND link.allocation_status IN ('SUBMITTED','APPROVED')
                    GROUP BY link.analysis_item_id, link.plan_id
                ),
                plan_ids AS (
                    SELECT DISTINCT plan_id
                    FROM active_links
                ),
                item_rollup AS (
                    SELECT ids.plan_id,
                           COUNT(plan_item.id) AS item_count,
                           COALESCE(SUM(GREATEST(COALESCE(plan_item.qty,0),0)),0)
                             AS planned_qty,
                           COALESCE(SUM(GREATEST(LEAST(
                               COALESCE(plan_item.iqty,0),
                               GREATEST(COALESCE(plan_item.qty,0),0)),0)),0)
                             AS inbound_qty,
                           COALESCE(BOOL_AND(
                               COALESCE(plan_item.qty,0) - COALESCE(plan_item.iqty,0) <= 0)
                               FILTER (WHERE plan_item.id IS NOT NULL), FALSE)
                             AS all_complete
                    FROM plan_ids ids
                    LEFT JOIN production_plan_items plan_item
                      ON plan_item.plan_id = ids.plan_id
                     AND plan_item.is_deleted = FALSE
                    GROUP BY ids.plan_id
                ),
                segment_rollup AS (
                    SELECT ids.plan_id,
                           COALESCE(BOOL_OR(segment.status = 'IN_PROGRESS'), FALSE)
                             AS has_in_progress,
                           COALESCE(BOOL_OR(segment.status = 'DISPATCHED'), FALSE)
                             AS has_dispatched,
                           COALESCE(BOOL_OR(segment.status = 'READY'), FALSE)
                             AS has_ready,
                           COALESCE(BOOL_OR(segment.status = 'WAITING'), FALSE)
                             AS has_waiting,
                           COALESCE(BOOL_OR(
                               segment.material_requirement_mode = 'ZERO_MATERIAL'),
                               FALSE)
                             AS has_zero_segment,
                           MIN(NULLIF(workshop.name, '')) AS workshop_name,
                           MIN(NULLIF(responsible.full_name, '')) AS responsible_name
                    FROM plan_ids ids
                    LEFT JOIN production_plan_items plan_item
                      ON plan_item.plan_id = ids.plan_id
                     AND plan_item.is_deleted = FALSE
                    LEFT JOIN production_execution_segments segment
                      ON segment.source_plan_item_id = plan_item.id
                     AND segment.is_deleted = FALSE
                     AND segment.status NOT IN ('CANCELLED','REVERSED')
                    LEFT JOIN departments workshop
                      ON workshop.id = segment.workshop_department_id
                    LEFT JOIN employees responsible
                      ON responsible.id = segment.responsible_employee_id
                    GROUP BY ids.plan_id
                ),
                report_rollup AS (
                    SELECT ids.plan_id,
                           COALESCE(SUM(report_item.qty), 0) AS reported_qty
                    FROM plan_ids ids
                    LEFT JOIN production_plan_items plan_item
                      ON plan_item.plan_id = ids.plan_id
                     AND plan_item.is_deleted = FALSE
                    LEFT JOIN production_execution_segments segment
                      ON segment.source_plan_item_id = plan_item.id
                     AND segment.is_deleted = FALSE
                     AND segment.status NOT IN ('CANCELLED','REVERSED')
                    LEFT JOIN production_daily_report_items report_item
                      ON report_item.execution_segment_id = segment.id
                     AND report_item.is_deleted = FALSE
                    LEFT JOIN production_daily_reports report
                      ON report.id = report_item.report_id
                     AND report.is_deleted = FALSE
                     AND report.status = 1
                    GROUP BY ids.plan_id
                )
                SELECT link.analysis_item_id,
                       (array_agg(plan.id ORDER BY link.created_at DESC, plan.id DESC))[1],
                       (array_agg(plan.bill_no ORDER BY link.created_at DESC, plan.id DESC))[1],
                       CASE
                         WHEN COALESCE(SUM(item_rollup.item_count),0) > 0
                              AND BOOL_AND(item_rollup.all_complete)
                            THEN 'COMPLETED'
                         WHEN COALESCE(BOOL_OR(segment_rollup.has_in_progress), FALSE)
                            THEN 'IN_PROGRESS'
                         WHEN COALESCE(BOOL_OR(segment_rollup.has_dispatched), FALSE)
                            THEN 'DISPATCHED'
                         WHEN COALESCE(BOOL_OR(segment_rollup.has_ready), FALSE)
                            THEN 'READY'
                         WHEN COALESCE(BOOL_OR(segment_rollup.has_waiting), FALSE)
                            THEN 'WAITING'
                         WHEN COALESCE(BOOL_OR(link.approved), FALSE)
                            THEN 'APPROVED'
                         ELSE 'SUBMITTED'
                       END AS execution_status,
                       COALESCE(SUM(item_rollup.planned_qty)
                           FILTER (WHERE link.approved AND plan.status = 1),0)
                         AS execution_planned_qty,
                       COALESCE(SUM(item_rollup.inbound_qty)
                           FILTER (WHERE link.approved AND plan.status = 1),0)
                         AS execution_inbound_qty,
                       COALESCE(SUM(report_rollup.reported_qty)
                           FILTER (WHERE link.approved AND plan.status = 1),0)
                         AS execution_reported_qty,
                       COALESCE(BOOL_OR(segment_rollup.has_zero_segment), FALSE)
                         AS execution_zero_material,
                       COALESCE(MIN(NULLIF(segment_rollup.workshop_name, '')), '')
                         AS execution_workshop_name,
                       COALESCE(
                           MIN(NULLIF(segment_rollup.responsible_name, '')), '')
                         AS execution_responsible_name
                FROM active_links link
                JOIN production_plans plan
                  ON plan.id = link.plan_id
                JOIN item_rollup
                  ON item_rollup.plan_id = link.plan_id
                JOIN segment_rollup
                  ON segment_rollup.plan_id = link.plan_id
                JOIN report_rollup
                  ON report_rollup.plan_id = link.plan_id
                GROUP BY link.analysis_item_id
                ORDER BY link.analysis_item_id
                """).setParameter("analysisId", analysisId))) {
            BigDecimal plannedQty = decimal(row[4]);
            BigDecimal inboundQty = decimal(row[5]);
            result.put(uuid(row[0]), new ProductPlanState(
                    string(row[3]), uuid(row[1]), string(row[2]),
                    plannedQty, inboundQty,
                    planExecutionProgressRatio(plannedQty, inboundQty),
                    decimal(row[6]), Boolean.TRUE.equals(row[7]),
                    string(row[8]), string(row[9])));
        }
        return Map.copyOf(result);
    }

    static BigDecimal planExecutionProgressRatio(
            BigDecimal plannedQty, BigDecimal inboundQty) {
        if (plannedQty == null || plannedQty.signum() <= 0) return null;
        BigDecimal safeInbound = inboundQty == null ? BigDecimal.ZERO : inboundQty;
        safeInbound = safeInbound.max(BigDecimal.ZERO).min(plannedQty);
        return safeInbound.divide(plannedQty, 4, RoundingMode.DOWN);
    }

    private SharedFutureIndex sharedFutureSupply(
            UUID analysisId, UUID warehouseId, List<MaterialRow> materials) {
        Set<UUID> goodsIds = materials.stream().map(MaterialRow::goodsId)
                .collect(Collectors.toSet());
        if (goodsIds.isEmpty()) return new SharedFutureIndex(Map.of());
        boolean canSeePurchase = access.hasAuthority("purchase_request:view")
                || access.hasAuthority("purchase_order:view");
        boolean canSeeSubcontract = access.hasAuthority("subcontract_application:view")
                || access.hasAuthority("subcontract_order:view");
        OwnerVisibility.OwnerScope purchaseScope = ownerVisibility.evaluate(
                "purchase", "purchase:view:all");
        OwnerVisibility.OwnerScope subcontractScope = ownerVisibility.evaluate(
                "subcontract", "subcontract:view:all");
        Map<WarehouseMaterialDimension, SharedFutureAggregate> aggregates =
                new LinkedHashMap<>();
        for (Object[] row : NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT source_state.warehouse_id, source_state.goods_id,
                       source_state.color_id, source_state.unit_id,
                       source_state.route, source_state.approved_open_qty,
                       source_state.available_to_claim_qty,
                       source_state.expected_date,
                       source_state.source_action_id,
                       source_state.source_analysis_id,
                       source_state.external_document_type,
                       source_state.external_document_id,
                       source_state.external_document_no,
                       COALESCE(purchase_request.maker_id,
                                subcontract_application.maker_id)
                           AS external_document_maker_id
                FROM v_preplan_public_surplus_source_state source_state
                LEFT JOIN purchase_requests purchase_request
                  ON source_state.route = 'BUY'
                 AND purchase_request.id = source_state.external_document_id
                LEFT JOIN subcontract_applications subcontract_application
                  ON source_state.route = 'SUBCONTRACT'
                 AND subcontract_application.id = source_state.external_document_id
                WHERE fn_warehouse_same_main(source_state.warehouse_id,:warehouseId)
                  AND source_state.goods_id IN (:goodsIds)
                  AND source_state.approved_open_qty > 0
                ORDER BY source_state.warehouse_id, source_state.goods_id,
                         source_state.color_id NULLS FIRST,
                         source_state.unit_id,
                         source_state.expected_date NULLS LAST,
                         source_state.source_action_id
                """).setParameter("warehouseId", warehouseId)
                .setParameter("goodsIds", goodsIds))) {
            MaterialDimension dimension = new MaterialDimension(
                    uuid(row[1]), uuid(row[2]), uuid(row[3]));
            WarehouseMaterialDimension key = new WarehouseMaterialDimension(
                    uuid(row[0]), dimension);
            String route = string(row[4]);
            UUID documentMakerId = uuid(row[13]);
            boolean reveal = "BUY".equals(route)
                    ? canSeePurchase && ownerVisible(purchaseScope, documentMakerId)
                    : canSeeSubcontract
                            && ownerVisible(subcontractScope, documentMakerId);
            SharedFutureSupplyRef ref = new SharedFutureSupplyRef(
                    route, decimal(row[5]), decimal(row[6]), date(row[7]),
                    reveal ? uuid(row[8]) : null,
                    reveal ? string(row[10]) : null,
                    reveal ? uuid(row[11]) : null,
                    reveal ? string(row[12]) : null,
                    analysisId.equals(uuid(row[9])));
            SharedFutureAggregate current = aggregates.getOrDefault(
                    key, SharedFutureAggregate.ZERO);
            aggregates.put(key, current.plus(ref));
        }
        return new SharedFutureIndex(Map.copyOf(aggregates));
    }

    private static boolean ownerVisible(
            OwnerVisibility.OwnerScope scope, UUID ownerEmployeeId) {
        return scope.seeAll() || ownerEmployeeId == null
                || scope.visibleOwners().contains(ownerEmployeeId);
    }

    private Map<UUID, BigDecimal> sharedFutureClaimedByMaterial(UUID analysisId) {
        Map<UUID, BigDecimal> result = new LinkedHashMap<>();
        for (Object[] row : NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT allocation.analysis_material_id,
                       SUM(allocation.allocated_qty)::numeric
                FROM preplan_supply_action_allocations allocation
                JOIN preplan_supply_actions action ON action.id = allocation.action_id
                WHERE action.analysis_id = :analysisId
                  AND action.operation_type = 'SHARED_FUTURE_CLAIM'
                  AND action.status <> 'CANCELLED'
                GROUP BY allocation.analysis_material_id
                """).setParameter("analysisId", analysisId))) {
            result.put(uuid(row[0]), decimal(row[1]));
        }
        return Map.copyOf(result);
    }

    private Map<UUID, BigDecimal> activeFutureCoverageByMaterial(UUID analysisId) {
        Map<UUID, BigDecimal> result = new LinkedHashMap<>();
        for (Object[] row : NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                WITH action_future AS (
                    SELECT action.id AS action_id,
                           progress.demand_future_qty AS future_qty
                    FROM preplan_supply_actions action
                    JOIN v_preplan_buy_action_slice_progress progress
                      ON progress.action_id = action.id
                    WHERE action.analysis_id = :analysisId
                      AND action.status = 'CANCELLED'
                      AND action.route = 'BUY'
                      AND action.cancellation_reason IN (
                        '到货质检存在不合格且原采购需求已无在途，需重新通知补采',
                        '需求或公共安全补库存在终态不合格且已无未来供给，需按失败切片重新通知')
                      AND progress.demand_future_qty > 0
                ), coverage AS (
                    SELECT allocation.analysis_material_id,
                           GREATEST(allocation.allocated_qty
                             - fn_preplan_allocation_effective_exact_qty(allocation.id)
                             - COALESCE((SELECT SUM(CASE WHEN output.event_kind='FULFILL'
                                      THEN output.qty_base ELSE -output.qty_base END)
                                 FROM preplan_root_output_events output
                                 JOIN preplan_analysis_stock_exact_pegs exact
                                   ON exact.stock_reservation_id=output.source_reservation_id
                                 WHERE exact.supply_action_allocation_id=allocation.id),0),0)::numeric AS qty
                    FROM preplan_supply_action_allocations allocation
                    JOIN preplan_supply_actions action
                      ON action.id = allocation.action_id
                    WHERE action.analysis_id = :analysisId
                      AND action.status IN ('OPEN','CREATED','IN_PROGRESS')
                      AND action.external_document_type IS DISTINCT FROM 'SUBCONTRACT_MAKE_TASK'
                    UNION ALL
                    SELECT task.analysis_material_id,
                           GREATEST(task.required_qty-task.notified_qty,0)::numeric
                    FROM preplan_subcontract_make_tasks task
                    WHERE task.analysis_id=:analysisId AND task.status='ACTIVE'
                    UNION ALL
                    SELECT allocation.analysis_material_id,
                           LEAST(allocation.allocated_qty,
                               future.future_qty * allocation.allocated_qty
                                   / NULLIF(action.requested_qty,0))::numeric
                    FROM action_future future
                    JOIN preplan_supply_actions action ON action.id = future.action_id
                    JOIN preplan_supply_action_allocations allocation
                      ON allocation.action_id = action.id
                )
                SELECT analysis_material_id, SUM(qty)::numeric
                FROM coverage
                GROUP BY analysis_material_id
                """).setParameter("analysisId", analysisId))) {
            result.put(uuid(row[0]), decimal(row[1]));
        }
        return Map.copyOf(result);
    }

    private Map<MaterialDimension, List<WarehouseBreakdown>> warehouseBreakdown(
            UUID analysisId, List<MaterialRow> materials,
            SharedFutureIndex sharedFuture,
            Map<WarehouseMaterialDimension,BigDecimal> qualifiedOwned) {
        Set<UUID> goodsIds = materials.stream().map(MaterialRow::goodsId)
                .collect(Collectors.toSet());
        if (goodsIds.isEmpty()) return Map.of();
        Map<MaterialDimension, List<WarehouseBreakdown>> result = new HashMap<>();
        Map<MaterialDimension, MaterialRow> materialsByDimension = materials.stream()
                .collect(Collectors.toMap(MaterialRow::dimension, row -> row,
                        (first, ignored) -> first, LinkedHashMap::new));
        List<Object[]> rows = NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                WITH dimensions AS (
                    SELECT DISTINCT material.goods_id, material.color_id,
                           material.unit_id
                    FROM production_material_analysis_materials material
                    WHERE material.analysis_id = :analysisId
                      AND material.active = TRUE
                      AND material.goods_id IN (:goodsIds)
                )
                SELECT dimension.goods_id, dimension.color_id, dimension.unit_id,
                       w.id, w.code, w.name,
                       COALESCE(v.on_hand_qty,0), COALESCE(v.reserved_qty,0),
                       GREATEST(COALESCE(v.available_qty,0),0),
                       COALESCE(own.own_qty,0),
                       GREATEST(COALESCE(g.min_qty,0),0),
                       COALESCE(open_safety.open_qty,0),
                       (NOT w.is_defective AND COALESCE(w.status,'')<>'禁用'
                        AND NOT EXISTS(SELECT 1 FROM warehouses child
                            WHERE child.parent_id=w.id AND child.is_deleted=FALSE)) AS public_allowed, fn_warehouse_main_id(w.id) AS main_warehouse_id
                FROM dimensions dimension
                CROSS JOIN warehouses w
                JOIN goods g ON g.id = dimension.goods_id
                LEFT JOIN v_stock_available v
                  ON v.warehouse_id = w.id
                 AND v.goods_id = dimension.goods_id
                 AND v.color_id IS NOT DISTINCT FROM dimension.color_id
                LEFT JOIN LATERAL (
                    SELECT SUM(CASE
                        WHEN EXISTS (
                            SELECT 1
                            FROM preplan_stock_entitlement_events tracked
                            WHERE tracked.stock_reservation_id = r.id
                        ) THEN COALESCE((
                            SELECT SUM(balance.effective_qty)
                            FROM v_preplan_stock_entitlement_beneficiary_balance balance
                            JOIN production_material_analysis_materials beneficiary
                              ON beneficiary.id =
                                 balance.beneficiary_analysis_material_id
                             AND beneficiary.analysis_id =
                                 balance.beneficiary_analysis_id
                            WHERE balance.stock_reservation_id = r.id
                              AND balance.beneficiary_analysis_id = :analysisId
                              AND beneficiary.active = TRUE
                        ), 0)
                        WHEN r.owner_id = :analysisId
                        THEN r.qty - r.consumed_qty - r.released_qty
                        ELSE 0
                    END) AS own_qty
                    FROM stock_reservations r
                    WHERE r.is_deleted = FALSE
                      AND r.status = 0
                      AND r.owner_type = 'PREPLAN_ANALYSIS'
                      AND r.warehouse_id = w.id
                      AND r.goods_id = dimension.goods_id
                      AND r.color_id IS NOT DISTINCT FROM dimension.color_id
                ) own ON TRUE
                LEFT JOIN LATERAL (
                    SELECT SUM(progress.safety_future_qty)::numeric AS open_qty
                    FROM preplan_supply_actions action
                    JOIN v_preplan_buy_action_slice_progress progress
                      ON progress.action_id = action.id
                    WHERE action.status <> 'CANCELLED'
                      AND progress.safety_source_valid = TRUE
                      AND action.warehouse_id = w.id
                      AND action.goods_id = dimension.goods_id
                      AND action.color_id IS NOT DISTINCT FROM dimension.color_id
                ) open_safety ON TRUE
                WHERE w.is_deleted = FALSE AND w.is_accountable = TRUE
                ORDER BY w.code, w.id
                """).setParameter("goodsIds", goodsIds)
                .setParameter("analysisId", analysisId));
        Map<MainWarehouseMaterialDimension, List<com.uten.imp.common.inventory.MainWarehouseStockBudget.Leaf<WarehouseMaterialDimension>>> leaves = new LinkedHashMap<>();
        Map<MainWarehouseMaterialDimension, BigDecimal> safetyByMain = new HashMap<>();
        Map<WarehouseMaterialDimension, WarehouseBreakdown> preliminary = new LinkedHashMap<>();
        for (Object[] row : rows) {
            MaterialDimension dimension = new MaterialDimension(
                    uuid(row[0]), uuid(row[1]), uuid(row[2]));
            MaterialRow matching = materialsByDimension.get(dimension);
            if (matching == null) continue;
            BigDecimal qualified = qualifiedOwned.getOrDefault(
                    new WarehouseMaterialDimension(uuid(row[3]), matching.dimension()), BigDecimal.ZERO);
            boolean publicAllowed = Boolean.TRUE.equals(row[12]);
            BigDecimal ownPegged = publicAllowed ? decimal(row[9]) : qualified;
            BigDecimal reserved = decimal(row[7]).subtract(ownPegged).max(BigDecimal.ZERO);
            ownPegged = ownPegged.min(decimal(row[6]).subtract(reserved).max(BigDecimal.ZERO));
            BigDecimal publicAvailable = publicAllowed ? decimal(row[8]).max(BigDecimal.ZERO) : BigDecimal.ZERO;
            BigDecimal safetyStock = decimal(row[10]).max(BigDecimal.ZERO);
            BigDecimal openSafety = decimal(row[11]).max(BigDecimal.ZERO);
            // Only proven task-owned qualified receipts bypass the public safety threshold.
            BigDecimal available = availableWithQualifiedOwnAfterSafety(
                    publicAvailable, ownPegged, qualified, safetyStock);
            BigDecimal safetyGap = publicSafetyReplenishmentGap(
                    safetyStock, publicAvailable, openSafety);
            SharedFutureAggregate shared = sharedFuture.overview(
                    uuid(row[3]), matching.dimension());
            WarehouseMaterialDimension location = new WarehouseMaterialDimension(uuid(row[3]), dimension);
            UUID mainWarehouse = uuid(row[13]);
            MainWarehouseMaterialDimension main = new MainWarehouseMaterialDimension(
                    mainWarehouse == null ? location.warehouseId() : mainWarehouse, dimension);
            leaves.computeIfAbsent(main, ignored -> new ArrayList<>()).add(
                    new com.uten.imp.common.inventory.MainWarehouseStockBudget.Leaf<>(
                            location, publicAvailable, ownPegged, qualified));
            safetyByMain.merge(main, safetyStock, BigDecimal::max);
            preliminary.put(location, new WarehouseBreakdown(location.warehouseId(), string(row[4]), string(row[5]),
                    decimal(row[6]), reserved, available, ownPegged,
                    publicAvailable, openSafety, safetyGap,
                    shared.approvedInboundQty(), shared.availableQty(), shared.expectedDate()));
        }
        for (var entry : leaves.entrySet()) {
            var distributed = com.uten.imp.common.inventory.MainWarehouseStockBudget.distribute(
                    entry.getValue(), safetyByMain.get(entry.getKey()));
            for (var leaf : entry.getValue()) {
                WarehouseBreakdown row = preliminary.get(leaf.key());
                result.computeIfAbsent(entry.getKey().dimension(), ignored -> new ArrayList<>()).add(
                        new WarehouseBreakdown(row.warehouseId(), row.warehouseCode(), row.warehouseName(),
                                row.onHandQty(), row.reservedQty(), distributed.get(leaf.key()), row.ownPeggedQty(),
                                row.publicAvailableQty(), row.openSafetySupplyQty(), row.safetyReplenishmentGapQty(),
                                row.publicSurplusApprovedInboundQty(), row.publicSurplusRemainingQty(),
                                row.publicSurplusExpectedDate()));
            }
        }
        return result;
    }

    private record MainWarehouseMaterialDimension(UUID warehouseId, MaterialDimension dimension) {}

    private Map<StockIdentity, BigDecimal> mainWarehouseOpenSafetySupply(UUID warehouseId, Set<UUID> goodsIds) {
        if (goodsIds.isEmpty()) return Map.of();
        Map<StockIdentity, BigDecimal> result = new HashMap<>();
        for (Object[] row : NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT action.goods_id, action.color_id, SUM(progress.safety_future_qty)::numeric
                FROM preplan_supply_actions action
                JOIN v_preplan_buy_action_slice_progress progress ON progress.action_id=action.id
                WHERE action.status<>'CANCELLED' AND progress.safety_source_valid=TRUE
                  AND progress.safety_future_qty>0 AND action.goods_id IN (:goodsIds)
                  AND fn_warehouse_same_main(action.warehouse_id,:warehouseId)
                GROUP BY action.goods_id, action.color_id
                """).setParameter("goodsIds", goodsIds).setParameter("warehouseId", warehouseId))) {
            result.put(new StockIdentity(uuid(row[0]), uuid(row[1])), decimal(row[2]));
        }
        return result;
    }

    private record MainWarehouseSafetySummary(BigDecimal publicAvailable, BigDecimal openSupply, BigDecimal gap) {}

    private static MainWarehouseSafetySummary mainWarehouseSafetySummary(
            List<WarehouseBreakdown> warehouses, Set<UUID> mainScope, BigDecimal safety, BigDecimal openSupply) {
        BigDecimal publicAvailable = BigDecimal.ZERO;
        Set<UUID> counted = new HashSet<>();
        for (WarehouseBreakdown warehouse : warehouses) {
            if (!mainScope.contains(warehouse.warehouseId()) || !counted.add(warehouse.warehouseId())) continue;
            publicAvailable = publicAvailable.add(warehouse.publicAvailableQty().max(BigDecimal.ZERO));
        }
        return new MainWarehouseSafetySummary(publicAvailable, openSupply,
                com.uten.imp.common.inventory.MainWarehouseStockBudget.safetyGap(safety, publicAvailable, openSupply));
    }

    /** 节点级 V309 当前权益；禁止把 analysis+SKU 聚合数复制到兄弟节点。 */
    private Map<UUID, BigDecimal> exactPeggedByMaterial(
            UUID analysisId, UUID warehouseId) {
        Map<UUID, BigDecimal> result = new LinkedHashMap<>();
        List<Object[]> rows = NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT balance.beneficiary_analysis_material_id,
                       SUM(balance.effective_qty)::numeric
                FROM v_preplan_stock_entitlement_beneficiary_balance balance
                JOIN stock_reservations reservation
                  ON reservation.id = balance.stock_reservation_id
                 AND reservation.is_deleted = FALSE
                 AND reservation.status = 0
                JOIN production_material_analysis_materials material
                  ON material.id = balance.beneficiary_analysis_material_id
                 AND material.analysis_id = balance.beneficiary_analysis_id
                 AND material.active = TRUE
                WHERE balance.beneficiary_analysis_id = :analysisId
                  AND (fn_warehouse_same_main(reservation.warehouse_id,:warehouseId)
                       OR fn_preplan_reservation_has_qualified_origin(reservation.id))
                GROUP BY balance.beneficiary_analysis_material_id
                ORDER BY balance.beneficiary_analysis_material_id
                """)
                .setParameter("analysisId", analysisId)
                .setParameter("warehouseId", warehouseId));
        for (Object[] row : rows) {
            result.put(uuid(row[0]), decimal(row[1]));
        }
        return Map.copyOf(result);
    }

    /** Unarrived V447 capacity already owned by one preparation material. */
    private Map<UUID, BigDecimal> subcontractHandoffFutureByMaterial(
            UUID analysisId) {
        Map<UUID, BigDecimal> result = new LinkedHashMap<>();
        for (Object[] row : NativeQueryResults.objectArrayRows(
                em.createNativeQuery("""
                        SELECT mapped.target_analysis_material_id,
                               SUM(claim.future_qty)::numeric
                        FROM v_preplan_subcontract_requirement_supply_claim_state claim
                        JOIN preplan_subcontract_requirement_handoff_items mapped
                          ON mapped.id = claim.handoff_item_id
                        WHERE mapped.target_analysis_id = :analysisId
                          AND claim.future_qty > 0
                        GROUP BY mapped.target_analysis_material_id
                        ORDER BY mapped.target_analysis_material_id
                        """).setParameter("analysisId", analysisId))) {
            result.put(uuid(row[0]), decimal(row[1]));
        }
        return Map.copyOf(result);
    }

    private Map<UUID, CrossProjection> crossReallocationProjections(UUID analysisId) {
        List<Object[]> rows = NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT reallocation.id,
                       reallocation.from_analysis_id,
                       reallocation.from_analysis_material_id,
                       reallocation.to_analysis_id,
                       reallocation.to_analysis_material_id,
                       reallocation.qty,
                       reallocation.priority_fulfilled_qty,
                       reallocation.status,
                       reallocation.reason,
                       source_analysis.version, source_analysis.fingerprint,
                       target_analysis.version, target_analysis.fingerprint,
                       source_item.source_ref, source_goods.code, source_goods.name,
                       target_item.source_ref, target_goods.code, target_goods.name,
                       EXISTS (
                           SELECT 1
                           FROM preplan_stock_entitlement_events formalize
                           JOIN preplan_stock_entitlement_events source_lot
                             ON source_lot.id = formalize.source_entitlement_event_id
                           WHERE formalize.event_type = 'FORMALIZE'
                             AND source_lot.reallocation_id = reallocation.id
                             AND NOT EXISTS (
                                 SELECT 1
                                 FROM preplan_stock_entitlement_events restore
                                 WHERE restore.event_type = 'RESTORE'
                                   AND restore.counter_event_id = formalize.id
                             )
                       ) AS formalized,
                       GREATEST(reallocation.qty - COALESCE((
                           SELECT SUM(released_event.qty)
                           FROM preplan_stock_entitlement_events released_event
                           WHERE released_event.reallocation_id = reallocation.id
                             AND released_event.event_type = 'RELEASE'
                             AND released_event.beneficiary_analysis_id =
                                 reallocation.to_analysis_id
                             AND released_event.beneficiary_analysis_material_id =
                                 reallocation.to_analysis_material_id
                       ), 0), 0) AS current_effective_qty
                FROM preplan_material_reallocations reallocation
                JOIN production_material_analyses source_analysis
                  ON source_analysis.id = reallocation.from_analysis_id
                JOIN production_material_analyses target_analysis
                  ON target_analysis.id = reallocation.to_analysis_id
                JOIN production_material_analysis_materials source_material
                  ON source_material.id = reallocation.from_analysis_material_id
                JOIN production_material_analysis_items source_item
                  ON source_item.id = source_material.analysis_item_id
                LEFT JOIN goods source_goods ON source_goods.id = source_item.goods_id
                JOIN production_material_analysis_materials target_material
                  ON target_material.id = reallocation.to_analysis_material_id
                JOIN production_material_analysis_items target_item
                  ON target_item.id = target_material.analysis_item_id
                LEFT JOIN goods target_goods ON target_goods.id = target_item.goods_id
                WHERE reallocation.from_analysis_id = :analysisId
                   OR reallocation.to_analysis_id = :analysisId
                ORDER BY reallocation.created_at, reallocation.id
                """).setParameter("analysisId", analysisId));
        List<UUID> ids = rows.stream().map(row -> uuid(row[0])).toList();
        Map<UUID, List<ReplenishmentRef>> replenishments =
                replenishmentsByReallocation(ids);
        Map<UUID, List<CrossReallocationRef>> refs = new LinkedHashMap<>();
        for (Object[] row : rows) {
            UUID id = uuid(row[0]);
            boolean outgoing = analysisId.equals(uuid(row[1]));
            String status = string(row[7]);
            BigDecimal qty = decimal(row[5]);
            BigDecimal currentEffective = decimal(row[20]);
            BigDecimal fulfilled = decimal(row[6]);
            BigDecimal open = qty.subtract(fulfilled).max(BigDecimal.ZERO);
            boolean formalized = Boolean.TRUE.equals(row[19]);
            boolean canRevoke = outgoing && "OPEN".equals(status)
                    && fulfilled.signum() == 0 && !formalized;
            String blocked = canRevoke ? null
                    : formalized ? "接受计划已正式占用，需先取消对应计划"
                    : fulfilled.signum() > 0 ? "来源计划已经开始优先补齐"
                    : List.of("REVERSED", "CANCELLED").contains(status)
                    ? "让料记录已经关闭" : outgoing ? "当前状态不能撤销" : "仅来源计划可撤销";
            UUID counterpartAnalysisId = outgoing ? uuid(row[3]) : uuid(row[1]);
            UUID counterpartMaterialId = outgoing ? uuid(row[4]) : uuid(row[2]);
            long counterpartVersion = ((Number) (outgoing ? row[11] : row[9])).longValue();
            String counterpartFingerprint = string(outgoing ? row[12] : row[10]);
            String counterpartProduct = outgoing
                    ? firstNonBlank(string(row[16]),
                        displayLabel(string(row[17]), string(row[18])))
                    : firstNonBlank(string(row[13]),
                        displayLabel(string(row[14]), string(row[15])));
            CrossReallocationRef ref = new CrossReallocationRef(
                    id, outgoing ? "OUT" : "IN", status,
                    counterpartAnalysisId, counterpartVersion,
                    counterpartFingerprint, counterpartMaterialId,
                    "物料分析 " + counterpartAnalysisId.toString()
                            .substring(0, 8).toUpperCase(Locale.ROOT),
                    counterpartProduct, qty, currentEffective,
                    fulfilled, open, string(row[8]),
                    canRevoke, blocked,
                    replenishments.getOrDefault(id, List.of()));
            UUID materialId = outgoing ? uuid(row[2]) : uuid(row[4]);
            refs.computeIfAbsent(materialId, ignored -> new ArrayList<>()).add(ref);
        }
        Map<UUID, CrossProjection> result = new LinkedHashMap<>();
        refs.forEach((materialId, materialRefs) -> {
            BigDecimal incoming = materialRefs.stream()
                    .filter(ref -> "IN".equals(ref.direction()))
                    .map(CrossReallocationRef::currentEffectiveQty)
                    .reduce(BigDecimal.ZERO, BigDecimal::add);
            BigDecimal outgoing = materialRefs.stream()
                    .filter(ref -> "OUT".equals(ref.direction()))
                    .map(CrossReallocationRef::currentEffectiveQty)
                    .reduce(BigDecimal.ZERO, BigDecimal::add);
            BigDecimal pending = materialRefs.stream()
                    .filter(ref -> "OUT".equals(ref.direction()))
                    .filter(ref -> List.of("OPEN", "PARTIAL").contains(ref.status()))
                    .map(CrossReallocationRef::priorityOpenQty)
                    .reduce(BigDecimal.ZERO, BigDecimal::add);
            BigDecimal fulfilled = materialRefs.stream()
                    .filter(ref -> "OUT".equals(ref.direction()))
                    .map(CrossReallocationRef::priorityFulfilledQty)
                    .reduce(BigDecimal.ZERO, BigDecimal::add);
            result.put(materialId, new CrossProjection(
                    incoming, outgoing, pending, fulfilled, List.copyOf(materialRefs)));
        });
        return Map.copyOf(result);
    }

    private Map<UUID, List<ReplenishmentRef>> replenishmentsByReallocation(
            List<UUID> reallocationIds) {
        if (reallocationIds.isEmpty()) return Map.of();
        List<Object[]> rows = NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT event.reallocation_id,
                       exact.source_receipt_type,
                       exact.source_receipt_id,
                       COALESCE(purchase.bill_no, subcontract.bill_no, stock.bill_no),
                       event.qty, event.created_at
                FROM preplan_stock_entitlement_events event
                LEFT JOIN preplan_stock_entitlement_events source_lot
                  ON source_lot.id = event.source_entitlement_event_id
                LEFT JOIN preplan_analysis_stock_exact_pegs exact
                  ON exact.id = COALESCE(
                      event.source_exact_peg_id, source_lot.source_exact_peg_id)
                LEFT JOIN purchase_receipts purchase
                  ON exact.source_receipt_type = 'PURCHASE'
                 AND purchase.id = exact.source_receipt_id
                LEFT JOIN subcontract_receipts subcontract
                  ON exact.source_receipt_type = 'SUBCONTRACT'
                 AND subcontract.id = exact.source_receipt_id
                LEFT JOIN stock_documents stock
                  ON exact.source_receipt_type = 'MAKE'
                 AND stock.id = exact.source_stock_document_id
                WHERE event.reallocation_id IN (:ids)
                  AND event.event_type IN (
                      'PRIORITY_IN', 'PRIORITY_SATISFIED_IN_PLACE')
                ORDER BY event.created_at, event.id
                """).setParameter("ids", reallocationIds));
        Map<UUID, List<ReplenishmentRef>> result = new LinkedHashMap<>();
        for (Object[] row : rows) {
            result.computeIfAbsent(uuid(row[0]), ignored -> new ArrayList<>())
                    .add(new ReplenishmentRef(
                            string(row[1]), uuid(row[2]), string(row[3]),
                            decimal(row[4]), offsetDateTime(row[5])));
        }
        return result;
    }

    private List<WarehouseView> warehouses(
            UUID primaryWarehouseId,
            Set<UUID> selectedWarehouseIds) {
        return NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT id, code, name
                FROM warehouses
                WHERE is_deleted = FALSE AND (parent_id IS NULL OR is_accountable = TRUE)
                ORDER BY code, name, id
                """)).stream().map(row -> new WarehouseView(
                uuid(row[0]), string(row[1]), string(row[2]),
                selectedWarehouseIds.contains(uuid(row[0])),
                Objects.equals(primaryWarehouseId, uuid(row[0])))).toList();
    }

    static WarehouseSelectionSummary selectedWarehouseSummary(
            List<WarehouseBreakdown> breakdown,
            Set<UUID> selectedWarehouseIds,
            UUID primaryWarehouseId) {
        return selectedWarehouseSummary(breakdown, selectedWarehouseIds,
                primaryWarehouseId == null ? Set.of() : Set.of(primaryWarehouseId));
    }

    static WarehouseSelectionSummary selectedWarehouseSummary(
            List<WarehouseBreakdown> breakdown,
            Set<UUID> selectedWarehouseIds,
            Set<UUID> operationalWarehouseIds) {
        BigDecimal total = BigDecimal.ZERO;
        BigDecimal other = BigDecimal.ZERO;
        for (WarehouseBreakdown warehouse : breakdown) {
            if (!selectedWarehouseIds.contains(warehouse.warehouseId())) continue;
            BigDecimal available = warehouse.availableQty() == null
                    ? BigDecimal.ZERO : warehouse.availableQty().max(BigDecimal.ZERO);
            total = total.add(available);
            if (!operationalWarehouseIds.contains(warehouse.warehouseId())) {
                other = other.add(available);
            }
        }
        return new WarehouseSelectionSummary(
                total.setScale(4, RoundingMode.DOWN),
                other.setScale(4, RoundingMode.DOWN));
    }

    private static WarehouseSelectionSummary selectedWarehouseSummaryWithQualifiedSources(
            List<WarehouseBreakdown> breakdown, Set<UUID> selectedWarehouseIds,
            Set<UUID> operationalWarehouseIds,
            Map<WarehouseMaterialDimension,BigDecimal> qualifiedOwned, MaterialDimension dimension) {
        BigDecimal total=BigDecimal.ZERO,transfer=BigDecimal.ZERO;
        for(WarehouseBreakdown warehouse:breakdown) {
            BigDecimal available=warehouse.availableQty()==null?BigDecimal.ZERO:warehouse.availableQty().max(BigDecimal.ZERO);
            BigDecimal qualified=qualifiedOwned.getOrDefault(
                    new WarehouseMaterialDimension(warehouse.warehouseId(),dimension),BigDecimal.ZERO).min(available);
            if(selectedWarehouseIds.contains(warehouse.warehouseId())) {
                total=total.add(available);
                if(!operationalWarehouseIds.contains(warehouse.warehouseId()))
                    transfer=transfer.add(available.subtract(qualified).max(BigDecimal.ZERO));
            } else {
                // A known receipt follows this task without selecting unrelated public stock.
                total=total.add(qualified);
            }
        }
        return new WarehouseSelectionSummary(total.setScale(4,RoundingMode.DOWN),transfer.setScale(4,RoundingMode.DOWN));
    }

    private UUID fqcRecoveryAuthorizationId(UUID analysisId) {
        List<UUID> rows = NativeQueryResults.typedRows(
                em.createNativeQuery("""
                        SELECT link.authorization_id
                        FROM production_fqc_replenishment_analysis_links link
                        WHERE link.material_analysis_id = :analysisId
                        ORDER BY link.id
                        LIMIT 1
                        """, UUID.class)
                        .setParameter("analysisId", analysisId),
                UUID.class);
        return rows.isEmpty() ? null : rows.getFirst();
    }

    private List<String> allowedActions(
            UUID analysisId, AnalysisHeader header, boolean fqcReplenishmentOnly) {
        if (fqcReplenishmentOnly) {
            return List.of("VIEW", "FQC_REPLENISHMENT_CONFIRM");
        }
        if (!access.canWrite(header.makerId(), scopeForAnalysis(header))) return List.of("VIEW");
        List<String> result = new ArrayList<>(List.of("VIEW"));
        if (!"CANCELLED".equals(header.status()) && rootSupply != null
                && access.hasAuthority("production_material_analysis:notify")
                && rootSupply.hasReversibleExistingOutput(analysisId)) {
            result.add("ROOT_OUTPUT_REVOKE");
        }
        if (!List.of(STATUS_ACTIVE, STATUS_PARTIAL).contains(header.status())) return List.copyOf(result);
        if (access.hasAuthority("production_material_analysis:refresh")) {
            result.add("REFRESH");
        }
        if (access.hasAuthority("production_material_analysis:route")) {
            result.add("CONFIRM_ROUTES");
        }
        if (access.hasAuthority("production_material_analysis:notify")) {
            result.add("NOTIFY_SUPPLY");
            Number retractable = (Number) em.createNativeQuery("""
                    SELECT COUNT(*) FROM preplan_supply_actions action
                    WHERE analysis_id = :analysisId
                      AND operation_type = 'SUPPLY'
                      AND (status IN ('OPEN','CREATED','IN_PROGRESS')
                        OR (status='DONE' AND external_document_type IN
                          ('SUBCONTRACT_MAKE_TASK','SUBCONTRACT_APPLICATION'))
                        OR (status='CANCELLED' AND external_document_type='SUBCONTRACT_APPLICATION'
                          AND EXISTS (SELECT 1 FROM preplan_subcontract_make_task_batches batch
                            WHERE batch.application_id=action.external_document_id
                              AND NOT EXISTS (SELECT 1 FROM preplan_subcontract_make_batch_reversals reversal
                                              WHERE reversal.batch_id=batch.id))))
                    """).setParameter("analysisId", analysisId).getSingleResult();
            if (retractable.longValue() > 0) result.add("CANCEL_ACTION");
        }
        if (access.hasAuthority("production_material_analysis:notify")
                && access.hasAuthority("production_material_analysis:over_supply")) {
            result.add("OVER_SUPPLY");
        }
        if (access.hasAuthority(
                "production_material_analysis:claim_shared_future")) {
            result.add("CLAIM_SHARED_FUTURE");
            Number retractableClaim = (Number) em.createNativeQuery("""
                    SELECT COUNT(*) FROM preplan_supply_actions
                    WHERE analysis_id = :analysisId
                      AND operation_type = 'SHARED_FUTURE_CLAIM'
                      AND status IN ('OPEN','CREATED','IN_PROGRESS')
                    """).setParameter("analysisId", analysisId).getSingleResult();
            if (retractableClaim.longValue() > 0
                    && !result.contains("CANCEL_ACTION")) {
                result.add("CANCEL_ACTION");
            }
        }
        if (access.hasAuthority("production_material_analysis:reallocate")) {
            result.add("REALLOCATE");
        }
        if (access.hasAuthority("production_material_analysis:cross_reallocate")) {
            result.add("CROSS_REALLOCATE");
        }
        if (access.hasAuthority("production_material_analysis:generate")) {
            result.add("PLAN_PREVIEW");
            result.add("GENERATE_PLAN");
            if (access.hasAuthority("production_plan:approve")) {
                result.add("GENERATE_AND_APPROVE");
            }
        }
        if (access.hasAuthority("production_material_analysis:cancel")) {
            result.add("CANCEL_ANALYSIS");
        }
        return List.copyOf(result);
    }

    private List<String> displayPath(
            MaterialRow material,
            Map<MaterialNodeIdentity, MaterialRow> materialsByNode,
            Map<UUID, String> sourceLabels) {
        List<String> reversed = new ArrayList<>();
        MaterialRow cursor = material;
        Set<String> seen = new HashSet<>();
        while (cursor != null && seen.add(cursor.nodeKey())) {
            reversed.add(displayLabel(cursor.goodsCode(), cursor.goodsName()));
            cursor = cursor.parentNodeKey() == null
                    ? null : materialsByNode.get(new MaterialNodeIdentity(
                            cursor.analysisItemId(), cursor.parentNodeKey()));
        }
        java.util.Collections.reverse(reversed);
        String source = sourceLabels.get(material.analysisItemId());
        if (source != null) reversed.addFirst(source);
        return List.copyOf(reversed);
    }

    private String parentLabel(
            MaterialRow material,
            Map<MaterialNodeIdentity, MaterialRow> materialsByNode,
            Map<UUID, String> sourceLabels) {
        if (material.parentNodeKey() == null) {
            return sourceLabels.get(material.analysisItemId());
        }
        return Optional.ofNullable(materialsByNode.get(new MaterialNodeIdentity(
                        material.analysisItemId(), material.parentNodeKey())))
                .map(row -> displayLabel(row.goodsCode(), row.goodsName()))
                .orElse(null);
    }

    private static String displayLabel(String code, String name) {
        String left = blankToNull(code);
        String right = blankToNull(name);
        if (left == null) return right;
        if (right == null) return left;
        return left + " · " + right;
    }

    private static String firstNonBlank(String value, String fallback) {
        String normalized = blankToNull(value);
        return normalized == null ? fallback : normalized;
    }

    private String routeRequestHash(UUID analysisId, RouteRequest request) {
        List<String> parts = new ArrayList<>(List.of(
                "MATERIAL-ANALYSIS-ROUTE-V1", analysisId.toString(),
                Long.toString(request.version()), request.fingerprint()));
        request.decisions().forEach(decision -> parts.add(String.join("|",
                Objects.toString(decision.materialLineId(), ""),
                Objects.toString(blankToNull(decision.actionGroupKey()), ""),
                Objects.toString(decision.route(), ""),
                Objects.toString(blankToNull(decision.reason()), ""))));
        return PlanningPackageFingerprint.sha256(parts);
    }

    private String allocationPriorityRequestHash(
            UUID analysisId, AllocationPriorityRequest request) {
        List<String> parts = new ArrayList<>(List.of(
                "MATERIAL-ANALYSIS-REALLOCATE-V1", analysisId.toString(),
                Long.toString(request.version()), request.fingerprint()));
        request.items().stream()
                .sorted(Comparator.comparingInt(AllocationPriorityItem::priority)
                        .thenComparing(AllocationPriorityItem::analysisLineId))
                .forEach(item -> parts.add(
                        item.analysisLineId() + "|" + item.priority()));
        return PlanningPackageFingerprint.sha256(parts);
    }

    private String previewRequestHash(
            PreviewRequest request,
            List<PreviewItem> items,
            List<UUID> warehouseIds) {
        List<String> parts = new ArrayList<>(List.of(
                "MATERIAL-ANALYSIS-PREVIEW-V1",
                Objects.toString(request.analysisId(), "NEW"),
                Objects.toString(request.version(), ""),
                Objects.toString(request.fingerprint(), ""),
                request.warehouseId().toString(),
                "WAREHOUSES|" + warehouseIdsParameter(warehouseIds)));
        items.forEach(item -> parts.add(String.join("|",
                sourceType(item), Objects.toString(item.salesOrderItemId(), ""),
                Objects.toString(item.goodsId(), ""), Objects.toString(item.colorId(), ""),
                Objects.toString(item.unitId(), ""), Objects.toString(item.sourceRef(), ""),
                Objects.toString(item.sourceReason(), ""),
                Objects.toString(item.deliveryDate(), ""), decimalText(item.requestedQty()))));
        return PlanningPackageFingerprint.sha256(parts);
    }

    private boolean isCommandReplay(
            UUID analysisId, String operation, String key, String requestHash) {
        List<?> rows = em.createNativeQuery("""
                SELECT request_hash
                FROM production_material_analysis_commands
                WHERE analysis_id = :analysisId AND operation = :operation
                  AND idempotency_key = :key
                """)
                .setParameter("analysisId", analysisId)
                .setParameter("operation", operation)
                .setParameter("key", key)
                .getResultList();
        if (rows.isEmpty()) return false;
        if (!requestHash.equals(Objects.toString(rows.getFirst(), ""))) {
            throw conflict("同一幂等键已用于不同请求");
        }
        return true;
    }

    private void recordSimpleCommand(
            UUID analysisId, String operation, String key, String requestHash) {
        em.createNativeQuery("""
                INSERT INTO production_material_analysis_commands (
                    id, analysis_id, operation, idempotency_key,
                    request_hash, result_payload, created_by
                ) VALUES (
                    :id, :analysisId, :operation, :key,
                    :requestHash, '{}'::jsonb, :actorId
                )
                """)
                .setParameter("id", UUID.randomUUID())
                .setParameter("analysisId", analysisId)
                .setParameter("operation", operation)
                .setParameter("key", key)
                .setParameter("requestHash", requestHash)
                .setParameter("actorId", currentUser.requireId())
                .executeUpdate();
    }

    private Map<UUID, List<DownstreamReference>> downstreamReferences(UUID analysisId) {
        Map<UUID, List<DownstreamReference>> result = new HashMap<>();
        List<Object[]> rows = NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT allocation.analysis_material_id, action.id, action.route,
                       action.status, action.external_document_type,
                       action.external_document_id, action.external_document_no,
                       allocation.allocated_qty,
                       action.status='CANCELLED' AND action.external_document_type='SUBCONTRACT_APPLICATION'
                         AND EXISTS (SELECT 1 FROM preplan_subcontract_make_task_batches batch
                           WHERE batch.allocation_id=allocation.id
                             AND NOT EXISTS (SELECT 1 FROM preplan_subcontract_make_batch_reversals reversal
                                             WHERE reversal.batch_id=batch.id))
                FROM preplan_supply_action_allocations allocation
                JOIN preplan_supply_actions action ON action.id = allocation.action_id
                WHERE action.analysis_id = :id
                ORDER BY action.created_at, action.id, allocation.id
                """).setParameter("id", analysisId));
        for (Object[] row : rows) {
            result.computeIfAbsent(uuid(row[0]), ignored -> new ArrayList<>()).add(
                    new DownstreamReference(uuid(row[1]), string(row[2]), string(row[3]),
                            string(row[4]), uuid(row[5]), string(row[6]), decimal(row[7]),
                            row.length>8 && Boolean.TRUE.equals(row[8])));
        }
        return result;
    }

    private List<MaterialRow> resolveMaterialGroup(
            List<MaterialRow> materials, RouteDecision decision) {
        if (decision == null || (decision.materialLineId() == null
                && blankToNull(decision.actionGroupKey()) == null)) {
            throw validation("物料路线必须提交 actionGroupKey 或代表节点");
        }
        String groupKey = blankToNull(decision.actionGroupKey());
        if (groupKey == null) {
            MaterialRow representative = materials.stream()
                    .filter(row -> row.id().equals(decision.materialLineId()))
                    .findFirst().orElseThrow(() -> validation("物料分析代表节点不存在"));
            if (!representative.actionable()) {
                throw validation("该节点当前没有独立需求，不能确认供应路线");
            }
            groupKey = representative.actionGroupKey();
        }
        final String resolved = groupKey;
        List<MaterialRow> group = materials.stream()
                .filter(MaterialRow::actionable)
                .filter(row -> row.actionGroupKey().equals(resolved)).toList();
        if (group.isEmpty()) throw validation("物料操作组不存在或已过期");
        return group;
    }

    List<SupplyActionView> supplyActions(UUID analysisId) {
        return NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT id, action_group_key, generation, predecessor_action_id,
                       route, status, goods_id, color_id, unit_id,
                       requested_qty, safety_replenishment_qty,
                       requested_qty + safety_replenishment_qty
                           + public_surplus_qty,
                       safety_stock_snapshot_qty,
                       public_available_snapshot_qty,
                       open_safety_supply_snapshot_qty,
                       need_date, external_document_type,
                       external_document_id, external_document_no,
                       public_surplus_qty, public_surplus_external_item_id,
                       operation_type, claim_source_action_id
                FROM preplan_supply_actions
                WHERE analysis_id = :id
                ORDER BY created_at, id
                """).setParameter("id", analysisId)).stream()
                .map(row -> new SupplyActionView(uuid(row[0]), string(row[1]), integer(row[2]),
                        uuid(row[3]), string(row[4]), string(row[5]), uuid(row[6]),
                        uuid(row[7]), uuid(row[8]), decimal(row[9]), decimal(row[10]),
                        decimal(row[11]), decimal(row[12]), decimal(row[13]),
                        decimal(row[14]), date(row[15]), string(row[16]),
                        uuid(row[17]), string(row[18]), decimal(row[19]),
                        uuid(row[20]), string(row[21]), uuid(row[22])))
                .toList();
    }

    private SourceMaster salesSourceMaster(UUID salesOrderItemId) {
        Object[] row = oneRow(em.createNativeQuery("""
                SELECT i.goods_id, i.color_id, i.unit_id,
                       COALESCE(i.deliver_date,o.deliver_date),
                       o.status, o.is_stopped, o.is_closed, o.is_deleted, i.is_deleted,
                       o.finance_confirmed
                FROM sales_order_items i
                JOIN sales_orders o ON o.id = i.order_id
                JOIN goods g ON g.id = i.goods_id
                WHERE i.id = :id
                """).setParameter("id", salesOrderItemId), "销售订单行不存在");
        if (((Number) row[4]).shortValue() != 1 || Boolean.TRUE.equals(row[5])
                || Boolean.TRUE.equals(row[6]) || Boolean.TRUE.equals(row[7])
                || Boolean.TRUE.equals(row[8])) {
            throw conflict("销售订单未审核、已中止、已关闭或已删除");
        }
        if (!Boolean.TRUE.equals(row[9])) {
            throw conflict("销售订单未通过财务确认，暂不能纳入物料分析");
        }
        if (row[2] == null) throw conflict("销售订单行未维护有效单位");
        return new SourceMaster(uuid(row[0]), uuid(row[1]), uuid(row[2]),
                date(row[3]));
    }

    private SourceMaster manualSourceMaster(UUID goodsId, UUID colorId, UUID unitId) {
        com.uten.imp.common.concurrency.GoodsQuantityBasisLocks.lockUnused(em, java.util.Collections.singleton(goodsId));
        Object[] row = oneRow(em.createNativeQuery("""
                SELECT g.id, :colorId, u.id,
                       g.unit_id AS base_unit_id
                FROM goods g
                JOIN units u ON u.id = :unitId AND u.is_deleted = FALSE
                WHERE g.id = :goodsId AND g.is_deleted = FALSE
                """).setParameter("colorId", colorId).setParameter("unitId", unitId)
                .setParameter("goodsId", goodsId), "手工生产来源的货品或单位不存在");
        if (row[3] == null || !Objects.equals(uuid(row[2]), uuid(row[3]))) {
            throw validation("手工生产来源只能使用货品主档的基本单位");
        }
        return new SourceMaster(uuid(row[0]), uuid(row[1]), uuid(row[2]), null);
    }

    private AnalysisHeader readHeader(UUID analysisId) {
        Object[] row = oneRow(em.createNativeQuery("""
                SELECT id, warehouse_id,
                       CASE WHEN status='COMPLETED' AND EXISTS (
                         SELECT 1 FROM production_plans plan
                         JOIN production_plan_items item ON item.plan_id=plan.id
                         WHERE plan.material_analysis_id=production_material_analyses.id
                           AND plan.is_deleted=FALSE AND plan.is_canceled=FALSE
                           AND plan.status IN (0,1) AND item.is_deleted=FALSE
                           AND item.qty>COALESCE(item.iqty,0))
                         THEN 'PARTIALLY_PLANNED' ELSE status END,
                       version, fingerprint,
                       analyzed_at, maker_id, is_deleted
                FROM production_material_analyses WHERE id = :id
                """).setParameter("id", analysisId), "物料分析不存在");
        if (Boolean.TRUE.equals(row[7])) throw notFound("物料分析不存在");
        return new AnalysisHeader(uuid(row[0]), uuid(row[1]), string(row[2]),
                ((Number) row[3]).longValue(), string(row[4]), offsetDateTime(row[5]),
                uuid(row[6]));
    }

    /** Historical leaf selections and their real parent represent the same planning stock scope. */
    private boolean samePlanningWarehouseScope(UUID first, List<UUID> firstScope,
                                               UUID second, List<UUID> secondScope) {
        Set<UUID> left = new LinkedHashSet<>(firstScope), right = new LinkedHashSet<>(secondScope);
        if (Objects.equals(first, second) && left.equals(right)) return true;
        Set<UUID> ids = new LinkedHashSet<>(left); ids.addAll(right); ids.add(first); ids.add(second);
        if (ids.contains(null)) return false;
        Map<UUID, UUID> mains = new HashMap<>();
        for (Object[] row : NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT id, fn_warehouse_main_id(id) AS main_id
                FROM warehouses WHERE id IN (:ids) AND is_deleted=FALSE
                """).setParameter("ids", ids))) mains.put(uuid(row[0]), uuid(row[1]));
        if (ids.stream().anyMatch(id -> mains.get(id)==null)) return false;
        return Objects.equals(mains.get(first), mains.get(second))
                && left.stream().map(mains::get).collect(Collectors.toSet())
                    .equals(right.stream().map(mains::get).collect(Collectors.toSet()));
    }

    private List<UUID> normalizeParticipatingWarehouses(
            UUID primaryWarehouseId,
            List<UUID> requestedWarehouseIds) {
        if (primaryWarehouseId == null) {
            throw validation("请选择主仓库");
        }
        LinkedHashSet<UUID> requested = new LinkedHashSet<>();
        if (requestedWarehouseIds == null || requestedWarehouseIds.isEmpty()) {
            requested.add(primaryWarehouseId);
        } else {
            if (requestedWarehouseIds.stream().anyMatch(Objects::isNull)) {
                throw validation("参与仓库不能包含空值");
            }
            requested.addAll(requestedWarehouseIds);
            if (requested.size() != requestedWarehouseIds.size()) {
                throw validation("参与仓库不能重复");
            }
            if (!requested.contains(primaryWarehouseId)) {
                throw validation("仓库范围必须包含主仓库");
            }
        }
        if (requested.size() > 100) {
            throw validation("一次物料分析最多选择 100 个参与仓库");
        }
        Number valid = (Number) em.createNativeQuery("""
                SELECT COUNT(*)
                FROM warehouses
                WHERE id IN (:warehouseIds)
                  AND is_deleted = FALSE
                  AND COALESCE(status, '') <> '禁用'
                  AND (parent_id IS NULL OR (is_accountable = TRUE
                    AND NOT EXISTS (SELECT 1 FROM warehouses c
                                    WHERE c.parent_id = warehouses.id AND c.is_deleted = FALSE)))
                """).setParameter("warehouseIds", requested).getSingleResult();
        if (valid.longValue() != requested.size()) {
            throw notFound("所选主仓库或历史仓库范围不存在、已禁用或不能用于物料分析");
        }
        List<UUID> result = new ArrayList<>();
        result.add(primaryWarehouseId);
        requested.stream()
                .filter(id -> !id.equals(primaryWarehouseId))
                .sorted()
                .forEach(result::add);
        return List.copyOf(result);
    }

    private List<UUID> participatingWarehouseIds(
            UUID analysisId, UUID primaryWarehouseId) {
        List<?> rows = em.createNativeQuery("""
                SELECT selected.warehouse_id
                FROM production_material_analyses analysis
                CROSS JOIN LATERAL unnest(
                    analysis.participating_warehouse_ids)
                    AS selected(warehouse_id)
                WHERE analysis.id = :analysisId
                ORDER BY CASE WHEN selected.warehouse_id = analysis.warehouse_id
                              THEN 0 ELSE 1 END,
                         selected.warehouse_id
                """).setParameter("analysisId", analysisId).getResultList();
        if (rows.isEmpty()) {
            return primaryWarehouseId == null
                    ? List.of() : List.of(primaryWarehouseId);
        }
        return rows.stream().map(MaterialAnalysisService::uuid).toList();
    }

    private static String warehouseIdsParameter(List<UUID> warehouseIds) {
        return warehouseIds.stream().map(UUID::toString)
                .collect(Collectors.joining(","));
    }

    private static String sourceType(PreviewItem item) {
        return item.sourceType() == null || item.sourceType().isBlank()
                ? SOURCE_SALES : item.sourceType().strip().toUpperCase(Locale.ROOT);
    }

    private static String suggestion(String rawSourceType) {
        String value = rawSourceType == null ? "" : rawSourceType.strip();
        return switch (value) {
            case "采购" -> "BUY";
            case "自制" -> "MAKE";
            case "委外" -> "SUBCONTRACT";
            default -> "REVIEW";
        };
    }

    static String normalizeRouteReason(String raw) {
        String reason = blankToNull(raw);
        if (reason != null && reason.length() > 1000) {
            throw validation("路线原因最多 1000 个字符");
        }
        return reason;
    }

    static String normalizeRoute(String raw) {
        String route = raw == null ? "" : raw.strip().toUpperCase(Locale.ROOT);
        if (!Set.of("BUY", "MAKE", "SUBCONTRACT").contains(route)) {
            throw validation("物料路线必须为 BUY、MAKE 或 SUBCONTRACT");
        }
        return route;
    }

    static boolean hasAuthority(SecurityContextCurrentUser currentUser, String authority) {
        return currentUser.get().map(user -> user.isSuperAdmin()
                || user.getPermissions().contains(authority)).orElse(false);
    }

    private static BigDecimal scaleQty(BigDecimal value) {
        try {
            return value.setScale(4, RoundingMode.UNNECESSARY);
        } catch (ArithmeticException ex) {
            throw validation("数量最多保留四位小数");
        }
    }

    static BigDecimal decimal(Object value) {
        return value == null ? BigDecimal.ZERO : new BigDecimal(value.toString());
    }

    static String decimalText(BigDecimal value) {
        return value == null ? "0" : value.stripTrailingZeros().toPlainString();
    }

    static UUID uuid(Object value) {
        return value == null ? null : (UUID) value;
    }

    static String string(Object value) {
        return value == null ? null : value.toString();
    }

    static Integer integer(Object value) {
        return value == null ? null : ((Number) value).intValue();
    }

    static Long longValue(Object value) {
        return value == null ? null : ((Number) value).longValue();
    }

    static LocalDate date(Object value) {
        if (value == null) return null;
        if (value instanceof LocalDate localDate) return localDate;
        return ((java.sql.Date) value).toLocalDate();
    }

    static OffsetDateTime offsetDateTime(Object value) {
        if (value instanceof OffsetDateTime offset) return offset;
        if (value instanceof java.time.Instant instant) return instant.atOffset(ZoneOffset.UTC);
        return OffsetDateTime.parse(value.toString());
    }

    static Object[] oneRow(Query query, String missingMessage) {
        List<Object[]> rows = NativeQueryResults.objectArrayRows(query);
        if (rows.isEmpty()) throw notFound(missingMessage);
        return rows.getFirst();
    }

    static String blankToNull(String value) {
        return value == null || value.isBlank() ? null : value.strip();
    }

    private static List<String> splitAggregate(String value) {
        if (value == null || value.isBlank()) return List.of();
        return java.util.Arrays.stream(value.split("\u001f"))
                .map(String::strip).filter(part -> !part.isEmpty()).sorted().toList();
    }

    static ApiException validation(String message) {
        return new ApiException(ErrorCode.VALIDATION_FAILED, message);
    }

    static ApiException conflict(String message) {
        return new ApiException(ErrorCode.CONFLICT, message);
    }

    static ApiException notFound(String message) {
        return new ApiException(ErrorCode.NOT_FOUND, message);
    }

    static final class TimePhasedPool {
        private final Map<MaterialDimension, List<SupplyLot>> lots = new LinkedHashMap<>();

        TimePhasedPool(
                Map<MaterialDimension, BigDecimal> stock,
                List<InboundLot> inbound) {
            stock.forEach((dimension, qty) -> lots.computeIfAbsent(
                    dimension, ignored -> new ArrayList<>()).add(new SupplyLot(null, qty)));
            inbound.forEach(value -> lots.computeIfAbsent(
                    value.dimension(), ignored -> new ArrayList<>())
                    .add(new SupplyLot(value.expectedDate(), value.qty())));
            lots.values().forEach(values -> values.sort(Comparator.comparing(
                    SupplyLot::expectedDate,
                    Comparator.nullsFirst(Comparator.naturalOrder()))));
        }

        BigDecimal maxReadyExact(
                BigDecimal demand,
                List<BomNode> nodes,
                LocalDate cutoff) {
            return maxReadyFromBaseExact(
                    BigDecimal.ZERO.setScale(4), demand, nodes, cutoff);
        }

        void consumeExact(
                BigDecimal quantity,
                List<BomNode> nodes,
                LocalDate cutoff) {
            consumeIncrementExact(
                    BigDecimal.ZERO.setScale(4), quantity, nodes, cutoff);
        }

        BigDecimal maxReadyFromBaseExact(
                BigDecimal base,
                BigDecimal demand,
                List<BomNode> nodes,
                LocalDate cutoff) {
            BigDecimal normalizedDemand = demand.max(BigDecimal.ZERO)
                    .setScale(4, RoundingMode.DOWN);
            BigDecimal normalizedBase = base.max(BigDecimal.ZERO)
                    .min(normalizedDemand).setScale(4, RoundingMode.DOWN);
            if (nodes.isEmpty()) return normalizedDemand;
            long low = normalizedBase.movePointRight(4).longValueExact();
            long high = normalizedDemand.movePointRight(4).longValueExact();
            Map<MaterialDimension, BigDecimal> available = availableAt(cutoff);
            while (low < high) {
                long middle = low + (high - low + 1) / 2;
                BigDecimal candidate = BigDecimal.valueOf(middle, 4);
                boolean feasible = incrementalRequirements(
                        normalizedBase, candidate, nodes).entrySet().stream()
                        .allMatch(entry -> entry.getValue().compareTo(
                                available.getOrDefault(
                                        entry.getKey(), BigDecimal.ZERO)) <= 0);
                if (feasible) {
                    low = middle;
                } else {
                    high = middle - 1;
                }
            }
            return BigDecimal.valueOf(low, 4);
        }

        void consumeIncrementExact(
                BigDecimal base,
                BigDecimal total,
                List<BomNode> nodes,
                LocalDate cutoff) {
            for (Map.Entry<MaterialDimension, BigDecimal> entry
                    : incrementalRequirements(base, total, nodes).entrySet()) {
                BigDecimal need = entry.getValue();
                for (SupplyLot lot : lots.getOrDefault(entry.getKey(), List.of())) {
                    if (!lot.eligible(cutoff) || need.signum() == 0) continue;
                    BigDecimal take = need.min(lot.remaining());
                    lot.consume(take);
                    need = need.subtract(take);
                }
                if (need.signum() > 0) {
                    throw new IllegalStateException(
                            "time-phased allocation exceeded the verified material pool");
                }
            }
        }

        private Map<MaterialDimension, BigDecimal> availableAt(LocalDate cutoff) {
            Map<MaterialDimension, BigDecimal> available = new LinkedHashMap<>();
            lots.forEach((dimension, values) -> available.put(
                    dimension,
                    values.stream().filter(lot -> lot.eligible(cutoff))
                            .map(SupplyLot::remaining)
                            .reduce(BigDecimal.ZERO, BigDecimal::add)
                            .setScale(4, RoundingMode.DOWN)));
            return available;
        }
    }

    private static final class SupplyLot {
        private final LocalDate expectedDate;
        private BigDecimal remaining;

        private SupplyLot(LocalDate expectedDate, BigDecimal remaining) {
            this.expectedDate = expectedDate;
            this.remaining = remaining.max(BigDecimal.ZERO);
        }

        private LocalDate expectedDate() {
            return expectedDate;
        }

        private BigDecimal remaining() {
            return remaining;
        }

        private boolean eligible(LocalDate cutoff) {
            return expectedDate == null || cutoff != null && !expectedDate.isAfter(cutoff);
        }

        private void consume(BigDecimal qty) {
            remaining = remaining.subtract(qty).max(BigDecimal.ZERO);
        }
    }

    record NodeAllocation(BigDecimal allocatedQty, BigDecimal shortageQty) {
        static final NodeAllocation ZERO = new NodeAllocation(
                BigDecimal.ZERO.setScale(4), BigDecimal.ZERO.setScale(4));
    }

    record StageAllocation(
            Map<UUID, BigDecimal> readyByItem,
            Map<String, NodeAllocation> nodeAllocations,
            Map<MaterialDimension, BigDecimal> remainingPool) {
    }

    record StageExtension(
            Map<UUID, BigDecimal> readyByItem,
            Map<String, NodeAllocation> nodeAllocations,
            Map<MaterialDimension, BigDecimal> remainingPool) {
    }

    record StagePlan(
            StageAllocation finish,
            StageExtension ship,
            StageExtension start) {
    }

    record NestedDiagnosticPlan(
            List<BomNode> nodes,
            Map<String, NodeAllocation> nodeAllocations,
            Set<MaterialNodeIdentity> parentsWithUncoveredChildren) {
        NestedDiagnosticPlan(
                List<BomNode> nodes,
                Map<String, NodeAllocation> nodeAllocations) {
            this(nodes, nodeAllocations, nodes.stream()
                    .filter(node -> node.parentNodeKey() != null)
                    .filter(node -> node.hardGate()
                            && !STAGE_REFERENCE.equals(node.controlStage()))
                    .filter(node -> nodeAllocations.getOrDefault(
                            nodeAllocationKey(node), NodeAllocation.ZERO)
                            .shortageQty().signum() > 0)
                    .map(node -> new MaterialNodeIdentity(
                            node.analysisItemId(), node.parentNodeKey()))
                    .collect(Collectors.toUnmodifiableSet()));
        }

        boolean hasUncoveredDirectChild(BomNode parent) {
            return parentsWithUncoveredChildren.contains(
                    new MaterialNodeIdentity(parent.analysisItemId(), parent.nodeKey()));
        }
    }

    record AnalysisHeader(UUID id, UUID warehouseId, String status, long version,
                          String fingerprint, OffsetDateTime analyzedAt, UUID makerId) {
    }

    record MaterialDimension(UUID goodsId, UUID colorId, UUID unitId) {
    }

    record WarehouseMaterialDimension(
            UUID warehouseId, MaterialDimension dimension) {
    }

    record StockIdentity(UUID goodsId, UUID colorId) {
    }

    record WarehouseSelectionSummary(
            BigDecimal totalAvailableQty,
            BigDecimal otherTransferableQty) {
    }

    record SharedFutureAggregate(
            BigDecimal approvedInboundQty,
            BigDecimal availableQty,
            LocalDate expectedDate,
            List<SharedFutureSupplyRef> refs) {
        static final SharedFutureAggregate ZERO = new SharedFutureAggregate(
                BigDecimal.ZERO.setScale(4), BigDecimal.ZERO.setScale(4),
                null, List.of());

        SharedFutureAggregate plus(SharedFutureSupplyRef ref) {
            LocalDate nextDate = expectedDate;
            if (ref.expectedDate() != null
                    && (nextDate == null || ref.expectedDate().isBefore(nextDate))) {
                nextDate = ref.expectedDate();
            }
            List<SharedFutureSupplyRef> nextRefs = new ArrayList<>(refs);
            nextRefs.add(ref);
            return new SharedFutureAggregate(
                    approvedInboundQty.add(ref.approvedInboundQty()),
                    availableQty.add(ref.availableToClaimQty()),
                    nextDate, List.copyOf(nextRefs));
        }
    }

    record SharedFutureIndex(
            Map<WarehouseMaterialDimension, SharedFutureAggregate> byDimension) {
        SharedFutureAggregate overview(
                UUID warehouseId, MaterialDimension dimension) {
            SharedFutureAggregate raw = byDimension.getOrDefault(
                    new WarehouseMaterialDimension(warehouseId, dimension),
                    SharedFutureAggregate.ZERO);
            return new SharedFutureAggregate(raw.approvedInboundQty(),
                    BigDecimal.ZERO.setScale(4), raw.expectedDate(), raw.refs());
        }

        SharedFutureAggregate forMaterial(
                UUID warehouseId, MaterialDimension dimension,
                String route, LocalDate needDate) {
            SharedFutureAggregate raw = byDimension.getOrDefault(
                    new WarehouseMaterialDimension(warehouseId, dimension),
                    SharedFutureAggregate.ZERO);
            boolean actionableRoute = Set.of("BUY", "SUBCONTRACT")
                    .contains(Objects.toString(route, ""));
            List<SharedFutureSupplyRef> matching = raw.refs().stream()
                    .filter(ref -> !actionableRoute || ref.route().equals(route))
                    .toList();
            BigDecimal approved = matching.stream()
                    .map(SharedFutureSupplyRef::approvedInboundQty)
                    .reduce(BigDecimal.ZERO, BigDecimal::add);
            BigDecimal available = actionableRoute ? matching.stream()
                    .filter(ref -> !ref.sourceIsCurrentAnalysis())
                    .filter(ref -> needDate == null
                            || ref.expectedDate() != null
                            && !ref.expectedDate().isAfter(needDate))
                    .map(SharedFutureSupplyRef::availableToClaimQty)
                    .reduce(BigDecimal.ZERO, BigDecimal::add)
                    : BigDecimal.ZERO;
            LocalDate expected = matching.stream()
                    .map(SharedFutureSupplyRef::expectedDate)
                    .filter(Objects::nonNull).min(LocalDate::compareTo).orElse(null);
            return new SharedFutureAggregate(
                    approved, available, expected, List.copyOf(matching));
        }
    }

    record SourceIdentity(String sourceType, UUID salesOrderItemId, UUID goodsId,
                          UUID colorId, UUID unitId, String sourceRef)
            implements Comparable<SourceIdentity> {
        SourceIdentity {
            if (SOURCE_SALES.equals(sourceType)) {
                goodsId = null;
                colorId = null;
                unitId = null;
                sourceRef = null;
            } else {
                salesOrderItemId = null;
            }
            sourceRef = sourceRef == null
                    ? null : sourceRef.strip().toLowerCase(Locale.ROOT);
        }

        @Override
        public int compareTo(SourceIdentity other) {
            return canonical().compareTo(other.canonical());
        }

        private String canonical() {
            return String.join("|", Objects.toString(sourceType, ""),
                    Objects.toString(salesOrderItemId, ""), Objects.toString(goodsId, ""),
                    Objects.toString(colorId, ""), Objects.toString(unitId, ""),
                    Objects.toString(sourceRef, ""));
        }
    }

    record SourceMaster(UUID goodsId, UUID colorId, UUID unitId,
                        LocalDate deliveryDate) {
    }

    record SourceLine(
            UUID analysisItemId, String sourceType, UUID salesOrderItemId,
            UUID salesOrderId, String salesOrderNo, LocalDate orderDate,
            LocalDate deliveryDate, String clientName,
            UUID goodsId, String goodsCode, String goodsName, String spec,
            UUID colorId, String colorName, UUID unitId, String unitName,
            BigDecimal unitRate, BigDecimal requestedQty, BigDecimal submittedQty,
            BigDecimal approvedQty,
            BigDecimal salesQty, BigDecimal shippedQty, BigDecimal returnedQty,
            BigDecimal flagQty, BigDecimal reservedQty, BigDecimal plannedQty,
            BigDecimal producedQty, BigDecimal activeDraftQty,
            Short orderStatus, boolean orderStopped, boolean orderClosed,
            boolean orderDeleted, boolean orderItemDeleted,
            String sourceRef, String sourceReason, int allocationPriority,
            BigDecimal readyNowQty, BigDecimal readyByDateQty,
            BigDecimal readyStartQty, BigDecimal readyFinishQty,
            BigDecimal readyShipQty, UUID parentAnalysisLineId,
            String parentGoodsName, boolean orderFinanceConfirmed,
            UUID rootMaterialLineId, BigDecimal rootFulfilledQty, String rootRoute) {
        SourceLine(
            UUID analysisItemId, String sourceType, UUID salesOrderItemId,
            UUID salesOrderId, String salesOrderNo, LocalDate orderDate,
            LocalDate deliveryDate, String clientName,
            UUID goodsId, String goodsCode, String goodsName, String spec,
            UUID colorId, String colorName, UUID unitId, String unitName,
            BigDecimal unitRate, BigDecimal requestedQty, BigDecimal submittedQty,
            BigDecimal approvedQty,
            BigDecimal salesQty, BigDecimal shippedQty, BigDecimal returnedQty,
            BigDecimal flagQty, BigDecimal reservedQty, BigDecimal plannedQty,
            BigDecimal producedQty, BigDecimal activeDraftQty,
            Short orderStatus, boolean orderStopped, boolean orderClosed,
            boolean orderDeleted, boolean orderItemDeleted,
            String sourceRef, String sourceReason, int allocationPriority,
            BigDecimal readyNowQty, BigDecimal readyByDateQty,
            BigDecimal readyStartQty, BigDecimal readyFinishQty,
            BigDecimal readyShipQty, UUID parentAnalysisLineId,
            String parentGoodsName, boolean orderFinanceConfirmed) {
            this(analysisItemId, sourceType, salesOrderItemId, salesOrderId, salesOrderNo, orderDate, deliveryDate, clientName, goodsId, goodsCode, goodsName, spec, colorId, colorName, unitId, unitName, unitRate, requestedQty, submittedQty, approvedQty, salesQty, shippedQty, returnedQty, flagQty, reservedQty, plannedQty, producedQty, activeDraftQty, orderStatus, orderStopped, orderClosed, orderDeleted, orderItemDeleted, sourceRef, sourceReason, allocationPriority, readyNowQty, readyByDateQty, readyStartQty, readyFinishQty, readyShipQty, parentAnalysisLineId, parentGoodsName, orderFinanceConfirmed, null, BigDecimal.ZERO, null);
        }


        static SourceLine from(Object[] row) {
            return new SourceLine(uuid(row[0]), string(row[1]), uuid(row[2]), uuid(row[3]),
                    string(row[4]), date(row[5]), date(row[6]), string(row[7]),
                    uuid(row[8]), string(row[9]), string(row[10]), string(row[11]),
                    uuid(row[12]), string(row[13]), uuid(row[14]), string(row[15]),
                    decimal(row[16]), decimal(row[17]), decimal(row[18]), decimal(row[19]),
                    decimal(row[20]), decimal(row[21]), decimal(row[22]), decimal(row[23]),
                    decimal(row[24]), decimal(row[25]), decimal(row[26]), decimal(row[27]),
                    row[28] == null ? null : ((Number) row[28]).shortValue(),
                    Boolean.TRUE.equals(row[29]), Boolean.TRUE.equals(row[30]),
                    Boolean.TRUE.equals(row[31]), Boolean.TRUE.equals(row[32]),
                    string(row[33]), string(row[34]), integer(row[35]),
                    decimal(row[36]), decimal(row[37]), decimal(row[38]),
                    decimal(row[39]), decimal(row[40]),
                    uuid(row[41]), string(row[42]),
                    Boolean.TRUE.equals(row[43]),
                    row.length > 44 ? uuid(row[44]) : null,
                    row.length > 45 ? decimal(row[45]) : BigDecimal.ZERO,
                    row.length > 46 ? string(row[46]) : null);
        }

        BigDecimal remainingAnalysisQty() {
            return requestedQty.subtract(submittedQty).subtract(approvedQty).subtract(rootFulfilledQty)
                    .max(BigDecimal.ZERO).setScale(4, RoundingMode.DOWN);
        }

        String planningBlockedReason() {
            if (!SOURCE_SALES.equals(sourceType)) return null;
            if (orderStatus == null || orderStatus != 1 || orderStopped
                    || orderClosed || orderDeleted || orderItemDeleted) {
                return "销售订单未审核、已中止、已关闭或已删除，不能新增安排";
            }
            if (!orderFinanceConfirmed) {
                return "销售订单等待财务确认，已有任务进度照常更新，暂不能新增安排";
            }
            BigDecimal outstanding = salesQty.subtract(shippedQty)
                    .add(returnedQty).subtract(flagQty);
            BigDecimal unfinishedApproved = plannedQty.subtract(producedQty)
                    .max(BigDecimal.ZERO);
            BigDecimal available = outstanding.subtract(reservedQty)
                    .subtract(unfinishedApproved).subtract(activeDraftQty)
                    .add(submittedQty).add(approvedQty);
            if (available.signum() < 0) {
                return "销售订单剩余可排数量为负，请先核对累计数量";
            }
            if (remainingAnalysisQty().compareTo(available) > 0) {
                return "销售订单数量已减少，请先调整物料分析中的待安排数量";
            }
            return null;
        }

        /** Plan issuance does not fulfill the batch's material requirement. */
        BigDecimal materialRequirementQty() {
            return requestedQty.subtract(rootFulfilledQty)
                    .max(BigDecimal.ZERO).setScale(4, RoundingMode.DOWN);
        }

        BigDecimal unplannedReadyQty(BigDecimal batchReadyQty) {
            return batchReadyQty.subtract(submittedQty).subtract(approvedQty)
                    .max(BigDecimal.ZERO).min(remainingAnalysisQty())
                    .setScale(4, RoundingMode.DOWN);
        }

        ProductView toView(
                BigDecimal ratio,
                boolean hasProductionMaterialChildren,
                ProductPlanState planState) {
            return toView(ratio, hasProductionMaterialChildren, planState,
                    planningBlockedReason());
        }

        ProductView toView(BigDecimal ratio, boolean hasProductionMaterialChildren,
                ProductPlanState planState, String planningBlockedReason) {
            BigDecimal remaining = remainingAnalysisQty();
            boolean externalRoot = rootRoute != null && !"MAKE".equals(rootRoute);
            // 与子件同口径（2026-09-05）：V478 根节点存在但路线未确认（NULL）时
            // 不可排产——顶层必须像子件一样显式确认为自制后才能下达车间；
            // 无根节点的旧分析（rootMaterialLineId 为 null）沿用旧合同。
            boolean rootRoutePending = rootMaterialLineId != null && rootRoute == null;
            boolean canSchedule = planningBlockedReason == null
                    && remaining.signum() > 0 && !externalRoot && !rootRoutePending;
            return new ProductView(analysisItemId, sourceType, sourceRef, sourceReason,
                    salesOrderItemId,
                    salesOrderId, salesOrderNo, orderDate, deliveryDate, clientName,
                    goodsId, goodsCode, goodsName, spec, colorId, colorName, unitId,
                    unitName, unitRate, requestedQty, submittedQty, approvedQty,
                    remaining, allocationPriority,
                    canSchedule, remaining,
                    planningBlockedReason != null ? planningBlockedReason
                            : canSchedule ? null : rootRoutePending
                            ? "根产品供料路线未确认，请先确认为自制再下达车间"
                            : externalRoot
                            ? "根产品按采购或委外供给，不能重复生成自制计划"
                            : "当前分析需求已全部转入生产计划",
                    externalRoot ? BigDecimal.ZERO : readyNowQty, externalRoot ? BigDecimal.ZERO : readyByDateQty,
                    externalRoot ? BigDecimal.ZERO : readyStartQty, externalRoot ? BigDecimal.ZERO : readyFinishQty,
                    externalRoot ? BigDecimal.ZERO : readyShipQty, ratio,
                    hasProductionMaterialChildren,
                    parentAnalysisLineId, parentGoodsName,
                    planState.status(), planState.planId(), planState.planNo(),
                    planState.plannedQty(), planState.inboundQty(),
                    planState.progressRatio(), planState.reportedQty(),
                    planState.zeroMaterial(), planState.workshopName(),
                    planState.responsibleName(), rootMaterialLineId);
        }
    }

    record ProductPlanState(
            String status,
            UUID planId,
            String planNo,
            BigDecimal plannedQty,
            BigDecimal inboundQty,
            BigDecimal progressRatio,
            BigDecimal reportedQty,
            boolean zeroMaterial,
            String workshopName,
            String responsibleName) {
        static final ProductPlanState NONE = new ProductPlanState(
                null, null, null, BigDecimal.ZERO, BigDecimal.ZERO, null,
                BigDecimal.ZERO, false, null, null);
     }

    record BomNode(
            UUID analysisItemId, UUID bomItemId, UUID parentGoodsId,
            UUID goodsId, UUID colorId, UUID unitId, int depth,
            String nodeKey, String parentNodeKey,
            BigDecimal parentPerProductQty, BigDecimal bomQty,
            BigDecimal perProductQty, BigDecimal snapshotRequiredQty,
            String goodsCode, String goodsName, String spec, String colorName,
            String unitName, BigDecimal safetyStock, String suggestion,
            boolean hasChildren, String controlStage, String consumptionBasis,
            BigDecimal basisOutputQty, boolean allowPartialPackage,
            boolean hardGate, List<BigDecimal> outputBatches) {
        BomNode(UUID analysisItemId, UUID bomItemId, UUID parentGoodsId,
                UUID goodsId, UUID colorId, UUID unitId, int depth,
                String nodeKey, String parentNodeKey,
                BigDecimal parentPerProductQty, BigDecimal bomQty,
                BigDecimal perProductQty, BigDecimal snapshotRequiredQty,
                String goodsCode, String goodsName, String spec, String colorName,
                String unitName, BigDecimal safetyStock, String suggestion,
                boolean hasChildren, String controlStage, String consumptionBasis,
                BigDecimal basisOutputQty, boolean allowPartialPackage, boolean hardGate) {
            this(analysisItemId,bomItemId,parentGoodsId,goodsId,colorId,unitId,depth,
                    nodeKey,parentNodeKey,parentPerProductQty,bomQty,perProductQty,snapshotRequiredQty,
                    goodsCode,goodsName,spec,colorName,unitName,safetyStock,suggestion,
                    hasChildren,controlStage,consumptionBasis,basisOutputQty,allowPartialPackage,
                    hardGate,List.of());
        }
        MaterialDimension dimension() {
            return new MaterialDimension(goodsId, colorId, unitId);
        }
        BigDecimal requiredForOutput(BigDecimal productQty) {
            return requiredForParentOutput(productQty.multiply(parentPerProductQty));
        }
        BigDecimal requiredForParentOutput(BigDecimal parentOutputQty) {
            BigDecimal remaining=parentOutputQty.max(BigDecimal.ZERO);
            BigDecimal required=BigDecimal.ZERO;
            for (BigDecimal batch : outputBatches) {
                BigDecimal take=remaining.min(batch);
                if (take.signum()<=0) break;
                required=required.add(requiredForSingleParentOutput(take));
                remaining=remaining.subtract(take);
            }
            return required.add(requiredForSingleParentOutput(remaining));
        }
        BigDecimal requiredForSingleParentOutput(BigDecimal parentOutputQty) {
            try {
                return MaterialConsumptionMath.required(
                        parentOutputQty, bomQty,
                        consumptionBasis, basisOutputQty, allowPartialPackage);
            } catch (IllegalArgumentException ex) {
                throw conflict("BOM 包装/批次计量数据无效，不能计算齐套数量");
            }
        }
        BomNode withSnapshotRequiredQty(BigDecimal requiredQty) {
            return new BomNode(
                    analysisItemId, bomItemId, parentGoodsId,
                    goodsId, colorId, unitId, depth, nodeKey, parentNodeKey,
                    parentPerProductQty, bomQty, perProductQty, requiredQty,
                    goodsCode, goodsName, spec, colorName, unitName, safetyStock,
                    suggestion, hasChildren, controlStage, consumptionBasis,
                    basisOutputQty, allowPartialPackage, hardGate,outputBatches);
        }
        BomNode withOutputBatches(List<BigDecimal> batches) {
            return new BomNode(analysisItemId,bomItemId,parentGoodsId,goodsId,colorId,unitId,depth,
                    nodeKey,parentNodeKey,parentPerProductQty,bomQty,perProductQty,snapshotRequiredQty,
                    goodsCode,goodsName,spec,colorName,unitName,safetyStock,suggestion,
                    hasChildren,controlStage,consumptionBasis,basisOutputQty,allowPartialPackage,
                    hardGate,List.copyOf(batches));
        }
        String path() {
            return nodeKey;
        }
    }

    record StockValue(BigDecimal onHand, BigDecimal reserved, BigDecimal available,
                      boolean safetyAlreadyApplied) {
        StockValue(BigDecimal onHand,BigDecimal reserved,BigDecimal available) {
            this(onHand,reserved,available,false);
        }
        static final StockValue ZERO = new StockValue(
                BigDecimal.ZERO, BigDecimal.ZERO, BigDecimal.ZERO);
        StockValue add(StockValue other) {
            return new StockValue(onHand.add(other.onHand), reserved.add(other.reserved),
                    available.add(other.available),safetyAlreadyApplied && other.safetyAlreadyApplied);
        }
        BigDecimal availableAfterSafety(BigDecimal safety) {
            return available.subtract(safetyAlreadyApplied ? BigDecimal.ZERO : safety)
                    .max(BigDecimal.ZERO).setScale(4,RoundingMode.DOWN);
        }
    }

    record InboundLot(MaterialDimension dimension, LocalDate expectedDate, BigDecimal qty) {
    }

    record InboundValue(BigDecimal qty, LocalDate expectedDate) {
        static final InboundValue ZERO = new InboundValue(BigDecimal.ZERO, null);
    }

    record AvailabilitySnapshot(Map<MaterialDimension, StockValue> stock,
                                List<InboundLot> inbound,
                                Map<WarehouseMaterialDimension,BigDecimal> usableByWarehouse) {
        AvailabilitySnapshot(Map<MaterialDimension,StockValue> stock,List<InboundLot> inbound) {
            this(stock,inbound,Map.of());
        }
        InboundValue inboundOnOrBefore(MaterialDimension key, LocalDate cutoff) {
            if (cutoff == null) return InboundValue.ZERO;
            BigDecimal qty = BigDecimal.ZERO;
            LocalDate earliest = null;
            for (InboundLot lot : inbound) {
                if (!lot.dimension().equals(key) || lot.expectedDate() == null
                        || lot.expectedDate().isAfter(cutoff)) continue;
                qty = qty.add(lot.qty());
                if (earliest == null || lot.expectedDate().isBefore(earliest)) {
                    earliest = lot.expectedDate();
                }
            }
            return new InboundValue(qty.setScale(4, RoundingMode.DOWN), earliest);
        }
    }

    record MaterialNodeIdentity(UUID analysisItemId, String nodeKey) {
        String allocationKey() {
            return analysisItemId + "|" + nodeKey;
        }
    }

    record DelegatedRequirementOwner(
            UUID parentMaterialId,
            UUID analysisLineId,
            String sourceRef,
            BigDecimal requestedQty) {
    }

    record RequirementProjection(
            String state,
            UUID delegatedToAnalysisLineId,
            String delegatedToSourceRef,
            BigDecimal delegatedToRequestedQty) {

        RequirementProjection {
            boolean delegated = REQUIREMENT_STATE_DELEGATED_TO_MAKE_CHILD.equals(state);
            boolean anyOwner = delegatedToAnalysisLineId != null
                    || delegatedToSourceRef != null
                    || delegatedToRequestedQty != null;
            boolean completeOwner = delegatedToAnalysisLineId != null
                    && blankToNull(delegatedToSourceRef) != null
                    && delegatedToRequestedQty != null
                    && delegatedToRequestedQty.signum() > 0;
            if ((delegated && !completeOwner) || (!delegated && anyOwner)) {
                throw new IllegalArgumentException(
                        "MAKE delegated requirement owner fields are inconsistent");
            }
        }

        static RequirementProjection active() {
            return of(REQUIREMENT_STATE_ACTIVE);
        }

        static RequirementProjection delegated(DelegatedRequirementOwner owner) {
            return new RequirementProjection(
                    REQUIREMENT_STATE_DELEGATED_TO_MAKE_CHILD,
                    owner.analysisLineId(), owner.sourceRef(), owner.requestedQty());
        }

        static RequirementProjection delegatedToSubcontractPreparation() {
            return of(REQUIREMENT_STATE_DELEGATED_TO_SUBCONTRACT_PREPARATION);
        }

        static RequirementProjection inactiveParentCovered() {
            return of(REQUIREMENT_STATE_INACTIVE_PARENT_COVERED);
        }

        static RequirementProjection inactiveParentRoute() {
            return of(REQUIREMENT_STATE_INACTIVE_PARENT_ROUTE);
        }

        static RequirementProjection inactiveReference() {
            return of(REQUIREMENT_STATE_INACTIVE_REFERENCE);
        }

        static RequirementProjection transferredToPlan() {
            return of(REQUIREMENT_STATE_TRANSFERRED_TO_PLAN);
        }

        static RequirementProjection inactive() {
            return of(REQUIREMENT_STATE_INACTIVE);
        }

        private static RequirementProjection of(String state) {
            return new RequirementProjection(state, null, null, null);
        }
    }

    record MaterialRow(
            UUID id, UUID analysisItemId, String nodeKey,
            UUID goodsId, String goodsCode,
            String goodsName, String spec, UUID colorId, String colorName,
            UUID unitId, String unitName, int depth, String path,
            String parentNodeKey, UUID parentGoodsId,
            String controlStage, String consumptionBasis, BigDecimal basisOutputQty,
            boolean allowPartialPackage, boolean hardGate,
            BigDecimal bomQty, BigDecimal parentPerProductQty,
            BigDecimal perProductQty,
            BigDecimal requiredQty, BigDecimal availableQty,
            BigDecimal allocatedAvailableQty, BigDecimal reservedQty,
            BigDecimal safetyStockQty, BigDecimal inboundQty, BigDecimal shortageQty,
            LocalDate expectedReadyDate, String suggestion, String confirmedRoute,
            String routeReason,
            boolean lowerLevelPending) {
        static MaterialRow from(Object[] row) {
            return new MaterialRow(uuid(row[0]), uuid(row[1]), string(row[2]),
                    uuid(row[3]), string(row[4]), string(row[5]), string(row[6]),
                    uuid(row[7]), string(row[8]), uuid(row[9]), string(row[10]),
                    integer(row[11]), string(row[12]), string(row[13]), uuid(row[14]),
                    string(row[15]), string(row[16]), decimal(row[17]),
                    Boolean.TRUE.equals(row[18]), Boolean.TRUE.equals(row[19]),
                    decimal(row[20]), decimal(row[21]), decimal(row[22]),
                    decimal(row[23]), decimal(row[24]), decimal(row[25]),
                    decimal(row[26]), decimal(row[27]), decimal(row[28]),
                    decimal(row[29]), date(row[30]), string(row[31]), string(row[32]),
                    string(row[33]), Boolean.TRUE.equals(row[34]));
        }
        MaterialDimension dimension() {
            return new MaterialDimension(goodsId, colorId, unitId);
        }
        MaterialView toView(List<WarehouseBreakdown> breakdown,
                            List<DownstreamReference> references,
                            List<String> displayPath, String parentLabel,
                            BigDecimal exactPeggedQty,
                            BigDecimal subcontractHandoffFutureQty,
                            BigDecimal borrowedIn, BigDecimal borrowedOut,
                            List<BorrowRef> borrowRefs,
                            CrossProjection cross,
                            RequirementProjection requirement,
                            SharedFutureAggregate sharedFuture,
                            BigDecimal sharedFutureClaimedQty,
                            BigDecimal activeFutureCoverageQty,
                            BigDecimal selectedWarehousesAvailableQty,
                            BigDecimal selectedOtherWarehouseTransferableQty,
                            String flowStage,
                            UUID planAnchorAnalysisLineId,
                            MainWarehouseSafetySummary mainSafety) {
            List<String> notified = references.stream().map(DownstreamReference::route)
                    .distinct().sorted().toList();
            BigDecimal demandGap = unboundDemandSupplyGap(
                    requiredQty, allocatedAvailableQty, exactPeggedQty,
                    subcontractHandoffFutureQty);
            return new MaterialView(id, analysisItemId, nodeKey,
                    actionGroupKey(), materialKey(),
                    goodsId, goodsCode, goodsName,
                    spec, colorId, colorName, unitId, unitName, depth, displayPath,
                    parentNodeKey, parentGoodsId, parentLabel,
                    controlStage, consumptionBasis, basisOutputQty,
                    allowPartialPackage, hardGate, bomQty, parentPerProductQty,
                    perProductQty, requiredQty,
                    availableQty, exactPeggedQty, allocatedAvailableQty, reservedQty,
                    safetyStockQty, inboundQty, shortageQty,
                    demandGap,
                    subcontractHandoffFutureQty,
                    expectedReadyDate, suggestion, confirmedRoute,
                    confirmedRoute != null, routeReason,
                    actionable(), lowerLevelPending,
                    requirement.state(), requirement.delegatedToAnalysisLineId(),
                    requirement.delegatedToSourceRef(),
                    requirement.delegatedToRequestedQty(),
                    borrowedIn, borrowedOut, borrowRefs, notified,
                    cross.incomingQty(), cross.outgoingQty(),
                    cross.priorityPendingQty(), cross.priorityFulfilledQty(),
                    cross.refs(), breakdown, references,
                    sharedFuture.approvedInboundQty(),
                    sharedFuture.availableQty(), sharedFutureClaimedQty,
                    demandGap.subtract(activeFutureCoverageQty)
                            .max(BigDecimal.ZERO).setScale(4, RoundingMode.CEILING),
                    selectedWarehousesAvailableQty,
                    selectedOtherWarehouseTransferableQty,
                    sharedFuture.expectedDate(), sharedFuture.refs(),
                    flowStage, planAnchorAnalysisLineId,
                    mainSafety.publicAvailable(), mainSafety.openSupply(), mainSafety.gap());
        }

        String actionGroupKey() {
            return PlanningPackageFingerprint.sha256(List.of(
                    "MATERIAL-NODE-ACTION-V3", analysisItemId.toString(), path,
                    goodsId.toString(), Objects.toString(colorId, "NONE"), unitId.toString()));
        }

        MaterialNodeIdentity nodeIdentity() {
            return new MaterialNodeIdentity(analysisItemId, nodeKey);
        }

        boolean actionable() {
            return requiredQty.signum() > 0 && (depth == 0 || shortageQty.signum() > 0);
        }

        String materialKey() {
            return goodsId + "|" + Objects.toString(colorId, "NONE") + "|" + unitId;
        }
    }

    private static final class CandidateOrderBuilder {
        private final UUID id;
        private final String no;
        private final LocalDate orderDate;
        private final LocalDate deliveryDate;
        private final String clientName;
        private final List<SalesCandidateLine> lines = new ArrayList<>();

        private CandidateOrderBuilder(UUID id, String no, LocalDate orderDate,
                                      LocalDate deliveryDate, String clientName) {
            this.id = id;
            this.no = no;
            this.orderDate = orderDate;
            this.deliveryDate = deliveryDate;
            this.clientName = clientName;
        }

        SalesCandidateOrder build() {
            return new SalesCandidateOrder(id, no, orderDate, deliveryDate,
                    clientName, List.copyOf(lines));
        }
    }
}
