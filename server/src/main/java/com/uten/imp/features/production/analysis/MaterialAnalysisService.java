package com.uten.imp.features.production.analysis;

import com.uten.imp.application.port.ProductionMutationFootprintPort;
import com.uten.imp.application.concurrency.FulfillmentMutationLockPlan;
import com.uten.imp.application.concurrency.FulfillmentMutationLocks;
import com.uten.imp.common.util.NativeQueryResults;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.web.NativeFacets;
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
import java.util.Collection;
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
import java.util.TreeMap;
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
    static final String SOURCE_AGGREGATE_MAKE = "AGGREGATE_MAKE";
    /**
     * 手工生产来源五类(ADR-130/V738)：一个需求编号 = 一张手工需求单，可挂多个货品行；
     * 同一编号只属于一份物料分析，同一编号下同一货品(货品+颜色+单位)只占一行。
     */
    static final Set<String> MANUAL_SOURCE_TYPES = Set.of("REWORK", "TRIAL", "SAMPLE", "STOCK", "OTHER");
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
    private final com.uten.imp.features.notice.ChainNoticeService chainNotice;
    private final PreplanStockEntitlementService stockEntitlement;
    private final MaterialAnalysisFlowStageService flowStages;
    private final FulfillmentMutationLocks mutationLocks;
    private final ProductionMutationFootprintPort mutationFootprints;
    @org.springframework.beans.factory.annotation.Autowired
    private MaterialAnalysisRootSupplyService rootSupply;
    @org.springframework.beans.factory.annotation.Autowired
    private org.springframework.beans.factory.ObjectProvider<com.uten.imp.features.production.fulfillment.ProductionExecutionReadinessService> reservationPreviewReadiness;
    @org.springframework.beans.factory.annotation.Autowired
    private org.springframework.beans.factory.ObjectProvider<com.uten.imp.application.port.PreplanAnalysisPegPort> reservationPreviewSources;
    /** V719 分析编号 WL+日期+日流水；字段注入与上面的可选依赖同款，不动构造器签名。 */
    @org.springframework.beans.factory.annotation.Autowired
    private com.uten.imp.common.docnumber.DocNumberService docNumbers;
    /** ADR-143 §二.3 委外件缺 BOM 转研发(研发任务模块实现)；直接 new 本类的单测里为空，只跳过登记。 */
    @org.springframework.beans.factory.annotation.Autowired
    private org.springframework.beans.factory.ObjectProvider<com.uten.imp.application.port.RdBomGapPort> rdBomGaps;

    /** 分析的对象级范围：与生产单据同一套经手人可见规则(ADR-088)。 */
    OwnerVisibility.OwnerScope scopeForAnalysis(AnalysisHeader header){
        return access.scope();
    }

    /** 调用人能否看见这份分析：与打开/刷新同一套归属判定；没有当前用户的系统路径按可见。 */
    private boolean canSeeAnalysis(UUID makerId){
        var scope=access.scope();
        return scope==null||access.canRead(makerId,scope);
    }

    /**
     * 物料分析的创建与刷新入口：按来源重算分配树。幂等键命中既有分析时直接重放；新建走 per(员工+幂等键) advisory 锁，
     * 可复用来源相同的进行中分析；刷新时来源、仓库变化须一并重算。
     */
    @Transactional
    public AnalysisView preview(PreviewRequest request) {
        tx.bind();
        if (request == null || request.items() == null || request.items().isEmpty()) {
            throw validation("至少选择一个生产需求来源");
        }
        List<UUID> participatingWarehouses = normalizeParticipatingWarehouses(
                request.warehouseId(), request.warehouseIds());
        List<PreviewItem> normalized = normalizePreviewItems(request.items());
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
            // The verified preview footprint already holds the requested
            // analysis row and both existing/requested source/warehouse sets.
            // Read its current CAS under that lock instead of discovering the
            // same full graph again. refreshLocked still discovers and verifies
            // the graph after source quantities or warehouse scope are written.
            AnalysisHeader requestedHeader = headerAfterPrelock(analysisId);
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
            String analysisNo = docNumbers.nextNumber(
                    com.uten.imp.common.docnumber.DocNumberPrefix.MATERIAL_ANALYSIS);
            mutationLocks.expectCreatedAnalysis(analysisId);
            em.createNativeQuery("""
                    INSERT INTO production_material_analyses (
                        id, analysis_no, warehouse_id, participating_warehouse_ids,
                        status, version, fingerprint,
                        initial_idempotency_key, analyzed_at, maker_id,
                        created_by, updated_by
                    ) VALUES (
                        :id, :analysisNo, :warehouseId,
                        CAST(string_to_array(:warehouseIds, ',') AS uuid[]),
                        'ACTIVE', 0, :fingerprint,
                        :idempotencyKey, now(), :makerId, :actorId, :actorId
                    )
                    """)
                    .setParameter("id", analysisId)
                    .setParameter("analysisNo", analysisNo)
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
            AnalysisHeader header = headerAfterPrelock(analysisId);
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
        // 刷新前先把 BOM 侧最新的设计/真实使用数量采纳进分析 (ADR-129)。
        adoptLatestBomUsage(analysisId);
        // 页面发起的新建/刷新在同一次重算里按货品档案确认供应方式 (ADR-102)。
        RefreshOutcome refreshed = refreshWithAnchorGrowth(analysisId, previousMakeAnchorRequirements,
                Map.of(), true);
        recordSimpleCommand(analysisId, "PREVIEW", request.idempotencyKey(), requestHash);
        return detailInternal(analysisId, false)
                .withRouteOutcome(refreshed.routeResets(), refreshed.autoConfirmedRoutes());
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
                        "OTHER", SOURCE_MAKE_COMPONENT).contains(normalizedSource)) {
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
                             lower(COALESCE(analysis.analysis_no, '')) LIKE :keywordLike OR
                             lower(COALESCE(source.source_ref,'')) LIKE :keywordLike OR
                             lower(COALESCE(goods.code,'')) LIKE :keywordLike OR
                             lower(COALESCE(goods.name,'')) LIKE :keywordLike OR
                             lower(COALESCE(sales_order.bill_no,'')) LIKE :keywordLike)
                  )
                """.formatted(ownerScope.predicate());
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
                WITH analysis_page AS MATERIALIZED (
                    SELECT analysis.*
                    """ + filters + """
                      AND EXISTS (SELECT 1 FROM warehouses warehouse WHERE warehouse.id=analysis.warehouse_id)
                    ORDER BY analysis.analyzed_at DESC, analysis.id DESC
                    LIMIT :limit OFFSET :offset
                )
                SELECT analysis.id, analysis.status, analysis.version,
                       analysis.fingerprint, analysis.warehouse_id,
                       warehouse.code, warehouse.name, analysis.analyzed_at,
                       analysis.updated_at, analysis.maker_id, maker.full_name,
                       summary.source_count, summary.source_types, summary.source_refs,
                       summary.product_labels, summary.requested_qty, summary.submitted_qty,
                       summary.approved_qty, summary.remaining_qty,
                       summary.ready_now_qty, summary.ready_by_date_qty,
                       analysis.analysis_no
                FROM analysis_page analysis
                JOIN warehouses warehouse ON warehouse.id = analysis.warehouse_id
                LEFT JOIN employees maker ON maker.id = analysis.maker_id
                CROSS JOIN LATERAL (
                    SELECT COUNT(source.id) AS source_count,
                           string_agg(DISTINCT source.source_type, chr(31)) AS source_types,
                           string_agg(DISTINCT COALESCE(
                               NULLIF(btrim(source.source_ref),''), sales_order.bill_no), chr(31)) AS source_refs,
                           -- 产品身份标签「名称 (编号 · 颜色)」：与 UtenGoodsIdentityCell.text
                           -- 同一排版，且同名不同色的两行不会被 DISTINCT 并成一条。
                           string_agg(DISTINCT
                               COALESCE(NULLIF(goods.name, ''), NULLIF(goods.code, ''), '未命名货品')
                               || COALESCE(' (' || NULLIF(concat_ws(' · ',
                                   CASE WHEN NULLIF(goods.name, '') IS NULL
                                        THEN NULL ELSE NULLIF(goods.code, '') END,
                                   NULLIF(product_color.name, '')), '') || ')', ''),
                               chr(31)) AS product_labels,
                           COALESCE(SUM(source.requested_qty),0) AS requested_qty,
                           COALESCE(SUM(source.submitted_qty),0) AS submitted_qty,
                           COALESCE(SUM(source.approved_qty),0) AS approved_qty,
                           COALESCE(SUM(GREATEST(source.requested_qty
                               -source.submitted_qty-source.approved_qty,0)),0) AS remaining_qty,
                           COALESCE(SUM(source.ready_now_qty),0) AS ready_now_qty,
                           COALESCE(SUM(source.ready_by_date_qty),0) AS ready_by_date_qty
                    FROM production_material_analysis_items source
                    JOIN goods goods ON goods.id = source.goods_id
                    -- 行色优先、主档色兜底（同 BOM 快照读取器的既有解析方式）。
                    LEFT JOIN colors product_color
                      ON product_color.id = COALESCE(source.color_id, goods.color_id)
                     AND product_color.is_deleted = FALSE
                    LEFT JOIN sales_order_items sales_item ON sales_item.id = source.sales_order_item_id
                    LEFT JOIN sales_orders sales_order ON sales_order.id = sales_item.order_id
                    WHERE source.analysis_id = analysis.id AND source.is_deleted = FALSE
                ) summary
                ORDER BY analysis.analyzed_at DESC, analysis.id DESC
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
                        decimal(row[18]), decimal(row[19]), decimal(row[20]),
                        string(row[21])))
                .toList();
        return new PageResponse<>(items, safePage, safeSize, total, totalPages);
    }

    /**
     * 保存物料供给路线（按操作组）：幂等重放 + 乐观版本校验。操作组已有不同路线的下游任务时禁止改路线（须先撤回）；
     * 原因可选；确认人和确认时间始终保留，已有下游的路线仍须先撤回。
     *
     * <p>2026-09-16 供应方式单一事实源 = 货品主档 goods.source_type：确认路线同事务回写主档
     * (BUY→采购、MAKE→自制、SUBCONTRACT→委外，含 ROOT_SUPPLY 根行——根确认为 MAKE 即产品是自制件)，
     * 新分析的建议路线从主档来，用户在分析里改的供应方式下次进来就是新值；按历史分析推导的
     * /last-routes 记忆整套退役。同一条 UPDATE 把本行 source_suggestion 对齐成确认值：否则
     * 主档回写后下一次刷新算出的建议 = 刚确认的值，与旧建议不同，会被
     * {@code NODE_FACT_CHANGED_CONDITION} 当成「主档事实变更」把确认清掉(反馈环)。
     * 主档回写必须先于 {@link #refreshLocked}，刷新按新主档算建议才与本行对齐。
     * 同批同货品的节点选用了不同路线时，各节点决定独立保存，保留原主档默认与建议，
     * 不以请求顺序挑选主档路线，也不在刷新时清掉合法的混合路线决定。
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
        MaterialGroupIndex materialGroups = MaterialGroupIndex.of(currentMaterials);
        List<RouteDecision> decisions = request.decisions() == null
                ? List.of() : request.decisions();
        List<SourceLine> routeSources = loadSourceLines(analysisId, false);
        Map<UUID, String> planningBlocks = planningBlockedReasons(routeSources);
        Set<UUID> knownSources = routeSources.stream().map(SourceLine::analysisItemId).collect(Collectors.toSet());
        List<MaterialAnalysisRouteBatchWriter.Change> changes = new ArrayList<>();
        for (RouteDecision decision : decisions) {
            MaterialGroup resolved = materialGroups.resolve(decision);
            List<MaterialRow> group = resolved.materials();
            for (UUID sourceId : group.stream().map(MaterialRow::analysisItemId).distinct().sorted().toList()) {
                if (!knownSources.contains(sourceId)) throw conflict("待安排产品已变化，请刷新后重试");
                String blocked = planningBlocks.get(sourceId);
                if (blocked != null) throw conflict(blocked);
            }
            String groupKey = resolved.key();
            if (!seen.add(groupKey)) throw validation("物料路线操作组重复");
            String route = normalizeRoute(decision.route());
            String reason = normalizeRouteReason(decision.reason());
            for (MaterialRow material : group) {
                changes.add(new MaterialAnalysisRouteBatchWriter.Change(material.id(), groupKey,
                        material.goodsId(), route, reason));
            }
        }
        // All request/source validation precedes writes. Mixed per-node routes
        // remain legitimate, but cannot choose a last-wins default for the goods.
        new MaterialAnalysisRouteBatchWriter(em).apply(analysisId, currentUser.requireId(), changes);
        // 人工改了父件路线后, 下层可能刚出现独立需求: 同一次重算里按货品档案把它们一并确认.
        RefreshOutcome refreshed = refreshLockedOutcome(analysisId, Map.of(), true);
        recordSimpleCommand(analysisId, "ROUTE", request.idempotencyKey(), requestHash);
        return detailInternal(analysisId, false).withRouteOutcome(0, refreshed.autoConfirmedRoutes());
    }

    /**
     * 一次服务端重算的路线结果: 因事实变更被清空、且没被本次自动确认补回的确认数 (仍要人补选),
     * 按货品档案自动确认的操作组数.
     */
    record RefreshOutcome(int routeResets, int autoConfirmedRoutes) {
        RefreshOutcome plus(RefreshOutcome other) {
            return new RefreshOutcome(routeResets + other.routeResets, autoConfirmedRoutes + other.autoConfirmedRoutes);
        }
    }

    /**
     * 能否确认供应方式: 详情里的 CONFIRM_ROUTES 能力与服务端自动确认共用这一道闸 (ADR-102).
     * = PUT /routes 的闸 (查看 + 路线维护权限, 本人负责或按归属范围可写) 再加分析仍在安排中、
     * 且不是只做成品检验补货的分析 (页面在这两种情况下本来就不给改路线).
     */
    private boolean canConfirmRoutes(AnalysisHeader header, boolean fqcReplenishmentOnly) {
        return !fqcReplenishmentOnly
                && List.of(STATUS_ACTIVE, STATUS_PARTIAL).contains(header.status())
                && access.hasAuthority("production_material_analysis:view")
                && access.hasAuthority("production_material_analysis:route")
                && access.canWrite(header.makerId(), scopeForAnalysis(header));
    }

    /**
     * 按货品档案自动确认供应方式 (ADR-102, 2026-09-27 从页面挪到服务端): 页面发起的新建/刷新
     * 与人工改路线在重算写完快照、换指纹之前执行, 与重算同一事务、只算一次. 判据唯一一份在
     * {@link MaterialAnalysisRouteAutoConfirm}; 写入复用人工确认的
     * {@link MaterialAnalysisRouteBatchWriter} (同一套行级校验与主档回写), 只是不为不改主档的
     * 货品去加锁. 自动确认的值就是本行重算时已经生效的路线 (未确认行按建议算; 顶层行未确认时
     * 按自制算, 历史计划证明的也是自制), 所以不需要再重算一遍.
     *
     * @return 本次自动确认的操作组数
     */
    private int autoConfirmDecisiveRoutes(UUID analysisId, List<SourceLine> sources) {
        if (!access.hasAuthority("production_material_analysis:view")
                || !access.hasAuthority("production_material_analysis:route")) return 0;
        List<MaterialRow> rows = loadMaterialRows(analysisId);
        Map<UUID, String> planningBlocks = planningBlockedReasons(sources);
        if (!MaterialAnalysisRouteAutoConfirm.hasCandidates(rows, planningBlocks)) return 0;
        if (!canConfirmRoutes(readHeader(analysisId), fqcRecoveryAuthorizationId(analysisId) != null)) return 0;
        Map<UUID, List<DownstreamReference>> references = downstreamReferences(analysisId);
        if (rootSupply != null) rootSupply.addOutputReferences(analysisId, references);
        MaterialAnalysisRouteAutoConfirm.Plan plan = MaterialAnalysisRouteAutoConfirm.plan(rows, planningBlocks,
                MaterialAnalysisRouteAutoConfirm.facts(sources, productPlanStates(analysisId),
                        planAnchorByMaterial(analysisId,
                                hasAggregateSources(sources) ? aggregateMembers(analysisId) : List.of()),
                        references, supplyActions(analysisId)));
        if (plan.changes().isEmpty()) return 0;
        new MaterialAnalysisRouteBatchWriter(em).applyAutomatic(analysisId, currentUser.requireId(), plan.changes());
        return plan.groupCount();
    }

    /**
     * 物料行 → 自制锚点产品行 (详情里的 planAnchorAnalysisLineId): 自制子件任务,
     * 再补上合单批次成员 (锚到批次的合单来源行).
     */
    private Map<UUID, UUID> planAnchorByMaterial(UUID analysisId, List<AggregateMember> aggregateMembers) {
        Map<UUID, UUID> anchors = new LinkedHashMap<>(anchorChildByParentLine(analysisId));
        for (AggregateMember member : aggregateMembers) anchors.putIfAbsent(member.materialId(), member.anchorId());
        return anchors;
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
        List<ExactPegRecord> protectedPegs = new ArrayList<>(loadExactPegs(analysisId, null));
        for (Object[] row : SubcontractComponentCustodyProjection.held(em, analysisId)) {
            protectedPegs.add(new ExactPegRecord(uuid(row[0]), uuid(row[1]), uuid(row[2]), string(row[3]),
                    new MaterialDimension(uuid(row[4]), uuid(row[5]), uuid(row[6])), decimal(row[8]), uuid(row[7])));
        }
        requireExactPegRefreshCompatible(protectedPegs, current);
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

    /**
     * 可纳入物料分析的销售订单候选：可生产量 = 未发 + 退回 − 标记 − 预留 − 超计划完工 − 在制草稿，
     * 仅保留仍有缺口的明细。
     */
    @Transactional(readOnly = true)
    public SalesCandidatePage salesCandidates(
            String keyword, int rawPage, int rawSize) {
        return salesCandidates(keyword, rawPage, rawSize, null, null, null);
    }

    /** 2026-09-25 单号列统一：销售单号列排序（orderNo→o.bill_no 白名单）与
     *  表头值筛选（orderBillNo 精确匹配，分页前服务端生效）。 */
    @Transactional(readOnly = true)
    public SalesCandidatePage salesCandidates(
            String keyword, int rawPage, int rawSize,
            String sort, String order, String orderBillNo) {
        int page = Math.max(rawPage, 1);
        int size = Math.min(Math.max(rawSize, 1), 100);
        String kw = keyword == null ? "" : keyword.strip().toLowerCase(Locale.ROOT);
        boolean billNoFilter = orderBillNo != null && !orderBillNo.isBlank();
        Query countQuery = em.createNativeQuery(
                "SELECT COUNT(DISTINCT o.id)\n"
                        + salesCandidatesFromWhere(kw, billNoFilter));
        if (!kw.isEmpty()) countQuery.setParameter("kw", "%" + kw + "%");
        if (billNoFilter) countQuery.setParameter("orderBillNo", orderBillNo.strip());
        long total = ((Number) countQuery.getSingleResult()).longValue();
        Query idsQuery = em.createNativeQuery(
                "SELECT o.id\n" + salesCandidatesFromWhere(kw, billNoFilter) + "\n" + """
                GROUP BY o.id, o.deliver_date, o.bill_date, o.bill_no
                """ + salesCandidatesOrderBy(sort, order));
        if (!kw.isEmpty()) idsQuery.setParameter("kw", "%" + kw + "%");
        if (billNoFilter) idsQuery.setParameter("orderBillNo", orderBillNo.strip());
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
                    -- 同 loadSourceLines 的 draft 口径（2026-09-15/V588）：分析
                    -- 草稿只把归本需求的量计入在制占用，公共备货产出不算。
                    SELECT SUM(CASE
                        WHEN link.id IS NOT NULL THEN link.submitted_qty
                        ELSE pi.qty END) AS qty
                    FROM production_plan_items pi
                    JOIN production_plans p ON p.id = pi.plan_id
                    LEFT JOIN production_material_analysis_plan_links link
                      ON link.plan_id = p.id
                     AND link.analysis_id = p.material_analysis_id
                     AND link.analysis_item_id = p.material_analysis_item_id
                    WHERE pi.sales_order_item_id = i.id
                      AND pi.is_deleted = FALSE AND p.is_deleted = FALSE
                      AND p.status = 0 AND p.is_canceled = FALSE
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

    /**
     * 销售单号列 facets（2026-09-25 单号列统一）：{orderNo:[…]}。与列表同一份
     * WHERE（keyword 生效、不含单号自身的值筛选）；计数与列表同为 DISTINCT 订单
     * 口径（一个单号一条候选），按单号升序，空串剔除。
     */
    @Transactional(readOnly = true)
    public java.util.Map<String, List<java.util.Map<String, Object>>> salesCandidatesFacets(
            String keyword) {
        String kw = keyword == null ? "" : keyword.strip().toLowerCase(Locale.ROOT);
        Query query = em.createNativeQuery(
                "SELECT o.bill_no, COUNT(DISTINCT o.id)\n"
                        + salesCandidatesFromWhere(kw, false)
                        + " GROUP BY o.bill_no"
                        + " HAVING COALESCE(o.bill_no,'') <> ''"
                        + " ORDER BY o.bill_no")
                .setMaxResults(500);
        if (!kw.isEmpty()) query.setParameter("kw", "%" + kw + "%");
        return java.util.Map.of("orderNo",
                NativeFacets.rows(NativeQueryResults.objectArrayRows(query)));
    }

    /** salesCandidates 列表/facets 共用的 FROM + LATERAL(在制草稿) + WHERE 基座。 */
    private static String salesCandidatesFromWhere(String kw, boolean billNoFilter) {
        return MaterialAnalysisSalesSourceQuery.fromWhere(kw, billNoFilter);
    }

    /** 排序白名单（2026-09-25 单号列统一）：orderNo→o.bill_no；未知/空回落默认
     *  交货升序；稳定键固定追加默认段（含 o.id）。 */
    private static String salesCandidatesOrderBy(String rawSort, String rawOrder) {
        String direction = "desc".equalsIgnoreCase(rawOrder) ? "DESC" : "ASC";
        return "orderNo".equals(rawSort == null ? "" : rawSort.strip())
                ? "ORDER BY o.bill_no " + direction
                        + " NULLS LAST, o.deliver_date NULLS LAST, o.bill_date, o.id\n"
                : "ORDER BY o.deliver_date NULLS LAST, o.bill_date, o.bill_no, o.id\n";
    }

    /**
     * Fail closed when the direct production structure changed after the analysis snapshot.
     * 只比结构(ADR-129 §2.5)：组件/颜色/单位/层级路径/控制段/计量规则/第一层单位换算率；
     * 设计或真实使用数量的变化不拦下达/审批，随下一次人工刷新生效。
     */
    public void requireCurrentBomSnapshot(UUID analysisId, Set<UUID> analysisItemIds) {
        if (analysisItemIds == null || analysisItemIds.isEmpty()) {
            throw validation("必须指定要校验的物料分析产品");
        }
        List<SourceLine> allSources = loadSourceLines(analysisId, false,
                MaterialAnalysisIssuePreviewOverlay.NONE, analysisItemIds);
        Map<UUID, SourceLine> sources = allSources.stream()
                .filter(source -> analysisItemIds.contains(source.analysisItemId()))
                .collect(Collectors.toMap(SourceLine::analysisItemId, source -> source));
        if (!sources.keySet().equals(analysisItemIds)) {
            throw conflict("待生成计划的产品已不属于当前物料分析");
        }
        // 新安排按所选产品及其来源父行校验；已有任务的实物进度另行刷新。
        requirePlanningSources(allSources, analysisItemIds);
        List<SourceLine> roots = sources.values().stream()
                .filter(source -> !SOURCE_MAKE_COMPONENT.equals(source.sourceType()))
                .toList();
        if (roots.isEmpty()) return;
        Map<UUID, Set<String>> currentBySource = new LinkedHashMap<>();
        for (BomNode node : loadBomTrees(roots)) {
            if (node.depth() == 1) currentBySource.computeIfAbsent(
                    node.analysisItemId(), ignored -> new TreeSet<>()).add(bomSignaturePart(node));
        }
        Map<UUID, Set<String>> snapshotBySource = new LinkedHashMap<>();
        for (Object[] row : NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT analysis_item_id, calculation_mode, %s
                FROM production_material_analysis_materials
                WHERE analysis_id = :analysisId
                  AND analysis_item_id IN (:analysisItemIds)
                  AND active = TRUE AND depth = 1
                ORDER BY analysis_item_id, node_key
                """.formatted(columnList(DIRECT_BOM_SIGNATURE)))
                .setParameter("analysisId", analysisId)
                .setParameter("analysisItemIds", roots.stream().map(SourceLine::analysisItemId).toList()))) {
            if (!"EDGE_RULE".equals(string(row[1]))) {
                throw conflict("历史物料快照必须先刷新，才能生成生产计划");
            }
            snapshotBySource.computeIfAbsent(uuid(row[0]), ignored -> new TreeSet<>())
                    .add(bomSignature(java.util.Arrays.copyOfRange(row, 2, row.length)));
        }
        for (SourceLine source : roots) {
            if (!currentBySource.getOrDefault(source.analysisItemId(), Set.of()).equals(
                    snapshotBySource.getOrDefault(source.analysisItemId(), Set.of()))) {
                throw conflict("BOM 直接层已变更，必须刷新物料分析并重新联合预览");
            }
        }
    }

    private static String bomSignaturePart(BomNode node) {
        return bomSignature(nodeValues(node, DIRECT_BOM_SIGNATURE));
    }

    /** 第一层签名：库内快照行与现时 BOM 节点按同一组列、同一文本口径比较(数值去尾零)。 */
    private static String bomSignature(Object[] values) {
        return java.util.Arrays.stream(values).map(value -> value == null ? ""
                        : value instanceof BigDecimal number ? decimalText(number) : value.toString())
                .collect(Collectors.joining("|"));
    }

    AnalysisHeader lockHeader(UUID analysisId) {
        // ADR-107: 嵌套在已持有预锁的命令里时只在内存里确认本分析已在集合内, 不再重跑发现。
        var guard = mutationLocks.acquire(FulfillmentMutationLockPlan.declaredAnalyses(List.of(analysisId)),
                () -> mutationFootprints.forAnalyses(List.of(analysisId)));
        AnalysisHeader header=readHeader(analysisId,true);
        guard.verifyUnchanged();
        return header;
    }

    /** Already-held A permits an immutable command replay before rejecting a stale write fingerprint. */
    AnalysisHeader headerAfterPrelock(UUID analysisId) {
        mutationLocks.requireAnalysesCovered(List.of(analysisId));
        return readHeader(analysisId,true);
    }

    private AnalysisHeader readHeader(UUID analysisId,boolean forUpdate) {
        Object[] row = oneRow(em.createNativeQuery("""
                SELECT id, warehouse_id, status, version, fingerprint,
                       analyzed_at, maker_id, is_deleted, analysis_no
                FROM production_material_analyses
                WHERE id = :id
                """ + (forUpdate ? " FOR UPDATE" : "")).setParameter("id", analysisId), "物料分析不存在");
        if (Boolean.TRUE.equals(row[7])) {
            throw notFound("物料分析不存在");
        }
        return new AnalysisHeader(uuid(row[0]), uuid(row[1]), string(row[2]),
                ((Number) row[3]).longValue(), string(row[4]), offsetDateTime(row[5]),
                uuid(row[6]), string(row[8]));
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

    int refreshLocked(UUID analysisId) {
        return refreshLocked(analysisId, Map.of());
    }

    /**
     * 按「本次每个父行填了多少」重算一遍(ADR-099 修订，2026-09-21 第五轮)。
     *
     * <p>[typedOutputByMaterialLine] = 层级表上每一行输入框里的数量(键是物料行 id)。
     * 它只补进该节点的<b>计划产出量</b>那一项：子件毛需求按父件计划产出展开，所以
     * 填在中间层的数量能像顶层一样把它自己的子层、孙层一路带大；节点自己的需求量、
     * 还需安排量一个字节不动(那是祖先决定的，不能被自己填的数覆盖)。</p>
     *
     * <p><b>只有下达预览会传它</b>(ADR-116 起预览不再调本方法, 走
     * {@link #issuePreviewView} 的只读投影)。真实下达恒传空 Map。</p>
     */
    int refreshLocked(UUID analysisId, Map<UUID, BigDecimal> typedOutputByMaterialLine) {
        return refreshLockedOutcome(analysisId, typedOutputByMaterialLine, false).routeResets();
    }

    /**
     * 同 {@link #refreshLocked(UUID, Map)}. [autoConfirmRoutes] 只由页面发起的新建/刷新
     * ({@link #preview}) 与人工改路线 ({@link #saveRoutes}) 打开 (ADR-102): 其余重算是别的单据
     * 顺带唤醒 (到货、审核、跨分析转移等), 操作人未必是这张分析的负责人, 也不该在那些事务里
     * 改货品主档、多拿货品行锁; 它们留下的待确认行由详情里的 pendingAutoConfirmRouteCount
     * 告诉页面, 页面静默刷新一次即可.
     */
    private RefreshOutcome refreshLockedOutcome(UUID analysisId, Map<UUID, BigDecimal> typedOutputByMaterialLine,
            boolean autoConfirmRoutes) {
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
        RefreshTree tree = refreshTree(analysisId, true, typedOutputByMaterialLine,
                MaterialAnalysisIssuePreviewOverlay.NONE);
        List<BomNode> nodes = tree.nodes();
        List<SourceLine> sources = tree.sources();
        // Reconcile identity membership, not every row's active flag. Existing
        // exact/borrow endpoints remain active when the same BOM node survives.
        em.createNativeQuery("""
                WITH current_nodes AS MATERIALIZED (
                    SELECT node_ref FROM unnest(string_to_array(:nodeRefs, ',')) AS nodes(node_ref)
                )
                UPDATE production_material_analysis_materials material
                SET active = FALSE, updated_at = now(), updated_by = :actorId
                WHERE material.analysis_id = :analysisId AND material.active = TRUE
                  AND material.node_role = 'BOM_COMPONENT'
                  AND NOT EXISTS (SELECT 1 FROM current_nodes current_node
                      WHERE current_node.node_ref = material.analysis_item_id::text || '|' || material.node_key)
                """)
                .setParameter("actorId", currentUser.requireId())
                .setParameter("analysisId", analysisId)
                .setParameter("nodeRefs", nodes.stream().map(MaterialAnalysisService::nodeAllocationKey)
                        .collect(Collectors.joining(",")))
                .executeUpdate();
        AvailabilitySnapshot availability = availability(
                analysisId, header.warehouseId(), nodes, sources);
        // 以单个明确字段类型的行数组分块提交；SQL和绑定数量不随节点数膨胀。
        // 冲突键、完整字段和「BOM 事实变更即清人工确认」条件保持原语义。
        // 写入前后各取一次已确认节点键，统计本次被清空的人工确认数（返回给刷新响应）。
        MaterialAnalysisSnapshotBaseline baseline = MaterialAnalysisSnapshotBaseline.load(em, analysisId, NODE_STRUCTURE_COLUMNS);
        Set<String> confirmedBefore = baseline.confirmedNodes();
        List<NodeSnapshotRow> snapshotRows = nodeSnapshotRows(tree, availability);
        boolean structureChanged = upsertNodeSnapshots(analysisId, snapshotRows, baseline);
        int routeResets = structureChanged && !confirmedBefore.isEmpty()
                ? clearedConfirmations(analysisId, nodes, confirmedBefore) : 0;
        // 分配读写入后的路线；选用量用的路线若已被这次写入改掉，按写入后的路线再选一次用量，
        // 同一次刷新里需求与分配看同一条路线。结构与建议已写好，第二遍只改用量列，不会再清确认。
        if (usageRoutesChanged(nodes, tree.usageRoutes(), loadEffectiveRoutes(analysisId))) {
            tree = refreshTree(analysisId, true, typedOutputByMaterialLine, MaterialAnalysisIssuePreviewOverlay.NONE);
            nodes = tree.nodes();
            sources = tree.sources();
            snapshotRows = nodeSnapshotRows(tree, availability);
            upsertNodeSnapshots(analysisId, snapshotRows,
                    MaterialAnalysisSnapshotBaseline.load(em, analysisId, NODE_STRUCTURE_COLUMNS));
        }
        validateActiveBorrowEndpointsAfterRefresh(analysisId);
        AllocationSnapshot allocation = computeAllocationSnapshot(
                analysisId, header.warehouseId(), sources, nodes, availability, snapshotRows,
                typedOutputByMaterialLine, MaterialAnalysisIssuePreviewOverlay.NONE);
        if (allocation.hasBorrows()) {
            persistBorrowEffectiveQuantities(allocation.borrowEffective());
        }
        updateSourceReadiness(analysisId, allocation.sourceReadyRows());
        updateNodeAllocations(analysisId, allocation.nodeRows(), baseline);
        // Aggregate aliases terminate at BOM_COMPONENT descendants; aggregate anchors have no ROOT_SUPPLY.
        // Root refresh needs direct promises only, including original-root public claims.
        if (rootSupply != null) rootSupply.refreshRootNodes(analysisId,activeFutureCoverageByMaterial(analysisId,false));
        // 快照 (含顶层行) 写完之后、换指纹之前: 自动确认只看本次重算的结果, 版本只涨一次.
        int autoConfirmed = autoConfirmRoutes ? autoConfirmDecisiveRoutes(analysisId, sources) : 0;
        // 被清掉又在上面按货品档案马上重新确认的不算「需重新确认」: 刷新提示只数真要人补选的
        // (与以前页面补发 PUT /routes、套用新快照后这条提示随之消失的结果相同).
        if (autoConfirmed > 0 && routeResets > 0) routeResets = clearedConfirmations(analysisId, nodes, confirmedBefore);
        bumpFingerprint(analysisId);
        scheduleBomGapForwards(header);
        return new RefreshOutcome(routeResets, autoConfirmed);
    }

    // ---------- ADR-143 §二.3 委外件缺 BOM：标记、转研发、研发完善后自动刷新 ----------

    /**
     * 研发完善委外件 BOM 之后的系统刷新(由 {@link MaterialAnalysisBomRefreshService} 在独立事务里、
     * 以分析负责人身份调用)：与页面上其他重算入口同一把锁({@link #lockHeader})、同一套重算；
     * 分析已结束时什么都不做。新展开出的直属物料行的路线确认留给页面静默刷新(同其他顺带重算)。
     *
     * @return 是否真的刷新了(分析已结束或还没定主仓时为 false)
     */
    boolean refreshForBomUpdate(UUID analysisId) {
        tx.bind();
        AnalysisHeader header = lockHeader(analysisId);
        if (!isOpenForFulfillment(header) || header.warehouseId() == null) return false;
        refreshLocked(analysisId);
        return true;
    }

    private com.uten.imp.application.port.RdBomGapPort rdBomGapPort() {
        return rdBomGaps == null ? null : rdBomGaps.getIfAvailable();
    }

    /**
     * 真有需求的委外节点(别名 material，ADR-143 §二.3)：本节点仍有需求量，或已有未结的委外供给行动在供它。
     * 父件走外购 / 待定的子树里只是 BOM 展开出来的零需求节点永远不会下达委外，不标缺 BOM、也不转研发；
     * 真要下达时仍由 {@link #rejectSubcontractBomGaps} 按货品拦下。
     */
    private static final String SUBCONTRACT_DEMAND_NODE_SQL = """
            (material.required_qty > 0 OR EXISTS (
                SELECT 1
                FROM preplan_supply_action_allocations allocation
                JOIN preplan_supply_actions action ON action.id = allocation.action_id
                 AND action.route = 'SUBCONTRACT' AND action.operation_type = 'SUPPLY'
                 AND action.status IN ('OPEN','CREATED','IN_PROGRESS')
                WHERE allocation.analysis_material_id = material.id AND allocation.allocated_qty > 0))
            """;

    /** 这些货品里没有任何可发外直属物料的(唯一判定 fn_subcontract_draw_edges)。 */
    Set<UUID> subcontractGoodsWithoutBom(Collection<UUID> goodsIds) {
        if (goodsIds == null || goodsIds.isEmpty()) return Set.of();
        return new LinkedHashSet<>(NativeQueryResults.typedRows(em.createNativeQuery("""
                SELECT goods.id
                FROM goods
                WHERE goods.id IN (:goodsIds)
                  AND NOT EXISTS (SELECT 1 FROM fn_subcontract_draw_edges(goods.id))
                ORDER BY goods.id
                """).setParameter("goodsIds", List.copyOf(goodsIds)), UUID.class));
    }

    /**
     * 详情最后一步：路线是委外、真有需求({@link #SUBCONTRACT_DEMAND_NODE_SQL})、货品没有可发外直属物料的行
     * (任何层级，含顶层供给行与汇总成员)标「缺 BOM」，并带上该货品未完成的「完善 BOM」研发任务编号。
     */
    private List<MaterialView> withSubcontractBomGaps(UUID analysisId, List<MaterialView> materials) {
        Set<UUID> subcontractGoods = materials.stream().filter(MaterialView::subcontractRoute)
                .map(MaterialView::goodsId).filter(Objects::nonNull)
                .collect(Collectors.toCollection(LinkedHashSet::new));
        Set<UUID> missing = subcontractGoodsWithoutBom(subcontractGoods);
        if (missing.isEmpty()) return materials;
        List<UUID> candidates = materials.stream()
                .filter(row -> row.subcontractRoute() && missing.contains(row.goodsId()))
                .map(MaterialView::materialLineId).filter(Objects::nonNull).distinct().toList();
        Set<UUID> demand = candidates.isEmpty() ? Set.of() : new HashSet<>(NativeQueryResults.typedRows(
                em.createNativeQuery("""
                        SELECT material.id
                        FROM production_material_analysis_materials material
                        WHERE material.analysis_id = :analysisId AND material.id IN (:materialIds)
                          AND %s
                        """.formatted(SUBCONTRACT_DEMAND_NODE_SQL))
                        .setParameter("analysisId", analysisId).setParameter("materialIds", candidates), UUID.class));
        if (demand.isEmpty()) return materials;
        var port = rdBomGapPort();
        Map<UUID, String> taskNos = port == null ? Map.of() : port.openBomTaskNos(missing);
        return materials.stream()
                .map(row -> row.subcontractRoute() && missing.contains(row.goodsId())
                        && demand.contains(row.materialLineId())
                        ? row.withBomGap(true, taskNos.get(row.goodsId())) : row)
                .toList();
    }

    /**
     * 新建 / 刷新后发现缺 BOM 的委外节点：本事务提交后逐个货品转研发(分析负责人进等待名单，
     * 来源 = 本分析)。只看真有需求的节点({@link #SUBCONTRACT_DEMAND_NODE_SQL}；本方法在节点需求量写完后
     * 才调用)。负责人已在等待名单里的货品跳过；本事务回滚则不登记，下次刷新再来。
     */
    private void scheduleBomGapForwards(AnalysisHeader header) {
        var port = rdBomGapPort();
        if (port == null || header.makerId() == null) return;
        List<UUID> gaps = NativeQueryResults.typedRows(em.createNativeQuery("""
                SELECT subcontract.goods_id
                FROM (
                    SELECT DISTINCT material.goods_id
                    FROM production_material_analysis_materials material
                    WHERE material.analysis_id = :analysisId AND material.active = TRUE
                      AND COALESCE(material.confirmed_route, material.source_suggestion) = 'SUBCONTRACT'
                      AND %s
                ) subcontract
                WHERE NOT EXISTS (SELECT 1 FROM fn_subcontract_draw_edges(subcontract.goods_id))
                ORDER BY subcontract.goods_id
                """.formatted(SUBCONTRACT_DEMAND_NODE_SQL)).setParameter("analysisId", header.id()), UUID.class);
        if (gaps.isEmpty()) return;
        Set<UUID> pending = port.goodsAwaitingForward(gaps, header.makerId());
        if (pending.isEmpty()) return;
        port.forwardBomGapsAfterCommit(pending, com.uten.imp.application.port.RdBomGapPort.SOURCE_MATERIAL_ANALYSIS,
                header.id(), header.analysisNo(), bomGapReason(header), header.makerId());
    }

    private static String bomGapReason(AnalysisHeader header) {
        return "物料分析 " + Objects.toString(header.analysisNo(), "")
                + " 里的委外件还没有维护 BOM(直属物料)，计划不能下达委外";
    }

    /**
     * 这些要下达委外的行里，货品没有任何可发外直属物料的：货品 → 「名称(编号)」(按行出现顺序)。
     * 按货品现查，不看「缺 BOM」角标(角标只标真有需求的节点)，真要下达的行一律拦。
     */
    Map<UUID, String> subcontractBomGapLabels(Collection<MaterialView> rows) {
        Map<UUID, String> labels = new LinkedHashMap<>();
        for (MaterialView row : rows) {
            if (row != null && row.goodsId() != null) {
                labels.putIfAbsent(row.goodsId(), com.uten.imp.application.port.RdBomGapPort.goodsLabel(
                        row.goodsName(), row.goodsCode()));
            }
        }
        labels.keySet().retainAll(subcontractGoodsWithoutBom(labels.keySet()));
        return labels;
    }

    /**
     * 下达委外 / 汇总下单遇到缺 BOM 的委外行(调用方只传这次要按委外下达的行)：逐个货品转研发
     * (独立事务立即提交，随后的 409 不会撤销；当前操作人进等待名单)，再以 409 拒绝本次下达。
     * 没有缺 BOM 的货品时什么都不做。
     */
    void rejectSubcontractBomGaps(AnalysisHeader header, Collection<MaterialView> rows) {
        Map<UUID, String> labels = subcontractBomGapLabels(rows);
        if (labels.isEmpty()) return;
        var port = rdBomGapPort();
        if (port != null) {
            for (UUID goodsId : labels.keySet()) {
                port.forwardBomGap(goodsId, com.uten.imp.application.port.RdBomGapPort.SOURCE_MATERIAL_ANALYSIS,
                        header.id(), header.analysisNo(), bomGapReason(header));
            }
        }
        throw conflict(com.uten.imp.application.port.RdBomGapPort.subcontractBomMissingMessage(labels.values(), true));
    }

    /** 刷新前已确认、此刻却没有确认的节点数 (刷新提示「N 条路线因主档变更需重新确认」的 N). */
    private int clearedConfirmations(UUID analysisId, List<BomNode> nodes, Set<String> confirmedBefore) {
        Set<String> confirmedNow = confirmedRouteNodeKeys(analysisId);
        int cleared = 0;
        for (BomNode node : nodes) {
            String nodeRef = nodeRef(node.analysisItemId(), node.nodeKey());
            if (confirmedBefore.contains(nodeRef) && !confirmedNow.contains(nodeRef)) cleared++;
        }
        return cleared;
    }

    /**
     * 刷新的来源行与 BOM 树(第 1 层已按来源计划产出量展开)；[usageRoutes] 是选用量时读到的
     * 各节点有效路线(写入本次快照之前的库内值)。
     */
    private record RefreshTree(List<SourceLine> sources, Map<UUID, SourceLine> sourcesById, List<BomNode> nodes,
            Map<String, String> usageRoutes) {}

    /**
     * 选用量时看的路线与写入快照后的有效路线是否不同(ADR-129 §2.5)。子节点用量按父节点路线选，
     * 所以只看有子节点的节点；库里还没有的节点选用量时按现时建议，写入后仍是它。写入会刷新主档
     * 建议、事实变化会清掉人工确认，分配读的是写入后的路线，两者不同时须按写入后的路线再选一次。
     */
    static boolean usageRoutesChanged(List<BomNode> nodes, Map<String, String> usageRoutes,
            Map<String, String> routesAfterWrite) {
        for (BomNode node : nodes) {
            if (!node.hasChildren()) continue;
            String ref = nodeRef(node.analysisItemId(), node.nodeKey());
            if (!Objects.equals(usageRoutes.getOrDefault(ref, node.suggestion()), routesAfterWrite.get(ref))) {
                return true;
            }
        }
        return false;
    }

    /**
     * 刷新第一段(只读): 来源行、BOM 树、计划批次与第 1 层按「计划产出量」展开。
     * 真实刷新与下达预览共用; 预览把下达会写的事实经 [overlay] 叠进来。
     */
    private RefreshTree refreshTree(UUID analysisId, boolean lockSales,
            Map<UUID, BigDecimal> typedOutputByMaterialLine, MaterialAnalysisIssuePreviewOverlay overlay) {
        List<SourceLine> sources = loadSourceLines(analysisId, lockSales, overlay);
        // Existing fulfillment belongs to the admitted analysis snapshot. A later
        // sales amendment must not roll back a real receipt merely because new
        // planning now needs another finance review. Commands check admission
        // for their selected source lines before creating any new commitment.
        // 已有节点沿用快照锁定的用量，只按当前路线重新选择(ADR-129 §2.5)。
        BomUsageContext usageContext = bomUsageContext(analysisId);
        List<BomNode> nodes = loadBomTrees(sources, usageContext);
        Map<UUID, SourceLine> sourcesById = sources.stream()
                .collect(Collectors.toMap(SourceLine::analysisItemId, source -> source));
        Map<String,List<BigDecimal>> plannedBatches = plannedMaterialBatches(analysisId, overlay);
        // 层级表上「顶层供给行」那一行填的数量：第 1 层子件是按**来源行**展开的，
        // 不走 parentSupply，所以它要并到来源的计划产出量上(顶层委外件按 1500
        // 下达时，它的直属物料就要按 1500 备)。
        Map<UUID, BigDecimal> typedSourceOutput =
                typedSourceOutputs(analysisId, typedOutputByMaterialLine);
        Map<UUID,BigDecimal> rootAdoptedPending=new HashMap<>();
        for(Object[] row:NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT adopted.analysis_item_id,SUM(adopted.qty) FROM (
                    SELECT material.analysis_item_id,fn_preplan_make_public_claim_pending_qty(claim.id) AS qty
                    FROM preplan_make_public_claims claim JOIN production_material_analysis_materials material ON material.id=claim.target_material_id
                    WHERE claim.target_analysis_id=:analysisId AND material.node_role='ROOT_SUPPLY'
                    UNION ALL
                    SELECT material.analysis_item_id,
                        CASE WHEN fn_preplan_action_has_future_transfer(action.id) OR fn_preplan_action_has_shared_claim_history(action.id)
                            THEN fn_preplan_future_allocation_pending_qty(allocation.id)
                            WHEN action.operation_type='SHARED_FUTURE_CLAIM'
                            THEN fn_preplan_shared_allocation_pending_qty(allocation.id)
                            ELSE fn_preplan_future_allocation_pending_qty(allocation.id) END
                    FROM preplan_supply_action_allocations allocation
                    JOIN preplan_supply_actions action ON action.id=allocation.action_id
                    JOIN production_material_analysis_materials material ON material.id=allocation.analysis_material_id
                    WHERE action.analysis_id=:analysisId AND material.node_role='ROOT_SUPPLY'
                      AND action.operation_type IN('SHARED_FUTURE_CLAIM','FUTURE_TRANSFER')
                      AND action.status IN('OPEN','CREATED','IN_PROGRESS')
                ) adopted GROUP BY adopted.analysis_item_id
                """).setParameter("analysisId",analysisId)))rootAdoptedPending.put(uuid(row[0]),decimal(row[1]));
        overlay.rootPublicAdoption().forEach((id,qty)->rootAdoptedPending.merge(id,qty,BigDecimal::add));
        nodes = nodes.stream().map(node -> {
            BomNode batched = node.withOutputBatches(plannedBatches.getOrDefault(
                    node.analysisItemId()+"|"+Objects.toString(node.parentNodeKey(),""),List.of()));
            // 第 1 层按来源「计划产出量」展开（需求与已下达计划取大，ADR-099）。
            return node.depth()==1 ? batched.withSnapshotRequiredQty(batched.requiredForOutput(
                    plannedSourceOutput(sourcesById.get(node.analysisItemId()), typedSourceOutput,
                            rootAdoptedPending.getOrDefault(node.analysisItemId(),BigDecimal.ZERO),
                            overlay.rootPublicAdoption().getOrDefault(node.analysisItemId(),BigDecimal.ZERO))))
                    : batched;
        }).toList();
        validateExactPegRefreshCompatibility(analysisId, nodes);
        return new RefreshTree(sources, sourcesById, nodes, usageContext.routes());
    }

    /** 刷新第二段(纯计算): 每个节点的库存/在途/缺口初值。 */
    private List<NodeSnapshotRow> nodeSnapshotRows(RefreshTree tree, AvailabilitySnapshot availability) {
        List<NodeSnapshotRow> snapshotRows = new ArrayList<>(tree.nodes().size());
        for (BomNode node : tree.nodes()) {
            MaterialDimension key = node.dimension();
            StockValue stock = availability.stock().getOrDefault(key, StockValue.ZERO);
            SourceLine source = Optional.ofNullable(
                    tree.sourcesById().get(node.analysisItemId())).orElseThrow();
            InboundValue inbound = availability.inboundOnOrBefore(
                    key, source.deliveryDate());
            BigDecimal available = stock.availableAfterSafety(node.safetyStock());
            BigDecimal required = node.snapshotRequiredQty();
            BigDecimal shortage = required.subtract(available)
                    .max(BigDecimal.ZERO).setScale(4, RoundingMode.CEILING);
            // 初始快照与 computeAllocationSnapshot 权威口径一致：MAKE 与有子层的
            // SUBCONTRACT(领直属物料发外, ADR-143)都可能下层未齐；随后权威重算会覆盖本值。
            boolean lowerPending = node.hasChildren()
                    && ("MAKE".equals(node.suggestion())
                        || "SUBCONTRACT".equals(node.suggestion()))
                    && shortage.signum() > 0;
            snapshotRows.add(new NodeSnapshotRow(node, required, available,
                    stock.reserved(), inbound.qty(), shortage, inbound.expectedDate(),
                    lowerPending));
        }
        return snapshotRows;
    }

    private static String nodeRef(UUID analysisItemId, String nodeKey) {
        return analysisItemId + "|" + nodeKey;
    }

    /** 当前仍有人工确认路线的节点键（含未激活行；调用方只与本次树节点求交）。 */
    private Set<String> confirmedRouteNodeKeys(UUID analysisId) {
        List<Object[]> rows = NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT analysis_item_id, node_key
                FROM production_material_analysis_materials
                WHERE analysis_id = :analysisId AND confirmed_route IS NOT NULL
                """).setParameter("analysisId", analysisId));
        Set<String> keys = new HashSet<>();
        for (Object[] row : rows) keys.add(nodeRef(uuid(row[0]), string(row[1])));
        return keys;
    }

    /** 刷新初始快照的一行（权威分配随后由 computeAllocationSnapshot 覆盖）。 */
    private record NodeSnapshotRow(
            BomNode node, BigDecimal required, BigDecimal available, BigDecimal reserved,
            BigDecimal inbound, BigDecimal shortage, LocalDate expectedReadyDate,
            boolean lowerPending) {}

    /** 每块至多 500 行；快照通过一个明确字段类型的 JSON 参数传递。 */
    private static final int NODE_WRITE_CHUNK = 500;

    /**
     * 节点快照的一列：列名、JSON 输入类型、从节点取值，以及它是不是用量(ADR-129 §2.5)。
     * 用量列(含按所选用量逐层算出的单耗)变化照常写入，但不是结构：预览/下达/审批的守卫与
     * 路线确认重置都不看它。
     */
    record NodeColumn(String name, String type, java.util.function.Function<BomNode, Object> value, boolean usage) {}

    private static NodeColumn structure(String name, String type, java.util.function.Function<BomNode, Object> value) {
        return new NodeColumn(name, type, value, false);
    }

    private static NodeColumn usage(String name, String type, java.util.function.Function<BomNode, Object> value) {
        return new NodeColumn(name, type, value, true);
    }

    /** 节点快照列只在这里定义一次：刷新比较、写入过滤、upsert、JSON 输入与守卫都由它派生。 */
    private static final List<NodeColumn> NODE_COLUMNS = List.of(
            structure("parent_node_key", "varchar", BomNode::parentNodeKey),
            structure("bom_item_id", "uuid", BomNode::bomItemId),
            structure("goods_id", "uuid", BomNode::goodsId),
            structure("color_id", "uuid", BomNode::colorId),
            structure("unit_id", "uuid", BomNode::unitId),
            structure("depth", "integer", BomNode::depth),
            structure("path", "text", BomNode::path),
            usage("per_product_qty", "numeric", BomNode::perProductQty),
            structure("control_stage", "varchar", BomNode::controlStage),
            structure("consumption_basis", "varchar", BomNode::consumptionBasis),
            structure("basis_output_qty", "numeric", BomNode::basisOutputQty),
            structure("allow_partial_package", "boolean", BomNode::allowPartialPackage),
            structure("hard_gate", "boolean", BomNode::hardGate),
            usage("bom_qty", "numeric", BomNode::bomQty),
            usage("parent_per_product_qty", "numeric", BomNode::parentPerProductQty),
            structure("calculation_mode", "varchar", node -> "EDGE_RULE"),
            structure("source_suggestion", "varchar", BomNode::suggestion),
            structure("active", "boolean", node -> true),
            usage("design_bom_qty", "numeric", node -> node.usage().designQty()),
            usage("actual_bom_qty", "numeric", node -> node.usage().actualQty()),
            usage("usage_basis", "varchar", node -> node.usage().basis()),
            usage("usage_reason", "varchar", node -> node.usage().reason()),
            usage("usage_sample_count", "bigint", node -> node.usage().sampleCount()),
            usage("usage_defect_rate", "numeric", node -> node.usage().defectRate()));
    private static final List<String> NODE_STRUCTURE_COLUMNS = NODE_COLUMNS.stream().map(NodeColumn::name).toList();
    /** 守卫只比结构(ADR-129 §2.5)：预览「结构已变化」不再比任何用量。 */
    private static final List<NodeColumn> NODE_GUARD = NODE_COLUMNS.stream().filter(column -> !column.usage()).toList();
    /** 下达/审批「BOM 直接层已变更」：结构列加第一层单位换算率(第一层的父件单耗就是来源换算率)。 */
    private static final List<NodeColumn> DIRECT_BOM_SIGNATURE = java.util.stream.Stream.concat(NODE_GUARD.stream(),
            NODE_COLUMNS.stream().filter(column -> column.name().equals("parent_per_product_qty"))).toList();
    /** JSON 输入：身份列、{@link #NODE_COLUMNS}、刷新初值列，与 {@link #nodeSnapshotValues} 逐段对应。 */
    private static final MaterialSnapshotInput NODE_INPUT = new MaterialSnapshotInput(java.util.stream.Stream.of(
                    java.util.stream.Stream.of("id uuid", "analysis_id uuid", "analysis_item_id uuid", "node_key varchar"),
                    NODE_COLUMNS.stream().map(column -> column.name() + " " + column.type()),
                    java.util.stream.Stream.of("required_qty numeric", "available_qty numeric", "reserved_qty numeric",
                            "allocated_available_qty numeric", "safety_stock_qty numeric", "inbound_qty numeric",
                            "allocated_start_qty numeric", "allocated_finish_qty numeric", "allocated_ship_qty numeric",
                            "shortage_qty numeric", "expected_ready_date date", "lower_level_pending boolean",
                            "created_by uuid", "updated_by uuid"))
            .flatMap(columns -> columns).toArray(String[]::new));
    private static final List<String> NODE_INPUT_COLUMNS = NODE_INPUT.columns();

    private static String columnList(List<NodeColumn> columns) {
        return columns.stream().map(NodeColumn::name).collect(Collectors.joining(", "));
    }

    private static Object[] nodeValues(BomNode node, List<NodeColumn> columns) {
        return columns.stream().map(column -> column.value().apply(node)).toArray();
    }

    private static String nodeStructureComparison(String left, String right, boolean distinct) {
        String leftFields = NODE_STRUCTURE_COLUMNS.stream().map(column -> left + "." + column).collect(Collectors.joining(", "));
        String rightFields = NODE_STRUCTURE_COLUMNS.stream().map(column -> right + "." + column).collect(Collectors.joining(", "));
        return "(" + leftFields + ") IS " + (distinct ? "" : "NOT ") + "DISTINCT FROM (" + rightFields + ")";
    }

    /**
     * 节点 upsert「BOM 事实变更即清人工确认」条件，四个路线确认列共用。
     *
     * <p>2026-09-10（F8 前向批注）：旧快照的 REVIEW 建议升级为具体建议（如主档来源为空的
     * BOM 父件改按自制建议）不算事实变更，不清人工确认。
     *
     * <p><b>2026-09-16：主档来源（source_suggestion）整项移出本条件</b>，它的变化不再
     * 清掉人工确认。供应方式收口成货品主档单一事实源之后，确认路线本身会回写
     * {@code goods.source_type}，于是「主档来源变了」与「有人确认过路线」成了同一件事，
     * 这条判定就变成一个**跨分析的反馈环**：同一货品在 A 分析里被确认为自制，B 分析下
     * 一次刷新算出的建议随之变成自制，与 B 里已确认的采购不一致，B 的人工确认被静默
     * 清空，随后 issue-plans 报「候选物料节点不存在或路线未确认」。
     * （{@code PreplanReallocationMakeSupplementEndToEndTest} 的让料用例正踩在这里：
     * 让出方与借入方两份分析共用同一个货品、路线各不相同。）
     *
     * <p><b>2026-09-27(ADR-129)：单耗(per_product_qty)与 BOM 数量(bom_qty)也移出本条件</b>。
     * 节点用量现在按设计/真实使用数量与父节点路线逐节点选择：学习更新真实值、人工刷新采用新值、
     * 父节点改路线换用设计值，都只是用量变化，不是配方变了，不能作废人工确认的路线。
     *
     * <p>结构性事实(货品 / 颜色 / 单位 / 父节点 / 路径 / 控制段 / 计量规则)一条没删，
     * 真改了照旧清确认并计入 {@code routeResetCount}。
     */
    private static final String NODE_FACT_CHANGED_CONDITION = """
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
            """;

    private static String resetUnlessFactsUnchanged(String column) {
        return "CASE WHEN " + NODE_FACT_CHANGED_CONDITION
                + " THEN NULL ELSE production_material_analysis_materials." + column + " END";
    }

    private static final String NODE_UPSERT_ON_CONFLICT =
            "ON CONFLICT (analysis_item_id, node_key) DO UPDATE SET\n"
            + NODE_STRUCTURE_COLUMNS.stream().map(column -> "    " + column + " = EXCLUDED." + column + ",\n")
                    .collect(Collectors.joining())
            + "    confirmed_route = " + resetUnlessFactsUnchanged("confirmed_route") + ",\n"
            + "    route_reason = " + resetUnlessFactsUnchanged("route_reason") + ",\n"
            + "    route_confirmed_by = " + resetUnlessFactsUnchanged("route_confirmed_by") + ",\n"
            + "    route_confirmed_at = " + resetUnlessFactsUnchanged("route_confirmed_at") + ",\n"
            + "    updated_at = now(), updated_by = EXCLUDED.updated_by"
            + "\nWHERE " + nodeStructureComparison("production_material_analysis_materials", "EXCLUDED", true);

    private static final String NODE_UPSERT_SQL =
            "WITH incoming AS MATERIALIZED (SELECT * FROM " + NODE_INPUT.recordset("source") + ")\n"
            + "INSERT INTO production_material_analysis_materials (" + String.join(", ", NODE_INPUT_COLUMNS) + ")\n"
            + "SELECT " + NODE_INPUT.selection("incoming") + " FROM incoming WHERE NOT EXISTS (\n"
            + "SELECT 1 FROM production_material_analysis_materials existing\n"
            + "WHERE existing.analysis_item_id=incoming.analysis_item_id AND existing.node_key=incoming.node_key\n"
            + "AND " + nodeStructureComparison("existing", "incoming", false) + ")\n"
            + "ORDER BY incoming._position\n" + NODE_UPSERT_ON_CONFLICT;

    private static String nodeUpsertSql() { return NODE_UPSERT_SQL; }

    /** Same complete input row as the former VALUES form; exact numeric values never pass through double. */
    private static Object[] nodeSnapshotValues(UUID analysisId, UUID actorId, NodeSnapshotRow row) {
        BomNode node = row.node();
        return java.util.stream.Stream.of(
                new Object[] {UUID.randomUUID(), analysisId, node.analysisItemId(), node.nodeKey()},
                nodeStructure(node),
                new Object[] {row.required(), row.available(), row.reserved(), BigDecimal.ZERO,
                        node.safetyStock(), row.inbound(), BigDecimal.ZERO, BigDecimal.ZERO, BigDecimal.ZERO,
                        row.shortage(), row.expectedReadyDate(), row.lowerPending(), actorId, actorId})
                .flatMap(java.util.Arrays::stream).toArray();
    }

    /** 与 {@link #NODE_STRUCTURE_COLUMNS} 逐列对应的快照值。 */
    private static Object[] nodeStructure(BomNode node) {
        return nodeValues(node, NODE_COLUMNS);
    }

    private boolean upsertNodeSnapshots(UUID analysisId, List<NodeSnapshotRow> rows, MaterialAnalysisSnapshotBaseline baseline) {
        Map<String, NodeSnapshotRow> distinct = new LinkedHashMap<>();
        for (NodeSnapshotRow row : rows) {
            distinct.put(nodeRef(row.node().analysisItemId(), row.node().nodeKey()), row);
        }
        List<NodeSnapshotRow> ordered = distinct.values().stream().filter(row -> {
            BomNode node = row.node();
            return !baseline.unchangedStructure(node.analysisItemId(), node.nodeKey(), nodeStructure(node));
        }).toList();
        UUID actorId = currentUser.requireId();
        for (int from = 0; from < ordered.size(); from += NODE_WRITE_CHUNK) {
            List<NodeSnapshotRow> chunk = ordered.subList(from, Math.min(ordered.size(), from + NODE_WRITE_CHUNK));
            String snapshots = NODE_INPUT.json(chunk, row -> nodeSnapshotValues(analysisId, actorId, row));
            em.createNativeQuery(NODE_UPSERT_SQL).setParameter("snapshots", snapshots).executeUpdate();
        }
        return !ordered.isEmpty();
    }

    /**
     * 委外供给行动「订单结清」(ADR-143 §4.5)：申请已结案，来源订货明细都已无可收余量
     * (合格入库 + 已结损耗 >= 订货量)，且没有还在检验、待入库的回厂。别名 action。
     */
    private static final String SUBCONTRACT_ACTION_SETTLED_SQL = """
            (EXISTS (
                SELECT 1 FROM subcontract_applications application
                WHERE application.id = action.external_document_id
                  AND application.is_deleted = FALSE
                  AND application.status IN (0,1)
                  AND application.is_closed = TRUE)
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
                  AND fn_procurement_order_source_remaining_qty(
                      'SUBCONTRACT', order_item.id, src.application_item_id) > 0)
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
                 AND (inspection.status NOT IN ('RESOLVED','REVERSED')
                      OR (inspection.status <> 'REVERSED'
                          AND inspection.passed_base_qty > inspection.warehouse_stocked_base_qty))
                WHERE allocation.action_id = action.id))
            """;

    /** Reconcile actionable coverage from authoritative downstream lifecycle facts. */
    private void reconcileSupplyActionStatuses(UUID analysisId) {
        UUID actorId = currentUser.requireId();
        em.createNativeQuery("""
                UPDATE preplan_supply_actions action
                SET status = 'CANCELLED', cancelled_by = :actorId,
                    cancelled_at = now(),
                    cancellation_reason = '下游单据已删除、红冲或中止，刷新物料分析时自动失效',
                    updated_at = now()
                WHERE action.analysis_id = :analysisId AND NOT fn_preplan_action_has_future_transfer(action.id) AND NOT fn_preplan_action_has_shared_claims(action.id) AND action.operation_type<>'SHARED_FUTURE_CLAIM'
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
                          AND (child.source_type = 'MAKE_COMPONENT' OR
                            (child.source_type='AGGREGATE_MAKE' AND EXISTS(SELECT 1 FROM preplan_aggregate_batches shared
                              WHERE shared.action_id=action.id AND shared.anchor_analysis_item_id=child.id AND shared.analysis_id=action.analysis_id)))
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
                  AND action.analysis_id = :analysisId AND NOT fn_preplan_action_has_future_transfer(action.id) AND NOT fn_preplan_action_has_shared_claims(action.id) AND action.operation_type<>'SHARED_FUTURE_CLAIM'
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
                WHERE action.analysis_id = :analysisId AND NOT fn_preplan_action_has_future_transfer(action.id) AND NOT fn_preplan_action_has_shared_claims(action.id) AND action.operation_type<>'SHARED_FUTURE_CLAIM'
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
                        AND fn_procurement_order_source_remaining_qty(
                            'PURCHASE', order_item.id, src.request_item_id) > 0)
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
                WHERE action.analysis_id = :analysisId AND NOT fn_preplan_action_has_future_transfer(action.id) AND NOT fn_preplan_action_has_shared_claims(action.id) AND action.operation_type<>'SHARED_FUTURE_CLAIM'
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
                        AND fn_procurement_order_source_remaining_qty(
                            'SUBCONTRACT', order_item.id, src.application_item_id) > 0)
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
                  AND action.analysis_id = :analysisId AND NOT fn_preplan_action_has_future_transfer(action.id) AND action.operation_type<>'SHARED_FUTURE_CLAIM'
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
                WHERE action.analysis_id = :analysisId AND NOT fn_preplan_action_has_future_transfer(action.id) AND action.operation_type<>'SHARED_FUTURE_CLAIM'
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
                WHERE action.analysis_id = :analysisId AND NOT fn_preplan_action_has_future_transfer(action.id) AND action.operation_type<>'SHARED_FUTURE_CLAIM'
                  AND action.status IN ('CREATED','DONE')
                  AND action.external_document_type = 'SUBCONTRACT_APPLICATION'
                  -- ADR-143 §4.5：申请量 + 公共超量都合格入库才算完成；订单结清另算完成。
                  AND action.requested_qty + action.public_surplus_qty > (
                """ + SubcontractComponentCustodyProjection.ACTION_STOCKED_BASE_SQL + """
                  )
                  AND NOT
                """ + SUBCONTRACT_ACTION_SETTLED_SQL + """
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
                WHERE action.analysis_id = :analysisId AND NOT fn_preplan_action_has_future_transfer(action.id) AND action.operation_type<>'SHARED_FUTURE_CLAIM'
                  AND action.status IN ('CREATED','DONE')
                  AND action.external_document_type = 'PREPLAN_MAKE_TASK'
                  AND EXISTS (
                      SELECT 1
                      FROM production_material_analysis_items child
                      WHERE child.id = action.external_document_id
                        AND child.analysis_id = action.analysis_id
                        AND (child.source_type = 'MAKE_COMPONENT' OR
                            (child.source_type='AGGREGATE_MAKE' AND EXISTS(SELECT 1 FROM preplan_aggregate_batches batch
                              WHERE batch.anchor_analysis_item_id=child.id AND batch.action_id=action.id AND batch.analysis_id=action.analysis_id)))
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
                  AND action.analysis_id = :analysisId AND NOT fn_preplan_action_has_future_transfer(action.id) AND action.operation_type<>'SHARED_FUTURE_CLAIM'
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
                WHERE action.analysis_id = :analysisId AND NOT fn_preplan_action_has_future_transfer(action.id) AND action.operation_type<>'SHARED_FUTURE_CLAIM'
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
                WHERE action.analysis_id = :analysisId AND NOT fn_preplan_action_has_future_transfer(action.id) AND action.operation_type<>'SHARED_FUTURE_CLAIM'
                  AND action.status IN ('CREATED','IN_PROGRESS')
                  AND action.external_document_type = 'SUBCONTRACT_APPLICATION'
                  -- ADR-143 §4.5：申请量 + 公共超量 <= 合格入库回厂量，或订单结清。
                  AND (action.requested_qty + action.public_surplus_qty <= (
                """ + SubcontractComponentCustodyProjection.ACTION_STOCKED_BASE_SQL + """
                  )
                    OR
                """ + SUBCONTRACT_ACTION_SETTLED_SQL + """
                  )
                """).setParameter("analysisId", analysisId).executeUpdate();

        em.createNativeQuery("""
                UPDATE preplan_supply_actions action
                SET status = 'DONE', updated_at = now()
                WHERE action.analysis_id = :analysisId AND NOT fn_preplan_action_has_future_transfer(action.id) AND action.operation_type<>'SHARED_FUTURE_CLAIM'
                  AND action.status IN ('CREATED','IN_PROGRESS')
                  AND action.external_document_type = 'PREPLAN_MAKE_TASK'
                  AND EXISTS (
                      SELECT 1
                      FROM production_material_analysis_items child
                      WHERE child.id = action.external_document_id
                        AND child.analysis_id = action.analysis_id
                        AND (child.source_type = 'MAKE_COMPONENT' OR
                            (child.source_type='AGGREGATE_MAKE' AND EXISTS(SELECT 1 FROM preplan_aggregate_batches batch
                              WHERE batch.anchor_analysis_item_id=child.id AND batch.action_id=action.id AND batch.analysis_id=action.analysis_id)))
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
        em.createNativeQuery("""
                UPDATE preplan_supply_actions action
                SET status=CASE WHEN action.operation_type='FUTURE_TRANSFER' AND fn_preplan_action_admitted_qty(action.id)=0 THEN 'CANCELLED'
                    WHEN fn_preplan_action_received_qty(action.id)>=fn_preplan_action_admitted_qty(action.id) THEN 'DONE'
                    ELSE 'IN_PROGRESS' END,
                    cancelled_by=CASE WHEN action.operation_type='FUTURE_TRANSFER' AND fn_preplan_action_admitted_qty(action.id)=0 THEN :actor ELSE cancelled_by END,
                    cancelled_at=CASE WHEN action.operation_type='FUTURE_TRANSFER' AND fn_preplan_action_admitted_qty(action.id)=0 THEN now() ELSE cancelled_at END,
                    cancellation_reason=CASE WHEN action.operation_type='FUTURE_TRANSFER' AND fn_preplan_action_admitted_qty(action.id)=0 THEN '未实收在途份额已撤销' ELSE cancellation_reason END
                WHERE action.analysis_id=:analysis AND action.status<>'CANCELLED'
                  AND (fn_preplan_action_has_future_transfer(action.id) OR action.operation_type='SHARED_FUTURE_CLAIM')
                  AND action.status IS DISTINCT FROM (CASE
                    WHEN action.operation_type='FUTURE_TRANSFER' AND fn_preplan_action_admitted_qty(action.id)=0 THEN 'CANCELLED'
                    WHEN fn_preplan_action_received_qty(action.id)>=fn_preplan_action_admitted_qty(action.id) THEN 'DONE'
                    ELSE 'IN_PROGRESS' END)
                """).setParameter("analysis",analysisId).setParameter("actor",actorId).executeUpdate();
    }

    /**
     * Persists the single authoritative pre-plan allocation snapshot.
     *
     * <p>Existing production hard commitments are reserved first. Current production kits are
     * allocated next and additional START capacity last. SHIP/REFERENCE rows are warning-only
     * and cannot reserve this pool, so every actionable depth-one readiness projection and
     * production hard-gate allocation uses one conserved pool.</p>
     */
    private AllocationSnapshot computeAllocationSnapshot(
            UUID analysisId,
            UUID warehouseId,
            List<SourceLine> sources,
            List<BomNode> nodes,
            AvailabilitySnapshot availability,
            List<NodeSnapshotRow> inputs,
            Map<UUID, BigDecimal> typedOutputByMaterialLine,
            MaterialAnalysisIssuePreviewOverlay overlay) {
        Map<String, NodeSnapshotRow> inputsByNode = inputs.stream().collect(Collectors.toMap(
                row -> nodeAllocationKey(row.node()), row -> row));
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
        // 子层展开基准的输入：父件已被外部最终件在途覆盖的量，以及父件已经
        // 承诺由我方制造的量。两条语句都按 analysis_id 一次取回。
        Map<String, ParentSupplyCommitment> parentSupply = withTypedOutput(
                analysisId, parentSupplyCommitments(analysisId, overlay,hasAggregateSources(sources)), typedOutputByMaterialLine, overlay);
        // V307 精确到货归属：先在扣除安全库存后的真实可分配池内，为原供应
        // 分摊行锁定 secured coverage；同分析兄弟产品只能看到扣除后的共享池。
        // 没有 exact 子账的历史 V298 预留仍留在共享池，维持兼容语义。
        List<ExactPegRecord> exactPegs = loadExactPegs(analysisId, warehouseId).stream().map(peg ->
                new ExactPegRecord(peg.id(),peg.beneficiaryMaterialId(),peg.analysisItemId(),peg.nodeKey(),peg.dimension(),
                        peg.effectiveQty().subtract(overlay.transferredEntitlement(peg.id())).max(BigDecimal.ZERO),peg.warehouseId()))
                .filter(peg -> peg.effectiveQty().signum()>0).toList();
        BorrowTuning exactTuning = planExactPegs(exactPegs, nodes, stockAfterSafety,
                availability.usableByWarehouse())
                .combinedWith(planFormalCoverage(
                        previewFormalCoverage(formalMaterialCoverage(analysisId, warehouseId), overlay), nodes))
                .combinedWith(planFormalCoverage(
                        subcontractChildCoverage(analysisId), nodes));
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
                    parentSupply, exactTuning.fresh());
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
                parentSupply, tuning);
        NestedDiagnosticPlan nestedDiagnostic = projection.nestedDiagnostic();
        nodes = projection.nodes();
        StagePlan stagePlan = projection.stagePlan();
        StageAllocation finishAllocation = stagePlan.finish();
        StageExtension shipAllocation = stagePlan.ship();
        StageExtension startAllocation = stagePlan.start();
        TimePhasedPool readyByPool = new TimePhasedPool(
                finishAllocation.remainingPool(), availability.inbound());
        List<SourceReadyRow> sourceReadyRows = new ArrayList<>(sources.size());
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
            sourceReadyRows.add(new SourceReadyRow(source.analysisItemId(), source.unplannedReadyQty(readyStart),
                    source.unplannedReadyQty(readyFinish), source.unplannedReadyQty(readyShip), source.unplannedReadyQty(readyByDate)));
        }

        Map<String, NodeAllocation> hardAllocations = projection.hardAllocations();
        Map<String, NodeAllocation> allocations = projection.allocations();

        // 2026-09-10 性能：逐节点单行 UPDATE 改为 UPDATE … FROM (VALUES …) 分块一条语句。
        List<NodeAllocationRow> allocationRows = new ArrayList<>(nodes.size());
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
            // 有子层级的委外件与自制同构(ADR-143：委外只领直属物料)——下层未齐套时
            // lower_level_pending=TRUE。ADR-071 之后计划侧不再有任何齐套门禁，这个标记
            // 只是给计划员看的诊断信号，不阻断「下达委外/下达车间」。
            String effectiveRoute = effectiveRoutes.getOrDefault(
                    nodeKey, node.suggestion());
            boolean lowerPending = node.hasChildren()
                    && ("MAKE".equals(effectiveRoute)
                        || "SUBCONTRACT".equals(effectiveRoute))
                    && !delegatedMakeNodes.contains(nodeKey)
                    && !STAGE_REFERENCE.equals(node.controlStage())
                    && nestedDiagnostic.hasUncoveredDirectChild(node);
            NodeSnapshotRow input = inputsByNode.get(nodeKey);
            allocationRows.add(new NodeAllocationRow(
                    node.analysisItemId(), node.nodeKey(), node.snapshotRequiredQty(),
                    allocation.allocatedQty(), startAllocated, finishAllocated, shipAllocated,
                    allocation.shortageQty(), lowerPending, input.available(), input.reserved(),
                    node.safetyStock(), input.inbound(), input.expectedReadyDate()));
        }
        return new AllocationSnapshot(sourceReadyRows, allocationRows, !borrows.isEmpty(), borrowEffective);
    }

    /**
     * 权威分配快照(纯计算结果): 真实刷新据此写回来源齐套列、物料行数量列与借用生效量;
     * 下达预览(ADR-116)只把它叠进内存视图, 一行不写。
     */
    private record AllocationSnapshot(List<SourceReadyRow> sourceReadyRows, List<NodeAllocationRow> nodeRows,
                                      boolean hasBorrows, Map<UUID, BigDecimal> borrowEffective) {}

    /** 权威分配快照写回的一行（按 analysis_item_id + node_key 定位活动节点）。 */
    private record SourceReadyRow(UUID sourceId, BigDecimal start, BigDecimal finish, BigDecimal ship, BigDecimal byDate) {}

    /** Pool consumption above remains ordered; persistence has no per-source read dependency. */
    private void updateSourceReadiness(UUID analysisId, List<SourceReadyRow> rows) {
        UUID actorId = currentUser.requireId();
        for (int from=0; from<rows.size(); from+=NODE_WRITE_CHUNK) {
            List<SourceReadyRow> chunk=rows.subList(from,Math.min(rows.size(),from+NODE_WRITE_CHUNK));
            StringBuilder values=new StringBuilder();
            for (int index=0; index<chunk.size(); index++) {
                if(index>0) values.append(",");
                values.append("(CAST(:analysisId AS uuid),CAST(:source").append(index).append(" AS uuid),CAST(:start").append(index)
                        .append(" AS numeric),CAST(:finish").append(index).append(" AS numeric),CAST(:ship").append(index)
                        .append(" AS numeric),CAST(:byDate").append(index).append(" AS numeric))");
            }
            Query query=em.createNativeQuery("""
                    UPDATE production_material_analysis_items source
                    SET ready_now_qty=snapshot.finish,ready_start_qty=snapshot.start,
                        ready_finish_qty=snapshot.finish,ready_ship_qty=snapshot.ship,ready_by_date_qty=snapshot.by_date,
                        updated_at=now(),updated_by=:actorId
                    FROM (VALUES
                    """+values+"""
                    ) snapshot(analysis_id,source_id,start,finish,ship,by_date)
                    WHERE source.id=snapshot.source_id AND source.analysis_id=snapshot.analysis_id AND source.is_deleted=FALSE
                    """).setParameter("analysisId",analysisId).setParameter("actorId",actorId);
            for(int index=0;index<chunk.size();index++) {
                SourceReadyRow row=chunk.get(index);
                query.setParameter("source"+index,row.sourceId()).setParameter("start"+index,row.start())
                        .setParameter("finish"+index,row.finish()).setParameter("ship"+index,row.ship()).setParameter("byDate"+index,row.byDate());
            }
            query.executeUpdate();
        }
    }

    private record NodeAllocationRow(
            UUID analysisItemId, String nodeKey, BigDecimal required, BigDecimal allocated,
            BigDecimal allocatedStart, BigDecimal allocatedFinish, BigDecimal allocatedShip,
            BigDecimal shortage, boolean lowerPending,
            BigDecimal available, BigDecimal reserved, BigDecimal safety,
            BigDecimal inbound, LocalDate expectedReadyDate) {}

    /**
     * Writes a bounded allocation block with explicit PostgreSQL value types.
     * Equal projections need no second physical UPDATE after the initial upsert;
     * identity/endpoint guards still run for that upsert, and the analysis header
     * records refresh time. Every changed quantity or pending flag is written.
     * The complete identity belongs to each input row: a newly inserted analysis
     * is not yet present in planner statistics, so a separate analysis-id constant
     * can incorrectly select a scan of the entire analysis for every block.
     */
    private static final MaterialSnapshotInput NODE_ALLOCATION_INPUT = new MaterialSnapshotInput(
            "analysis_id uuid", "analysis_item_id uuid", "node_key varchar", "required_qty numeric", "allocated_qty numeric",
            "allocated_start_qty numeric", "allocated_finish_qty numeric", "allocated_ship_qty numeric",
            "shortage_qty numeric", "lower_level_pending boolean", "available_qty numeric", "reserved_qty numeric",
            "safety_stock_qty numeric", "inbound_qty numeric", "expected_ready_date date");

    private static final String NODE_ALLOCATION_UPDATE_SQL = """
            UPDATE production_material_analysis_materials AS material
            SET required_qty = snapshot.required_qty,
                allocated_available_qty = snapshot.allocated_qty,
                allocated_start_qty = snapshot.allocated_start_qty,
                allocated_finish_qty = snapshot.allocated_finish_qty,
                allocated_ship_qty = snapshot.allocated_ship_qty,
                shortage_qty = snapshot.shortage_qty,
                lower_level_pending = snapshot.lower_level_pending,
                available_qty = snapshot.available_qty,
                reserved_qty = snapshot.reserved_qty,
                safety_stock_qty = snapshot.safety_stock_qty,
                inbound_qty = snapshot.inbound_qty,
                expected_ready_date = snapshot.expected_ready_date,
                updated_at = now(), updated_by = :actorId
            FROM
            """ + NODE_ALLOCATION_INPUT.recordset("snapshot") + "\n" + """
            WHERE material.analysis_id = snapshot.analysis_id
              AND material.analysis_item_id = snapshot.analysis_item_id
              AND material.node_key = snapshot.node_key
              AND material.active = TRUE
              AND (material.required_qty, material.allocated_available_qty,
                   material.allocated_start_qty, material.allocated_finish_qty,
                   material.allocated_ship_qty, material.shortage_qty,
                   material.lower_level_pending, material.available_qty,
                   material.reserved_qty, material.safety_stock_qty,
                   material.inbound_qty, material.expected_ready_date)
                  IS DISTINCT FROM
                  (snapshot.required_qty, snapshot.allocated_qty,
                   snapshot.allocated_start_qty, snapshot.allocated_finish_qty,
                   snapshot.allocated_ship_qty, snapshot.shortage_qty,
                   snapshot.lower_level_pending, snapshot.available_qty,
                   snapshot.reserved_qty, snapshot.safety_stock_qty,
                   snapshot.inbound_qty, snapshot.expected_ready_date)
            """;

    private void updateNodeAllocations(UUID analysisId, List<NodeAllocationRow> rows, MaterialAnalysisSnapshotBaseline baseline) {
        rows = rows.stream().filter(row -> !baseline.unchangedAllocation(row.analysisItemId(), row.nodeKey(), new Object[] {
                row.required(), row.allocated(), row.allocatedStart(), row.allocatedFinish(), row.allocatedShip(), row.shortage(),
                row.lowerPending(), row.available(), row.reserved(), row.safety(), row.inbound(), row.expectedReadyDate()})).toList();
        UUID actorId = currentUser.requireId();
        for (int from = 0; from < rows.size(); from += NODE_WRITE_CHUNK) {
            List<NodeAllocationRow> chunk = rows.subList(from, Math.min(rows.size(), from + NODE_WRITE_CHUNK));
            String snapshots = NODE_ALLOCATION_INPUT.json(chunk, row -> new Object[] {
                    analysisId, row.analysisItemId(), row.nodeKey(), row.required(), row.allocated(),
                    row.allocatedStart(), row.allocatedFinish(), row.allocatedShip(), row.shortage(), row.lowerPending(),
                    row.available(), row.reserved(), row.safety(), row.inbound(), row.expectedReadyDate()
            });
            em.createNativeQuery(NODE_ALLOCATION_UPDATE_SQL)
                    .setParameter("actorId", actorId).setParameter("snapshots", snapshots).executeUpdate();
        }
    }

    /**
     * fn_warehouse_same_main(x, :warehouseId) 的集合形式, 放进 WITH 每条语句只算一次:
     * 本仓 + 本仓所属主仓及其全部未删后代(fn_warehouse_main_id 沿未删上级找到顶层仓,
     * fn_warehouse_scope_ids 再沿未删下级展开, 正好是主仓相同的那些仓)。
     * 预留、分析这类大表用 {@code IN (SELECT id FROM same_main_warehouses)} 过滤, 不要逐行调用
     * fn_warehouse_same_main——它每行递归找两次主仓, 放在相关子查询或嵌套循环里就是
     * 「外层行数 x 全部预留行数」次递归, 预留一多单条语句就几十秒(2026-10-06 CI 物料分析刷新超时)。
     */
    static final String SAME_MAIN_WAREHOUSES_CTE = """
            same_main_warehouses AS MATERIALIZED (
                SELECT CAST(:warehouseId AS uuid) AS id
                UNION
                SELECT unnest(fn_warehouse_scope_ids(
                    ARRAY[fn_warehouse_main_id(CAST(:warehouseId AS uuid))]))
            )""";

    /**
     * Cross-analysis soft commitments come from other analyses' batch snapshots.
     * Draft-plan quantities are already included in those snapshots. Formal
     * reservations and issued quantities are netted out because neither belongs
     * to the public pool exposed by {@code v_stock_available}.
     * V298：其它分析已收货绑定的量（owner_type='PREPLAN_ANALYSIS' 生效预留）已被
     * {@code v_stock_available} 物理扣除，其快照承诺须按绑定量净额扣除，避免重复扣减。
     * 同主仓范围见 {@link #SAME_MAIN_WAREHOUSES_CTE}; 正式预留经 demand_id 索引按需求取。
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
                WITH %s,
                raw_commitments AS (
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
                    WHERE analysis.warehouse_id IN (SELECT id FROM same_main_warehouses)
                      AND analysis.id <> :analysisId
                      AND analysis.is_deleted = FALSE
                      AND analysis.status IN ('ACTIVE','PARTIALLY_PLANNED')
                      AND material.active = TRUE AND material.depth = 1
                      AND material.hard_gate = TRUE
                      AND material.control_stage IN (:includedStages)
                      AND material.goods_id IN (SELECT unnest(CAST(string_to_array(:goodsIds, ',') AS uuid[])))
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
                               FROM production_plans plan
                               JOIN production_material_demands demand
                                 ON demand.plan_id=plan.id AND demand.is_deleted=FALSE
                                 AND demand.status NOT IN ('RELEASED','REVERSED')
                               -- 生产物料预留的 owner_id 恒等于 demand_id(owner_shape CHECK), 按 demand_id 索引取
                               JOIN stock_reservations formal
                                 ON formal.owner_type='PRODUCTION_MATERIAL_DEMAND'
                                 AND formal.demand_id=demand.id
                               WHERE plan.material_analysis_id=c.claim_analysis_id
                                 AND plan.status=1 AND plan.is_deleted=FALSE
                                 AND plan.is_canceled=FALSE
                                 AND formal.is_deleted=FALSE
                                 AND formal.warehouse_id IN (SELECT id FROM same_main_warehouses)
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
                                 AND r.warehouse_id IN (SELECT id FROM same_main_warehouses)
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
                """.formatted(SAME_MAIN_WAREHOUSES_CTE)).setParameter("analysisId", analysisId)
                .setParameter("warehouseId", warehouseId)
                .setParameter("includedStages", effectiveStages)
                .setParameter("goodsIds", uuidArrayText(goodsIds)));
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
        return requiredQty.max(BigDecimal.ZERO)
                .subtract(allocatedAvailableQty.max(BigDecimal.ZERO)
                        .max(exactPeggedQty.max(BigDecimal.ZERO)))
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
        // A MAKE child plan's picked inputs cover the original tree until its
        // output is finished. Subcontract draws are covered per child by
        // subcontractChildCoverage (ADR-143 §4.5), not through plan demands.
        List<Object[]> rows = NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                WITH %s
                SELECT demand.id, material.analysis_item_id, material.node_key,
                       SUM(GREATEST(reservation.qty-reservation.released_qty,0))::numeric,
                       CASE WHEN source.source_type IN ('MAKE_COMPONENT','AGGREGATE_MAKE')
                         THEN GREATEST(COALESCE(segment.planned_qty,plan_item.qty)
                           - CASE WHEN segment.id IS NULL THEN COALESCE(plan_item.iqty,0)
                               ELSE COALESCE(finished.qty,0) END,0)
                           * COALESCE(segment.product_unit_rate,plan_item.unit_rate,1)
                         ELSE NULL END
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
                -- 生产物料预留的 owner_id 恒等于 demand_id(owner_shape CHECK), 按 demand_id 索引取
                JOIN stock_reservations reservation
                  ON reservation.owner_type='PRODUCTION_MATERIAL_DEMAND'
                  AND reservation.demand_id=demand.id AND reservation.is_deleted=FALSE
                  AND (reservation.warehouse_id IN (SELECT id FROM same_main_warehouses)
                       OR reservation.requires_qualified_origin)
                JOIN production_material_analysis_materials material
                  ON material.analysis_id=:analysisId AND material.active=TRUE
                  AND fn_analysis_plan_material_matches(plan.material_analysis_item_id,material.id)
                  AND material.goods_id=demand.goods_id
                  AND material.color_id IS NOT DISTINCT FROM demand.color_id
                  AND material.unit_id=demand.unit_id
                WHERE demand.is_deleted=FALSE AND demand.status NOT IN ('RELEASED','REVERSED')
                GROUP BY demand.id,material.analysis_item_id,material.node_key,material.path,
                         source.id,source.source_type,segment.id,segment.planned_qty,segment.product_unit_rate,
                         plan_item.qty,plan_item.iqty,plan_item.unit_rate,finished.qty
                ORDER BY demand.id,material.path,material.node_key
                """.formatted(SAME_MAIN_WAREHOUSES_CTE)).setParameter("analysisId", analysisId)
                .setParameter("warehouseId", warehouseId));
        return rows.stream().map(row -> new FormalMaterialCoverage(uuid(row[0]),uuid(row[1]),string(row[2]),
                decimal(row[3]),row[4]==null ? null : decimal(row[4]))).toList();
    }

    private static List<FormalMaterialCoverage> previewFormalCoverage(List<FormalMaterialCoverage> existing,
            MaterialAnalysisIssuePreviewOverlay overlay) {
        if (!overlay.hasFormalProjection()) return existing;
        Map<String,FormalMaterialCoverage> combined = new LinkedHashMap<>();
        for (FormalMaterialCoverage row : existing) {
            BigDecimal output=overlay.formalParentOutput(row.demandId());
            combined.put(row.demandId()+"|"+row.analysisItemId()+"|"+row.nodeKey(),output==null?row:
                    new FormalMaterialCoverage(row.demandId(),row.analysisItemId(),row.nodeKey(),row.coveredQty(),output));
        }
        for (FormalMaterialCoverage row : overlay.formalCoverage()) combined.merge(
                row.demandId()+"|"+row.analysisItemId()+"|"+row.nodeKey(),row,(old,added)->new FormalMaterialCoverage(
                        old.demandId(),old.analysisItemId(),old.nodeKey(),old.coveredQty().add(added.coveredQty()),
                        added.remainingParentOutputQty()==null?old.remainingParentOutputQty():added.remainingParentOutputQty()));
        return List.copyOf(combined.values());
    }

    /**
     * 委外领料对直属物料的逐种覆盖(ADR-143 §4.5)：草稿 + 已发净量 − f_i(合格入库回厂量)，
     * 由 {@link SubcontractComponentCustodyProjection#coverageForAnalysis} 按来源归属分到各物料节点，
     * 再以 P 尚未回厂的计划产出 U_n 对应的物料需求封顶(与车间领料同一套正式覆盖规则)。
     * 每行是一个物料节点的一份归属，行自带唯一的覆盖编号，同节点多行按各自 U_n 封顶。
     */
    private List<FormalMaterialCoverage> subcontractChildCoverage(UUID analysisId) {
        List<FormalMaterialCoverage> result = new ArrayList<>();
        for (SubcontractComponentCustodyProjection.ChildCoverage row
                : SubcontractComponentCustodyProjection.coverageForAnalysis(em, analysisId)) {
            if (row.netQty() == null || row.netQty().signum() <= 0) continue;
            result.add(new FormalMaterialCoverage(UUID.randomUUID(), row.analysisItemId(), row.childNodeKey(),
                    row.netQty(), row.remainingParentOutputQty() == null
                            ? BigDecimal.ZERO : row.remainingParentOutputQty().max(BigDecimal.ZERO)));
        }
        return List.copyOf(result);
    }

    /**
     * [overlay] 非空时(下达预览, ADR-116): 本批新计划追加在各自键的末尾(计划按建立时间
     * 排序), ADR-104 并入既有计划的追加量加在那张计划的第一段上(与 growSegment 取最小段号
     * 同口径)——与真实下达后重读本查询的结果一致。
     */
    private Map<String,List<BigDecimal>> plannedMaterialBatches(
            UUID analysisId, MaterialAnalysisIssuePreviewOverlay overlay) {
        record Batch(String key, UUID planId, BigDecimal qty) {}
        List<Batch> batches = new ArrayList<>();
        for (Object[] row : NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT COALESCE(parent.analysis_item_id,source.id),
                       CASE WHEN parent.node_role='ROOT_SUPPLY' THEN NULL ELSE parent.node_key END,
                       CASE WHEN source.source_type IN ('MAKE_COMPONENT','AGGREGATE_MAKE')
                         THEN GREATEST(COALESCE(segment.planned_qty,item.qty)
                           -COALESCE(finished.qty,item.iqty,0),0)
                         ELSE COALESCE(segment.planned_qty,item.qty) END * COALESCE(item.unit_rate,1),
                       plan.id
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
            batches.add(new Batch(uuid(row[0])+"|"+Objects.toString(row[1],""), uuid(row[3]), decimal(row[2])));
        }
        if (!overlay.isNone()) {
            Map<UUID, Integer> firstBatchOfPlan = new HashMap<>();
            for (int index = 0; index < batches.size(); index++) firstBatchOfPlan.putIfAbsent(batches.get(index).planId(), index);
            firstBatchOfPlan.forEach((planId, index) -> {
                BigDecimal grown = overlay.grownPlanBatch(planId);
                if (grown == null) return;
                Batch batch = batches.get(index);
                batches.set(index, new Batch(batch.key(), planId, batch.qty().add(grown)));
            });
            overlay.appendedBatches().forEach((key, appended) ->
                    appended.forEach(qty -> batches.add(new Batch(key, null, qty))));
        }
        Map<String,List<BigDecimal>> result = new LinkedHashMap<>();
        for (Batch batch : batches) {
            if (batch.qty().signum()>0) result.computeIfAbsent(batch.key(), ignored -> new ArrayList<>()).add(batch.qty());
        }
        return Map.copyOf(result);
    }

    /** A formal reservation or issued material covers only its original batch. */
    private record FormalCoverageRule(BigDecimal requiredQty,java.util.function.Function<BigDecimal,BigDecimal> requirement) { }

    static BorrowTuning planFormalCoverage(List<FormalMaterialCoverage> coverage,List<BomNode> nodes) {
        Map<String,FormalCoverageRule> rules=nodes.stream().collect(Collectors.toMap(MaterialAnalysisService::nodeAllocationKey,
                node->new FormalCoverageRule(node.snapshotRequiredQty(),node::requiredForSingleParentOutput)));
        return BorrowTuning.securedOnly(formalCoverageQuantities(coverage,rules),Map.of());
    }

    private static Map<String,BigDecimal> formalCoverageQuantities(List<FormalMaterialCoverage> coverage,Map<String,FormalCoverageRule> rules) {
        Map<UUID,BigDecimal> usedByDemand=new HashMap<>();
        Map<String,BigDecimal> secured=new LinkedHashMap<>();
        for(FormalMaterialCoverage row:coverage) {
            String key=row.analysisItemId()+"|"+row.nodeKey();FormalCoverageRule rule=rules.get(key);
            if(rule==null)continue;
            BigDecimal headroom=rule.requiredQty().subtract(secured.getOrDefault(key,BigDecimal.ZERO)).max(BigDecimal.ZERO);
            if(row.remainingParentOutputQty()!=null) {
                headroom=headroom.min(rule.requirement().apply(row.remainingParentOutputQty()));
            }
            BigDecimal take=row.coveredQty().subtract(usedByDemand.getOrDefault(row.demandId(),BigDecimal.ZERO)).max(BigDecimal.ZERO).min(headroom);
            if(take.signum()<=0)continue;
            secured.merge(key,take,BigDecimal::add);usedByDemand.merge(row.demandId(),take,BigDecimal::add);
        }
        return Map.copyOf(secured);
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
            Map<String, ParentSupplyCommitment> parentSupply,
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
                parentSupply, tuning, fixedDirectAllocations);
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
     * of a parent whose effective route is MAKE or SUBCONTRACT. Once a MAKE node is
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
                BorrowTuning.NONE);
    }

    static NestedDiagnosticPlan allocateNestedDiagnostics(
            List<SourceLine> sources,
            List<BomNode> nodes,
            Map<MaterialDimension, BigDecimal> rawStock,
            Map<String, String> effectiveRoutes,
            Set<String> delegatedMakeNodes,
            BorrowTuning tuning) {
        return allocateNestedDiagnostics(sources, nodes, rawStock, effectiveRoutes,
                delegatedMakeNodes, Map.of(), tuning, Map.of());
    }

    private static NestedDiagnosticPlan allocateNestedDiagnostics(
            List<SourceLine> sources,
            List<BomNode> nodes,
            Map<MaterialDimension, BigDecimal> rawStock,
            Map<String, String> effectiveRoutes,
            Set<String> delegatedMakeNodes,
            Map<String, ParentSupplyCommitment> parentSupply,
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
                // 自制与委外父件同构(ADR-143：委外只领直属物料)，子件都按父件展开。
                boolean expandsChildren = AggregateRouteForwarding.forwardsSubtree(parentRoute, null)
                        && !delegatedMakeNodes.contains(parentKey);
                // 子件毛需求跟随父件「还要自己产出多少」：
                //   计划产出 = max(已承诺内部制造量, 物理缺口 - 外部最终件在途)
                // 外部在途到货即可顶上，不必为它备料；已下达的自制计划与未结的
                // 委外申请(领料发外)是冻结承诺，必须保留其原料，否则会断料。
                // 已领给车间/委外商的料由正式覆盖逐种抵扣，不从父件产出里扣。
                BigDecimal parentOutput = parentPlannedOutput(
                        parent, parentSupply.get(parentKey));
                required = expandsChildren
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

    /**
     * 父节点的计划产出量：在物理缺口里扣掉已被外部最终件在途覆盖的部分，
     * 再以「已承诺由我方制造的量」托底（托底值本身不超过物理缺口，避免
     * 历史累加的锚点数量把下层需求抬高到缺口以上）；最后与「已下达且仍有效
     * 的计划总量」取大（ADR-099）——已下达的计划是冻结承诺，本批数量超过需求
     * 的部分同样要备料，这一项不受物理缺口封顶。
     */
    static BigDecimal parentPlannedOutput(
            NodeAllocation parent, ParentSupplyCommitment supply) {
        BigDecimal shortage = parent.shortageQty();
        if (supply == null) return shortage;
        BigDecimal netted = shortage.subtract(supply.externalFutureQty())
                .max(BigDecimal.ZERO);
        return netted.max(supply.internalCommittedQty().min(shortage))
                .max(supply.plannedOutputQty())
                .subtract(supply.aggregateDelegatedOutputQty()).max(BigDecimal.ZERO)
                .max(supply.plannedOutputQty());
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
            // 子件锚点行（MAKE_COMPONENT）无直接料行——齐套
            // 与否由其生产计划的执行段判定，分析侧不预设「无门槛即全可产」。
            boolean anchorChild = SOURCE_MAKE_COMPONENT.equals(source.sourceType());
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
        record RankedNode(BomNode node, int sourceRank) {}
        List<RankedNode> ranked = new ArrayList<>();
        for (int rank = 0; rank < ordered.size(); rank++) {
            for (BomNode node : directBySource.getOrDefault(ordered.get(rank).analysisItemId(), List.of())) {
                ranked.add(new RankedNode(node, rank));
            }
        }
        // Reference/shipping hints cannot take residual public stock before a
        // real production input merely because their source was listed first.
        ranked.sort(Comparator.comparingInt((RankedNode value) -> diagnosticAllocationPriority(value.node()))
                .thenComparingInt(RankedNode::sourceRank).thenComparing(value -> value.node().nodeKey()));
        for (RankedNode value : ranked) {
            BomNode node = value.node();
                String nodeKey = nodeAllocationKey(node);
                // Complete kits have already consumed their protected share.
                // Residual public stock also covers an individual hard material;
                // this diagnostic coverage must not create a second purchase or
                // MAKE task merely because a different component is missing.
                // Readiness and formal reservations still use the kit stage plan.
                BigDecimal required = node.snapshotRequiredQty();
                NodeAllocation existing = result.getOrDefault(
                        nodeKey, NodeAllocation.ZERO);
                BigDecimal residual = required.subtract(existing.allocatedQty())
                        .max(BigDecimal.ZERO);
                BigDecimal cap = tuning == null ? null : tuning.capOrNull(nodeKey);
                if (cap != null) residual = residual.min(
                        cap.subtract(existing.allocatedQty()).max(BigDecimal.ZERO));
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

    /**
     * 物料分析的只读对象级门禁(ADR-088)。
     *
     * <p>同包内的轻量只读投影(如关联销售订货单货品清单)复用这一处判定，
     * 不要各自复制 readHeader + scopeForAnalysis 的组合——两份判定一旦漂移，
     * 就会出现「分析详情 404、附属只读页 200」的越权缺口。
     * 不可读时统一吐 404 而不是 403，不泄露「这张分析存在」。
     */
    void requireReadableAnalysis(UUID analysisId) {
        AnalysisHeader header = readHeader(analysisId);
        access.requireReadable(header.makerId(), "物料分析不存在", scopeForAnalysis(header));
    }

    private static Map<UUID, BigDecimal> sourceRequiredQuantities(
            List<SourceLine> sources, List<MaterialRow> materials) {
        try {
            Set<UUID> aggregates=sources.stream().filter(source->SOURCE_AGGREGATE_MAKE.equals(source.sourceType()))
                    .map(SourceLine::analysisItemId).collect(Collectors.toSet());
            Map<UUID,BigDecimal> result=new LinkedHashMap<>(MaterialAnalysisSourceRequirementProjection.project(
                    sources.stream()
                            .filter(source -> !SOURCE_MAKE_COMPONENT.equals(source.sourceType())
                                    && !SOURCE_AGGREGATE_MAKE.equals(source.sourceType()))
                            .map(source -> new MaterialAnalysisSourceRequirementProjection.Source(
                                    source.analysisItemId(), source.requestedQty(), source.unitRate()))
                            .toList(),
                    materials.stream()
                            .filter(row->!aggregates.contains(row.analysisItemId()))
                            .map(row -> new MaterialAnalysisSourceRequirementProjection.Node(
                                    row.id(), row.analysisItemId(), row.nodeKey(), row.parentNodeKey(),
                                    row.depth(), row.bomQty(), row.consumptionBasis(),
                                    row.basisOutputQty(), row.allowPartialPackage()))
                            .toList()));
            // Shared execution does not introduce another customer requirement.
            for(MaterialRow row:materials)if(aggregates.contains(row.analysisItemId()))result.put(row.id(),BigDecimal.ZERO);
            return Map.copyOf(result);
        } catch (IllegalArgumentException invalidSourceTree) {
            throw conflict("原始需求或 BOM 路径不完整，请重新分析后再查看");
        }
    }

    AnalysisView detailInternal(UUID analysisId, boolean enforceAccess) {
        return detailInternal(analysisId, enforceAccess, MaterialAnalysisIssuePreviewOverlay.NONE);
    }

    /**
     * [overlay] 非空时(下达预览, ADR-116)来源行与物料行的数量取内存投影, 其余事实照读库内;
     * 视图推导与 GET 详情逐行同一套代码。
     */
    private AnalysisView detailInternal(
            UUID analysisId, boolean enforceAccess, MaterialAnalysisIssuePreviewOverlay overlay) {
        AnalysisHeader header = readHeader(analysisId);
        if (enforceAccess) {
            access.requireReadable(header.makerId(), "物料分析不存在",scopeForAnalysis(header));
        }
        List<SourceLine> sources = loadSourceLines(analysisId, false, overlay);
        List<MaterialRow> materialRows = loadMaterialRows(analysisId, overlay);
        SharedFutureIndex sharedFuture = sharedFutureSupply(
                analysisId, header.warehouseId(), materialRows);
        Map<UUID, ClaimedFutureState> claimedFuture = sharedFutureClaimedByMaterial(analysisId);
        boolean aggregateSources=hasAggregateSources(sources);
        List<AggregateMember> aggregateMembers=aggregateSources?aggregateMembers(analysisId):List.of();
        Map<UUID,BigDecimal> aggregateCommitments=new HashMap<>();
        for(AggregateMember member:aggregateMembers)aggregateCommitments.merge(member.materialId(),member.qty(),BigDecimal::add);
        AggregateAliasCoverage aliasCoverage=aggregateSources?aggregateAliasCoverage(analysisId):AggregateAliasCoverage.EMPTY;
        Map<UUID, BigDecimal> previewRootAdoptions = previewRootAdoptions(sources, overlay);
        Map<UUID, FutureCoverage> activeFuture = new LinkedHashMap<>(activeFutureCoverage(analysisId,aliasCoverage.incoming()));
        previewRootAdoptions.forEach((id, qty) -> activeFuture.merge(id, new FutureCoverage(qty, qty),
                (stored, projected) -> new FutureCoverage(stored.totalQty().add(projected.totalQty()),
                        stored.externalQty().add(projected.externalQty()))));
        Map<UUID, SourceLine> sourcesById = sources.stream().collect(
                Collectors.toMap(SourceLine::analysisItemId, source -> source));
        Map<MaterialNodeIdentity, MaterialRow> materialRowsByNode =
                materialRows.stream().collect(Collectors.toMap(
                        MaterialRow::nodeIdentity, row -> row));
        Map<UUID, BigDecimal> sourceRequiredByMaterial =
                sourceRequiredQuantities(sources, materialRows);
        // 2026-09-05 简化：不再投影「需求已转交自制子任务」——子件只做计划
        // 锚点，物料行保持原位（进度由子件行的计划/执行段展示）。
        Map<MaterialNodeIdentity, DelegatedRequirementOwner> delegatedOwners = new HashMap<>();
        for(AggregateMember member:aggregateMembers)delegatedOwners.put(new MaterialNodeIdentity(member.sourceId(),member.nodeKey()),
                new DelegatedRequirementOwner(member.materialId(),member.anchorId(),member.sourceRef(),member.qty()));
        // 同料合并转交投影(2026-09-26 修订，取代 #31 的别名份额单查)：需求转走的
        // 产品树原行 requiredQty 已归零、也没有自己的下单引用——任意深度的行都靠
        // 这份投影拿回自己的 BOM 份额、共享批次树上的目标行与真实进度阶段，不再
        // 显示成可填的 0 / 「未下达」。
        Map<UUID,AggregateDelegationProjection.Delegation> aggregateDelegations=
                aggregateSources?aggregateDelegationProjection(analysisId):Map.of();
        // 本行在共享批次之外还有自己的供给行动(下单/任务引用)——进度列仍按本行
        // 自己的链路推导，只有「需求整体转出且无自有引用」的行才报目标行阶段。
        Set<UUID> rowsWithOwnSupply=aggregateSources?materialLinesWithOwnSupplyActions(analysisId):Set.of();
        List<UUID> participatingWarehouseIds = participatingWarehouseIds(
                analysisId, header.warehouseId());
        Set<UUID> participatingWarehouseSet = Set.copyOf(
                participatingWarehouseIds);
        Map<WarehouseMaterialDimension, BigDecimal> qualifiedOwned = new LinkedHashMap<>(qualifiedOwnedStock(analysisId,
                materialRows.stream().map(row -> row.analysisItemId()+"|"+row.nodeKey()).collect(Collectors.toSet())));
        qualifiedOwned.replaceAll((key,qty)->qty.subtract(overlay.qualifiedTransferred(key)).max(BigDecimal.ZERO));
        Map<WarehouseMaterialDimension, BigDecimal> componentDraftOwned = new LinkedHashMap<>();
        // 领料草稿里带专属交接的那份(按物料节点)：已计入精确归属，备料预算不再重复计。
        Map<String, BigDecimal> componentDraftHeldByNode = new HashMap<>();
        for (Object[] row : SubcontractComponentCustodyProjection.held(em, analysisId)) {
            componentDraftOwned.merge(new WarehouseMaterialDimension(uuid(row[7]),
                    new MaterialDimension(uuid(row[4]), uuid(row[5]), uuid(row[6]))), decimal(row[8]), BigDecimal::add);
            componentDraftHeldByNode.merge(nodeRef(uuid(row[2]), string(row[3])), decimal(row[8]), BigDecimal::add);
        }
        componentDraftOwned.forEach((dimension, qty) -> qualifiedOwned.merge(dimension, qty, BigDecimal::add));
        Set<UUID> operationalWarehouseIds = Set.copyOf(NativeQueryResults.typedRows(
                em.createNativeQuery("""
                        SELECT warehouse.id FROM warehouses warehouse
                        WHERE warehouse.is_deleted=FALSE AND warehouse.is_accountable=TRUE
                          AND fn_warehouse_same_main(warehouse.id,:warehouseId)
                        """).setParameter("warehouseId",header.warehouseId()), UUID.class));
        List<WarehouseView> warehouses = warehouses(
                header.warehouseId(), participatingWarehouseSet);
        Map<MaterialDimension, List<WarehouseBreakdown>> breakdown =
                warehouseBreakdown(analysisId, materialRows, sharedFuture, qualifiedOwned, componentDraftOwned, overlay);
        Map<StockIdentity, BigDecimal> mainOpenSafety = mainWarehouseOpenSafetySupply(
                header.warehouseId(), materialRows.stream().map(MaterialRow::goodsId).collect(Collectors.toSet()));
        Map<UUID, List<DownstreamReference>> references = downstreamReferences(analysisId);
        if (rootSupply != null) rootSupply.addOutputReferences(analysisId,references);
        Map<UUID, ProductPlanState> productPlanStates = productPlanStates(analysisId);
        // 行级流程阶段（表格进度/待办列唯一口径）：锚点子件的执行状态 + 行路线/缺口
        // + 采购/委外单据链，全部在服务端一次批量推导。
        Map<UUID, UUID> anchorChildByParentLine = planAnchorByMaterial(analysisId, aggregateMembers);
        Map<UUID, String> childStatusByLine = new LinkedHashMap<>();
        Map<UUID, Boolean> childZeroByLine = new LinkedHashMap<>();
        anchorChildByParentLine.forEach((parentLine, childItem) -> {
            ProductPlanState childState = productPlanStates.getOrDefault(
                    childItem, ProductPlanState.NONE);
            childStatusByLine.put(parentLine, childState.status());
            childZeroByLine.put(parentLine, childState.zeroMaterial());
        });
        // A source can have several immutable batches after execution has begun.
        // Its progress follows the earliest unfinished batch, not whichever anchor was read first.
        for(AggregateMember member:aggregateMembers) {
            ProductPlanState state=productPlanStates.getOrDefault(member.anchorId(),ProductPlanState.NONE);
            if(state.status()==null)continue;
            String current=childStatusByLine.get(member.materialId());
            String nextStage=MaterialAnalysisFlowStageService.makeStage(state.status(),state.zeroMaterial());
            String currentStage=MaterialAnalysisFlowStageService.makeStage(current,childZeroByLine.getOrDefault(member.materialId(),false));
            if(current==null||preparationStageRank(nextStage)<preparationStageRank(currentStage)) {
                childStatusByLine.put(member.materialId(),state.status());childZeroByLine.put(member.materialId(),state.zeroMaterial());
            }
        }
        Map<UUID, String> routeByLine = new LinkedHashMap<>();
        Map<UUID, BigDecimal> shortageByLine = new LinkedHashMap<>();
        Map<UUID, BigDecimal> requiredByLine = new LinkedHashMap<>();
        for (MaterialRow row : materialRows) {
            // ADR-102：depth>0 且还有需求的行，路线没确认就是「路线未定」——
            // 以前这里回落 suggestion，主档来源为空时 suggestion 是 REVIEW，
            // 掉进采购分支后整行显示「等待下发采购」，与红框「请先选供应方式」
            // 自相矛盾。根供给行(depth=0)另有根路线冻结机制，不在此列。
            boolean routePending = row.depth() > 0
                    && row.confirmedRoute() == null
                    && row.requiredQty() != null
                    && row.requiredQty().signum() > 0;
            routeByLine.put(row.id(), routePending
                    ? MaterialAnalysisFlowStageService.ROUTE_PENDING_INPUT
                    : (row.confirmedRoute() != null
                            ? row.confirmedRoute() : row.suggestion()));
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
        boolean hasPriority = crossProjections.values().stream().anyMatch(cross -> cross.priorityPendingQty().signum()>0);
        var makeSupplementReader = new PreplanReallocationMakeSupplement(em);
        Map<UUID, PreplanReallocationMakeSupplement.Allowance> makeSupplementAllowances = hasPriority
                ? makeSupplementReader.read(analysisId) : Map.of();
        // Legacy action-backed MAKE and its child quota describe the same
        // unfinished production. Read its actual source progress and count it once.
        var makeSupplementCoverage = new MaterialAnalysisSupplyCoverageReader(em).read(analysisId,
                materialRows.stream().filter(row -> makeSupplementAllowances.containsKey(row.id()))
                        .map(row -> new MaterialAnalysisSupplyCoverageReader.Group(
                                row.actionGroupKey(),row.confirmedRoute(),List.of(row.id()))).toList());
        Set<UUID> supplementedChildren = !crossProjections.isEmpty()
                ? makeSupplementReader.supplementedChildren(analysisId) : Set.of();
        Map<UUID, BigDecimal> exactPegged = new LinkedHashMap<>(exactPeggedByMaterial(
                analysisId, header.warehouseId()));
        Map<UUID,BigDecimal> authoritativeExactPegged=Map.copyOf(exactPegged);
        exactPegged.replaceAll((id,qty)->qty.subtract(overlay.transferredMaterial(id)).max(BigDecimal.ZERO));
        Map<UUID, String> sourceLabels = sources.stream().collect(Collectors.toMap(
                SourceLine::analysisItemId,
                source -> displayLabel(source.goodsCode(), source.goodsName())));
        Set<UUID> selectedWarehouseIds = new HashSet<>(participatingWarehouseSet);
        selectedWarehouseIds.addAll(operationalWarehouseIds);
        Map<MaterialDimension, WarehouseSelectionSummary> warehouseSummaries = new HashMap<>();
        // ADR-102：「还缺数量」要不要替这一行扣掉可认领的公共在途，见 sharedFutureDeductible。
        Set<String> soleRowDimensions = soleRowDimensions(materialRows);
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
                            sourcesById.get(row.analysisItemId()));
                    SourceLine materialSource = sourcesById.get(row.analysisItemId());
                    String futureRoute = row.confirmedRoute() != null
                            ? row.confirmedRoute() : row.suggestion();
                    SharedFutureAggregate shared = sharedFuture.forMaterial(
                            row.id(), header.warehouseId(), row.dimension(), futureRoute,
                            materialSource == null ? null
                                    : materialSource.deliveryDate());
                    // Hundreds of source paths can share one material dimension.
                    // Warehouse totals depend on that dimension, not on the source
                    // item; retain one calculation within this immutable response.
                    WarehouseSelectionSummary selectedWarehouses = warehouseSummaries.computeIfAbsent(
                            row.dimension(), dimension -> selectedWarehouseSummaryWithQualifiedSources(
                                    breakdown.getOrDefault(
                                            dimension, List.of()), selectedWarehouseIds,
                                    operationalWarehouseIds, qualifiedOwned, dimension));
                    MainWarehouseSafetySummary mainSafety = mainWarehouseSafetySummary(
                            breakdown.getOrDefault(row.dimension(), List.of()), operationalWarehouseIds, row.safetyStockQty(),
                            mainOpenSafety.getOrDefault(new StockIdentity(row.goodsId(), row.colorId()), BigDecimal.ZERO));
                    FutureCoverage future = activeFuture.getOrDefault(row.id(), FutureCoverage.NONE);
                    UUID anchorId = anchorChildByParentLine.get(row.id());
                    SourceLine anchor = anchorId == null ? null : sourcesById.get(anchorId);
                    // ADR-099：锚点已下达且仍有效的计划总量（含公共备货产出）也是
                    // 内部制造承诺；顶层供给行的计划产出按来源单位换成基本单位。
                    boolean sharedAnchor=anchor!=null&&SOURCE_AGGREGATE_MAKE.equals(anchor.sourceType());
                    BigDecimal anchorPlanned = (sharedAnchor||anchor==null?BigDecimal.ZERO:anchor.issuedPlanQty())
                            .add(aggregateCommitments.getOrDefault(row.id(),BigDecimal.ZERO));
                    BigDecimal internalCommitment = future.totalQty().subtract(future.externalQty())
                            .max(anchor == null || sharedAnchor ? BigDecimal.ZERO : anchor.requestedQty())
                            .max(anchorPlanned);
                    // 本节点的计划产出量 = max(需求量, 本节点已下达的计划量)：顶层供给行
                    // 按来源行的计划产出(含公共备货产出, 换成基本单位)，其余行按自家锚点。
                    BigDecimal plannedOutput = row.requiredQty().max(anchorPlanned);
                    // 本节点已下达自制计划里归本需求的那一份: 顶层 = 来源行自己的计划(换成
                    // 基本单位), 其余 = 锚点的计划。只用来从「还缺数量」里扣(见 toView)。
                    BigDecimal committedPlan = (sharedAnchor||anchor==null?BigDecimal.ZERO:anchor.committedPlanQty())
                            .add(aggregateCommitments.getOrDefault(row.id(),BigDecimal.ZERO));
                    if (row.depth() == 0 && materialSource != null) {
                        plannedOutput = plannedOutput.max(materialSource.plannedOutputQty()
                                .multiply(materialSource.unitRate()).setScale(4, RoundingMode.DOWN));
                        committedPlan = committedPlan.max(materialSource.committedPlanQty()
                                .multiply(materialSource.unitRate()).setScale(4, RoundingMode.DOWN));
                    }
                    // 转交投影：份额与目标行一次取齐；需求整体转出且无自有引用的行
                    // 进度列报目标行(嵌套批次已解析到最终真实下达行)的阶段。
                    AggregateDelegationProjection.Delegation delegation = aggregateDelegations.get(row.id());
                    return row.toView(
                            breakdown.getOrDefault(row.dimension(), List.of()),
                            references.getOrDefault(row.id(), List.of()),
                            displayPath(row, materialRowsByNode, sourceLabels),
                            parentLabel(row, materialRowsByNode, sourceLabels),
                            exactPegged.getOrDefault(row.id(), BigDecimal.ZERO),
                            borrowedIn, borrowedOut, rowBorrows, cross, requirement,
                            shared,
                            claimedFuture.getOrDefault(row.id(), ClaimedFutureState.NONE).claimedQty(),
                            future.totalQty(), future.externalQty(), internalCommitment,
                            selectedWarehouses.totalAvailableQty(),
                            selectedWarehouses.otherTransferableQty(),
                            delegatedFlowStage(delegation, row.id(),
                                    lineFlowStages, rowsWithOwnSupply),
                            anchorChildByParentLine.get(row.id()), mainSafety,
                            makeSupplementAllowances.getOrDefault(row.id(),PreplanReallocationMakeSupplement.Allowance.NONE),
                            makeSupplementCoverage.active(row.actionGroupKey(),row.confirmedRoute())
                                    .add(makeSupplementCoverage.replacement(row.actionGroupKey(),row.confirmedRoute())),
                            claimedFuture.getOrDefault(row.id(),ClaimedFutureState.NONE).pendingQty(),
                            plannedOutput,
                            sharedFutureDeductible(
                                    row, soleRowDimensions),
                            committedPlan, sourceRequiredByMaterial.get(row.id()),
                            delegation == null ? BigDecimal.ZERO : delegation.qty(),
                            delegation == null ? null : delegation.targetMaterialLineId());
                })
                .toList();
        Map<UUID, String> planningBlocks = planningBlockedReasons(sources);
        List<ProductView> products = sources.stream().map(source -> {
            BigDecimal remaining = source.remainingAnalysisQty();
            BigDecimal ratio = remaining.signum() == 0
                    ? BigDecimal.ONE
                    : source.readyNowQty().divide(remaining, 4, RoundingMode.DOWN)
                        .min(BigDecimal.ONE);
            ProductPlanState planState=productPlanStates.getOrDefault(source.analysisItemId(),ProductPlanState.NONE);
            if(supplementedChildren.contains(source.analysisItemId()) && remaining.signum()>0
                    && "COMPLETED".equals(planState.status())) {
                planState=new ProductPlanState("NOT_STARTED",planState.planId(),planState.planNo(),
                        planState.plannedQty(),planState.inboundQty(),planExecutionProgressRatio(source.requestedQty(),planState.inboundQty()),
                        planState.reportedQty(),planState.zeroMaterial(),planState.workshopName(),planState.responsibleName(),planState.workshopId(),planState.responsibleId());
            }
            return source.toView(ratio,productIdsWithMaterialChildren.contains(source.analysisItemId()),
                    planState,planningBlocks.get(source.analysisItemId()));
        }).toList();
        UUID fqcRecoveryAuthorizationId = fqcRecoveryAuthorizationId(analysisId);
        boolean fqcReplenishmentOnly = fqcRecoveryAuthorizationId != null;
        Set<UUID> rateGoodsIds = products.stream().map(ProductView::goodsId)
                .filter(Objects::nonNull).collect(Collectors.toCollection(HashSet::new));
        materials.stream().map(MaterialView::goodsId).filter(Objects::nonNull).forEach(rateGoodsIds::add);
        Map<UUID,BigDecimal> adoptedByMaterial=preparationAdoptedQuantities(analysisId);
        previewRootAdoptions.forEach((id, qty) -> adoptedByMaterial.merge(id, qty, BigDecimal::add));
        Map<UUID,String> claimedMakeStages=PreplanMakePublicSupplyService.claimedStages(em,analysisId);
        materials=materials.stream().map(row->row.planningUncoveredQty().signum()==0&&row.flowStage()!=null
                &&row.flowStage().endsWith("PENDING_ISSUE")&&claimedMakeStages.containsKey(row.materialLineId())
                ?row.withFlowStage(claimedMakeStages.get(row.materialLineId())):row).toList();
        OwnerVisibility.OwnerScope makeScope=access.scope();
        boolean revealMakePlan=access.hasAuthority("production_plan:view");
        Map<UUID,List<PreplanMakePublicSupplyService.Candidate>> makeCandidates=PreplanMakePublicSupplyService.candidates(em,analysisId,
                owner->revealMakePlan&&access.canRead(owner,makeScope));
        materials=materials.stream().map(row->{
            List<PreplanMakePublicSupplyService.Candidate> candidates=makeCandidates.getOrDefault(row.materialLineId(),List.of());
            BigDecimal publicPlanned=sharedFuture.overview(header.warehouseId(),new MaterialDimension(row.goodsId(),row.colorId(),row.unitId())).refs().stream()
                    .map(SharedFutureSupplyRef::availableToClaimQty).reduce(BigDecimal.ZERO,BigDecimal::add);
            BigDecimal makePlanned=candidates.stream().map(PreplanMakePublicSupplyService.Candidate::availableQty).reduce(BigDecimal.ZERO,BigDecimal::add);
            return row.withPreparationSupply(row.selectedWarehousesAvailableQty().add(activeFuture.getOrDefault(row.materialLineId(),FutureCoverage.NONE).totalQty()).add(publicPlanned).add(makePlanned),candidates)
                    .withPreparationAdoptedQty(adoptedByMaterial.getOrDefault(row.materialLineId(),BigDecimal.ZERO));
        }).toList();
        var budgetFacts=new MaterialPreparationBudgetReader(em).read(analysisId,header.warehouseId(),materials,selectedWarehouseIds,aliasCoverage.outgoing());
        Map<String,FormalCoverageRule> budgetRules=materialRows.stream().collect(Collectors.toMap(row->nodeRef(row.analysisItemId(),row.nodeKey()),
                row->new FormalCoverageRule(row.requiredQty(),row::requiredForSingleParentOutput)));
        Map<String,BigDecimal> formalPrivate=new HashMap<>(formalCoverageQuantities(formalMaterialCoverage(analysisId,header.warehouseId()),budgetRules));
        // 委外领料覆盖(ADR-143 §4.5)：与刷新同一套逐种覆盖与封顶；带专属交接的草稿已在精确归属里，只补其余部分。
        formalCoverageQuantities(subcontractChildCoverage(analysisId),budgetRules).forEach((key,covered)->{
            BigDecimal extra=covered.subtract(componentDraftHeldByNode.getOrDefault(key,BigDecimal.ZERO)).max(BigDecimal.ZERO);
            if(extra.signum()>0)formalPrivate.merge(key,extra,BigDecimal::add);
        });
        Map<UUID,ProductView> budgetProducts=products.stream().collect(Collectors.toMap(ProductView::analysisLineId,value->value));
        materials=materials.stream().map(row->{
            FutureCoverage future=activeFuture.getOrDefault(row.materialLineId(),FutureCoverage.NONE);
            BigDecimal internal=future.totalQty().subtract(future.externalQty()).max(BigDecimal.ZERO)
                    .max(budgetFacts.privateMakePendingByMaterial().getOrDefault(row.materialLineId(),BigDecimal.ZERO));
            BigDecimal owned=authoritativeExactPegged.getOrDefault(row.materialLineId(),BigDecimal.ZERO)
                    .add(formalPrivate.getOrDefault(nodeRef(row.analysisLineId(),row.nodeKey()),BigDecimal.ZERO))
                    .add(future.externalQty()).add(internal)
                    .subtract(budgetFacts.outgoingInheritedPendingByMaterial().getOrDefault(row.materialLineId(),BigDecimal.ZERO)).max(BigDecimal.ZERO);
            BigDecimal required=row.requiredQty().subtract(owned).max(BigDecimal.ZERO).max(row.priorityMakeSupplementQty());
            ProductView anchor=budgetProducts.get(row.planAnchorAnalysisLineId());
            if(row.requiredQty().signum()==0&&anchor!=null&&!SOURCE_AGGREGATE_MAKE.equals(anchor.sourceType()))required=required.max(anchor.remainingQty());
            String pool=budgetFacts.poolKeyByMaterial().get(row.materialLineId());
            BigDecimal shared=budgetFacts.sharedQtyByPoolKey().getOrDefault(pool,BigDecimal.ZERO);
            List<PreparationSharedSupplySlice> slices=budgetFacts.slicesByMaterial().getOrDefault(row.materialLineId(),List.of());
            BigDecimal adoptable=slices.stream().filter(PreparationSharedSupplySlice::adoptable)
                    .map(PreparationSharedSupplySlice::availableQty).reduce(BigDecimal.ZERO,BigDecimal::add);
            return row.withPreparationBudget(MaterialPreparationBudgetReader.wireKey(pool),shared,owned,required).withPreparationAdoptableSharedQty(adoptable)
                    .withPreparationSharedSupplySlices(slices);
        }).toList();
        List<SupplyActionView> actionViews=supplyActions(analysisId);
        Set<UUID> originalItems=products.stream().filter(product->!SOURCE_AGGREGATE_MAKE.equals(product.sourceType()))
                .map(ProductView::analysisLineId).collect(Collectors.toSet());
        Set<UUID> originalMaterials=materials.stream().filter(row->originalItems.contains(row.analysisLineId()))
                .map(MaterialView::materialLineId).collect(Collectors.toSet());
        Map<UUID,Map<UUID,BigDecimal>> directPrivate=new AggregatePrivateIntentReader(em).read(analysisId).byTarget();
        Map<UUID,Map<UUID,BigDecimal>> attributedPrivate=AggregatePrivateCoveragePropagation.propagate(
                directPrivate,aliasCoverage.attributedCoverage(),originalMaterials);
        materials=AggregateMaterialPreparationProjection.apply(materials,products,actionViews,
                aggregateDelegations,aggregateOrderIntents(analysisId),new AggregateAdoptionIntentReader(em).read(analysisId),attributedPrivate,directPrivate);
        materials = withSubcontractBomGaps(analysisId, materials);
        List<String> allowed = allowedActions(analysisId, header, fqcReplenishmentOnly);
        // ADR-102: 还能按货品档案自动确认的操作组 (与重算里的自动确认同一判据、同一批事实);
        // 通常是到货/审核等别的单据顺带重算后新冒出来的行, 页面据此静默刷新一次. 下达预览不算;
        // 当前账号不能确认路线 (无 CONFIRM_ROUTES, 与自动确认同一道闸) 时恒为 0, 数了也做不了.
        int pendingAutoConfirm = !overlay.isNone() || !allowed.contains("CONFIRM_ROUTES") ? 0
                : MaterialAnalysisRouteAutoConfirm.plan(materialRows, planningBlocks,
                        MaterialAnalysisRouteAutoConfirm.facts(sources, productPlanStates, anchorChildByParentLine,
                                references, actionViews)).groupCount();
        return new AnalysisView(
                header.id(), header.status(), header.version(), header.fingerprint(),
                header.fingerprint(),
                header.warehouseId(), participatingWarehouseIds,
                header.analyzedAt(), products, materials,
                warehouses, actionViews,
                allowed,
                fqcReplenishmentOnly, fqcRecoveryAuthorizationId, planningBlocks, 0, 0, pendingAutoConfirm,
                com.uten.imp.features.production.plan.ProductionOverproductionAllowance.defaults(em, rateGoodsIds),
                header.analysisNo());
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

    /**
     * 指纹只覆盖「会改变分析结论的事实」：范围仓、来源行数量、BOM 节点与供给动作。
     *
     * <p>V587 的货品「所属仓库」(goods.owning_warehouse_id) **故意不进指纹**：
     * 它是货品主档的归属分类，只用于展示与筛选，不参与需求、可用量、齐套或
     * 路线的任何计算。把它算进去，仓管在主档改一个归属，就会让所有正在编辑
     * 这份分析的计划员手里的 CAS 令牌 (version + fingerprint) 立即失效、提交
     * 报 409，纯粹是误伤。同理，这里也不 bump 版本、不触发 refresh。
     */
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
        List<ProductionMutationFootprintPort.WarehouseDimension> roots = normalized.stream()
                .filter(item -> item.goodsId()!=null)
                .map(item -> new ProductionMutationFootprintPort.WarehouseDimension(
                        request.warehouseId(),item.goodsId(),item.colorId())).toList();
        return mutationFootprints.forPreview(sales,roots,warehouses,
                existing==null ? List.of() : List.of(existing));
    }

    private List<PreviewItem> normalizePreviewItems(List<PreviewItem> raw) {
        List<PreviewItem> result = new ArrayList<>();
        Set<String> keys = new HashSet<>();
        // ADR-130：同一 (来源类型, 需求编号) 的各货品行统一落第一行的写法，历史列表不会出现两种拼写。
        Map<String, String> manualRefSpelling = new HashMap<>();
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
            if (!Set.of(SOURCE_SALES, "REWORK", "TRIAL", "SAMPLE", "STOCK", "OTHER")
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
            String sourceRef = blankToNull(item.sourceRef());
            String key;
            if (SOURCE_SALES.equals(source)) {
                key = source + ":" + item.salesOrderItemId();
            } else {
                // 去重键与 SourceIdentity 同一规范形(去首尾空白+小写)：'RW-1' 与 ' rw-1' 是同一个编号，
                // 否则会一路漏到按来源身份建 Map 的地方变成 500。
                String canonicalRef = canonicalSourceRef(sourceRef);
                if (MANUAL_SOURCE_TYPES.contains(source)) {
                    String spelling = manualRefSpelling.putIfAbsent(source + "|" + canonicalRef, sourceRef);
                    if (spelling != null) sourceRef = spelling;
                }
                key = source + ":" + item.goodsId() + ":" + Objects.toString(item.colorId(), "")
                        + ":" + item.unitId() + ":" + canonicalRef;
            }
            if (!keys.add(key)) {
                throw validation(MANUAL_SOURCE_TYPES.contains(source)
                        ? "需求编号 " + sourceRef + " 下货品重复，请合并为一行"
                        : "生产需求来源重复");
            }
            result.add(new PreviewItem(source, item.salesOrderItemId(), item.goodsId(),
                    item.colorId(), item.unitId(), sourceRef,
                    blankToNull(item.sourceReason()), item.deliveryDate(),
                    scaleQty(item.requestedQty())));
        }
        return List.copyOf(result);
    }

    private UUID findReusableAnalysis(List<PreviewItem> items) {
        Set<UUID> analyses = new LinkedHashSet<>();
        // 非销售来源按 (来源类型, 规范化编号) 分组：一张手工需求单的多个货品行只查一次(ADR-130)。
        Map<String, List<PreviewItem>> refGroups = new LinkedHashMap<>();
        for (PreviewItem item : items) {
            if (!SOURCE_SALES.equals(sourceType(item))) {
                refGroups.computeIfAbsent(sourceType(item) + "|" + canonicalSourceRef(item.sourceRef()),
                        ignored -> new ArrayList<>()).add(item);
                continue;
            }
            List<?> matches = em.createNativeQuery("""
                    SELECT DISTINCT analysis.id
                    FROM production_material_analysis_items source
                    JOIN production_material_analyses analysis
                      ON analysis.id = source.analysis_id
                     AND analysis.is_deleted = FALSE
                    WHERE source.is_deleted = FALSE
                      AND source.source_type = 'SALES_ORDER_ITEM'
                      AND source.sales_order_item_id = :salesOrderItemId
                      AND analysis.status IN ('ACTIVE','PARTIALLY_PLANNED')
                    ORDER BY analysis.id
                    """)
                    .setParameter("salesOrderItemId", item.salesOrderItemId())
                    .getResultList();
            for (Object match : matches) analyses.add(uuid(match));
        }
        for (List<PreviewItem> group : refGroups.values()) {
            PreviewItem first = group.getFirst();
            boolean manual = MANUAL_SOURCE_TYPES.contains(sourceType(first));
            // 手工五类写死字面量，规划器才能用上 V738 的 uq_production_material_analysis_manual_source_line。
            List<Object[]> matches = NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                    SELECT analysis.id, analysis.status, analysis.analysis_no,
                           source.goods_id, source.color_id, source.unit_id,
                           analysis.maker_id
                    FROM production_material_analysis_items source
                    JOIN production_material_analyses analysis
                      ON analysis.id = source.analysis_id
                     AND analysis.is_deleted = FALSE
                    WHERE source.is_deleted = FALSE
                      AND source.source_type = :sourceType
                      AND lower(btrim(source.source_ref)) = lower(btrim(:sourceRef))%s
                    ORDER BY analysis.id
                    """.formatted(manual
                            ? "\n  AND source.source_type IN ('REWORK','TRIAL','SAMPLE','STOCK','OTHER')" : ""))
                    .setParameter("sourceType", sourceType(first))
                    .setParameter("sourceRef", first.sourceRef()));
            Map<UUID, List<Object[]>> linesByAnalysis = new LinkedHashMap<>();
            for (Object[] match : matches) {
                if (!List.of(STATUS_ACTIVE, STATUS_PARTIAL).contains(string(match[1]))) {
                    throw conflict("手工需求编号已有历史物料分析，请打开历史记录或使用新的需求编号");
                }
                linesByAnalysis.computeIfAbsent(uuid(match[0]), ignored -> new ArrayList<>()).add(match);
            }
            if (manual && linesByAnalysis.size() == 1) {
                List<Object[]> lines = linesByAnalysis.values().iterator().next();
                Set<SourceIdentity> existingGoods = lines.stream()
                        .map(line -> new SourceIdentity(sourceType(first), null, uuid(line[3]),
                                uuid(line[4]), uuid(line[5]), first.sourceRef()))
                        .collect(Collectors.toSet());
                Set<SourceIdentity> requestedGoods = group.stream()
                        .map(this::sourceIdentity).collect(Collectors.toSet());
                if (!existingGoods.equals(requestedGoods)) {
                    Object[] owner = lines.getFirst();
                    // 这里先于打开分析时的归属校验：看不见原分析的人只得到中性提示，不透露编号和货品数。
                    if (!canSeeAnalysis(uuid(owner[6]))) {
                        throw conflict("需求编号 " + first.sourceRef()
                                + " 已被另一份物料分析使用，请换一个需求编号");
                    }
                    // 已建分析的来源集合只能刷新数量(requireSameSources/syncRequestedQuantities)，增减货品只能换编号。
                    String analysisNo = blankToNull(string(owner[2]));
                    throw conflict("需求编号 " + first.sourceRef() + " 已在物料分析"
                            + (analysisNo == null ? "" : " " + analysisNo + " ") + "中(" + existingGoods.size()
                            + " 个货品)；已建的分析不能增减货品，要增减货品请换一个需求编号(只改数量请打开原分析刷新)");
                }
            }
            analyses.addAll(linesByAnalysis.keySet());
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
                  AND source_type NOT IN ('MAKE_COMPONENT','AGGREGATE_MAKE')
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
                  AND source_type NOT IN ('MAKE_COMPONENT','AGGREGATE_MAKE')
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
        requireManualSourceMasters(items.stream()
                .filter(item -> !SOURCE_SALES.equals(sourceType(item)))
                .map(this::sourceIdentity).toList());
        int priority = 0;
        for (PreviewItem item : items) {
            priority++;
            SourceMaster master = SOURCE_SALES.equals(sourceType(item))
                    ? salesSourceMaster(item.salesOrderItemId())
                    : new SourceMaster(item.goodsId(), item.colorId(), item.unitId(), null);
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
    /**
     * 每个锚点行上「未撤销供给行动登记了多少」：需求回落时配额不能退到它以下,
     * 否则行动的撤回链路({@code cancelMakeDemandRow}, 它按行动自己登记的数回退)
     * 会把配额减成负数或减过头。没有行动背书的锚点取 0。
     */
    private Map<UUID, BigDecimal> actionBackedAnchorQuantities(UUID analysisId) {
        Map<UUID, BigDecimal> result = new LinkedHashMap<>();
        for (Object[] row : NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT external_document_id, SUM(requested_qty)::numeric
                FROM preplan_supply_actions
                WHERE analysis_id=:analysis AND status<>'CANCELLED'
                  AND external_document_type = 'PREPLAN_MAKE_TASK'
                  AND external_document_id IS NOT NULL
                GROUP BY 1
                """).setParameter("analysis",analysisId))) {
            result.put(uuid(row[0]), decimal(row[1]));
        }
        return result;
    }

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

    /**
     * 刷新并让既有自制锚点的配额跟上需求增长（ADR-099）。
     *
     * <p>来源数量增加（刷新预览）或父件按超过需求的本批数量下达车间（下层需求
     * 按计划产出量放大）都会让已有自制锚点的物料行需求变大；锚点行的
     * requested_qty 只在这里按「新增需求」增长，车间桶的剩余可排量随之变大。
     * [previousRequirements] 为空表示调用方没有提前取基线，这里自行取一次。</p>
     */
    int refreshWithAnchorGrowth(UUID analysisId, Map<UUID, BigDecimal> previousRequirements) {
        return refreshWithAnchorGrowth(analysisId, previousRequirements, Map.of());
    }

    int refreshWithAnchorGrowth(UUID analysisId, Map<UUID, BigDecimal> previousRequirements,
            Map<UUID, BigDecimal> typedOutputByMaterialLine) {
        return refreshWithAnchorGrowth(analysisId, previousRequirements, typedOutputByMaterialLine, false)
                .routeResets();
    }

    /** [autoConfirmRoutes] 见 {@link #refreshLockedOutcome}; 锚点跟涨后的第二次重算同样确认新出现的行. */
    private RefreshOutcome refreshWithAnchorGrowth(UUID analysisId, Map<UUID, BigDecimal> previousRequirements,
            Map<UUID, BigDecimal> typedOutputByMaterialLine, boolean autoConfirmRoutes) {
        Map<UUID, BigDecimal> previous = previousRequirements == null || previousRequirements.isEmpty()
                ? makeAnchorParentRequirements(analysisId) : previousRequirements;
        RefreshOutcome outcome = refreshLockedOutcome(analysisId, typedOutputByMaterialLine, autoConfirmRoutes);
        if (growMakeAnchorQuotasAfterSourcePreview(analysisId, previous)) {
            outcome = outcome.plus(refreshLockedOutcome(analysisId, typedOutputByMaterialLine, autoConfirmRoutes));
        }
        return outcome;
    }

    int refreshWithAnchorGrowth(UUID analysisId) {
        return refreshWithAnchorGrowth(analysisId, Map.of());
    }

    /**
     * 下达预览(ADR-116): 只读、不取任何锁、不建计划也不回滚。
     *
     * <p>[overlay] 已由命令服务装好「本批下达之后」会多出来的事实(本批计划的归需求量/
     * 公共备货量、计划批次、锚点父节点的计划产出、新锚点的内部承诺),
     * [typedOutputByMaterialLine] 是层级表上其余各行填的数量。这里按
     * {@link #refreshWithAnchorGrowth} 的同一顺序——刷新投影 → 锚点配额跟涨/跟落 →
     * (有调整时)再投影一次——全部在内存里算, 最后由与 GET 详情同一个视图构建器出视图。
     * 刷新引擎、分配、锚点规则与顶层供给行只有一份代码, 预览与真实下达不会各算各的。</p>
     *
     * <p>分析的 BOM 结构与库内快照不一致(需要刷新改写结构、可能清掉人工确认的路线)时
     * 直接 409, 请先刷新分析——预览不替真实刷新做结构决定。</p>
     */
    AnalysisView issuePreviewView(UUID analysisId, MaterialAnalysisIssuePreviewOverlay overlay,
            Map<UUID, BigDecimal> typedOutputByMaterialLine) {
        AnalysisHeader header = previewableHeader(analysisId);
        // 锚点配额的基线 = 建计划之前那次刷新的需求(真实下达里是入口刷新, 有新锚点/让料补充时是
        // 其后那次刷新); 预览里就是 overlay 此刻持有的实况投影, 不是库内上次刷新留下的旧值。
        Map<UUID, BigDecimal> previous = projectedAnchorParentRequirements(analysisId, overlay);
        projectPreview(analysisId, header.warehouseId(), typedOutputByMaterialLine, overlay, false);
        AnalysisView view = detailInternal(analysisId, false, overlay);
        if (previous.isEmpty()) return view;
        boolean adjusted = false;
        for (AnchorQuotaChange change : planAnchorQuotaChanges(analysisId, view, previous)) {
            // 与真实 UPDATE 的守卫同口径: 退到 0 不在这里做(走撤回链路)。
            if (change.previousRequested().add(change.delta()).signum() <= 0) continue;
            overlay.addSourceQuantities(change.anchorId(), change.delta(),
                    BigDecimal.ZERO, BigDecimal.ZERO, BigDecimal.ZERO);
            overlay.addInternalCommitment(change.parentNodeRef(), change.delta());
            adjusted = true;
        }
        if (!adjusted) return view;
        projectPreview(analysisId, header.warehouseId(), typedOutputByMaterialLine, overlay, false);
        return detailInternal(analysisId, false, overlay);
    }

    private AnalysisHeader previewableHeader(UUID analysisId) {
        AnalysisHeader header = readHeader(analysisId);
        if (!isOpenForFulfillment(header)) {
            throw conflict("物料分析已结束，不能预览下达");
        }
        if (header.warehouseId() == null) {
            throw conflict("物料分析未选择目标仓库");
        }
        return header;
    }

    /**
     * 下达预览第一步: 与真实下达入口的 refreshLocked 同一组计算——不含本批、按实况库存投影一次
     * (仓库命令不刷新分析, 库内快照可能已旧)。BOM 结构与库内快照不一致时在这里 409。
     */
    void projectIssuePreviewBase(UUID analysisId, MaterialAnalysisIssuePreviewOverlay overlay) {
        projectPreview(analysisId, previewableHeader(analysisId).warehouseId(), Map.of(), overlay, true);
    }

    /** 真实下达建锚点/补让料配额之后、建计划之前的那次刷新(不含本批计划与层级填数)。 */
    AnalysisView reprojectIssuePreview(UUID analysisId, MaterialAnalysisIssuePreviewOverlay overlay) {
        projectPreview(analysisId, previewableHeader(analysisId).warehouseId(), Map.of(), overlay, false);
        return detailInternal(analysisId, false, overlay);
    }

    /** 当前投影下的分析视图(与 GET 详情同一个构建器)。 */
    AnalysisView issuePreviewDetail(UUID analysisId, MaterialAnalysisIssuePreviewOverlay overlay) {
        return detailInternal(analysisId, false, overlay);
    }

    /** {@link #makeAnchorParentRequirements} 的投影版: 需求取 overlay 此刻持有的投影值。 */
    private Map<UUID, BigDecimal> projectedAnchorParentRequirements(
            UUID analysisId, MaterialAnalysisIssuePreviewOverlay overlay) {
        Map<UUID, BigDecimal> stored = makeAnchorParentRequirements(analysisId);
        if (stored.isEmpty()) return stored;
        Map<UUID, String> refs = new HashMap<>();
        activeBomMaterialIds(analysisId).forEach((ref, id) -> refs.put(id, ref));
        Map<UUID, BigDecimal> projected = new LinkedHashMap<>();
        stored.forEach((id, required) -> {
            String ref = refs.get(id);
            MaterialAnalysisIssuePreviewOverlay.NodeSnapshot node = ref == null ? null : overlay.node(ref);
            MaterialAnalysisIssuePreviewOverlay.RootSnapshot root = overlay.root(id);
            projected.put(id, node != null ? node.required() : root != null ? root.required() : required);
        });
        return projected;
    }

    /** 下达预览只读取表头, 不取锁。 */
    AnalysisHeader readOnlyHeader(UUID analysisId) {
        return readHeader(analysisId);
    }

    /**
     * 下达预览(ADR-116)里的一张「本批计划」, 已由命令服务按真实下达的同一套校验解析好:
     * [lineId] 是计划挂的分析行(来源行或既有锚点); 为 null 时表示真实下达会当场为
     * [newAnchorParentMaterialId] 新建锚点(其初始配额已由命令服务作为内部承诺叠入)。
     * [growPlanId] 非空表示按 ADR-104 并入那张既有计划; 并入的是草稿且立即审核时,
     * [growDraftSubmittedQty] 是该计划关联行原有的已提交量——审核会把它一并转成已审核。
     */
    record IssuePreviewSeed(UUID lineId, UUID newAnchorParentMaterialId,
                            BigDecimal qty, BigDecimal demandQty, BigDecimal surplusQty, UUID growPlanId,
                            BigDecimal growDraftSubmittedQty) {}

    /**
     * 把本批计划折成「真实下达后重读会多出来的事实」叠进 [overlay]: 分析行的归需求量/
     * 公共备货量(计划关联行触发器同步到分析行的那两列)、计划批次、锚点父节点的计划产出、
     * 顶层供给行的未完工计划量。
     */
    void addIssuePreviewSeeds(UUID analysisId, List<IssuePreviewSeed> seeds, boolean approveNow,
            MaterialAnalysisIssuePreviewOverlay overlay) {
        if (seeds.isEmpty()) return;
        Map<UUID, SourceLine> sources = loadSourceLines(analysisId, false).stream()
                .collect(Collectors.toMap(SourceLine::analysisItemId, source -> source));
        // 分析行 → 其锚点父物料行的两种键: 计划产出(父节点键)与计划批次(顶层供给行按来源汇总)。
        Map<UUID, String[]> anchorParents = new HashMap<>();
        for (Object[] row : NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT item.id, parent.analysis_item_id || '|' || parent.node_key,
                       parent.analysis_item_id || '|'
                           || CASE WHEN parent.node_role = 'ROOT_SUPPLY' THEN '' ELSE parent.node_key END
                FROM production_material_analysis_items item
                JOIN production_material_analysis_materials parent
                  ON parent.id = item.parent_analysis_material_id
                 AND parent.analysis_id = item.analysis_id
                 AND parent.active = TRUE
                WHERE item.analysis_id = :analysisId AND item.is_deleted = FALSE
                  AND item.source_type = 'MAKE_COMPONENT'
                """).setParameter("analysisId", analysisId))) {
            anchorParents.put(uuid(row[0]), new String[] {string(row[1]), string(row[2])});
        }
        List<UUID> newAnchorParents = seeds.stream().map(IssuePreviewSeed::newAnchorParentMaterialId)
                .filter(Objects::nonNull).distinct().toList();
        Map<UUID, String[]> materialRefs = new HashMap<>();
        if (!newAnchorParents.isEmpty()) {
            for (Object[] row : NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                    SELECT id, analysis_item_id || '|' || node_key,
                           analysis_item_id || '|' || CASE WHEN node_role = 'ROOT_SUPPLY' THEN '' ELSE node_key END
                    FROM production_material_analysis_materials
                    WHERE analysis_id = :analysisId AND active = TRUE AND id IN (:ids)
                    """).setParameter("analysisId", analysisId).setParameter("ids", newAnchorParents))) {
                materialRefs.put(uuid(row[0]), new String[] {string(row[1]), string(row[2])});
            }
        }
        BigDecimal zero = BigDecimal.ZERO;
        for (IssuePreviewSeed seed : seeds) {
            if (seed.lineId() == null) {
                String[] refs = materialRefs.get(seed.newAnchorParentMaterialId());
                if (refs == null) throw conflict("候选物料节点不存在或路线未确认，请刷新后重试");
                overlay.appendBatch(refs[1], seed.qty());
                overlay.addPlannedOutput(refs[0], seed.qty());
                continue;
            }
            SourceLine source = sources.get(seed.lineId());
            if (source == null) throw validation("待生成计划产品不属于当前分析");
            BigDecimal draftSubmitted = approveNow ? seed.growDraftSubmittedQty() : zero;
            overlay.addSourceQuantities(seed.lineId(), zero,
                    approveNow ? draftSubmitted.negate() : seed.demandQty(),
                    approveNow ? seed.demandQty().add(draftSubmitted) : zero, seed.surplusQty());
            BigDecimal baseQty = seed.qty().multiply(source.unitRate());
            String[] parent = anchorParents.get(seed.lineId());
            if (seed.growPlanId() != null) overlay.growPlanBatch(seed.growPlanId(), baseQty);
            else overlay.appendBatch(parent == null ? seed.lineId() + "|" : parent[1], baseQty);
            if (parent != null) overlay.addPlannedOutput(parent[0], seed.qty());
            overlay.addOpenPlanQty(seed.lineId(), baseQty);
        }
        // No physical balance means no route can create a physical reservation. Keep the
        // large empty-stock planning case at one indexed existence query, not one lookup per plan.
        boolean physicalStock = approveNow && Boolean.TRUE.equals(em.createNativeQuery("""
                SELECT EXISTS(SELECT 1 FROM stock_balances stock WHERE stock.qty>0 AND (
                    EXISTS(SELECT 1 FROM production_material_analysis_materials material
                        WHERE material.analysis_id=:analysis AND material.active AND material.goods_id=stock.goods_id
                          AND material.color_id IS NOT DISTINCT FROM stock.color_id)
                    OR EXISTS(SELECT 1 FROM production_plans plan JOIN production_material_demands demand ON demand.plan_id=plan.id
                        WHERE plan.material_analysis_id=:analysis AND NOT plan.is_deleted AND NOT demand.is_deleted
                          AND demand.goods_id=stock.goods_id AND demand.color_id IS NOT DISTINCT FROM stock.color_id)))
                """).setParameter("analysis",analysisId).getSingleResult());
        if (physicalStock) new MaterialAnalysisReservationPreview(em, reservationPreviewReadiness.getObject(),
                reservationPreviewSources.getObject()).project(analysisId, readHeader(analysisId).warehouseId(),
                seeds, sources, refreshTree(analysisId,false,Map.of(),overlay).nodes(),
                loadMaterialRows(analysisId,overlay),overlay);
    }

    /** 下达预览的一轮刷新投影: 与 {@link #refreshLocked} 同一组计算, 结果只进 [overlay]。 */
    private void projectPreview(UUID analysisId, UUID warehouseId, Map<UUID, BigDecimal> typedOutputByMaterialLine,
            MaterialAnalysisIssuePreviewOverlay overlay, boolean requireStoredStructure) {
        RefreshTree tree = refreshTree(analysisId, false, typedOutputByMaterialLine, overlay);
        if (requireStoredStructure) requireStoredStructure(analysisId, tree.nodes());
        AvailabilitySnapshot availability = availability(analysisId, warehouseId, tree.nodes(), tree.sources(), overlay);
        List<NodeSnapshotRow> snapshotRows = nodeSnapshotRows(tree, availability);
        AllocationSnapshot allocation = computeAllocationSnapshot(analysisId, warehouseId, tree.sources(),
                tree.nodes(), availability, snapshotRows, typedOutputByMaterialLine, overlay);
        Map<String, MaterialAnalysisIssuePreviewOverlay.NodeSnapshot> nodes = new HashMap<>();
        for (NodeAllocationRow row : allocation.nodeRows()) {
            nodes.put(nodeRef(row.analysisItemId(), row.nodeKey()), new MaterialAnalysisIssuePreviewOverlay.NodeSnapshot(
                    row.required(), row.available(), row.allocated(), row.reserved(), row.safety(),
                    row.inbound(), row.shortage(), row.expectedReadyDate(), row.lowerPending()));
        }
        // 与 updateSourceReadiness 及其后顶层供给行「非自制根清零齐套列」同口径。
        Map<UUID, BigDecimal[]> ready = new HashMap<>();
        for (SourceReadyRow row : allocation.sourceReadyRows()) {
            ready.put(row.sourceId(), new BigDecimal[] {row.finish(), row.byDate(), row.start(), row.finish(), row.ship()});
        }
        Map<UUID, MaterialAnalysisIssuePreviewOverlay.RootSnapshot> roots = new HashMap<>();
        if (rootSupply != null) {
            BigDecimal zero = BigDecimal.ZERO;
            for (SourceLine source : tree.sources()) {
                if (source.rootMaterialLineId() != null && source.rootRoute() != null
                        && !"MAKE".equals(source.rootRoute())) {
                    ready.put(source.analysisItemId(), new BigDecimal[] {zero, zero, zero, zero, zero});
                }
            }
            Map<String, UUID> materialIds = activeBomMaterialIds(analysisId);
            Map<UUID, BigDecimal> allocatedByMaterial = new HashMap<>();
            nodes.forEach((ref, node) -> {
                UUID id = materialIds.get(ref);
                if (id != null) allocatedByMaterial.put(id, node.allocated());
            });
            Map<UUID, BigDecimal> rootFutureCoverage = new LinkedHashMap<>(
                    activeFutureCoverageByMaterial(analysisId,hasAggregateSources(tree.sources())));
            previewRootAdoptions(tree.sources(), overlay)
                    .forEach((id, qty) -> rootFutureCoverage.merge(id, qty, BigDecimal::add));
            for (MaterialAnalysisRootSupplyService.RootQuantityRow row : rootSupply.projectRootNodes(analysisId,
                    rootFutureCoverage, allocatedByMaterial, overlay.openPlanQtyBySource(), overlay)) {
                roots.put(row.id(), new MaterialAnalysisIssuePreviewOverlay.RootSnapshot(row.required(), row.stock(),
                        row.reserved(), row.safety(), row.allocated(), row.shortage(), row.inbound()));
            }
        }
        overlay.replaceSnapshots(nodes, ready, roots);
    }

    /** Pending root adoption is a projected external promise, never physical stock or a stored claim. */
    private static Map<UUID, BigDecimal> previewRootAdoptions(
            List<SourceLine> sources, MaterialAnalysisIssuePreviewOverlay overlay) {
        if (overlay.isNone() || overlay.rootPublicAdoption().isEmpty()) return Map.of();
        Map<UUID, BigDecimal> result = new LinkedHashMap<>();
        for (SourceLine source : sources) {
            BigDecimal adopted = overlay.rootPublicAdoption().getOrDefault(source.analysisItemId(), BigDecimal.ZERO);
            if (source.rootMaterialLineId() != null && adopted.signum() > 0) {
                result.merge(source.rootMaterialLineId(), adopted, BigDecimal::add);
            }
        }
        return result;
    }

    /**
     * 预览不做结构决定: 需要新增/停用节点或改写结构列时, 请先刷新分析。
     * 只比结构列(ADR-129 §2.5)：用量锁定在快照里，预览按同一锁定值展开，用量不同不拦。
     */
    private void requireStoredStructure(UUID analysisId, List<BomNode> nodes) {
        MaterialAnalysisSnapshotBaseline baseline = MaterialAnalysisSnapshotBaseline.load(em, analysisId,
                NODE_GUARD.stream().map(NodeColumn::name).toList());
        Set<String> refs = new HashSet<>();
        for (BomNode node : nodes) {
            refs.add(nodeRef(node.analysisItemId(), node.nodeKey()));
            if (!baseline.unchangedStructure(node.analysisItemId(), node.nodeKey(), nodeValues(node, NODE_GUARD))) {
                throw conflict("物料分析的 BOM 结构已变化，请先刷新分析再预览下达");
            }
        }
        if (activeBomMaterialIds(analysisId).size() != refs.size()) {
            throw conflict("物料分析的 BOM 结构已变化，请先刷新分析再预览下达");
        }
    }

    /** 活动 BOM 物料行: 节点键 → 物料行 id。 */
    private Map<String, UUID> activeBomMaterialIds(UUID analysisId) {
        Map<String, UUID> result = new HashMap<>();
        for (Object[] row : NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT analysis_item_id, node_key, id
                FROM production_material_analysis_materials
                WHERE analysis_id = :analysisId AND active = TRUE AND node_role = 'BOM_COMPONENT'
                """).setParameter("analysisId", analysisId))) {
            result.put(nodeRef(uuid(row[0]), string(row[1])), uuid(row[2]));
        }
        return result;
    }

    /**
     * 让自制锚点的配额跟着来源需求走。
     *
     * <p>涨：只认**新增的来源需求**，老的物理缺口不能把配额撑大。</p>
     *
     * <p>落(2026-09-21 用户口径「假如没有下单, 立马把父件改回 1000, 子件也要立马
     * 变回 1000」)：把**从来没下达过**的那部分配额退回来。地板是
     * `submitted + approved`——已经提交/已审核的计划是冻结承诺, 一分不动(与
     * `cancelMakeDemandRow` 同一道地板)。不退的话, 把来源数量调高再调回来, 锚点
     * 就永久停在高位, 子件那一行的「还需安排」再也降不下来, 只能删掉整条分析重建。
     * 行动背书的锚点(通知供给建的)不在这里退, 它有自己的撤回链路。</p>
     */
    private boolean growMakeAnchorQuotasAfterSourcePreview(
            UUID analysisId, Map<UUID, BigDecimal> previousRequirements) {
        if (previousRequirements.isEmpty()) return false;
        boolean changed=false;
        for (AnchorQuotaChange change : planAnchorQuotaChanges(
                analysisId, detailInternal(analysisId,false), previousRequirements)) {
            if (change.delta().signum()<0) {
                BigDecimal decrease=change.delta().negate();
                // 齐套列(ready_*)是按旧配额算的, 紧跟着的那次 refreshLocked 会重算,
                // 但本条 UPDATE 必须先把它们压回新配额的余量内, 否则撞
                // production_material_analysis_item_qty_chk。退到 0 不在这里做
                // ——那是「这条子件任务整个不要了」, 走撤回链路软删, 不是改量。
                int shrunk=em.createNativeQuery("""
                        UPDATE production_material_analysis_items
                        SET requested_qty=requested_qty-:decrease,
                            ready_now_qty=LEAST(ready_now_qty,
                                requested_qty-:decrease-submitted_qty-approved_qty),
                            ready_by_date_qty=LEAST(ready_by_date_qty,
                                requested_qty-:decrease-submitted_qty-approved_qty),
                            ready_start_qty=LEAST(ready_start_qty,
                                requested_qty-:decrease-submitted_qty-approved_qty),
                            ready_finish_qty=LEAST(ready_finish_qty,
                                requested_qty-:decrease-submitted_qty-approved_qty),
                            ready_ship_qty=LEAST(ready_ship_qty,
                                requested_qty-:decrease-submitted_qty-approved_qty),
                            updated_by=:actor,updated_at=now()
                        WHERE id=:child AND analysis_id=:analysis AND parent_analysis_material_id=:parent
                          AND source_type='MAKE_COMPONENT' AND is_deleted=FALSE AND requested_qty=:previous
                          AND requested_qty-:decrease>=submitted_qty+approved_qty
                          AND requested_qty-:decrease>0
                        """).setParameter("decrease",decrease).setParameter("actor",currentUser.requireId())
                        .setParameter("child",change.anchorId()).setParameter("analysis",analysisId)
                        .setParameter("parent",change.parentMaterialId())
                        .setParameter("previous",change.previousRequested())
                        .executeUpdate();
                if (shrunk==1) changed=true;
                continue;
            }
            int updated=em.createNativeQuery("""
                    UPDATE production_material_analysis_items
                    SET requested_qty=requested_qty+:increase,updated_by=:actor,updated_at=now()
                    WHERE id=:child AND analysis_id=:analysis AND parent_analysis_material_id=:parent
                      AND source_type='MAKE_COMPONENT' AND is_deleted=FALSE AND requested_qty=:previous
                    """).setParameter("increase",change.delta()).setParameter("actor",currentUser.requireId())
                    .setParameter("child",change.anchorId()).setParameter("analysis",analysisId)
                    .setParameter("parent",change.parentMaterialId()).setParameter("previous",change.previousRequested())
                    .executeUpdate();
            if (updated!=1) throw conflict("计划锚点需求已变化，请刷新后重试");
            changed=true;
        }
        return changed;
    }

    /**
     * 自制锚点配额的一次调整: delta 为正是涨、为负是退; parentNodeRef 是锚点父物料行的
     * 节点键(内部承诺按它汇总); 退的那一侧只在「退后仍 ≥ 已提交+已审核且 > 0」时生效。
     */
    private record AnchorQuotaChange(UUID anchorId, UUID parentMaterialId, String parentNodeRef,
                                     BigDecimal previousRequested, BigDecimal delta) {}

    /**
     * 锚点配额该怎么调(纯计算, 不写库): 真实刷新据此执行 UPDATE, 下达预览(ADR-116)
     * 把同一组调整叠进内存投影——两条路径同一套规则。
     */
    private List<AnchorQuotaChange> planAnchorQuotaChanges(
            UUID analysisId, AnalysisView view, Map<UUID, BigDecimal> previousRequirements) {
        Map<UUID,ProductView> products=view.products().stream()
                .collect(Collectors.toMap(ProductView::analysisLineId,product->product));
        Map<UUID,BigDecimal> actionBackedAnchors=null;
        List<AnchorQuotaChange> changes=new ArrayList<>();
        for (MaterialView material:view.flatMaterials()) {
            BigDecimal previous=previousRequirements.get(material.materialLineId());
            if (previous==null || material.planAnchorAnalysisLineId()==null) continue;
            BigDecimal delta=material.requiredQty().subtract(previous);
            if (delta.signum()==0) continue;
            BigDecimal admittedIncrease=delta.max(BigDecimal.ZERO);
            ProductView anchor=products.get(material.planAnchorAnalysisLineId());
            if (anchor==null || !SOURCE_MAKE_COMPONENT.equals(anchor.sourceType())
                    || !Objects.equals(anchor.goodsId(),material.goodsId())
                    || !Objects.equals(anchor.colorId(),material.colorId())
                    || !Objects.equals(anchor.unitId(),material.unitId())) {
                if (delta.signum()<0) continue;
                throw conflict("来源变化后的物料与原计划锚点不一致，请先核对原任务");
            }
            String blocked=view.planningBlockedReasons().get(material.analysisLineId());
            if (blocked!=null) {
                if (delta.signum()<0) continue;
                throw conflict(blocked);
            }
            String parentNodeRef=nodeRef(material.analysisLineId(),material.nodeKey());
            if (delta.signum()<0) {
                if (actionBackedAnchors==null) actionBackedAnchors=actionBackedAnchorQuantities(analysisId);
                // 行动背书的那一截由撤回链路管, 不在这里退; 其余(下达车间建的锚点
                // 本来就没有行动)照退。涨的那一侧对行动背书锚点也是加的, 只退不涨
                // 或只涨不退都会让配额单向漂移。
                BigDecimal actionFloor=actionBackedAnchors
                        .getOrDefault(anchor.analysisLineId(),BigDecimal.ZERO);
                BigDecimal decrease=delta.negate().min(anchor.remainingQty())
                        .min(anchor.requestedQty().subtract(actionFloor).max(BigDecimal.ZERO))
                        .max(BigDecimal.ZERO).setScale(4,RoundingMode.DOWN);
                if (decrease.signum()==0) continue;
                changes.add(new AnchorQuotaChange(anchor.analysisLineId(),material.materialLineId(),
                        parentNodeRef,anchor.requestedQty(),decrease.negate()));
                continue;
            }
            // Unplanned, submitted and approved-but-not-inbound quantities are one quota,
            // including old action-backed anchors. Do not add the action quantity a second time.
            BigDecimal openQuota=anchor.requestedQty().subtract(anchor.planExecutionInboundQty()).max(BigDecimal.ZERO);
            BigDecimal increase=material.demandSupplyGapQty().subtract(openQuota).max(BigDecimal.ZERO)
                    .min(admittedIncrease).setScale(4,RoundingMode.CEILING);
            if (increase.signum()==0) continue;
            changes.add(new AnchorQuotaChange(anchor.analysisLineId(),material.materialLineId(),
                    parentNodeRef,anchor.requestedQty(),increase));
        }
        return changes;
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
                  AND source_type NOT IN ('MAKE_COMPONENT','AGGREGATE_MAKE')
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
        requireManualSourceMasters(requestedByIdentity.keySet().stream()
                .filter(identity -> !SOURCE_SALES.equals(identity.sourceType())).toList());
        for (Object[] row : rows) {
            SourceIdentity identity = new SourceIdentity(
                    string(row[1]), uuid(row[2]), uuid(row[3]), uuid(row[4]),
                    uuid(row[5]), blankToNull(string(row[6])));
            PreviewItem requestedItem = requestedByIdentity.get(identity);
            if (requestedItem == null) {
                throw conflict("刷新不能改变物料分析的来源集合");
            }
            LocalDate deliveryDate = requestedItem.deliveryDate();
            if (SOURCE_SALES.equals(identity.sourceType()) && deliveryDate == null) {
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
                  AND source_type NOT IN ('MAKE_COMPONENT','AGGREGATE_MAKE')
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

    /** 需求编号的规范形：与 {@link SourceIdentity} 相同(去首尾空白+小写)，去重键、分组与冲突判定共用。 */
    static String canonicalSourceRef(String sourceRef) {
        return sourceRef == null ? "" : sourceRef.strip().toLowerCase(Locale.ROOT);
    }

    private SourceIdentity sourceIdentity(PreviewItem item) {
        String source = sourceType(item);
        return SOURCE_SALES.equals(source)
                ? new SourceIdentity(source, item.salesOrderItemId(), null, null, null, null)
                : new SourceIdentity(source, null, item.goodsId(), item.colorId(),
                        item.unitId(), blankToNull(item.sourceRef()));
    }

    /**
     * 按一个固定顺序一次取齐本次请求的全部来源锁：每个来源身份一把；每个手工需求编号再加一把编号锁
     * (ADR-130)，同一编号下不同货品的并发请求也在这里排队，不会各建一份分析。编号锁的键由 SQL 用与
     * V738 触发器 fn_guard_manual_demand_single_analysis 逐字相同的表达式拼出，落库时触发器重入同一把锁。
     */
    private void lockSourceIdentities(List<PreviewItem> items) {
        Map<String, Runnable> locks = new TreeMap<>();
        for (PreviewItem item : items) {
            SourceIdentity identity = sourceIdentity(item);
            String identityKey = "MATERIAL-ANALYSIS-SOURCE:" + identity.canonical();
            locks.putIfAbsent(identityKey, () -> em.createNativeQuery("""
                    SELECT pg_advisory_xact_lock(hashtextextended(:lockKey,0))
                    """).setParameter("lockKey", identityKey).getSingleResult());
            if (!MANUAL_SOURCE_TYPES.contains(identity.sourceType())) continue;
            locks.putIfAbsent("MATERIAL-ANALYSIS-MANUAL-REF:" + identity.sourceType() + "|" + identity.sourceRef(),
                    () -> em.createNativeQuery("""
                            SELECT pg_advisory_xact_lock(hashtextextended(
                                'MATERIAL-ANALYSIS-MANUAL-REF:' || :sourceType || '|' || lower(btrim(:sourceRef)), 0))
                            """).setParameter("sourceType", identity.sourceType())
                            .setParameter("sourceRef", item.sourceRef()).getSingleResult());
        }
        locks.values().forEach(Runnable::run);
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
        return loadSourceLines(analysisId, lockSales, MaterialAnalysisIssuePreviewOverlay.NONE);
    }

    /** Internal command read under the existing analysis/source locks. No page
     * stock, workflow, supplier or history projections are needed to create a plan. */
    Map<UUID,MaterialAnalysisPlanSource> aggregatePlanSources(UUID analysisId,Set<UUID> anchorIds) {
        if (anchorIds.isEmpty()) return Map.of();
        Map<UUID,MaterialAnalysisPlanSource> result=new LinkedHashMap<>();
        for (SourceLine source:loadSourceLines(analysisId,false,MaterialAnalysisIssuePreviewOverlay.NONE,anchorIds)) {
            if (!anchorIds.contains(source.analysisItemId())) continue;
            if (!SOURCE_AGGREGATE_MAKE.equals(source.sourceType())) {
                throw new ApiException(ErrorCode.CONFLICT,"生产锚点的真实来源类型已变化，请重新核对");
            }
            result.put(source.analysisItemId(),source);
        }
        if (result.size()!=anchorIds.size()) {
            throw new ApiException(ErrorCode.CONFLICT,"生产锚点的真实来源已失效，请重新核对");
        }
        return Map.copyOf(result);
    }

    /** [overlay] 非空时(下达预览, ADR-116)把本批计划与锚点配额、齐套重算结果叠到库内来源行上。 */
    private List<SourceLine> loadSourceLines(
            UUID analysisId, boolean lockSales, MaterialAnalysisIssuePreviewOverlay overlay) {
        return loadSourceLines(analysisId,lockSales,overlay,null);
    }

    /** Selected-plan admission reads its complete ancestor chain, not every sibling plan. */
    private List<SourceLine> loadSourceLines(UUID analysisId,boolean lockSales,
            MaterialAnalysisIssuePreviewOverlay overlay,Set<UUID> selectedItemIds) {
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
        String selected=selectedItemIds==null ? "" : """
                WITH RECURSIVE selected_source_ids(id) AS (
                  SELECT id FROM production_material_analysis_items
                  WHERE analysis_id=:id AND id IN(:selectedItemIds) AND NOT is_deleted
                  UNION
                  SELECT parent.id FROM selected_source_ids selected
                  JOIN production_material_analysis_items child ON child.id=selected.id
                  JOIN production_material_analysis_materials material ON material.id=child.parent_analysis_material_id
                  JOIN production_material_analysis_items parent ON parent.id=material.analysis_item_id
                  WHERE parent.analysis_id=:id
                )
                """;
        Query sourceQuery=em.createNativeQuery(selected+"""
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
                       ai.root_material_id, CASE WHEN ai.source_type='AGGREGATE_MAKE' THEN COALESCE((
                         SELECT SUM(shared_item.iqty*shared_item.unit_rate)
                         FROM production_plan_items shared_item JOIN production_plans shared_plan ON shared_plan.id=shared_item.plan_id
                         WHERE shared_plan.material_analysis_item_id=ai.id AND NOT shared_plan.is_deleted
                           AND shared_plan.status=1 AND NOT shared_plan.is_canceled AND NOT shared_item.is_deleted),0)
                         ELSE ai.root_fulfilled_qty END, root_material.confirmed_route,
                       g.owning_warehouse_id, owning_warehouse.name,
                       g.owning_workshop_department_id, owning_workshop.name,
                       COALESCE(planned_surplus.qty, 0),
                       COALESCE(root_subcontract.qty, 0)
                FROM production_material_analysis_items ai
                JOIN goods g ON g.id = ai.goods_id
                JOIN units u ON u.id = ai.unit_id
                LEFT JOIN LATERAL (
                    -- ADR-143 §4.5：顶层委外件(顶层供给行确认为委外)的计划产出 = 它那几笔未结
                    -- 委外申请的申请量 + 公共超量 − 合格入库回厂量(只算我方领料发外的份额,
                    -- 基本单位)。第 1 层直属物料按来源行展开、不经 parentSupply, 所以并到这里。
                    SELECT SUM(
                """ + SUBCONTRACT_PLANNED_OUTPUT_SQL + """
                           ) AS qty
                    FROM production_material_analysis_materials root
                    JOIN preplan_supply_action_allocations allocation
                      ON allocation.analysis_material_id = root.id
                    JOIN preplan_supply_actions action
                      ON action.id = allocation.action_id
                    WHERE root.analysis_id = ai.analysis_id
                      AND root.analysis_item_id = ai.id
                      AND root.node_role = 'ROOT_SUPPLY'
                      AND action.operation_type = 'SUPPLY'
                      AND action.route = 'SUBCONTRACT'
                      AND action.status IN ('OPEN','CREATED','IN_PROGRESS')
                      AND action.requested_qty > 0
                ) root_subcontract ON TRUE
                LEFT JOIN LATERAL (
                    -- 计划量单一入口(ADR-099)：本来源行已下达且仍有效的计划里
                    -- 超出需求的公共备货产出合计。它与 submitted/approved 一起
                    -- 构成「计划产出量」，下层物料按计划产出量展开。
                    SELECT SUM(link.public_surplus_qty) AS qty
                    FROM production_material_analysis_plan_links link
                    WHERE link.analysis_id = ai.analysis_id
                      AND link.analysis_item_id = ai.id
                      AND link.allocation_status IN ('SUBMITTED','APPROVED')
                ) planned_surplus ON TRUE
                LEFT JOIN warehouses owning_warehouse
                  ON owning_warehouse.id = g.owning_warehouse_id
                LEFT JOIN departments owning_workshop
                  ON owning_workshop.id = g.owning_workshop_department_id
                 AND owning_workshop.is_deleted = FALSE
                LEFT JOIN colors col ON col.id = ai.color_id
                LEFT JOIN sales_order_items soi ON soi.id = ai.sales_order_item_id
                LEFT JOIN sales_orders so ON so.id = soi.order_id
                LEFT JOIN clients c ON c.id = so.client_id
                LEFT JOIN LATERAL (
                    -- 2026-09-15（V588 单计划超量）：分析来源的草稿计划只把
                    -- 「归本需求的量」（plan link 的 submitted_qty）计入销售
                    -- 容量占用——公共备货产出（public_surplus_qty）不占订单
                    -- 可排量，否则「需求 1000 实下 5000」会在自身审核的二次
                    -- 校验里把剩余可排算成负数（available = 需求 − 超量）。
                    -- 非分析的手工草稿照旧整行计入（1:1 销售来源）。
                    SELECT SUM(CASE
                        WHEN link.id IS NOT NULL THEN link.submitted_qty
                        ELSE pi.qty END) AS qty
                    FROM production_plan_items pi
                    JOIN production_plans p ON p.id = pi.plan_id
                    LEFT JOIN production_material_analysis_plan_links link
                      ON link.plan_id = p.id
                     AND link.analysis_id = p.material_analysis_id
                     AND link.analysis_item_id = p.material_analysis_item_id
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
                """+(selectedItemIds==null?"":" AND ai.id IN(SELECT id FROM selected_source_ids)\n")+"""
                ORDER BY ai.line_priority, ai.delivery_date NULLS LAST, ai.id
                """).setParameter("id", analysisId);
        if(selectedItemIds!=null)sourceQuery.setParameter("selectedItemIds",selectedItemIds);
        List<Object[]> rows = NativeQueryResults.objectArrayRows(sourceQuery);
        List<SourceLine> sources = rows.stream().map(SourceLine::from).toList();
        if (overlay.isNone()) return sources;
        return sources.stream().map(source -> {
            MaterialAnalysisIssuePreviewOverlay.SourceDelta delta = overlay.source(source.analysisItemId());
            return delta == null ? source : source.withPreview(delta);
        }).toList();
    }

    private void validateSourceCapacity(List<SourceLine> sources) {
        requirePlanningSources(sources, sources.stream()
                .map(SourceLine::analysisItemId).collect(Collectors.toSet()));
    }

    void requirePlanningSources(UUID analysisId, Set<UUID> selectedItemIds) {
        requirePlanningSources(loadSourceLines(analysisId, false,
                MaterialAnalysisIssuePreviewOverlay.NONE,selectedItemIds), selectedItemIds);
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

    /** 不带分析快照的读取(下达/审批的第一层结构签名、结构测试)：全部按新节点取现时用量。 */
    private List<BomNode> loadBomTrees(List<SourceLine> sources) {
        return loadBomTrees(sources, BomUsageContext.LIVE);
    }

    private List<BomNode> loadBomTrees(List<SourceLine> sources, BomUsageContext usageContext) {
        // BUY roots own external supply; child items only anchor plans and never
        // duplicate the material tree retained on their original source item.
        List<SourceLine> roots = sources.stream()
                .filter(source -> !"BUY".equals(source.rootRoute()))
                .filter(source -> !SOURCE_MAKE_COMPONENT.equals(source.sourceType()))
                .toList();
        Map<UUID, List<Object[]>> rows = new MaterialAnalysisBomSnapshotReader(em).read(roots);
        Set<String> outboundNodes = subcontractOutboundNodes(roots, rows, usageContext.routes());
        List<BomNode> result = new ArrayList<>();
        for (SourceLine source : roots) {
            result.addAll(bomNodes(source, rows.getOrDefault(source.analysisItemId(), List.of()),
                    usageContext, outboundNodes));
        }
        return List.copyOf(result);
    }

    /**
     * 由快照读取行建节点(ADR-129 §2.5)。已有节点(同一节点键、同一条 BOM 边且组件、单位与计量
     * 规则都没变)沿用快照锁定的设计/真实使用数量(连同有效批次与不良率)；原地改了组件或计量规则的边
     * 按新节点整组取现时值，锁定值只在原规则下有意义，锁定值与现时值不混用。每个节点再按父节点路线选用量。单耗在这里逐层算
     * (6 位向上取整)并作为下一层的父件单耗，与写入列的精度一致，刷新不会误判变化。
     */
    static List<BomNode> bomNodes(SourceLine source, List<Object[]> rows,
            BomUsageContext usageContext, Set<String> subcontractOutboundNodes) {
        List<BomNode> result = new ArrayList<>();
        Map<String, BomNode> byNodeKey = new LinkedHashMap<>();
        for (Object[] row : rows) {
            if (row[4] == null) {
                throw conflict("BOM 组件未维护有效基本单位，不能进行物料分析");
            }
            int depth = integer(row[5]);
            String nodeKey = string(row[6]);
            String parentNodeKey = string(row[7]);
            BigDecimal parentPerProductQty;
            BigDecimal parentOutputQty;
            if (depth == 1) {
                parentPerProductQty = source.unitRate();
                parentOutputQty = source.plannedOutputQty().multiply(source.unitRate());
            } else {
                BomNode parent = byNodeKey.get(parentNodeKey);
                if (parent == null) {
                    throw conflict("BOM 层级路径不完整，无法计算子件需求");
                }
                parentPerProductQty = parent.perProductQty();
                // Gross first pass: this discovers every downstream stock dimension. The
                // persisted tree is rebased from each parent's stock-backed shortage later.
                parentOutputQty = parent.snapshotRequiredQty();
            }
            UUID bomItemId = uuid(row[0]);
            String ref = nodeRef(source.analysisItemId(), nodeKey);
            String consumptionBasis = string(row[20]);
            BigDecimal basisOutputQty = decimal(row[21]);
            boolean allowPartialPackage = Boolean.TRUE.equals(row[22]);
            PinnedUsage pinned = usageContext.pinned().get(ref);
            if (pinned != null && !pinned.sameEdgeRule(bomItemId, uuid(row[2]), uuid(row[4]),
                    consumptionBasis, basisOutputQty, allowPartialPackage)) pinned = null;
            BomUsage usage = BomUsage.choose(
                    pinned == null ? decimal(row[8]) : pinned.designQty(),
                    pinned == null ? optionalDecimal(row[9]) : pinned.actualQty(),
                    pinned == null ? longValue(row[25]) : pinned.sampleCount(),
                    pinned == null ? optionalDecimal(row[27]) : pinned.defectRate(),
                    string(row[10]), Boolean.TRUE.equals(row[26]),
                    subcontractOutboundNodes.contains(ref));
            BigDecimal perProductQty;
            BigDecimal snapshotRequired;
            try {
                perProductQty = MaterialConsumptionMath.effectivePerProduct(
                        parentPerProductQty, usage.usedQty(), consumptionBasis, basisOutputQty);
                snapshotRequired = MaterialConsumptionMath.required(
                        parentOutputQty, usage.usedQty(), consumptionBasis,
                        basisOutputQty, allowPartialPackage);
            } catch (IllegalArgumentException ex) {
                throw conflict("BOM 包装/批次计量数据无效，不能进行物料分析");
            }
            boolean hasChildren = Boolean.TRUE.equals(row[18]);
            BomNode node = new BomNode(
                    source.analysisItemId(), bomItemId, uuid(row[1]),
                    uuid(row[2]), uuid(row[3]), uuid(row[4]), depth,
                    nodeKey, parentNodeKey, parentPerProductQty, usage,
                    perProductQty, snapshotRequired,
                    string(row[11]), string(row[12]), string(row[13]), string(row[14]),
                    string(row[15]), decimal(row[16]), suggestion(string(row[17]), hasChildren),
                    hasChildren, string(row[19]), consumptionBasis,
                    basisOutputQty, allowPartialPackage,
                    Boolean.TRUE.equals(row[23]), List.of());
            result.add(node);
            byNodeKey.put(nodeKey, node);
        }
        return List.copyOf(result);
    }

    /**
     * 父节点有效路线是委外的节点(ADR-143 §4.5，推广 ADR-129 §2.5)：委外节点的直属物料都发给委外商，
     * 一律按设计使用数量(合同用量)，与委外领料计划冻结的单耗一致。第 1 层的父节点是来源行的根产品，
     * 看根产品确认的路线；下层看父节点的有效路线(与分配同一口径，新节点按建议)。不看会被路线确认
     * 回写的 goods.source_type。
     */
    private static Set<String> subcontractOutboundNodes(List<SourceLine> roots, Map<UUID, List<Object[]>> rows,
            Map<String, String> routes) {
        Set<String> result = new LinkedHashSet<>();
        for (SourceLine source : roots) {
            Map<String, String> routeByNodeKey = new HashMap<>();
            for (Object[] row : rows.getOrDefault(source.analysisItemId(), List.of())) {
                String nodeKey = string(row[6]);
                String ref = nodeRef(source.analysisItemId(), nodeKey);
                routeByNodeKey.put(nodeKey, routes.getOrDefault(ref,
                        suggestion(string(row[17]), Boolean.TRUE.equals(row[18]))));
                String parentRoute = integer(row[5]) == 1
                        ? source.rootRoute() : routeByNodeKey.get(string(row[7]));
                if ("SUBCONTRACT".equals(parentRoute)) result.add(ref);
            }
        }
        return Set.copyOf(result);
    }

    /**
     * 快照里已锁定的用量与锁定时这条边的规则(组件、单位、计量规则)。锁定值只在原规则下有意义：
     * 同一节点键、同一条 BOM 边且规则没变才沿用。不良率与真实使用数量一起锁定、一起沿用。
     */
    record PinnedUsage(UUID bomItemId, UUID goodsId, UUID unitId, String consumptionBasis,
            BigDecimal basisOutputQty, boolean allowPartialPackage,
            BigDecimal designQty, BigDecimal actualQty, Long sampleCount, BigDecimal defectRate) {
        /** 同一条边、同一计量规则：只有这样，锁定的用量才是按现时这条边的口径表达的。 */
        boolean sameEdgeRule(UUID bomItemId, UUID goodsId, UUID unitId, String consumptionBasis,
                BigDecimal basisOutputQty, boolean allowPartialPackage) {
            return Objects.equals(this.bomItemId, bomItemId) && Objects.equals(this.goodsId, goodsId)
                    && Objects.equals(this.unitId, unitId)
                    && Objects.equals(this.consumptionBasis, consumptionBasis)
                    && (this.basisOutputQty == null ? basisOutputQty == null
                            : basisOutputQty != null && this.basisOutputQty.compareTo(basisOutputQty) == 0)
                    && this.allowPartialPackage == allowPartialPackage;
        }
    }

    /**
     * 按节点选用量所需的库内事实：已锁定用量(键 analysis_item_id|node_key)与各节点的有效路线
     * (确认路线，未确认按建议，与分配同一口径)。{@link #LIVE} = 不带快照，全部取现时值。
     */
    record BomUsageContext(Map<String, PinnedUsage> pinned, Map<String, String> routes) {
        static final BomUsageContext LIVE = new BomUsageContext(Map.of(), Map.of());
    }

    private BomUsageContext bomUsageContext(UUID analysisId) {
        Map<UUID, Map<String, PinnedUsage>> byItem = new HashMap<>();
        for (Object[] row : NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT analysis_item_id, node_key, bom_item_id, goods_id, unit_id, consumption_basis,
                       basis_output_qty, allow_partial_package,
                       COALESCE(design_bom_qty, bom_qty), actual_bom_qty, usage_sample_count, usage_defect_rate
                FROM production_material_analysis_materials
                WHERE analysis_id = :analysisId AND active = TRUE AND node_role = 'BOM_COMPONENT'
                """).setParameter("analysisId", analysisId))) {
            byItem.computeIfAbsent(uuid(row[0]), ignored -> new HashMap<>()).put(string(row[1]), new PinnedUsage(
                    uuid(row[2]), uuid(row[3]), uuid(row[4]), string(row[5]), decimal(row[6]),
                    Boolean.TRUE.equals(row[7]), decimal(row[8]), optionalDecimal(row[9]), longValue(row[10]),
                    optionalDecimal(row[11])));
        }
        return new BomUsageContext(withAggregateAnchorPins(byItem, aggregateMemberSubtrees(analysisId)),
                loadEffectiveRoutes(analysisId));
    }

    /**
     * 已锁定用量按节点键展开，并给共享制造锚点(AGGREGATE_MAKE)还没有自己锁定值的节点补上批次成员
     * 子树里同一相对 BOM 路径(同一条边)的锁定值(ADR-129 §2.5)：汇总预览按第一个成员的子件用量
     * 算需求，锚点第一次展开就得到同一个数，写进计划的也是它。成员按行 id 排序(与预览同序)，
     * 第一个有该节点的成员优先；锚点自己已锁定的节点不动。
     */
    static Map<String, PinnedUsage> withAggregateAnchorPins(Map<UUID, Map<String, PinnedUsage>> byItem,
            Map<UUID, List<AggregateMemberSubtree>> anchorMembers) {
        Map<String, PinnedUsage> pinned = new HashMap<>();
        byItem.forEach((itemId, nodes) -> nodes.forEach((nodeKey, usage) -> pinned.put(nodeRef(itemId, nodeKey), usage)));
        anchorMembers.forEach((anchorId, members) -> {
            for (AggregateMemberSubtree member : members) {
                byItem.getOrDefault(member.analysisItemId(), Map.of()).forEach((nodeKey, usage) -> {
                    String relative = member.relativeNodeKey(nodeKey);
                    if (relative != null) pinned.putIfAbsent(nodeRef(anchorId, relative), usage);
                });
            }
        });
        return Map.copyOf(pinned);
    }

    /**
     * 共享制造批次的一个成员行(汇总时选中的物料行)。锚点树与成员子树按相对 BOM 路径对应：锚点
     * 节点键就是从锚点货品往下的边路径，成员子树节点键是成员节点键加同一段路径(成员是顶层供给行时
     * 就是同一段路径)，与 fn_aggregate_relative_bom_path 同义。
     */
    record AggregateMemberSubtree(UUID materialLineId, UUID analysisItemId, String nodeKey, boolean rootSupply) {
        /** 成员子树里的节点键 → 相对路径；不在本成员子树里为 null。 */
        String relativeNodeKey(String memberTreeNodeKey) {
            if (rootSupply) return memberTreeNodeKey;
            String prefix = nodeKey + "/";
            return memberTreeNodeKey.startsWith(prefix) ? memberTreeNodeKey.substring(prefix.length()) : null;
        }

        /** 相对路径 → 成员子树里的节点键(空路径 = 成员自己；顶层供给行的「自己」对应第 1 层的空父键)。 */
        String memberNodeKey(String relativeNodeKey) {
            if (rootSupply) return relativeNodeKey;
            return relativeNodeKey.isEmpty() ? nodeKey : nodeKey + "/" + relativeNodeKey;
        }
    }

    /** 共享批次的全部成员行 id(建立时的配置加上每次建立/追加事件)，别名 intent(id)；外层须有 batch。 */
    private static final String AGGREGATE_BATCH_MEMBER_IDS = """
                CROSS JOIN LATERAL (
                    SELECT value::uuid AS id FROM jsonb_array_elements_text(batch.configuration_snapshot->'materialLineIds')
                    UNION SELECT value::uuid FROM preplan_aggregate_batch_events event
                        CROSS JOIN LATERAL jsonb_array_elements_text(COALESCE(event.intent_snapshot->'materialLineIds','[]'::jsonb))
                        WHERE event.batch_id=batch.id AND event.event_type IN('CREATE','APPEND')
                ) intent
                """;

    /** 未撤回共享制造批次的锚点 → 仍有效的成员行，按行 id 排序(与汇总预览取第一个成员同序)。 */
    private Map<UUID, List<AggregateMemberSubtree>> aggregateMemberSubtrees(UUID analysisId) {
        Map<UUID, List<AggregateMemberSubtree>> result = new HashMap<>();
        for (Object[] row : NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT batch.anchor_analysis_item_id, member.id, member.analysis_item_id, member.node_key,
                       member.node_role = 'ROOT_SUPPLY'
                FROM preplan_aggregate_batches batch
                JOIN preplan_supply_actions action ON action.id=batch.action_id AND action.status<>'CANCELLED'
                """ + AGGREGATE_BATCH_MEMBER_IDS + """
                JOIN production_material_analysis_materials member ON member.id=intent.id
                    AND member.analysis_id=batch.analysis_id AND member.active
                WHERE batch.analysis_id=:analysisId AND batch.anchor_analysis_item_id IS NOT NULL
                """).setParameter("analysisId", analysisId))) {
            result.computeIfAbsent(uuid(row[0]), ignored -> new ArrayList<>()).add(new AggregateMemberSubtree(
                    uuid(row[1]), uuid(row[2]), string(row[3]), Boolean.TRUE.equals(row[4])));
        }
        result.values().forEach(members -> members.sort(
                Comparator.comparing(member -> member.materialLineId().toString())));
        return result;
    }

    /**
     * 人工刷新时保持原值的父键(analysis_item_id|父节点键)：父节点已有下达计划批次的子节点与已冻结
     * 的车间需求一致；共享制造锚点冻结的父键同步到每个批次成员子树的同一相对路径，同一批次的成员树
     * 与锚点树始终是同一个数(追加预览按成员子件算，追加计划按锚点子件长)。
     */
    static Set<String> frozenUsageParents(Set<String> plannedParents, Map<UUID, List<AggregateMemberSubtree>> anchorMembers) {
        Set<String> result = new HashSet<>(plannedParents);
        anchorMembers.forEach((anchorId, members) -> {
            String anchorPrefix = nodeRef(anchorId, "");
            for (String parent : plannedParents) {
                if (!parent.startsWith(anchorPrefix)) continue;
                String relative = parent.substring(anchorPrefix.length());
                for (AggregateMemberSubtree member : members) {
                    result.add(nodeRef(member.analysisItemId(), member.memberNodeKey(relative)));
                }
            }
        });
        return Set.copyOf(result);
    }

    /**
     * 人工刷新采用最新的设计/真实使用数量(ADR-129 §2.5)，只由人工刷新入口调用；保存路线、下达、
     * 审批、唤醒等内部重算沿用快照值。冻结的父键({@link #frozenUsageParents})下的子节点保持原值。
     * 只写真正变了的行；采用哪一个仍由随后的刷新按路线逐节点决定。
     */
    private void adoptLatestBomUsage(UUID analysisId) {
        Set<String> frozenParents = frozenUsageParents(plannedMaterialBatches(
                analysisId, MaterialAnalysisIssuePreviewOverlay.NONE).keySet(), aggregateMemberSubtrees(analysisId));
        em.createNativeQuery("""
                UPDATE production_material_analysis_materials material
                SET design_bom_qty = latest.design_qty, actual_bom_qty = latest.actual_qty,
                    usage_sample_count = latest.sample_count, usage_defect_rate = latest.defect_rate,
                    updated_at = now(), updated_by = :actorId
                FROM (
                    SELECT candidate.id, edge_usage.design_qty, edge_usage.actual_qty, edge_usage.sample_count,
                           edge_usage.defect_rate
                    FROM production_material_analysis_materials candidate
                    %s
                    WHERE candidate.analysis_id = :analysisId AND candidate.active = TRUE
                      AND candidate.node_role = 'BOM_COMPONENT' AND edge_usage.design_qty > 0
                      AND NOT (candidate.analysis_item_id::text || '|' || COALESCE(candidate.parent_node_key, '')
                               = ANY(string_to_array(:frozenParents, ',')))
                ) latest
                WHERE material.id = latest.id
                  AND (material.design_bom_qty, material.actual_bom_qty, material.usage_sample_count,
                       material.usage_defect_rate)
                      IS DISTINCT FROM (latest.design_qty, latest.actual_qty, latest.sample_count, latest.defect_rate)
                """.formatted(MaterialAnalysisBomSnapshotReader.edgeUsageLateral("candidate.bom_item_id")))
                .setParameter("analysisId", analysisId)
                .setParameter("frozenParents", String.join(",", frozenParents))
                .setParameter("actorId", currentUser.requireId())
                .executeUpdate();
    }

    /** Expanded trees use one typed array parameter, avoiding JDBC's scalar parameter ceiling. */
    private static String uuidArrayText(Collection<UUID> values) {
        return values.stream().map(UUID::toString).collect(Collectors.joining(","));
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
                  AND fn_warehouse_is_operational_leaf(warehouse.id)
                WHERE balance.beneficiary_analysis_id=:analysisId AND balance.effective_qty>0
                  -- Admission follows this authoritative BOM's composite UUID/path
                  -- identities even before structural reconciliation is persisted.
                  AND (material.analysis_item_id::text||'|'||material.node_key)
                      IN (SELECT unnest(string_to_array(:nodeKeys, ',')))
                  AND fn_preplan_reservation_has_qualified_origin(reservation.id)
                GROUP BY reservation.warehouse_id,reservation.goods_id,reservation.color_id,material.unit_id
                """).setParameter("analysisId", analysisId).setParameter("nodeKeys", String.join(",", currentNodeKeys)))) {
            result.put(new WarehouseMaterialDimension(uuid(row[0]),
                    new MaterialDimension(uuid(row[1]),uuid(row[2]),uuid(row[3]))),decimal(row[4]));
        }
        return Map.copyOf(result);
    }

    private AvailabilitySnapshot availability(
            UUID analysisId, UUID warehouseId,
            List<BomNode> nodes, List<SourceLine> sources) {
        return availability(analysisId, warehouseId, nodes, sources, MaterialAnalysisIssuePreviewOverlay.NONE);
    }

    private AvailabilitySnapshot availability(UUID analysisId, UUID warehouseId,
            List<BomNode> nodes, List<SourceLine> sources, MaterialAnalysisIssuePreviewOverlay overlay) {
        Set<UUID> goodsIds = nodes.stream().map(BomNode::goodsId)
                .collect(Collectors.toCollection(TreeSet::new));
        if (goodsIds.isEmpty()) return new AvailabilitySnapshot(Map.of(), List.of());
        Set<String> currentNodeKeys = nodes.stream()
                .map(MaterialAnalysisService::nodeAllocationKey)
                .collect(Collectors.toSet());
        Map<WarehouseMaterialDimension, BigDecimal> qualifiedOwn = new LinkedHashMap<>(qualifiedOwnedStock(analysisId, currentNodeKeys));
        qualifiedOwn.replaceAll((key,qty)->qty.subtract(overlay.qualifiedTransferred(key)).max(BigDecimal.ZERO));
        String qualifiedWarehouseIds = qualifiedOwn.keySet().stream().map(WarehouseMaterialDimension::warehouseId)
                .distinct().map(UUID::toString).sorted().collect(Collectors.joining(","));
        List<Object[]> stockRows = NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT v.warehouse_id, w.code, w.name, v.goods_id, v.color_id,
                       COALESCE(v.on_hand_qty,0), COALESCE(v.reserved_qty,0),
                       GREATEST(COALESCE(v.available_qty,0),0),
                       COALESCE(own.own_qty,0),
                       (fn_warehouse_counts_as_usable(w.id)
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
                                   || beneficiary.node_key) IN (SELECT unnest(string_to_array(:currentNodeKeys, ',')))
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
                WHERE v.goods_id IN (SELECT unnest(CAST(string_to_array(:goodsIds, ',') AS uuid[])))
                  AND w.is_deleted = FALSE AND w.is_accountable = TRUE
                  -- ADR-146: 不良品仓的货不算物料「库存」, 合格专属来源在不良品仓也不再算可用(废止 ADR-075 第 2 条)。
                  AND NOT w.is_defective
                  AND (CAST(:warehouseId AS uuid) IS NULL
                       OR fn_warehouse_same_main(v.warehouse_id,CAST(:warehouseId AS uuid))
                       OR v.warehouse_id=ANY(CAST(string_to_array(:qualifiedWarehouses,',') AS uuid[])))
                ORDER BY v.warehouse_id, v.goods_id, v.color_id NULLS FIRST
                """)
                .setParameter("goodsIds", uuidArrayText(goodsIds))
                .setParameter("currentNodeKeys", String.join(",", currentNodeKeys))
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
            BigDecimal ownReserved = publicAllowed ? decimal(row[8]).subtract(overlay.ownedTransferred(location)).max(BigDecimal.ZERO) : qualified;
            BigDecimal reserved = decimal(row[6]).add(overlay.publicReservationChange(location)).subtract(ownReserved).max(BigDecimal.ZERO);
            ownReserved = ownReserved.min(decimal(row[5]).subtract(reserved).max(BigDecimal.ZERO));
            BigDecimal publicQty = publicAllowed ? decimal(row[7]).subtract(overlay.publicReservationChange(location)).max(BigDecimal.ZERO) : BigDecimal.ZERO;
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
                               fn_preplan_allocation_admitted_qty(allocation.id) - COALESCE((
                                   SELECT SUM(CASE
                                       WHEN reservation.release_reason =
                                            'TRANSFERRED_TO_PLAN' OR %1$s THEN exact.qty
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
                                            'TRANSFERRED_TO_PLAN' OR %1$s)
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
                           -- Remaining supply is the interval after net accounted receipt,
                           -- including original-order replacement after an actual IQC return.
                           fn_procurement_order_source_remaining_qty(
                               'PURCHASE', i.id, src.request_item_id)::numeric AS open_qty
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
                           fn_procurement_order_source_remaining_qty(
                               'SUBCONTRACT', i.id, src.application_item_id)::numeric
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
                )
                SELECT goods_id, color_id, unit_id, eta,
                       SUM(open_qty)::numeric
                FROM capped_supply
                WHERE open_qty > 0
                GROUP BY goods_id, color_id, unit_id, eta
                ORDER BY goods_id, color_id NULLS FIRST, unit_id, eta
                """.formatted(SubcontractComponentCustodyProjection.TRANSFERRED_EVIDENCE))
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
        return loadMaterialRows(analysisId, MaterialAnalysisIssuePreviewOverlay.NONE);
    }

    /** [overlay] 非空时(下达预览, ADR-116)数量列取内存重算值, 结构列与主档列仍取库内。 */
    private List<MaterialRow> loadMaterialRows(UUID analysisId, MaterialAnalysisIssuePreviewOverlay overlay) {
        List<MaterialRow> rows = loadStoredMaterialRows(analysisId);
        if (overlay.isNone()) return rows;
        return rows.stream().map(row -> {
            MaterialAnalysisIssuePreviewOverlay.NodeSnapshot node =
                    overlay.node(nodeRef(row.analysisItemId(), row.nodeKey()));
            if (node != null) return row.withSnapshot(node.required(), node.available(), node.allocated(),
                    node.reserved(), node.safety(), node.inbound(), node.shortage(),
                    node.expectedReadyDate(), node.lowerPending());
            MaterialAnalysisIssuePreviewOverlay.RootSnapshot root = overlay.root(row.id());
            if (root != null) return row.withSnapshot(root.required(), root.available(), root.allocated(),
                    root.reserved(), root.safety(), root.inbound(), root.shortage(),
                    row.expectedReadyDate(), row.lowerLevelPending());
            return row;
        }).toList();
    }

    private List<MaterialRow> loadStoredMaterialRows(UUID analysisId) {
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
                       m.lower_level_pending,
                       g.min_order_qty, g.order_multiple_qty,
                       g.owning_warehouse_id, owning_warehouse.name,
                       g.owning_workshop_department_id, owning_workshop.name,
                       m.design_bom_qty, m.actual_bom_qty, m.usage_basis,
                       m.usage_reason, m.usage_sample_count, m.usage_defect_rate
                FROM production_material_analysis_materials m
                JOIN goods g ON g.id = m.goods_id
                JOIN units u ON u.id = m.unit_id
                LEFT JOIN colors c ON c.id = m.color_id
                LEFT JOIN warehouses owning_warehouse
                  ON owning_warehouse.id = g.owning_warehouse_id
                LEFT JOIN departments owning_workshop
                  ON owning_workshop.id = g.owning_workshop_department_id
                 AND owning_workshop.is_deleted = FALSE
                LEFT JOIN production_material_analysis_materials parent_material
                  ON parent_material.analysis_item_id = m.analysis_item_id
                 AND parent_material.node_key = m.parent_node_key
                WHERE m.analysis_id = :id AND m.active = TRUE
                ORDER BY m.analysis_item_id, m.path, m.id
                """).setParameter("id", analysisId)).stream()
                .map(MaterialRow::from).toList();
    }

    /**
     * Legacy per-row net shortage can debit a public pool only for a sole occurrence.
     * All three supply routes now adopt server-proven compatible output; repeated
     * source rows use the shared preparation budget instead of debiting this pool N times.
     */
    private static boolean sharedFutureDeductible(MaterialRow row,Set<String> soleRowDimensions) {
        String route=row.confirmedRoute()!=null?row.confirmedRoute():row.suggestion();
        return soleRowDimensions.contains(row.materialKey()) && Set.of("MAKE","BUY","SUBCONTRACT")
                .contains(Objects.toString(route,""));
    }

    /** 本分析里只出现一行的物料维度(公共在途池可以整池归给它)。 */
    private static Set<String> soleRowDimensions(List<MaterialRow> rows) {
        Map<String, Integer> counts = new HashMap<>();
        for (MaterialRow row : rows) {
            counts.merge(row.materialKey(), 1, Integer::sum);
        }
        Set<String> sole = new LinkedHashSet<>();
        counts.forEach((key, count) -> {
            if (count == 1) sole.add(key);
        });
        return sole;
    }

    /** 物料行 → 其计划锚点子件行（MAKE_COMPONENT）。 */
    private Map<UUID, UUID> anchorChildByParentLine(UUID analysisId) {
        Map<UUID, UUID> result = new LinkedHashMap<>();
        for (Object[] row : NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT item.parent_analysis_material_id, item.id
                FROM production_material_analysis_items item
                WHERE item.analysis_id = :analysisId
                  AND item.is_deleted = FALSE
                  AND item.source_type = 'MAKE_COMPONENT'
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
                           STRING_AGG(DISTINCT NULLIF(workshop.name, ''), ' / ' ORDER BY NULLIF(workshop.name, '')) AS workshop_name,
                           STRING_AGG(DISTINCT NULLIF(responsible.full_name, ''), ' / ' ORDER BY NULLIF(responsible.full_name, '')) AS responsible_name,
                           COUNT(segment.id) AS segment_count,
                           CASE WHEN COUNT(DISTINCT segment.workshop_department_id)=1 THEN MIN(segment.workshop_department_id::text)::uuid END AS workshop_id,
                           CASE WHEN COUNT(DISTINCT segment.responsible_employee_id)=1 THEN MIN(segment.responsible_employee_id::text)::uuid END AS responsible_id
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
                       (array_agg(CASE WHEN segment_rollup.segment_count>0 THEN COALESCE(segment_rollup.workshop_name,'')
                           ELSE COALESCE(plan_department.name,plan.workshop_name,'') END ORDER BY link.created_at DESC,plan.id DESC))[1] AS execution_workshop_name,
                       (array_agg(CASE WHEN segment_rollup.segment_count>0 THEN COALESCE(segment_rollup.responsible_name,'')
                           ELSE COALESCE(plan_worker.full_name,'') END ORDER BY link.created_at DESC,plan.id DESC))[1] AS execution_responsible_name,
                       (array_agg(CASE WHEN segment_rollup.segment_count>0 THEN segment_rollup.workshop_id
                           ELSE plan.department_id END ORDER BY link.created_at DESC,plan.id DESC))[1] AS execution_workshop_id,
                       (array_agg(CASE WHEN segment_rollup.segment_count>0 THEN segment_rollup.responsible_id
                           ELSE plan.worker_id END ORDER BY link.created_at DESC,plan.id DESC))[1] AS execution_responsible_id
                FROM active_links link
                JOIN production_plans plan
                  ON plan.id = link.plan_id
                LEFT JOIN departments plan_department ON plan_department.id=plan.department_id
                LEFT JOIN employees plan_worker ON plan_worker.id=plan.worker_id
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
                    string(row[8]), string(row[9]),uuid(row[10]),uuid(row[11])));
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
        record SharedSourceIdentity(UUID action,UUID externalItem) { }
        Map<SharedSourceIdentity,SharedFutureSupplyRef> refsBySource = new LinkedHashMap<>();
        Map<MaterialDimension,List<SharedSourceIdentity>> sourceIdsByDimension = new HashMap<>();
        Set<UUID> sameAnalysisSources = new HashSet<>();
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
                           AS external_document_maker_id,
                       source_state.claim_external_item_id
                FROM fn_preplan_public_surplus_sources(:analysisId) source_state
                LEFT JOIN purchase_requests purchase_request
                  ON source_state.route = 'BUY'
                 AND purchase_request.id = source_state.external_document_id
                LEFT JOIN subcontract_applications subcontract_application
                  ON source_state.route = 'SUBCONTRACT'
                 AND subcontract_application.id = source_state.external_document_id
                WHERE fn_warehouse_same_main(source_state.warehouse_id,:warehouseId)
                  AND source_state.goods_id IN (SELECT unnest(CAST(string_to_array(:goodsIds, ',') AS uuid[])))
                  AND source_state.planning_open_qty > 0
                ORDER BY source_state.warehouse_id, source_state.goods_id,
                         source_state.color_id NULLS FIRST,
                         source_state.unit_id,
                         source_state.expected_date NULLS LAST,
                         source_state.source_action_id
                """).setParameter("analysisId", analysisId).setParameter("warehouseId", warehouseId)
                .setParameter("goodsIds", uuidArrayText(goodsIds)))) {
            MaterialDimension dimension = new MaterialDimension(
                    uuid(row[1]), uuid(row[2]), uuid(row[3]));
            // This index represents the selected planning scope, not a physical
            // receiving location. Old leaf-scoped supply must remain visible to
            // a new main-scoped analysis; actual stock-in keeps its real leaf UUID.
            WarehouseMaterialDimension key = new WarehouseMaterialDimension(
                    warehouseId, dimension);
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
                    analysisId.equals(uuid(row[9])),com.uten.imp.common.util.CanonicalFingerprint.sha256(List.of(
                            "EXTERNAL_PUBLIC",Objects.toString(row[8],""),Objects.toString(row[14],""))));
            UUID sourceId=uuid(row[8]);
            SharedSourceIdentity identity=new SharedSourceIdentity(sourceId,uuid(row[14]));
            refsBySource.put(identity,ref);
            sourceIdsByDimension.computeIfAbsent(dimension,ignored->new ArrayList<>()).add(identity);
            if(analysisId.equals(uuid(row[9])))sameAnalysisSources.add(sourceId);
            SharedFutureAggregate current = aggregates.getOrDefault(
                    key, SharedFutureAggregate.ZERO);
            aggregates.put(key, current.plus(ref));
        }
        Map<UUID,Set<UUID>> ownSources = new HashMap<>();
        if(!sameAnalysisSources.isEmpty()) {
            // Identity is evaluated before document visibility redacts source ids.
            // One batch query, not one query for every repeated BOM occurrence.
            for(Object[] row:NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                    SELECT material.id,source.id
                    FROM production_material_analysis_materials material
                    JOIN preplan_supply_actions source ON source.goods_id=material.goods_id
                      AND source.color_id IS NOT DISTINCT FROM material.color_id AND source.unit_id=material.unit_id
                    WHERE material.analysis_id=:analysis AND material.active
                      AND source.id IN(SELECT unnest(CAST(string_to_array(:sources,',') AS uuid[])))
                      AND fn_preplan_public_target_is_source(source.id,material.id)
                    """).setParameter("analysis",analysisId).setParameter("sources",uuidArrayText(sameAnalysisSources)))) {
                ownSources.computeIfAbsent(uuid(row[0]),ignored->new HashSet<>()).add(uuid(row[1]));
            }
        }
        Map<UUID,SharedFutureAggregate> perMaterial=new HashMap<>();
        for(MaterialRow material:materials) {
            Set<UUID> ownSourceIds=ownSources.getOrDefault(material.id(),Set.of());
            List<SharedFutureSupplyRef> targetRefs=sourceIdsByDimension.getOrDefault(material.dimension(),List.of()).stream()
                    .map(id->sharedFutureRefForTarget(refsBySource.get(id),ownSourceIds.contains(id.action()))).toList();
            perMaterial.put(material.id(),new SharedFutureAggregate(
                    targetRefs.stream().map(SharedFutureSupplyRef::approvedInboundQty).reduce(BigDecimal.ZERO,BigDecimal::add),
                    targetRefs.stream().map(SharedFutureSupplyRef::availableToClaimQty).reduce(BigDecimal.ZERO,BigDecimal::add),
                    targetRefs.stream().map(SharedFutureSupplyRef::expectedDate).filter(Objects::nonNull).min(LocalDate::compareTo).orElse(null),targetRefs));
        }
        return new SharedFutureIndex(Map.copyOf(aggregates),Map.copyOf(perMaterial));
    }

    static SharedFutureSupplyRef sharedFutureRefForTarget(
            SharedFutureSupplyRef source, boolean targetIsSource) {
        if (!targetIsSource) return source;
        // A source's own demand must still see its approved public supply and ETA.
        // Only claiming that supply is forbidden. Use the exact source/target
        // relationship, before access control redacts document identifiers;
        // other demands in the same analysis may legitimately claim this source.
        return new SharedFutureSupplyRef(
                source.route(), source.approvedInboundQty(), BigDecimal.ZERO,
                source.expectedDate(), source.sourceActionId(), source.documentType(),
                source.documentId(), source.documentNo(), source.sourceIsCurrentAnalysis(),
                source.budgetKey());
    }

    /** 与 DocumentAccessPolicy.canRead 同口径：没有负责人的在途单据只对全量范围露出单号。 */
    private static boolean ownerVisible(
            OwnerVisibility.OwnerScope scope, UUID ownerEmployeeId) {
        return scope.seeAll() || ownerEmployeeId != null
                && scope.visibleOwners().contains(ownerEmployeeId);
    }

    private Map<UUID, ClaimedFutureState> sharedFutureClaimedByMaterial(UUID analysisId) {
        Map<UUID, ClaimedFutureState> result = new LinkedHashMap<>();
        for (Object[] row : NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT allocation.analysis_material_id,
                       SUM(allocation.allocated_qty)::numeric,
                       SUM(
                           GREATEST(allocation.allocated_qty
                               -fn_preplan_allocation_received_qty(allocation.id),0)
                           )::numeric
                FROM preplan_supply_action_allocations allocation
                JOIN preplan_supply_actions action ON action.id = allocation.action_id
                WHERE action.analysis_id = :analysisId
                  AND action.operation_type = 'SHARED_FUTURE_CLAIM'
                  AND action.status <> 'CANCELLED'
                GROUP BY allocation.analysis_material_id
                """).setParameter("analysisId", analysisId))) {
            result.put(uuid(row[0]),new ClaimedFutureState(decimal(row[1]),decimal(row[2])));
        }
        return Map.copyOf(result);
    }

    private record ClaimedFutureState(BigDecimal claimedQty,BigDecimal pendingQty) {
        static final ClaimedFutureState NONE=new ClaimedFutureState(BigDecimal.ZERO,BigDecimal.ZERO);
    }

    /**
     * 一笔委外申请分摊(别名 allocation，所属行动 action)里「要我方领直属物料发外」的份额，0..1
     * (ADR-143 §4.5)。已批准的委外订货一定有冻结领料计划行(缺 BOM 的委外件不能下单，§二.3)，
     * 订货余量全部计入；尚未批准订货的部分按货品现时是否有可发外直属边(fn_subcontract_draw_edges，
     * 与计划冻结同一判定)。还没挂上申请明细的行动只看现时直属边。
     */
    static final String SUBCONTRACT_DRAW_SHARE_SQL = """
                COALESCE((
                    SELECT CASE
                        WHEN split.ordered_open_qty + split.unordered_qty > 0
                        THEN (split.ordered_open_qty + CASE WHEN split.drawable_now
                                 THEN split.unordered_qty ELSE 0 END)
                             / (split.ordered_open_qty + split.unordered_qty)
                        WHEN split.drawable_now THEN 1 ELSE 0 END
                    FROM (
                        SELECT EXISTS (SELECT 1 FROM fn_subcontract_draw_edges(application_item.goods_id))
                                   AS drawable_now,
                               GREATEST(application_item.qty * COALESCE(application_item.unit_rate,1)
                                   - COALESCE(SUM(ordered.ordered_base),0), 0) AS unordered_qty,
                               COALESCE(SUM(ordered.open_qty), 0) AS ordered_open_qty
                        FROM subcontract_application_items application_item
                        LEFT JOIN LATERAL (
                            SELECT src.alloc_qty * COALESCE(order_item.unit_rate,1) AS ordered_base,
                                   fn_procurement_order_source_remaining_qty(
                                       'SUBCONTRACT', order_item.id, src.application_item_id) AS open_qty
                            FROM subcontract_order_item_sources src
                            JOIN subcontract_order_items order_item
                              ON order_item.id = src.order_item_id
                             AND order_item.is_deleted = FALSE
                            JOIN subcontract_orders subcontract_order
                              ON subcontract_order.id = order_item.order_id
                             AND subcontract_order.status = 1
                             AND subcontract_order.is_deleted = FALSE
                            WHERE src.application_item_id = application_item.id
                        ) ordered ON TRUE
                        WHERE application_item.id = allocation.external_item_id
                        GROUP BY application_item.id, application_item.goods_id,
                                 application_item.qty, application_item.unit_rate
                    ) split),
                    CASE WHEN EXISTS (SELECT 1 FROM fn_subcontract_draw_edges(action.goods_id))
                         THEN 1 ELSE 0 END)::numeric
                """;

    /**
     * 一笔未结委外申请分摊(别名 allocation/action)给 P 节点的计划产出(ADR-143 §4.5)：
     * 分摊比例 × (申请量 + 公共超量 − 合格入库回厂量)，只算要我方领料发外的份额。
     * 合格入库回厂量按回厂单与质检入库实收(与申请 DONE 判定同一口径)，领料、发货不动它。
     */
    static final String SUBCONTRACT_PLANNED_OUTPUT_SQL = """
                (GREATEST(allocation.allocated_qty / NULLIF(action.requested_qty, 0)
                    * (action.requested_qty + action.public_surplus_qty - (
                """ + SubcontractComponentCustodyProjection.ACTION_STOCKED_BASE_SQL + """
                    )), 0) * (
                """ + SUBCONTRACT_DRAW_SHARE_SQL + """
                    ))
                """;

    /**
     * 有效在途覆盖的公共取数。coverage 的每一行都带 supply_kind：
     * <ul>
     *   <li>EXTERNAL：真正来自外部的最终件供给——已下单未实收的采购/委外
     *       份额、跨计划转入的专属在途、公共在途认领，以及 IQC 失败后重新
     *       欠货的切片。它们到货即可直接冲减本节点需求，<b>不需要</b>本节点
     *       再展开下层原料。</li>
     *   <li>INTERNAL：本节点「已承诺由我方制造」的量——行动背书的自制备料
     *       动作，以及要我方领直属物料发外的委外申请(ADR-143 §4.5)。它们的物理
     *       来源恰恰要靠下层原料去产出，<b>绝不能</b>用来缩减下层需求。</li>
     * </ul>
     * 委外申请(SUPPLY)按份额分：已批准订货的份额(一定有冻结领料计划行)、以及未批准
     * 部分在货品现时有可发外直属边(fn_subcontract_draw_edges)时计 INTERNAL；缺 BOM
     * 的未批准部分计 EXTERNAL(它下面没有可展开的直属物料)。认领别人的在途、在途转入仍是外部。
     * 两类相加等于历史口径，所以「尚需下达量」的计算保持不变；只有子层
     * 展开基准需要区分二者（见 allocateNestedDiagnostics）。
     */
    private static final String ACTIVE_FUTURE_COVERAGE_SQL = """
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
                ), allocation_pending AS (
                    SELECT allocation.analysis_material_id,
                           CASE WHEN action.external_document_type = 'PREPLAN_MAKE_TASK'
                                THEN 1::numeric
                                WHEN action.external_document_type = 'SUBCONTRACT_APPLICATION'
                                 AND action.operation_type = 'SUPPLY'
                                THEN (
                """ + SUBCONTRACT_DRAW_SHARE_SQL + """
                                )
                                ELSE 0::numeric END AS internal_ratio,
                           CASE WHEN fn_preplan_action_has_future_transfer(action.id) OR fn_preplan_action_has_shared_claim_history(action.id) THEN fn_preplan_future_allocation_pending_qty(allocation.id)
                           WHEN action.operation_type='SHARED_FUTURE_CLAIM' THEN fn_preplan_shared_allocation_pending_qty(allocation.id)
                           ELSE GREATEST(fn_preplan_allocation_admitted_qty(allocation.id)
                             - fn_preplan_allocation_effective_exact_qty(allocation.id)
                             - COALESCE((SELECT SUM(CASE WHEN output.event_kind='FULFILL'
                                      THEN output.qty_base ELSE -output.qty_base END)
                                 FROM preplan_root_output_events output
                                 JOIN preplan_analysis_stock_exact_pegs exact
                                   ON exact.stock_reservation_id=output.source_reservation_id
                                 WHERE exact.supply_action_allocation_id=allocation.id),0),0) END::numeric AS qty
                    FROM preplan_supply_action_allocations allocation
                    JOIN preplan_supply_actions action
                      ON action.id = allocation.action_id
                    WHERE action.analysis_id = :analysisId
                      AND action.status IN ('OPEN','CREATED','IN_PROGRESS')
                ), coverage AS (
                    SELECT pending.analysis_material_id, split.supply_kind, split.qty
                    FROM allocation_pending pending
                    CROSS JOIN LATERAL (VALUES
                        ('INTERNAL', ROUND(pending.qty * pending.internal_ratio, 4)),
                        ('EXTERNAL', pending.qty - ROUND(pending.qty * pending.internal_ratio, 4))
                    ) split(supply_kind, qty)
                    UNION ALL
                    SELECT claim.target_material_id,'EXTERNAL',fn_preplan_make_public_claim_pending_qty(claim.id)::numeric
                    FROM preplan_make_public_claims claim WHERE claim.target_analysis_id=:analysisId
                    UNION ALL
                    SELECT allocation.analysis_material_id, 'EXTERNAL',
                           LEAST(allocation.allocated_qty,
                               future.future_qty * allocation.allocated_qty
                                   / NULLIF(action.requested_qty,0))::numeric
                    FROM action_future future
                    JOIN preplan_supply_actions action ON action.id = future.action_id
                    JOIN preplan_supply_action_allocations allocation
                      ON allocation.action_id = action.id
                )
                """;

    private Map<UUID, BigDecimal> activeFutureCoverageByMaterial(UUID analysisId,boolean aggregates) {
        Map<UUID, BigDecimal> result = new LinkedHashMap<>();
        activeFutureCoverage(analysisId,aggregates).forEach((id, coverage) -> result.put(id, coverage.totalQty()));
        return Map.copyOf(result);
    }

    private record FutureCoverage(BigDecimal totalQty, BigDecimal externalQty) {
        static final FutureCoverage NONE = new FutureCoverage(BigDecimal.ZERO, BigDecimal.ZERO);
    }

    private Map<UUID, FutureCoverage> activeFutureCoverage(UUID analysisId,boolean aggregates) {
        return activeFutureCoverage(analysisId,aggregates?aggregateInheritedPending(analysisId):Map.of());
    }
    private Map<UUID, FutureCoverage> activeFutureCoverage(UUID analysisId,Map<UUID,BigDecimal> inherited) {
        Map<UUID, FutureCoverage> result = new LinkedHashMap<>();
        for (Object[] row : NativeQueryResults.objectArrayRows(em.createNativeQuery(
                ACTIVE_FUTURE_COVERAGE_SQL + """
                SELECT analysis_material_id, SUM(qty)::numeric,
                       COALESCE(SUM(qty) FILTER (WHERE supply_kind = 'EXTERNAL'), 0)::numeric
                FROM coverage
                GROUP BY analysis_material_id
                """).setParameter("analysisId", analysisId))) {
            result.put(uuid(row[0]), new FutureCoverage(decimal(row[1]), decimal(row[2])));
        }
        inherited.forEach((id,pending)-> {
            FutureCoverage current=result.getOrDefault(id,FutureCoverage.NONE);
            result.put(id,new FutureCoverage(current.totalQty().add(pending),current.externalQty().add(pending)));
        });
        return Map.copyOf(result);
    }

    private static boolean hasAggregateSources(List<SourceLine> sources) {
        return sources.stream().anyMatch(source->SOURCE_AGGREGATE_MAKE.equals(source.sourceType()));
    }

    private record AggregateMember(UUID materialId,UUID sourceId,String nodeKey,UUID anchorId,String sourceRef,BigDecimal qty) { }

    private List<AggregateMember> aggregateMembers(UUID analysisId) {
        return NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT material.id,material.analysis_item_id,material.node_key,batch.anchor_analysis_item_id,
                       anchor.source_ref,allocation.allocated_qty
                FROM preplan_aggregate_batches batch
                JOIN preplan_supply_actions action ON action.id=batch.action_id AND action.status<>'CANCELLED'
                JOIN preplan_supply_action_allocations allocation ON allocation.action_id=action.id
                JOIN production_material_analysis_materials material ON material.id=allocation.analysis_material_id
                JOIN production_material_analysis_items anchor ON anchor.id=batch.anchor_analysis_item_id AND NOT anchor.is_deleted
                WHERE batch.analysis_id=:analysisId
                ORDER BY batch.created_at,batch.id,material.id
                """).setParameter("analysisId",analysisId)).stream()
                .map(row->new AggregateMember(uuid(row[0]),uuid(row[1]),string(row[2]),uuid(row[3]),string(row[4]),decimal(row[5]))).toList();
    }

    /** One immutable read boundary serves both sides of the same alias budget. */
    private record AggregateAliasCoverage(Map<UUID,BigDecimal> incoming,Map<UUID,BigDecimal> outgoing,Map<UUID,Map<UUID,BigDecimal>> attributedCoverage) {
        static final AggregateAliasCoverage EMPTY=new AggregateAliasCoverage(Map.of(),Map.of(),Map.of());
    }

    /** A responsibility edge alone carries no supply. Keep this check read-local:
     * an order, claim or receipt written by the next phase may introduce a source. */
    private boolean hasAggregateAliasSupply(UUID analysisId) {
        return Boolean.TRUE.equals(em.createNativeQuery("""
                WITH aliases AS MATERIALIZED (
                    SELECT alias.id,alias.source_material_id
                    FROM preplan_aggregate_material_aliases alias
                    JOIN preplan_aggregate_batches batch ON batch.id=alias.batch_id
                    JOIN preplan_supply_actions action ON action.id=batch.action_id
                    WHERE batch.analysis_id=:analysisId AND action.status<>'CANCELLED'
                ), sources AS MATERIALIZED (
                    SELECT DISTINCT source_material_id AS id FROM aliases
                )
                SELECT EXISTS (
                    SELECT 1 FROM sources
                    JOIN preplan_supply_action_allocations allocation ON allocation.analysis_material_id=sources.id
                    JOIN preplan_supply_actions action ON action.id=allocation.action_id
                    WHERE action.status<>'CANCELLED'
                    UNION ALL
                    SELECT 1 FROM sources
                    JOIN production_material_analysis_items child ON child.parent_analysis_material_id=sources.id
                      AND child.source_type='MAKE_COMPONENT' AND NOT child.is_deleted
                    JOIN production_material_analysis_plan_links link ON link.analysis_item_id=child.id
                      AND link.allocation_status IN('SUBMITTED','APPROVED')
                    JOIN production_plans plan ON plan.id=link.plan_id AND plan.status IN(0,1)
                      AND NOT plan.is_deleted AND NOT plan.is_canceled
                    UNION ALL
                    SELECT 1 FROM sources
                    JOIN preplan_make_public_claims claim ON claim.target_material_id=sources.id
                    UNION ALL
                    SELECT 1 FROM aliases
                    JOIN preplan_make_entitlement_delegations delegation ON delegation.aggregate_alias_id=aliases.id
                    UNION ALL
                    SELECT 1 FROM sources
                    JOIN preplan_stock_entitlement_events event ON event.beneficiary_analysis_material_id=sources.id
                )
                """).setParameter("analysisId",analysisId).getSingleResult());
    }

    private AggregateAliasCoverage aggregateAliasCoverage(UUID analysisId) {
        if (!hasAggregateAliasSupply(analysisId)) return AggregateAliasCoverage.EMPTY;
        Map<UUID,BigDecimal> incoming=new HashMap<>(),outgoing=new HashMap<>();
        Map<UUID,Map<UUID,BigDecimal>> attributed=new HashMap<>();
        for(Object[] row:NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                WITH coverage AS MATERIALIZED(SELECT * FROM fn_preplan_aggregate_alias_coverage(:analysisId))
                SELECT 'IN',analysis_material_id,NULL::uuid,inherited_pending_qty FROM coverage WHERE inherited_pending_qty>0
                UNION ALL
                SELECT 'OUT',CAST(source->>'sourceMaterialId' AS uuid),NULL::uuid,SUM(CAST(source->>'pendingQuantity' AS numeric))
                FROM coverage CROSS JOIN LATERAL jsonb_array_elements(coverage.source_aliases) source
                GROUP BY CAST(source->>'sourceMaterialId' AS uuid)
                UNION ALL
                SELECT 'COVERED',coverage.analysis_material_id,CAST(source->>'sourceMaterialId' AS uuid),SUM(CAST(source->>'inheritedQuantity' AS numeric))
                FROM coverage CROSS JOIN LATERAL jsonb_array_elements(coverage.source_aliases) source
                GROUP BY coverage.analysis_material_id,CAST(source->>'sourceMaterialId' AS uuid)
                """).setParameter("analysisId",analysisId))) {
            if("COVERED".equals(row[0]))attributed.computeIfAbsent(uuid(row[1]),ignored->new HashMap<>()).put(uuid(row[2]),decimal(row[3]));
            else ("IN".equals(row[0])?incoming:outgoing).put(uuid(row[1]),decimal(row[3]));
        }
        return new AggregateAliasCoverage(Map.copyOf(incoming),Map.copyOf(outgoing),Map.copyOf(attributed));
    }

    private Map<UUID,BigDecimal> aggregateInheritedPending(UUID analysisId) {
        if (!hasAggregateAliasSupply(analysisId)) return Map.of();
        Map<UUID,BigDecimal> result=new HashMap<>();
        for(Object[] row:NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT analysis_material_id,inherited_pending_qty FROM fn_preplan_aggregate_alias_coverage(:analysisId)
                WHERE inherited_pending_qty>0
                """).setParameter("analysisId",analysisId)))result.put(uuid(row[0]),decimal(row[1]));
        return result;
    }

    private Map<UUID,BigDecimal> preparationAdoptedQuantities(UUID analysisId) {
        Map<UUID,BigDecimal> result=new HashMap<>();
        for(Object[] row:NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT material_id,SUM(qty) FROM (
                    SELECT claim.target_material_id AS material_id,claim.qty-fn_preplan_make_public_claim_cancelled_qty(claim.id) AS qty
                    FROM preplan_make_public_claims claim WHERE claim.target_analysis_id=:analysisId
                    UNION ALL
                    SELECT allocation.analysis_material_id,fn_preplan_allocation_admitted_qty(allocation.id)
                    FROM preplan_supply_action_allocations allocation JOIN preplan_supply_actions action ON action.id=allocation.action_id
                    WHERE action.analysis_id=:analysisId AND action.status<>'CANCELLED'
                      AND action.operation_type IN('SHARED_FUTURE_CLAIM','FUTURE_TRANSFER')
                ) adopted GROUP BY material_id
                """).setParameter("analysisId",analysisId)))result.put(uuid(row[0]),decimal(row[1]));
        return result;
    }

    private Map<UUID,AggregateMaterialPreparationProjection.OrderIntent> aggregateOrderIntents(UUID analysisId) {
        Map<UUID,AggregateMaterialPreparationProjection.OrderIntent> result=new HashMap<>();
        for(Object[] row:NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT source_id::uuid,
                       SUM(COALESCE((event.intent_snapshot->'sourceRequestedQtyByMaterialLineId'->>source_id)::numeric,0)),
                       BOOL_AND(jsonb_exists(COALESCE(event.intent_snapshot->'sourceRequestedQtyByMaterialLineId','{}'::jsonb),source_id))
                FROM preplan_aggregate_batch_events event
                JOIN preplan_aggregate_batches batch ON batch.id=event.batch_id
                JOIN preplan_supply_actions action ON action.id=batch.action_id AND action.status<>'CANCELLED'
                CROSS JOIN LATERAL jsonb_array_elements_text(COALESCE(
                    event.intent_snapshot->'originalMaterialLineIds',batch.configuration_snapshot->'originalMaterialLineIds',
                    event.intent_snapshot->'materialLineIds','[]'::jsonb)) source_id
                WHERE batch.analysis_id=:analysisId AND event.event_type IN('CREATE','APPEND')
                GROUP BY source_id
                """).setParameter("analysisId",analysisId)))
            result.put(uuid(row[0]),new AggregateMaterialPreparationProjection.OrderIntent(decimal(row[1]),Boolean.TRUE.equals(row[2])));
        return result;
    }

    /** 成员行直接子层 → 批次树目标行的别名绑定：只统计未撤回批次。 */
    private List<AggregateDelegationProjection.Alias> aggregateAliasBindings(UUID analysisId) {
        return NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT alias.source_material_id,alias.aggregate_material_id,fn_preplan_aggregate_alias_qty(alias.id)
                FROM preplan_aggregate_material_aliases alias
                JOIN preplan_aggregate_batches batch ON batch.id=alias.batch_id
                JOIN preplan_supply_actions action ON action.id=batch.action_id AND action.status<>'CANCELLED'
                WHERE batch.analysis_id=:analysisId
                UNION ALL
                SELECT source.id,target.id,0::numeric
                FROM preplan_aggregate_batches batch
                JOIN preplan_supply_actions action ON action.id=batch.action_id AND action.status<>'CANCELLED'
                """ + AGGREGATE_BATCH_MEMBER_IDS + """
                JOIN production_material_analysis_materials parent ON parent.id=intent.id AND parent.analysis_id=batch.analysis_id
                JOIN production_material_analysis_materials source ON source.analysis_item_id=parent.analysis_item_id AND source.active
                    AND ((parent.node_role='ROOT_SUPPLY' AND source.depth=1) OR source.parent_node_key=parent.node_key)
                JOIN production_material_analysis_materials target ON target.analysis_item_id=batch.anchor_analysis_item_id
                    AND target.active AND target.depth=1 AND target.bom_item_id=source.bom_item_id
                    AND (target.goods_id,target.color_id,target.unit_id) IS NOT DISTINCT FROM (source.goods_id,source.color_id,source.unit_id)
                    AND fn_aggregate_relative_bom_path(source.id,parent.id)=fn_aggregate_relative_bom_path(target.id,NULL)
                WHERE batch.analysis_id=:analysisId
                """).setParameter("analysisId",analysisId)).stream()
                .map(row->new AggregateDelegationProjection.Alias(uuid(row[0]),uuid(row[1]),decimal(row[2]))).toList();
    }

    /**
     * 原路径到执行路径的精确身份投影。成员保留自己的行动身份；子层沿有效别名
     * 和不可变批次意图的 BOM 边链解析，多批数量累加，整包按整批取整后分份。
     */
    private Map<UUID,AggregateDelegationProjection.Delegation> aggregateDelegationProjection(UUID analysisId) {
        List<AggregateDelegationProjection.Node> nodes=NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT id,analysis_item_id,node_key,parent_node_key,goods_id,bom_item_id,bom_qty,
                       consumption_basis,basis_output_qty,allow_partial_package,node_role
                FROM production_material_analysis_materials
                WHERE analysis_id=:analysisId AND active
                ORDER BY analysis_item_id,depth,node_key
                """).setParameter("analysisId",analysisId)).stream()
                .map(row->new AggregateDelegationProjection.Node(uuid(row[0]),uuid(row[1]),string(row[2]),
                        string(row[3]),uuid(row[4]),uuid(row[5]),decimal(row[6]),string(row[7]),
                        decimal(row[8]),Boolean.TRUE.equals(row[9]),"ROOT_SUPPLY".equals(string(row[10]))))
                .toList();
        List<AggregateDelegationProjection.Member> members=aggregateMembers(analysisId).stream()
                .map(member->new AggregateDelegationProjection.Member(member.materialId(),member.anchorId(),member.qty()))
                .toList();
        return AggregateDelegationProjection.project(nodes,members,aggregateAliasBindings(analysisId));
    }

    /** 本行在共享批次之外还有自己的供给行动(采购/委外/自制任务引用)。 */
    private Set<UUID> materialLinesWithOwnSupplyActions(UUID analysisId) {
        Set<UUID> result=new HashSet<>();
        // 单列 DISTINCT: Hibernate 返回标量列表而非 Object[] 行, 不能走 objectArrayRows。
        for(Object id:em.createNativeQuery("""
                SELECT DISTINCT allocation.analysis_material_id
                FROM preplan_supply_action_allocations allocation
                JOIN preplan_supply_actions action ON action.id=allocation.action_id
                WHERE action.analysis_id=:analysisId AND action.status<>'CANCELLED'
                  AND NOT EXISTS(SELECT 1 FROM preplan_aggregate_batches shared WHERE shared.action_id=action.id)
                """).setParameter("analysisId",analysisId).getResultList())result.add(uuid(id));
        return result;
    }

    /**
     * 需求整体转入共享批次、且本行没有自己的下单/任务引用时，进度列报共享批次
     * 目标行(嵌套批次已解析)的真实阶段——这类原行自己只会推导出 *_PENDING_ISSUE
     * (未下达)，2026-09-26 用户实机「全选下单结束后整列都写未下达」即此。
     */
    private static String delegatedFlowStage(
            AggregateDelegationProjection.Delegation delegation, UUID rowId,
            Map<UUID,String> lineFlowStages, Set<UUID> rowsWithOwnSupply) {
        String own=lineFlowStages.get(rowId);
        if(delegation==null||delegation.targetMaterialLineIds().isEmpty()
                ||rowsWithOwnSupply.contains(rowId))return own;
        return delegation.targetMaterialLineIds().stream().map(lineFlowStages::get).filter(Objects::nonNull)
                .min(Comparator.comparingInt(MaterialAnalysisService::preparationStageRank)).orElse(own);
    }

    static int preparationStageRank(String stage) {
        if(stage.endsWith("PENDING_ISSUE"))return 0;
        if(stage.endsWith("REQUESTED")||stage.endsWith("PLAN_SUBMITTED"))return 1;
        if(stage.endsWith("PENDING_FINANCE"))return 2;
        if(stage.endsWith("WAITING_MATERIAL")||stage.endsWith("WAIT_RECEIPT"))return 3;
        if(stage.endsWith("WAITING_DRAW")||stage.endsWith("ZERO_READY")||stage.endsWith("WAIT_OUTBOUND"))return 4;
        if(stage.endsWith("IN_PROGRESS")||stage.endsWith("WAIT_RETURN"))return 5;
        if(stage.endsWith("WAIT_IQC"))return 6;
        if(stage.endsWith("WAIT_STOCK_IN"))return 7;
        return 8;
    }


    /**
     * 子层展开基准的两个输入，按节点键（analysis_item_id|node_key）给出：
     * 父件已被外部最终件在途覆盖的量，以及父件已承诺由我方制造的量。
     * 两条语句都按 analysis_id 一次取回，不引入逐行查询。
     *
     * <p>内部承诺取自制锚点的「锚点总量」；计划产出按已下达未完工的计划量与
     * 未结委外申请里要我方领料发外的计划产出(ADR-143 §4.5)。</p>
     */
    /**
     * [overlay] 非空时(下达预览, ADR-116)再叠上本批计划的计划产出(锚点/新锚点所在父节点)
     * 与锚点配额差(内部承诺), 即真实下达后本查询重读会多出来的那部分。
     */
    private Map<String, ParentSupplyCommitment> parentSupplyCommitments(
            UUID analysisId, MaterialAnalysisIssuePreviewOverlay overlay,boolean aggregates) {
        Map<String, BigDecimal> external = new LinkedHashMap<>();
        for (Object[] row : NativeQueryResults.objectArrayRows(em.createNativeQuery(
                ACTIVE_FUTURE_COVERAGE_SQL + """
                SELECT material.analysis_item_id || '|' || material.node_key,
                       SUM(coverage.qty)::numeric
                FROM coverage
                JOIN production_material_analysis_materials material
                  ON material.id = coverage.analysis_material_id
                 AND material.active = TRUE
                WHERE coverage.supply_kind = 'EXTERNAL'
                GROUP BY 1
                """).setParameter("analysisId", analysisId))) {
            external.put(string(row[0]), decimal(row[1]));
        }
        Map<String,BigDecimal> delegated=new HashMap<>();
        if(aggregates) {
            for(AggregateMember member:aggregateMembers(analysisId))delegated.merge(nodeRef(member.sourceId(),member.nodeKey()),member.qty(),BigDecimal::add);
            if (hasAggregateAliasSupply(analysisId)) for(Object[] row:NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                    SELECT material.analysis_item_id,material.node_key,coverage.inherited_pending_qty
                    FROM fn_preplan_aggregate_alias_coverage(:analysisId) coverage
                    JOIN production_material_analysis_materials material ON material.id=coverage.analysis_material_id
                    WHERE coverage.inherited_pending_qty>0
                    """).setParameter("analysisId",analysisId)))external.merge(nodeRef(uuid(row[0]),string(row[1])),decimal(row[2]),BigDecimal::add);
        }
        Map<String, BigDecimal> internal = new LinkedHashMap<>();
        for (Object[] row : NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT parent.analysis_item_id || '|' || parent.node_key,
                       SUM(child.requested_qty)::numeric
                FROM production_material_analysis_items child
                JOIN production_material_analysis_materials parent
                  ON parent.id = child.parent_analysis_material_id
                 AND parent.analysis_id = child.analysis_id
                 AND parent.active = TRUE
                WHERE child.analysis_id = :analysisId
                  AND child.source_type = 'MAKE_COMPONENT'
                  AND child.is_deleted = FALSE
                GROUP BY 1
                """).setParameter("analysisId", analysisId))) {
            internal.put(string(row[0]), decimal(row[1]));
        }
        // ADR-099：锚点行已下达且仍有效的计划总量（归需求量 + 公共备货产出）。
        // 车间桶填的本批数量超过需求时，下层按它展开，不再被物理缺口封顶。
        //
        // 2026-09-21 用户口径：已经做出来的那部分不再需要下层原料——它的料早就领走用掉了。
        // 所以每条计划链接按「本批计划量 − 本计划已完工入库量」计，单条不为负再求和。
        // 例：某件计划做 10、做完 10、其中 4 件报废要重做使锚点涨到 14 时，
        // 下层原料的「还需安排」是 4 份而不是 14 份（旧算法会让人多买 10 份料）。
        // 已完工入库量沿用 productPlanStates 的同一口径：按计划明细的 iqty 封顶到 qty。
        Map<String, BigDecimal> planned = new LinkedHashMap<>();
        for (Object[] row : NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT parent.analysis_item_id || '|' || parent.node_key,
                       SUM(GREATEST(
                           link.submitted_qty + link.public_surplus_qty
                           - COALESCE(done.inbound_qty, 0), 0))::numeric
                FROM production_material_analysis_plan_links link
                JOIN production_material_analysis_items child
                  ON child.id = link.analysis_item_id
                 AND child.analysis_id = link.analysis_id
                 AND child.is_deleted = FALSE
                 AND child.source_type = 'MAKE_COMPONENT'
                JOIN production_material_analysis_materials parent
                  ON parent.id = child.parent_analysis_material_id
                 AND parent.analysis_id = child.analysis_id
                 AND parent.active = TRUE
                LEFT JOIN LATERAL (
                    SELECT COALESCE(SUM(GREATEST(LEAST(
                               COALESCE(plan_item.iqty, 0),
                               GREATEST(COALESCE(plan_item.qty, 0), 0)), 0)), 0)
                             AS inbound_qty
                    FROM production_plan_items plan_item
                    WHERE plan_item.plan_id = link.plan_id
                ) done ON TRUE
                WHERE link.analysis_id = :analysisId
                  AND link.allocation_status IN ('SUBMITTED','APPROVED')
                GROUP BY 1
                """).setParameter("analysisId", analysisId))) {
            planned.put(string(row[0]), decimal(row[1]));
        }
        // ADR-143 §4.5：委外件(任何层级)不建锚点也不出计划, 上面那条计划链接的查询对它
        // 恒为空。我方领直属物料发外, 下层按它自己那张**未结的委外供给行动**展开:
        // 申请量 + 公共超量 − 合格入库回厂量, 按该行动在各物料行上的分摊比例摊回节点,
        // 只算要我方领料发外的份额。没有这一项, 真实下达 1500 之后直属物料需求会退回按
        // 物理缺口算的 1000, 多出来的 500 份物料就成了无人负责的需求。
        for (Object[] row : NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT material.analysis_item_id || '|' || material.node_key,
                       SUM(
                """ + SUBCONTRACT_PLANNED_OUTPUT_SQL + """
                       )::numeric
                FROM preplan_supply_actions action
                JOIN preplan_supply_action_allocations allocation
                  ON allocation.action_id = action.id
                JOIN production_material_analysis_materials material
                  ON material.id = allocation.analysis_material_id
                 AND material.active = TRUE
                WHERE action.analysis_id = :analysisId
                  AND action.operation_type = 'SUPPLY'
                  AND action.route = 'SUBCONTRACT'
                  AND action.status IN ('OPEN','CREATED','IN_PROGRESS')
                  AND action.requested_qty > 0
                GROUP BY 1
                """).setParameter("analysisId", analysisId))) {
            planned.merge(string(row[0]), decimal(row[1]), BigDecimal::add);
        }
        if (!overlay.isNone()) {
            overlay.plannedOutputByNode().forEach((key, qty) -> planned.merge(key, qty, BigDecimal::add));
            overlay.internalCommitmentByNode().forEach((key, qty) -> internal.merge(key, qty, BigDecimal::add));
        }
        if (external.isEmpty() && internal.isEmpty() && planned.isEmpty()&&delegated.isEmpty()) return Map.of();
        Map<String, ParentSupplyCommitment> result = new LinkedHashMap<>();
        Set<String> keys = new LinkedHashSet<>(external.keySet());
        keys.addAll(internal.keySet());
        keys.addAll(planned.keySet());
        keys.addAll(delegated.keySet());
        for (String key : keys) {
            result.put(key, new ParentSupplyCommitment(
                    external.getOrDefault(key, BigDecimal.ZERO),
                    internal.getOrDefault(key, BigDecimal.ZERO),
                    planned.getOrDefault(key, BigDecimal.ZERO),delegated.getOrDefault(key,BigDecimal.ZERO)));
        }
        return Map.copyOf(result);
    }

    /**
     * 层级表上「顶层供给行」(ROOT_SUPPLY) 填的数量 → 它那条来源行的计划产出量。
     * 第 1 层子件按来源展开，不经 parentSupply，所以顶层那一行必须单独落到这里。
     */
    private Map<UUID, BigDecimal> typedSourceOutputs(
            UUID analysisId, Map<UUID, BigDecimal> typedOutputByMaterialLine) {
        if (typedOutputByMaterialLine == null || typedOutputByMaterialLine.isEmpty()) return Map.of();
        List<UUID> lineIds = typedOutputByMaterialLine.entrySet().stream()
                .filter(entry -> entry.getValue() != null && entry.getValue().signum() > 0)
                .map(Map.Entry::getKey).distinct().toList();
        if (lineIds.isEmpty()) return Map.of();
        Map<UUID, BigDecimal> result = new LinkedHashMap<>();
        for (Object[] row : NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT id, analysis_item_id
                FROM production_material_analysis_materials
                WHERE analysis_id = :analysisId AND active = TRUE
                  AND node_role = 'ROOT_SUPPLY' AND id IN (:lineIds)
                """).setParameter("analysisId", analysisId).setParameter("lineIds", lineIds))) {
            BigDecimal typed = typedOutputByMaterialLine.get(uuid(row[0]));
            if (typed != null && typed.signum() > 0) {
                result.merge(uuid(row[1]), typed, BigDecimal::max);
            }
        }
        return Map.copyOf(result);
    }

    /**
     * 来源行的计划产出量, 把「顶层供给行这次填了多少」并进来。
     *
     * <p>并法与 {@link #withTypedOutput} 逐字一致: <b>已下达计划量 + 本次填的量</b>,
     * 再与需求量取大。框里那个数是「本次要下达多少」(追加行更是明写「追加量」),
     * 不是「把这一批改成多少」——取大的话, 已经下达过 1000 的顶层再追加 500 就只算
     * 1000, 那 500 的子件需求凭空消失。</p>
     */
    private static BigDecimal plannedSourceOutput(
            SourceLine source, Map<UUID, BigDecimal> typedSourceOutput) {
        BigDecimal typed = typedSourceOutput.get(source.analysisItemId());
        if (typed == null) return source.plannedOutputQty();
        return source.materialRequirementQty().max(source.committedOutputQty().add(typed));
    }

    private static BigDecimal plannedSourceOutput(SourceLine source,Map<UUID,BigDecimal> typedSourceOutput,BigDecimal adoptedBase,BigDecimal forecastBase) {
        if(adoptedBase.signum()==0)return plannedSourceOutput(source,typedSourceOutput);
        BigDecimal adoptedUnits=adoptedBase.divide(source.unitRate(),12,RoundingMode.DOWN);
        BigDecimal requirement=source.materialRequirementQty().subtract(adoptedUnits).max(BigDecimal.ZERO);
        BigDecimal typed=typedSourceOutput.getOrDefault(source.analysisItemId(),BigDecimal.ZERO);
        if(typed.signum()>0)typed=typed.subtract(forecastBase.divide(source.unitRate(),12,RoundingMode.DOWN)).max(BigDecimal.ZERO);
        return requirement.max(source.committedOutputQty().add(typed));
    }

    /**
     * 把「本次每个父行填了多少」并进各自节点的计划产出量(ADR-099 修订，2026-09-21)。
     *
     * <p>加在 {@link ParentSupplyCommitment#plannedOutputQty()} 上，而不是与需求量取大：
     * 那一项本来就是「已下达且未完工的计划总量」，本次要下的这批与它是同一种东西，
     * 所以是 <b>已下达 + 本次填写</b>。{@link #parentPlannedOutput} 随后再与物理缺口
     * 取大，于是「填得比缺口少」(缺口里有一部分已由在途顶上)不会把子层需求抬高，
     * 「填得比缺口多」(超量 / 追加公共备货)则如实带大子层。</p>
     *
     * <p>输入框挂在<b>提交单元</b>上(同一操作组在树里可能出现多条路径，只有第一处
     * 能填)，所以填的是整组的总量：这里按各路径当前需求量的占比拆回节点，全组需求
     * 都是 0 时平均分。不拆的话，整组的量会全压在第一条路径上，那条路径的子层被
     * 撑大、别的路径的子层纹丝不动，合计对不上。</p>
     */
    private Map<String, ParentSupplyCommitment> withTypedOutput(
            UUID analysisId, Map<String, ParentSupplyCommitment> committed,
            Map<UUID, BigDecimal> typedOutputByMaterialLine, MaterialAnalysisIssuePreviewOverlay overlay) {
        if (typedOutputByMaterialLine == null || typedOutputByMaterialLine.isEmpty()) return committed;
        List<UUID> lineIds = typedOutputByMaterialLine.entrySet().stream()
                .filter(entry -> entry.getValue() != null && entry.getValue().signum() > 0)
                .map(Map.Entry::getKey).distinct().toList();
        if (lineIds.isEmpty()) return committed;
        record Peer(UUID ownerId, String nodeRef, BigDecimal requiredQty) {}
        List<Peer> peers = new ArrayList<>();
        for (Object[] row : NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT owner.id,
                       peer.analysis_item_id || '|' || peer.node_key,
                       peer.required_qty
                FROM production_material_analysis_materials owner
                JOIN production_material_analysis_materials peer
                  ON peer.analysis_id = owner.analysis_id
                 AND peer.active = TRUE
                 AND peer.analysis_item_id = owner.analysis_item_id
                 AND peer.path = owner.path
                 AND peer.goods_id = owner.goods_id
                 AND peer.color_id IS NOT DISTINCT FROM owner.color_id
                 AND peer.unit_id = owner.unit_id
                WHERE owner.analysis_id = :analysisId
                  AND owner.active = TRUE
                  AND owner.id IN (:lineIds)
                """).setParameter("analysisId", analysisId).setParameter("lineIds", lineIds))) {
            // 下达预览第二轮(锚点配额增长后)按上一轮内存重算的需求拆分, 与真实刷新重读
            // 上一轮写回值同口径。
            MaterialAnalysisIssuePreviewOverlay.NodeSnapshot projected = overlay.node(string(row[1]));
            peers.add(new Peer(uuid(row[0]), string(row[1]),
                    projected == null ? decimal(row[2]) : projected.required()));
        }
        if (peers.isEmpty()) return committed;
        Map<UUID, List<Peer>> byOwner = peers.stream()
                .collect(Collectors.groupingBy(Peer::ownerId, LinkedHashMap::new, Collectors.toList()));
        Map<String, ParentSupplyCommitment> merged = new LinkedHashMap<>(committed);
        byOwner.forEach((ownerId, group) -> {
            BigDecimal typed = typedOutputByMaterialLine.get(ownerId);
            if (typed == null || typed.signum() <= 0) return;
            BigDecimal totalRequired = group.stream().map(Peer::requiredQty)
                    .reduce(BigDecimal.ZERO, BigDecimal::add);
            BigDecimal allocated = BigDecimal.ZERO;
            for (int index = 0; index < group.size(); index++) {
                Peer peer = group.get(index);
                BigDecimal share = index == group.size() - 1
                        ? typed.subtract(allocated)
                        : totalRequired.signum() > 0
                                ? typed.multiply(peer.requiredQty())
                                        .divide(totalRequired, 4, RoundingMode.DOWN)
                                : typed.divide(BigDecimal.valueOf(group.size()), 4, RoundingMode.DOWN);
                allocated = allocated.add(share);
                if (share.signum() <= 0) continue;
                ParentSupplyCommitment current = merged.getOrDefault(
                        peer.nodeRef(), ParentSupplyCommitment.NONE);
                merged.put(peer.nodeRef(), new ParentSupplyCommitment(
                        current.externalFutureQty(), current.internalCommittedQty(),
                        current.plannedOutputQty().add(share),current.aggregateDelegatedOutputQty()));
            }
        });
        return Map.copyOf(merged);
    }

    private Map<MaterialDimension, List<WarehouseBreakdown>> warehouseBreakdown(
            UUID analysisId, List<MaterialRow> materials, SharedFutureIndex sharedFuture,
            Map<WarehouseMaterialDimension,BigDecimal> qualifiedOwned,
            Map<WarehouseMaterialDimension,BigDecimal> componentDraftOwned) {
        return warehouseBreakdown(analysisId,materials,sharedFuture,qualifiedOwned,componentDraftOwned,MaterialAnalysisIssuePreviewOverlay.NONE);
    }

    private Map<MaterialDimension, List<WarehouseBreakdown>> warehouseBreakdown(
            UUID analysisId, List<MaterialRow> materials,
            SharedFutureIndex sharedFuture,
            Map<WarehouseMaterialDimension,BigDecimal> qualifiedOwned,
            Map<WarehouseMaterialDimension,BigDecimal> componentDraftOwned,
            MaterialAnalysisIssuePreviewOverlay overlay) {
        Set<UUID> goodsIds = materials.stream().map(MaterialRow::goodsId)
                .collect(Collectors.toSet());
        if (goodsIds.isEmpty()) return Map.of();
        Map<MaterialDimension, List<WarehouseBreakdown>> result = new HashMap<>();
        Map<MaterialDimension, MaterialRow> materialsByDimension = materials.stream()
                .collect(Collectors.toMap(MaterialRow::dimension, row -> row,
                        (first, ignored) -> first, LinkedHashMap::new));
        List<Object[]> rows = MaterialAnalysisWarehouseBreakdownReader.read(
                em, analysisId, uuidArrayText(goodsIds));
        Map<MainWarehouseMaterialDimension, List<com.uten.imp.common.inventory.MainWarehouseStockBudget.Leaf<WarehouseMaterialDimension>>> leaves = new LinkedHashMap<>();
        Map<MainWarehouseMaterialDimension, BigDecimal> safetyByMain = new HashMap<>();
        Map<WarehouseMaterialDimension, WarehouseBreakdown> preliminary = new LinkedHashMap<>();
        for (Object[] row : rows) {
            MaterialDimension dimension = new MaterialDimension(
                    uuid(row[0]), uuid(row[1]), uuid(row[2]));
            MaterialRow matching = materialsByDimension.get(dimension);
            if (matching == null) continue;
            WarehouseMaterialDimension location = new WarehouseMaterialDimension(uuid(row[3]), dimension);
            BigDecimal qualified = qualifiedOwned.getOrDefault(
                    new WarehouseMaterialDimension(uuid(row[3]), matching.dimension()), BigDecimal.ZERO);
            boolean publicAllowed = Boolean.TRUE.equals(row[12]);
            BigDecimal ownPegged = publicAllowed
                    ? decimal(row[9]).subtract(overlay.ownedTransferred(location)).max(BigDecimal.ZERO)
                        .add(componentDraftOwned.getOrDefault(location, BigDecimal.ZERO)) : qualified;
            BigDecimal reserved = decimal(row[7]).add(overlay.publicReservationChange(location)).subtract(ownPegged).max(BigDecimal.ZERO);
            ownPegged = ownPegged.min(decimal(row[6]).subtract(reserved).max(BigDecimal.ZERO));
            BigDecimal publicAvailable = publicAllowed ? decimal(row[8]).subtract(overlay.publicReservationChange(location)).max(BigDecimal.ZERO) : BigDecimal.ZERO;
            BigDecimal safetyStock = decimal(row[10]).max(BigDecimal.ZERO);
            BigDecimal openSafety = decimal(row[11]).max(BigDecimal.ZERO);
            // Only proven task-owned qualified receipts bypass the public safety threshold.
            BigDecimal available = availableWithQualifiedOwnAfterSafety(
                    publicAvailable, ownPegged, qualified, safetyStock);
            BigDecimal safetyGap = publicSafetyReplenishmentGap(
                    safetyStock, publicAvailable, openSafety);
            SharedFutureAggregate shared = sharedFuture.overview(
                    uuid(row[3]), matching.dimension());
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
                  AND progress.safety_future_qty>0 AND action.goods_id IN (SELECT unnest(CAST(string_to_array(:goodsIds, ',') AS uuid[])))
                  AND fn_warehouse_same_main(action.warehouse_id,:warehouseId)
                GROUP BY action.goods_id, action.color_id
                """).setParameter("goodsIds", uuidArrayText(goodsIds)).setParameter("warehouseId", warehouseId))) {
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
        for (Object[] row : SubcontractComponentCustodyProjection.held(em, analysisId)) {
            result.merge(uuid(row[1]), decimal(row[8]), BigDecimal::add);
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
                       ), 0), 0) AS current_effective_qty,
                       COALESCE(reallocation_creator_employee.full_name,
                                reallocation_creator.login_account) AS created_by_name,
                       reallocation.created_at,
                       source_analysis.analysis_no,
                       target_analysis.analysis_no
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
                LEFT JOIN users reallocation_creator
                  ON reallocation_creator.id = reallocation.created_by
                LEFT JOIN employees reallocation_creator_employee
                  ON reallocation_creator_employee.id = reallocation_creator.employee_id
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
            // 对端分析标签（V719）：优先编号；无编号的夹具行回退 id 前 8 位短号。
            String counterpartLabel = firstNonBlank(
                    string(outgoing ? row[24] : row[23]),
                    "物料分析 " + counterpartAnalysisId.toString()
                            .substring(0, 8).toUpperCase(Locale.ROOT));
            CrossReallocationRef ref = new CrossReallocationRef(
                    id, outgoing ? "OUT" : "IN", status,
                    counterpartAnalysisId, counterpartVersion,
                    counterpartFingerprint, counterpartMaterialId,
                    counterpartLabel,
                    counterpartProduct, qty, currentEffective,
                    fulfilled, open, string(row[8]),
                    canRevoke, blocked,
                    replenishments.getOrDefault(id, List.of()),
                    string(row[21]), offsetDateTime(row[22]));
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
                WHERE event.reallocation_id IN (SELECT unnest(CAST(string_to_array(:ids, ',') AS uuid[])))
                  AND event.event_type IN (
                      'PRIORITY_IN', 'PRIORITY_SATISFIED_IN_PLACE')
                ORDER BY event.created_at, event.id
                """).setParameter("ids", uuidArrayText(reallocationIds)));
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
        if (!access.canWrite(header.makerId(), scopeForAnalysis(header))) return List.of("VIEW", "VIEW_FUTURE_TRANSFERS");
        List<String> result = new ArrayList<>(List.of("VIEW", "VIEW_FUTURE_TRANSFERS"));
        if (!"CANCELLED".equals(header.status()) && rootSupply != null
                && access.hasAuthority("production_material_analysis:notify")
                && rootSupply.hasReversibleExistingOutput(analysisId)) {
            result.add("ROOT_OUTPUT_REVOKE");
        }
        if (!List.of(STATUS_ACTIVE, STATUS_PARTIAL).contains(header.status())) return List.copyOf(result);
        if (access.hasAuthority("production_material_analysis:refresh")) {
            result.add("REFRESH");
        }
        if (canConfirmRoutes(header, fqcReplenishmentOnly)) {
            result.add("CONFIRM_ROUTES");
        }
        if (access.hasAuthority("production_material_analysis:notify")) {
            result.add("NOTIFY_SUPPLY");
            Number retractable = (Number) em.createNativeQuery("""
                    SELECT COUNT(*) FROM preplan_supply_actions action
                    WHERE analysis_id = :analysisId
                      AND operation_type = 'SUPPLY'
                      AND status IN ('OPEN','CREATED','IN_PROGRESS')
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
            if (!result.contains("CANCEL_ACTION") && Boolean.TRUE.equals(em.createNativeQuery("""
                    SELECT EXISTS(SELECT 1 FROM preplan_aggregate_batches batch
                      JOIN preplan_supply_actions action ON action.id=batch.action_id
                      WHERE batch.analysis_id=:analysis AND batch.plan_id IS NOT NULL
                        AND action.status IN('OPEN','CREATED','IN_PROGRESS'))
                    """).setParameter("analysis",analysisId).getSingleResult())) {
                result.add("CANCEL_ACTION");
            }
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
                WITH selected_actions AS MATERIALIZED (
                    SELECT action.*,
                           CASE WHEN fn_preplan_supply_action_growable(action.id)
                                THEN action.requested_qty+action.public_surplus_qty END AS growable_order_qty
                    FROM preplan_supply_actions action
                    WHERE action.analysis_id=:id
                      AND EXISTS(SELECT 1 FROM preplan_supply_action_allocations allocation WHERE allocation.action_id=action.id)
                )
                SELECT allocation.analysis_material_id, action.id,
                       -- 跨路线调入（专属在途转拨 / 公共在途认领）沿用来源路线
                       -- 落动作，但它冲减的是「目标行自己那条路线」的待下达量。
                       -- 分桶归属与桶内已下达量都读这个 route，所以这里按目标行
                       -- 已确认路线归位；来源单据类型与单号保持原样，进度链路
                       -- 仍然显示真实的采购/委外单。
                       CASE WHEN action.operation_type IN ('FUTURE_TRANSFER','SHARED_FUTURE_CLAIM')
                            THEN COALESCE(target_material.confirmed_route, action.route)
                            ELSE action.route END,
                       action.status, action.external_document_type,
                       action.external_document_id, action.external_document_no,
                       allocation.allocated_qty,
                       -- ADR-099：申请明细仍未订货(可就地改大)时给出明细当前数量。
                       action.growable_order_qty
                FROM preplan_supply_action_allocations allocation
                JOIN selected_actions action ON action.id = allocation.action_id
                JOIN production_material_analysis_materials target_material
                  ON target_material.id = allocation.analysis_material_id
                WHERE action.analysis_id = :id
                ORDER BY action.created_at, action.id, allocation.id
                """).setParameter("id", analysisId));
        for (Object[] row : rows) {
            result.computeIfAbsent(uuid(row[0]), ignored -> new ArrayList<>()).add(
                    new DownstreamReference(uuid(row[1]), string(row[2]), string(row[3]),
                            string(row[4]), uuid(row[5]), string(row[6]), decimal(row[7]),
                            row.length>8 && row[8]!=null ? decimal(row[8]) : null));
        }
        // A pure-public shared append has no private allocation row. Its explicit
        // source context remains navigable, with zero private quantity, through the immutable intent.
        for(Object[] row:NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT DISTINCT material.id,action.id,action.route,action.status,action.external_document_type,
                       action.external_document_id,action.external_document_no
                FROM preplan_aggregate_batches batch JOIN preplan_supply_actions action ON action.id=batch.action_id
                JOIN preplan_aggregate_batch_events event ON event.batch_id=batch.id AND event.event_type IN('CREATE','APPEND')
                CROSS JOIN LATERAL jsonb_array_elements_text(COALESCE(event.intent_snapshot->'materialLineIds','[]'::jsonb)) scope(id)
                JOIN production_material_analysis_materials material ON material.id=CAST(scope.id AS uuid) AND material.analysis_id=batch.analysis_id
                WHERE batch.analysis_id=:id AND action.public_surplus_qty>0
                  AND NOT EXISTS(SELECT 1 FROM preplan_supply_action_allocations allocation
                    WHERE allocation.action_id=action.id AND allocation.analysis_material_id=material.id)
                """).setParameter("id",analysisId))) {
            result.computeIfAbsent(uuid(row[0]),ignored->new ArrayList<>()).add(new DownstreamReference(uuid(row[1]),string(row[2]),string(row[3]),
                    string(row[4]),uuid(row[5]),string(row[6]),BigDecimal.ZERO));
        }
        return result;
    }

    record MaterialGroup(String key, List<MaterialRow> materials) {}

    /** One command-local index; a group key's SHA is calculated once per node. */
    record MaterialGroupIndex(Map<UUID, MaterialRow> byId, Map<UUID, String> keyById,
                              Map<String, List<MaterialRow>> byKey) {
        static MaterialGroupIndex of(List<MaterialRow> materials) {
            Map<UUID, MaterialRow> byId = new LinkedHashMap<>();
            Map<UUID, String> keys = new HashMap<>();
            Map<String, List<MaterialRow>> groups = new LinkedHashMap<>();
            for (MaterialRow row : materials) {
                byId.put(row.id(), row);
                if (!row.actionable()) continue;
                String key = row.actionGroupKey();
                keys.put(row.id(), key);
                groups.computeIfAbsent(key, ignored -> new ArrayList<>()).add(row);
            }
            groups.replaceAll((key, rows) -> List.copyOf(rows));
            return new MaterialGroupIndex(Map.copyOf(byId), Map.copyOf(keys), Map.copyOf(groups));
        }

        MaterialGroup resolve(RouteDecision decision) {
            if (decision == null || (decision.materialLineId() == null
                    && blankToNull(decision.actionGroupKey()) == null)) {
                throw validation("物料路线必须提交 actionGroupKey 或代表节点");
            }
            String key = blankToNull(decision.actionGroupKey());
            if (key == null) {
                MaterialRow row = byId.get(decision.materialLineId());
                if (row == null) throw validation("物料分析代表节点不存在");
                if (!row.actionable()) throw validation("该节点当前没有独立需求，不能确认供应路线");
                key = keyById.get(row.id());
            }
            List<MaterialRow> group = byKey.getOrDefault(key, List.of());
            if (group.isEmpty()) throw validation("物料操作组不存在或已过期");
            return new MaterialGroup(key, group);
        }
    }

    List<SupplyActionView> supplyActions(UUID analysisId) {
        return NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT id, action_group_key, generation, predecessor_action_id,
                       route, status, goods_id, color_id, unit_id,
                       requested_qty, safety_replenishment_qty,
                       requested_qty + safety_replenishment_qty + public_surplus_qty,
                       safety_stock_snapshot_qty,
                       public_available_snapshot_qty,
                       open_safety_supply_snapshot_qty,
                       need_date, external_document_type,
                       external_document_id, external_document_no,
                       public_surplus_qty,
                       public_surplus_external_item_id,
                       CASE WHEN EXISTS(SELECT 1 FROM preplan_aggregate_batches aggregate_batch
                            WHERE aggregate_batch.action_id=preplan_supply_actions.id)
                            THEN 'AGGREGATE_SUPPLY' ELSE operation_type END, claim_source_action_id
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

    /**
     * 非销售来源的主档校验(批量)：一次按 id 排序锁住全部货品的数量基准(FOR KEY SHARE)，再各用一条查询读回
     * 货品基本单位与有效单位——一张手工需求单挂多少货品都是固定三条语句(ADR-130)，不再每行两条。
     */
    private void requireManualSourceMasters(Collection<SourceIdentity> sources) {
        if (sources.isEmpty()) return;
        List<UUID> goodsIds = sources.stream().map(SourceIdentity::goodsId)
                .filter(Objects::nonNull).distinct().sorted().toList();
        List<UUID> unitIds = sources.stream().map(SourceIdentity::unitId)
                .filter(Objects::nonNull).distinct().sorted().toList();
        if (goodsIds.isEmpty() || unitIds.isEmpty()) throw notFound("手工生产来源的货品或单位不存在");
        com.uten.imp.common.concurrency.GoodsQuantityBasisLocks.lockForQuantityUse(em, goodsIds);
        Map<UUID, UUID> baseUnitByGoods = new HashMap<>();
        for (Object[] row : NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT g.id, g.unit_id AS base_unit_id
                FROM goods g
                WHERE g.id IN (:goodsIds) AND g.is_deleted = FALSE
                """).setParameter("goodsIds", goodsIds))) {
            baseUnitByGoods.put(uuid(row[0]), uuid(row[1]));
        }
        Set<UUID> liveUnits = new HashSet<>();
        for (Object unit : em.createNativeQuery("""
                SELECT u.id FROM units u
                WHERE u.id IN (:unitIds) AND u.is_deleted = FALSE
                """).setParameter("unitIds", unitIds).getResultList()) {
            liveUnits.add(uuid(unit));
        }
        for (SourceIdentity source : sources) {
            if (!baseUnitByGoods.containsKey(source.goodsId()) || !liveUnits.contains(source.unitId())) {
                throw notFound("手工生产来源的货品或单位不存在");
            }
            if (!Objects.equals(baseUnitByGoods.get(source.goodsId()), source.unitId())) {
                throw validation("手工生产来源只能使用货品主档的基本单位");
            }
        }
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
                       analyzed_at, maker_id, is_deleted, analysis_no
                FROM production_material_analyses WHERE id = :id
                """).setParameter("id", analysisId), "物料分析不存在");
        if (Boolean.TRUE.equals(row[7])) throw notFound("物料分析不存在");
        return new AnalysisHeader(uuid(row[0]), uuid(row[1]), string(row[2]),
                ((Number) row[3]).longValue(), string(row[4]), offsetDateTime(row[5]),
                uuid(row[6]), string(row[8]));
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
                  AND NOT is_defective
                  AND COALESCE(status, '') <> '禁用'
                  AND (parent_id IS NULL OR (is_accountable = TRUE
                    AND fn_warehouse_is_operational_leaf(warehouses.id)))
                """).setParameter("warehouseIds", requested).getSingleResult();
        if (valid.longValue() != requested.size()) {
            throw notFound("所选主仓库或历史仓库范围不存在、已禁用、是不良品仓或不能用于物料分析");
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

    /**
     * 主档来源 → 建议路线。空/未知来源：有 BOM 子层的件按自制建议（有维护 BOM 的件默认
     * 可自制，子层需求随之展开，与主档为「自制」的父件同一行为；ADR-029 §6.1 2026-09-10
     * 前向批注），叶子件仍为 REVIEW（只影响 UI 默认预填，不展开任何子层）。
     */
    static String suggestion(String rawSourceType, boolean hasChildren) {
        String value = rawSourceType == null ? "" : rawSourceType.strip();
        return switch (value) {
            case "采购" -> "BUY";
            case "自制" -> "MAKE";
            case "委外" -> "SUBCONTRACT";
            default -> hasChildren ? "MAKE" : "REVIEW";
        };
    }

    /**
     * 确认路线 → 货品主档来源 (goods.source_type 值域见 V128：'自制' / '采购' / '委外')，
     * 是 {@link #suggestion(String, boolean)} 的逆映射：确认即回写主档，下次分析的建议
     * 路线就是这次确认的值。非法路线与 {@link #normalizeRoute} 同一条报错。
     */
    static String sourceTypeForRoute(String route) {
        return switch (normalizeRoute(route)) {
            case "BUY" -> "采购";
            case "MAKE" -> "自制";
            case "SUBCONTRACT" -> "委外";
            default -> throw validation("物料路线必须为 BUY、MAKE 或 SUBCONTRACT");
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
        return value == null ? BigDecimal.ZERO
                : value instanceof BigDecimal number ? number : new BigDecimal(value.toString());
    }

    /** 可空数值列：未维护时保持 null，不能当 0 用（0 与「没填」语义不同）。 */
    static BigDecimal optionalDecimal(Object value) {
        return value == null ? null : decimal(value);
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

    /**
     * 父节点的两类已承诺供给，决定它「还要自己产出多少」，进而决定下层毛需求。
     *
     * @param externalFutureQty   已被外部最终件在途覆盖的量（采购/委外在途、
     *                            跨计划转入、公共认领、失败重开切片）。这部分
     *                            到货即可直接顶上，父件不必为它准备下层原料。
     * @param internalCommittedQty 已承诺由我方制造的量（已下达车间的自制锚点）。
     *                            这部分的物理来源就是下层原料，已下达即冻结，
     *                            绝不能被在途挤掉。
     * @param plannedOutputQty    锚点行已下达且仍有效、且**尚未完工**的计划总量
     *                            （归需求量 + 公共备货产出 − 已完工入库量，
     *                            ADR-099），以及未结委外申请要我方领料发外的
     *                            申请量 + 公共超量 − 合格入库回厂量（ADR-143）。
     *                            计划员填的本批数量超过需求时，下层按这个量展开，
     *                            不再被物理缺口封顶；已经做出来/回厂的那部分不计入
     *                            ——它的下层原料早已领走用掉。
     */
    record ParentSupplyCommitment(
            BigDecimal externalFutureQty, BigDecimal internalCommittedQty,
            BigDecimal plannedOutputQty,BigDecimal aggregateDelegatedOutputQty) {
        static final ParentSupplyCommitment NONE = new ParentSupplyCommitment(
                BigDecimal.ZERO, BigDecimal.ZERO, BigDecimal.ZERO);

        ParentSupplyCommitment(BigDecimal externalFutureQty, BigDecimal internalCommittedQty) {
            this(externalFutureQty, internalCommittedQty, BigDecimal.ZERO);
        }
        ParentSupplyCommitment(BigDecimal externalFutureQty,BigDecimal internalCommittedQty,BigDecimal plannedOutputQty) {
            this(externalFutureQty,internalCommittedQty,plannedOutputQty,BigDecimal.ZERO);
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
                          String fingerprint, OffsetDateTime analyzedAt, UUID makerId,
                          String analysisNo) {
        /** 兼容旧签名（在途归属调整等只读用途不关心编号）。 */
        AnalysisHeader(UUID id, UUID warehouseId, String status, long version,
                       String fingerprint, OffsetDateTime analyzedAt, UUID makerId) {
            this(id, warehouseId, status, version, fingerprint, analyzedAt, makerId, null);
        }
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
            List<SharedFutureSupplyRef> refs, BigDecimal lateAvailableQty) {
        SharedFutureAggregate(BigDecimal approvedInboundQty,BigDecimal availableQty,LocalDate expectedDate,List<SharedFutureSupplyRef> refs) {
            this(approvedInboundQty,availableQty,expectedDate,refs,BigDecimal.ZERO);
        }
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
            Map<WarehouseMaterialDimension, SharedFutureAggregate> byDimension,
            Map<UUID,SharedFutureAggregate> byMaterial) {
        SharedFutureIndex(Map<WarehouseMaterialDimension,SharedFutureAggregate> byDimension) {
            this(byDimension,Map.of());
        }
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
            return forMaterial(null,warehouseId,dimension,route,needDate);
        }
        SharedFutureAggregate forMaterial(
                UUID materialId,UUID warehouseId,MaterialDimension dimension,
                String route,LocalDate needDate) {
            SharedFutureAggregate dimensionTotal = byDimension.getOrDefault(
                    new WarehouseMaterialDimension(warehouseId, dimension),
                    SharedFutureAggregate.ZERO);
            SharedFutureAggregate raw=materialId==null?dimensionTotal:byMaterial.getOrDefault(materialId,dimensionTotal);
            boolean actionableRoute = Set.of("MAKE", "BUY", "SUBCONTRACT")
                    .contains(Objects.toString(route, ""));
            List<SharedFutureSupplyRef> matching = raw.refs();
            BigDecimal approved = matching.stream()
                    .map(SharedFutureSupplyRef::approvedInboundQty)
                    .reduce(BigDecimal.ZERO, BigDecimal::add);
            BigDecimal available = actionableRoute ? matching.stream()
                    .filter(ref -> ref.expectedDate() != null
                            && (needDate == null || !ref.expectedDate().isAfter(needDate)))
                    .map(SharedFutureSupplyRef::availableToClaimQty)
                    .reduce(BigDecimal.ZERO, BigDecimal::add)
                    : BigDecimal.ZERO;
            BigDecimal late=actionableRoute ? matching.stream()
                    .filter(ref->ref.expectedDate()==null || needDate!=null && ref.expectedDate().isAfter(needDate))
                    .map(SharedFutureSupplyRef::availableToClaimQty).reduce(BigDecimal.ZERO,BigDecimal::add) : BigDecimal.ZERO;
            LocalDate expected = matching.stream()
                    .map(SharedFutureSupplyRef::expectedDate)
                    .filter(Objects::nonNull).min(LocalDate::compareTo).orElse(null);
            return new SharedFutureAggregate(
                    approved, available, expected, List.copyOf(matching),late);
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
            UUID rootMaterialLineId, BigDecimal rootFulfilledQty, String rootRoute,
            /** V587 货品主档「所属仓库」，与落点仓/分析范围仓无关；未登记为 null。 */
            UUID owningWarehouseId, String owningWarehouseName,
            /** V590 货品主档「归属生产车间」（最近一次排产确认/改派学习回写）。 */
            UUID owningWorkshopId, String owningWorkshopName,
            /** 已下达且仍有效的计划里超出需求的公共备货产出合计（ADR-099）。 */
            BigDecimal plannedSurplusQty,
            /**
             * 顶层委外件未结委外申请的计划产出(基本单位，ADR-143 §4.5)：申请量 + 公共超量
             * − 合格入库回厂量，只算我方领直属物料发外的份额；非委外顶层为 0。
             */
            BigDecimal rootSubcontractOutputBaseQty) implements MaterialAnalysisPlanSource {
        @Override public UUID analysisLineId() { return analysisItemId; }
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
            this(analysisItemId, sourceType, salesOrderItemId, salesOrderId, salesOrderNo, orderDate, deliveryDate, clientName, goodsId, goodsCode, goodsName, spec, colorId, colorName, unitId, unitName, unitRate, requestedQty, submittedQty, approvedQty, salesQty, shippedQty, returnedQty, flagQty, reservedQty, plannedQty, producedQty, activeDraftQty, orderStatus, orderStopped, orderClosed, orderDeleted, orderItemDeleted, sourceRef, sourceReason, allocationPriority, readyNowQty, readyByDateQty, readyStartQty, readyFinishQty, readyShipQty, parentAnalysisLineId, parentGoodsName, orderFinanceConfirmed, null, BigDecimal.ZERO, null, null, null, null, null, BigDecimal.ZERO, BigDecimal.ZERO);
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
                    row.length > 46 ? string(row[46]) : null,
                    row.length > 47 ? uuid(row[47]) : null,
                    row.length > 48 ? string(row[48]) : null,
                    row.length > 49 ? uuid(row[49]) : null,
                    row.length > 50 ? string(row[50]) : null,
                    row.length > 51 ? decimal(row[51]) : BigDecimal.ZERO,
                    row.length > 52 ? decimal(row[52]) : BigDecimal.ZERO);
        }

        /** 下达预览(ADR-116): 叠上本批计划/锚点配额差与重算后的齐套列; 其余字段原样。 */
        SourceLine withPreview(MaterialAnalysisIssuePreviewOverlay.SourceDelta delta) {
            return new SourceLine(analysisItemId, sourceType, salesOrderItemId, salesOrderId, salesOrderNo,
                    orderDate, deliveryDate, clientName, goodsId, goodsCode, goodsName, spec,
                    colorId, colorName, unitId, unitName, unitRate,
                    requestedQty.add(delta.requested()), submittedQty.add(delta.submitted()),
                    approvedQty.add(delta.approved()),
                    salesQty, shippedQty, returnedQty, flagQty, reservedQty, plannedQty, producedQty,
                    activeDraftQty, orderStatus, orderStopped, orderClosed, orderDeleted, orderItemDeleted,
                    sourceRef, sourceReason, allocationPriority,
                    delta.readyNow() == null ? readyNowQty : delta.readyNow(),
                    delta.readyByDate() == null ? readyByDateQty : delta.readyByDate(),
                    delta.readyStart() == null ? readyStartQty : delta.readyStart(),
                    delta.readyFinish() == null ? readyFinishQty : delta.readyFinish(),
                    delta.readyShip() == null ? readyShipQty : delta.readyShip(),
                    parentAnalysisLineId, parentGoodsName, orderFinanceConfirmed,
                    rootMaterialLineId, rootFulfilledQty, rootRoute,
                    owningWarehouseId, owningWarehouseName, owningWorkshopId, owningWorkshopName,
                    plannedSurplusQty.add(delta.surplus()), rootSubcontractOutputBaseQty);
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
            if(SOURCE_AGGREGATE_MAKE.equals(sourceType)) {
                return requestedQty.max(issuedPlanQty()).subtract(rootFulfilledQty).max(BigDecimal.ZERO).setScale(4,RoundingMode.DOWN);
            }
            return requestedQty.subtract(rootFulfilledQty)
                    .max(BigDecimal.ZERO).setScale(4, RoundingMode.DOWN);
        }

        /** 已下达且仍有效的计划里归本需求的那一份(不含公共备货产出)。 */
        BigDecimal committedPlanQty() {
            return submittedQty.add(approvedQty)
                    .max(BigDecimal.ZERO).setScale(4, RoundingMode.DOWN);
        }

        /** 已下达且仍有效的计划总量（归需求量 + 公共备货产出）。 */
        BigDecimal issuedPlanQty() {
            return submittedQty.add(approvedQty).add(plannedSurplusQty)
                    .max(BigDecimal.ZERO).setScale(4, RoundingMode.DOWN);
        }

        /**
         * 计划产出量（ADR-099 数量单一入口）：来源净需求与已下达计划总量取大。
         * 直接子件的毛需求按它展开——计划员在下达车间填的本批数量超过需求时，
         * 超出部分同样要备料；未下达的余量仍按需求备料。顶层委外件的已下达量是
         * 未结委外申请的计划产出(ADR-143 §4.5)，下达 1500(含公共 500)就按 1500 备直属物料。
         */
        BigDecimal plannedOutputQty() {
            if(SOURCE_AGGREGATE_MAKE.equals(sourceType)) {
                return requestedQty.max(issuedPlanQty()).subtract(rootFulfilledQty).max(BigDecimal.ZERO);
            }
            return materialRequirementQty().max(committedOutputQty());
        }

        /** 已下达的产出总量(来源单位)：自制计划总量 + 顶层委外件未结申请的计划产出。 */
        BigDecimal committedOutputQty() {
            BigDecimal subcontract = rootSubcontractOutputBaseQty == null
                    || rootSubcontractOutputBaseQty.signum() <= 0 || unitRate == null || unitRate.signum() <= 0
                    ? BigDecimal.ZERO
                    : rootSubcontractOutputBaseQty.divide(unitRate, 4, RoundingMode.UP);
            return issuedPlanQty().add(subcontract);
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
                    && remaining.signum() > 0 && !externalRoot && !rootRoutePending
                    && !SOURCE_AGGREGATE_MAKE.equals(sourceType);
            // ADR-099：需求已全部转入计划的自制行仍可再下一批纯公共备货产出
            // (V577 合法形态)——用户口径「父层级那里还是可以追加下单, 多下的属于公共的」。
            boolean canIssueSurplus = planningBlockedReason == null
                    && remaining.signum() == 0 && !externalRoot && !rootRoutePending
                    && !SOURCE_AGGREGATE_MAKE.equals(sourceType);
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
                    planState.responsibleName(), rootMaterialLineId,
                    owningWarehouseId, owningWarehouseName,
                    owningWorkshopId, owningWorkshopName,
                    issuedPlanQty(), canIssueSurplus,planState.workshopId(),planState.responsibleId());
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
            String responsibleName,
            UUID workshopId,
            UUID responsibleId) {
        ProductPlanState(String status,UUID planId,String planNo,BigDecimal plannedQty,BigDecimal inboundQty,BigDecimal progressRatio,
                BigDecimal reportedQty,boolean zeroMaterial,String workshopName,String responsibleName) {
            this(status,planId,planNo,plannedQty,inboundQty,progressRatio,reportedQty,zeroMaterial,workshopName,responsibleName,null,null);
        }
        static final ProductPlanState NONE = new ProductPlanState(
                null, null, null, BigDecimal.ZERO, BigDecimal.ZERO, null,
                BigDecimal.ZERO, false, null, null);
     }

    /**
     * 节点采用的用量(ADR-129 §2.5)：设计使用数量、真实使用数量(该边计量口径)、实际采用哪一个
     * (basis)、没用真实值的原因(reason)、真实值依据的有效批次，以及与真实值一起的报工不良率
     * (defectRate，0..1，6 位；没有真实值时为空，只作说明，不参与计算)。快照原样落这六个值。
     */
    record BomUsage(BigDecimal designQty, BigDecimal actualQty, String basis, String reason, Long sampleCount,
            BigDecimal defectRate) {
        static final String ACTUAL = "ACTUAL";
        static final String DESIGN = "DESIGN";

        /** 只有设计值的节点(没有用量来源的调用方)。 */
        static BomUsage design(BigDecimal designQty) {
            return new BomUsage(designQty, null, DESIGN, null, null, null);
        }

        /**
         * 逐节点选用量：父节点按委外把这个直属物料发给委外商 → 设计值(与委外领料计划一致，ADR-143)；
         * 边不是线性规则(整包/固定批次，平均单耗不能近似) → 设计值；其余有真实值用真实值，否则设计值。
         * [linear] 与 [liveStatus] 都是 v_goods_bom_item_usage 对这条边的现时结果，Java 不再重判；
         * 锁定的真实值只在计量规则没变时沿用(见 {@link PinnedUsage#sameEdgeRule})，这里仍按现时线性
         * 把关。[liveStatus] 只用来说明没有真实值的原因(父件单位变了还是没有数据)，锁定的真实值
         * 为空而现时已学到数据时仍记「没有数据」，等人工刷新再采用。[defectRate] 始终跟着真实使用数量走：
         * 真实值留着(含按委外发出时留作路线改回的依据)它就留着，没有真实值时为空。
         */
        static BomUsage choose(BigDecimal designQty, BigDecimal actualQty, Long sampleCount, BigDecimal defectRate,
                String liveStatus, boolean linear, boolean subcontractOutbound) {
            if (subcontractOutbound) {
                return new BomUsage(designQty, actualQty, DESIGN, "SUBCONTRACT_OUTBOUND", sampleCount, defectRate);
            }
            if (!linear) return new BomUsage(designQty, actualQty, DESIGN, "NOT_LINEAR", sampleCount, defectRate);
            if (actualQty != null) return new BomUsage(designQty, actualQty, ACTUAL, null, sampleCount, defectRate);
            return new BomUsage(designQty, null, DESIGN,
                    "OUTPUT_UNIT_CHANGED".equals(liveStatus) ? liveStatus : "NO_DATA", sampleCount, null);
        }

        /** 本节点实际采用的每父件用量。 */
        BigDecimal usedQty() {
            return ACTUAL.equals(basis) ? actualQty : designQty;
        }
    }

    record BomNode(
            UUID analysisItemId, UUID bomItemId, UUID parentGoodsId,
            UUID goodsId, UUID colorId, UUID unitId, int depth,
            String nodeKey, String parentNodeKey,
            BigDecimal parentPerProductQty, BomUsage usage,
            BigDecimal perProductQty, BigDecimal snapshotRequiredQty,
            String goodsCode, String goodsName, String spec, String colorName,
            String unitName, BigDecimal safetyStock, String suggestion,
            boolean hasChildren, String controlStage, String consumptionBasis,
            BigDecimal basisOutputQty, boolean allowPartialPackage,
            boolean hardGate, List<BigDecimal> outputBatches) {
        /** 用量只有设计值的节点。 */
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
                    nodeKey,parentNodeKey,parentPerProductQty,BomUsage.design(bomQty),perProductQty,snapshotRequiredQty,
                    goodsCode,goodsName,spec,colorName,unitName,safetyStock,suggestion,
                    hasChildren,controlStage,consumptionBasis,basisOutputQty,allowPartialPackage,
                    hardGate,List.of());
        }
        /** 本节点实际采用的每父件用量(真实或设计，见 {@link BomUsage#choose})。 */
        BigDecimal bomQty() {
            return usage.usedQty();
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
                        parentOutputQty, bomQty(),
                        consumptionBasis, basisOutputQty, allowPartialPackage);
            } catch (IllegalArgumentException ex) {
                throw conflict("BOM 包装/批次计量数据无效，不能计算齐套数量");
            }
        }
        BomNode withSnapshotRequiredQty(BigDecimal requiredQty) {
            return new BomNode(
                    analysisItemId, bomItemId, parentGoodsId,
                    goodsId, colorId, unitId, depth, nodeKey, parentNodeKey,
                    parentPerProductQty, usage, perProductQty, requiredQty,
                    goodsCode, goodsName, spec, colorName, unitName, safetyStock,
                    suggestion, hasChildren, controlStage, consumptionBasis,
                    basisOutputQty, allowPartialPackage, hardGate,outputBatches);
        }
        BomNode withOutputBatches(List<BigDecimal> batches) {
            return new BomNode(analysisItemId,bomItemId,parentGoodsId,goodsId,colorId,unitId,depth,
                    nodeKey,parentNodeKey,parentPerProductQty,usage,perProductQty,snapshotRequiredQty,
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
            /** 快照锁定的设计/真实使用数量与采用依据(ADR-129)；顶层供给行只有默认的 DESIGN。 */
            BomUsage usage,
            BigDecimal requiredQty, BigDecimal availableQty,
            BigDecimal allocatedAvailableQty, BigDecimal reservedQty,
            BigDecimal safetyStockQty, BigDecimal inboundQty, BigDecimal shortageQty,
            LocalDate expectedReadyDate, String suggestion, String confirmedRoute,
            String routeReason,
            boolean lowerLevelPending,
            BigDecimal minOrderQty, BigDecimal orderMultipleQty,
            /** V587 货品主档「所属仓库」，与落点仓/分析范围仓无关；未登记为 null。 */
            UUID owningWarehouseId, String owningWarehouseName,
            /** V590 货品主档「归属生产车间」（最近一次排产确认/改派学习回写）。 */
            UUID owningWorkshopId, String owningWorkshopName) {
        static MaterialRow from(Object[] row) {
            return new MaterialRow(uuid(row[0]), uuid(row[1]), string(row[2]),
                    uuid(row[3]), string(row[4]), string(row[5]), string(row[6]),
                    uuid(row[7]), string(row[8]), uuid(row[9]), string(row[10]),
                    integer(row[11]), string(row[12]), string(row[13]), uuid(row[14]),
                    string(row[15]), string(row[16]), decimal(row[17]),
                    Boolean.TRUE.equals(row[18]), Boolean.TRUE.equals(row[19]),
                    decimal(row[20]), decimal(row[21]), decimal(row[22]),
                    new BomUsage(optionalDecimal(row[41]), optionalDecimal(row[42]),
                            string(row[43]), string(row[44]), longValue(row[45]), optionalDecimal(row[46])),
                    decimal(row[23]), decimal(row[24]), decimal(row[25]),
                    decimal(row[26]), decimal(row[27]), decimal(row[28]),
                    decimal(row[29]), date(row[30]), string(row[31]), string(row[32]),
                    string(row[33]), Boolean.TRUE.equals(row[34]),
                    optionalDecimal(row[35]), optionalDecimal(row[36]),
                    row.length > 37 ? uuid(row[37]) : null,
                    row.length > 38 ? string(row[38]) : null,
                    row.length > 39 ? uuid(row[39]) : null,
                    row.length > 40 ? string(row[40]) : null);
        }
        MaterialDimension dimension() {
            return new MaterialDimension(goodsId, colorId, unitId);
        }
        BigDecimal requiredForSingleParentOutput(BigDecimal output) {
            try {
                return MaterialConsumptionMath.required(output,bomQty,consumptionBasis,basisOutputQty,allowPartialPackage);
            } catch(IllegalArgumentException invalidBom) {
                throw conflict("BOM 包装/批次计量数据无效，不能计算齐套数量");
            }
        }
        /** 下达预览(ADR-116): 换上内存重算的数量列(与刷新写回的列一一对应)。 */
        MaterialRow withSnapshot(BigDecimal required, BigDecimal available, BigDecimal allocated,
                                 BigDecimal reserved, BigDecimal safety, BigDecimal inbound,
                                 BigDecimal shortage, LocalDate expectedReady, boolean lowerPending) {
            return new MaterialRow(id, analysisItemId, nodeKey, goodsId, goodsCode, goodsName, spec,
                    colorId, colorName, unitId, unitName, depth, path, parentNodeKey, parentGoodsId,
                    controlStage, consumptionBasis, basisOutputQty, allowPartialPackage, hardGate,
                    bomQty, parentPerProductQty, perProductQty, usage,
                    required, available, allocated, reserved, safety, inbound, shortage,
                    expectedReady, suggestion, confirmedRoute, routeReason, lowerPending,
                    minOrderQty, orderMultipleQty, owningWarehouseId, owningWarehouseName,
                    owningWorkshopId, owningWorkshopName);
        }
        MaterialView toView(List<WarehouseBreakdown> breakdown,
                            List<DownstreamReference> references,
                            List<String> displayPath, String parentLabel,
                            BigDecimal exactPeggedQty,
                            BigDecimal borrowedIn, BigDecimal borrowedOut,
                            List<BorrowRef> borrowRefs,
                            CrossProjection cross,
                            RequirementProjection requirement,
                            SharedFutureAggregate sharedFuture,
                            BigDecimal sharedFutureClaimedQty,
                            BigDecimal activeFutureCoverageQty,
                            BigDecimal externalFutureCoverageQty,
                            BigDecimal internalCommittedOutputQty,
                            BigDecimal selectedWarehousesAvailableQty,
                            BigDecimal selectedOtherWarehouseTransferableQty,
                            String flowStage,
                            UUID planAnchorAnalysisLineId,
                            MainWarehouseSafetySummary mainSafety,
                            PreplanReallocationMakeSupplement.Allowance makeSupplement,
                            BigDecimal makeSupplementOpenSupply, BigDecimal sharedFuturePendingQty,
                            BigDecimal plannedOutputQty,
                            boolean sharedFutureDeductible,
                            BigDecimal committedPlanQty,
                            BigDecimal sourceRequiredQty,
                            BigDecimal aggregateDelegatedShare,
                            UUID aggregateTargetMaterialLineId) {
            List<String> notified = references.stream().map(DownstreamReference::route)
                    .distinct().sorted().toList();
            BigDecimal demandGap = unboundDemandSupplyGap(
                    requiredQty, allocatedAvailableQty, exactPeggedQty);
            BigDecimal additionalRecommended = demandGap.subtract(activeFutureCoverageQty)
                    .max(BigDecimal.ZERO).setScale(4, RoundingMode.CEILING);
            // 可认领的公共在途 = 按期 + 晚到(下达采购/委外时自动认领，ADR-099)。
            BigDecimal sharedFutureClaimable = sharedFuture.availableQty()
                    .add(sharedFuture.lateAvailableQty())
                    .max(BigDecimal.ZERO).setScale(4, RoundingMode.DOWN);
            // 还缺数量(ADR-102 一张表口径)：在「建议下单量」基础上再把此刻可认领的
            // 同主仓公共在途当成已占用扣掉，得到人真正还要另外下单的量。
            //
            // **只是展示量**：这里不建任何占用，真正的认领仍发生在下达那一刻(ADR-099)，
            // 而且下达时服务端是从「本次要覆盖的总量」里切走认领量、不是在它之上另加——
            // 所以这个数**不能拿去预填下单数量**，否则每一行都会少下一个认领量。
            // 物理缺口 shortageQty 的算法不动——它同时是 actionable、让料候选与入库
            // 齐套三处的判据，把公共量算进去会让这些行整行掉出可下达集合。
            // 已经排进本节点自制计划、归本需求的那一份(顶层 = 产品行自己的计划, 其余 = 锚点的
            // 计划; 不含公共备货产出——那份不绑任何需求, 锚点余量也不因它归零)对「人还要另外
            // 下多少」来说就不缺了。计划是内部制造承诺, 按契约不算外部成品供给——shortageQty /
            // 齐套 / 让料三处判据不动, additionalSupplyRecommendedQty 作为转入与让料的上限也不动,
            // 只从这个纯展示量里扣。行动背书的自制任务与领料发外的委外申请已经作为 INTERNAL
            // 在途进了 activeFutureCoverageQty 被上面扣过一次, 这里只扣计划超出那部分, 不扣两遍。2026-09-23 用户实机: 已排满 2000 的自制行与
            // 下了计划的顶层照旧显示「还缺 2000 / 1000」。
            BigDecimal internalCovered = activeFutureCoverageQty.subtract(externalFutureCoverageQty)
                    .max(BigDecimal.ZERO);
            BigDecimal planningUncovered = additionalRecommended
                    .subtract(committedPlanQty.max(BigDecimal.ZERO).subtract(internalCovered)
                            .max(BigDecimal.ZERO))
                    .max(BigDecimal.ZERO).setScale(4, RoundingMode.CEILING);
            // 公共候选尚未被本需求认领，不是已落实的供给。保留未覆盖量供催计划/办结使用，
            // 只有纯展示的「需另外新下单」才预扣它；两者来自同一处真实覆盖计算。
            BigDecimal netShortage = sharedFutureDeductible
                    ? planningUncovered.subtract(sharedFutureClaimable).max(BigDecimal.ZERO)
                    : planningUncovered;
            return new MaterialView(id, analysisItemId, nodeKey,
                    actionGroupKey(), materialKey(),
                    goodsId, goodsCode, goodsName,
                    spec, colorId, colorName, unitId, unitName, depth, displayPath,
                    parentNodeKey, parentGoodsId, parentLabel,
                    controlStage, consumptionBasis, basisOutputQty,
                    allowPartialPackage, hardGate, bomQty, parentPerProductQty,
                    perProductQty, usage.designQty(), usage.actualQty(), usage.basis(),
                    usage.reason(), usage.sampleCount(), usage.defectRate(), requiredQty,
                    availableQty, exactPeggedQty, allocatedAvailableQty, reservedQty,
                    safetyStockQty, inboundQty, shortageQty,
                    demandGap,
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
                    // 「还需安排」= 需求缺口 − 本分析自己的在途, 保持毛口径。
                    //
                    // 「再扣掉别人计划的公共在途、显示净数」不在本字段上就地改: 用户可以选择
                    // 「足额下单，不扣可用数量」跳过自动认领, 在本字段上预扣可认领量会把数做小,
                    // 计划员照着填就会少下。本字段同时还是 PreplanFutureSupplyTransferService
                    // 与 MaterialStockReallocationService 的数量上限, 就地改语义会连带改掉那两处
                    // 闸门的含义。净数由 ADR-102 以独立派生字段 netShortage 给出(见上方 netShortage
                    // 的注释), 两个数并排显示, 各自口径清楚。
                    additionalRecommended,
                    minOrderQty, orderMultipleQty,
                    selectedWarehousesAvailableQty,
                    selectedOtherWarehouseTransferableQty,
                    sharedFuture.expectedDate(), sharedFuture.refs(),
                    flowStage, planAnchorAnalysisLineId,
                    mainSafety.publicAvailable(), mainSafety.openSupply(), mainSafety.gap(),
                    makeSupplement.additional(demandGap,makeSupplementOpenSupply),
                    sharedFuturePendingQty,sharedFuture.lateAvailableQty(),
                    owningWarehouseId, owningWarehouseName,
                    owningWorkshopId, owningWorkshopName,
                    externalFutureCoverageQty, internalCommittedOutputQty,
                    sharedFutureClaimable,
                    plannedOutputQty == null ? BigDecimal.ZERO : plannedOutputQty,
                    netShortage, sourceRequiredQty, planningUncovered,
                    aggregateDelegatedShare, aggregateTargetMaterialLineId, null, null, List.of(), BigDecimal.ZERO, null, null, null, null, null, List.of(),
                    false, null);
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
