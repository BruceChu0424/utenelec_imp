package com.uten.imp.features.production.analysis;

import com.uten.imp.common.util.NativeQueryResults;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.features.production.ProductionDocumentAccessPolicy;
import com.uten.imp.features.production.fulfillment.PlanningPackageFingerprint;
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
import java.util.Set;
import java.util.TreeSet;
import java.util.UUID;
import java.util.stream.Collectors;

import static com.uten.imp.features.production.analysis.MaterialAnalysisContracts.*;

/**
 * Persistent, non-authoritative pre-plan material analysis.
 *
 * <p>The full recursive tree is a dependency/read model. Readiness and formal
 * generation use direct BOM children only, so a MAKE component and its own
 * children are never counted twice.</p>
 */
@Service
@RequiredArgsConstructor
public class MaterialAnalysisService {

    static final String STATUS_ACTIVE = "ACTIVE";
    static final String STATUS_PARTIAL = "PARTIALLY_PLANNED";
    static final String SOURCE_SALES = "SALES_ORDER_ITEM";
    static final String SOURCE_MAKE_COMPONENT = "MAKE_COMPONENT";
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

    @Transactional
    public AnalysisView preview(PreviewRequest request) {
        tx.bind();
        if (request == null || request.items() == null || request.items().isEmpty()) {
            throw validation("至少选择一个生产需求来源");
        }
        requireWarehouse(request.warehouseId());
        List<PreviewItem> normalized = normalizePreviewItems(request.items());
        String requestHash = previewRequestHash(request, normalized);
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
                        "只能打开本人负责的物料分析", access.scope());
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
                    access.scope());
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
                        "只能打开本人负责的进行中物料分析", access.scope());
                requireReusablePayloadMatches(
                        analysisId, reusable, request.warehouseId(), normalized);
                if (!isCommandReplay(analysisId, "PREVIEW",
                        request.idempotencyKey(), requestHash)) {
                    recordSimpleCommand(analysisId, "PREVIEW",
                            request.idempotencyKey(), requestHash);
                }
                return detailInternal(analysisId, false);
            }
        }
        if (analysisId == null) {
            analysisId = UUID.randomUUID();
            em.createNativeQuery("""
                    INSERT INTO production_material_analyses (
                        id, warehouse_id, status, version, fingerprint,
                        initial_idempotency_key, analyzed_at, maker_id,
                        created_by, updated_by
                    ) VALUES (
                        :id, :warehouseId, 'ACTIVE', 0, :fingerprint,
                        :idempotencyKey, now(), :makerId, :actorId, :actorId
                    )
                    """)
                    .setParameter("id", analysisId)
                    .setParameter("warehouseId", request.warehouseId())
                    .setParameter("fingerprint", PlanningPackageFingerprint.sha256(
                            List.of("MATERIAL-ANALYSIS-PENDING", analysisId.toString())))
                    .setParameter("idempotencyKey", request.idempotencyKey())
                    .setParameter("makerId", currentUser.requireEmployeeId())
                    .setParameter("actorId", currentUser.requireId())
                    .executeUpdate();
            insertSourceItems(analysisId, normalized);
        } else {
            AnalysisHeader header = lockHeader(analysisId);
            access.requireWritable(header.makerId(), "只能刷新本人负责的物料分析",
                    access.scope());
            syncRequestedQuantities(analysisId, normalized);
            em.createNativeQuery("""
                    UPDATE production_material_analyses
                    SET warehouse_id = :warehouseId, updated_at = now(),
                        updated_by = :actorId
                    WHERE id = :id
                    """)
                    .setParameter("warehouseId", request.warehouseId())
                    .setParameter("actorId", currentUser.requireId())
                    .setParameter("id", analysisId)
                    .executeUpdate();
        }
        refreshLocked(analysisId);
        recordSimpleCommand(analysisId, "PREVIEW", request.idempotencyKey(), requestHash);
        return detailInternal(analysisId, false);
    }

    @Transactional(readOnly = true)
    public AnalysisView detail(UUID analysisId) {
        return detailInternal(analysisId, true);
    }

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

    @Transactional
    public AnalysisView saveRoutes(UUID analysisId, RouteRequest request) {
        tx.bind();
        AnalysisHeader header = lockHeader(analysisId);
        access.requireWritable(header.makerId(), "只能维护本人负责的物料分析",
                access.scope());
        String requestHash = routeRequestHash(analysisId, request);
        if (isCommandReplay(analysisId, "ROUTE", request.idempotencyKey(), requestHash)) {
            return detailInternal(analysisId, false);
        }
        requireCurrent(header, request.version(), request.fingerprint());
        Set<String> seen = new HashSet<>();
        List<MaterialRow> currentMaterials = loadMaterialRows(analysisId);
        List<RouteDecision> decisions = request.decisions() == null
                ? List.of() : request.decisions();
        for (RouteDecision decision : decisions) {
            List<MaterialRow> group = resolveMaterialGroup(currentMaterials, decision);
            String groupKey = group.getFirst().actionGroupKey();
            if (!seen.add(groupKey)) throw validation("物料路线操作组重复");
            String route = normalizeRoute(decision.route());
            String reason = blankToNull(decision.reason());
            Number downstream = (Number) em.createNativeQuery("""
                    SELECT COUNT(*) FROM preplan_supply_actions
                    WHERE analysis_id = :analysisId
                      AND action_group_key = :groupKey
                      AND status <> 'CANCELLED'
                      AND route IS DISTINCT FROM :route
                    """)
                    .setParameter("analysisId", analysisId)
                    .setParameter("groupKey", groupKey)
                    .setParameter("route", route)
                    .getSingleResult();
            if (downstream.longValue() > 0) {
                throw conflict("物料操作组已有不同路线的下游任务，请先撤回后再改路线");
            }
            for (MaterialRow material : group) {
                if (("REVIEW".equals(material.suggestion())
                        || !route.equals(material.suggestion())) && reason == null) {
                    throw validation("路线偏离货品来源建议时必须填写原因");
                }
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

    @Transactional
    public AnalysisView saveAllocationPriorities(
            UUID analysisId, AllocationPriorityRequest request) {
        tx.bind();
        AnalysisHeader header = lockHeader(analysisId);
        access.requireWritable(header.makerId(),
                "只能调整本人负责的物料分析分配顺序", access.scope());
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

    @Transactional
    public PlanPreview planPreview(UUID analysisId, PlanPreviewRequest request) {
        tx.bind();
        AnalysisHeader header = lockHeader(analysisId);
        access.requireWritable(header.makerId(), "只能对本人负责的物料分析排产",
                access.scope());
        requireCurrent(header, request.version(), request.fingerprint());
        if (!Objects.equals(header.warehouseId(), request.warehouseId())) {
            em.createNativeQuery("""
                    UPDATE production_material_analyses
                    SET warehouse_id = :warehouseId, updated_at = now(), updated_by = :actorId
                    WHERE id = :id
                    """)
                    .setParameter("warehouseId", request.warehouseId())
                    .setParameter("actorId", currentUser.requireId())
                    .setParameter("id", analysisId)
                    .executeUpdate();
        }
        requireWarehouse(request.warehouseId());
        refreshLocked(analysisId);
        AnalysisView view = detailInternal(analysisId, false);
        return buildPlanPreview(view, request.items(), request.routes(),
                request.bomOverrides(), true);
    }

    @Transactional(readOnly = true)
    public SalesCandidatePage salesCandidates(
            String keyword, int rawPage, int rawSize) {
        int page = Math.max(rawPage, 1);
        int size = Math.min(Math.max(rawSize, 1), 100);
        String kw = keyword == null ? "" : keyword.strip().toLowerCase(Locale.ROOT);
        String predicate = """
                o.status = 1 AND o.is_deleted = FALSE
                AND COALESCE(o.is_stopped, FALSE) = FALSE
                AND o.is_closed = FALSE
                AND i.is_deleted = FALSE
                AND g.is_deleted = FALSE
                AND g.production_bom_policy <> 'NOT_PRODUCED'
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
                    + " OR lower(COALESCE(g.code,'')) LIKE :kw OR lower(COALESCE(g.name,'')) LIKE :kw)";
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
                       g.production_bom_policy,
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
                  AND COALESCE(o.is_stopped,FALSE) = FALSE AND o.is_closed = FALSE
                  AND g.production_bom_policy <> 'NOT_PRODUCED'
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
                    decimal(row[17]), decimal(row[18]), date(row[19]), string(row[20]),
                    uuid(row[21]), string(row[22]), longValue(row[23])));
        }
        List<SalesCandidateOrder> items = builders.values().stream()
                .map(CandidateOrderBuilder::build).toList();
        return new SalesCandidatePage(items, page, size, total,
                (int) ((total + size - 1) / size));
    }

    /** Called by the command service while it already owns the analysis row lock. */
    PlanPreview buildPlanPreviewLocked(
            UUID analysisId,
            UUID warehouseId,
            List<PlanQuantity> items,
            List<RouteDecision> routes,
            List<BomOverride> bomOverrides) {
        requireCurrentBomSnapshot(analysisId, items == null ? Set.of() : items.stream()
                .filter(Objects::nonNull).map(PlanQuantity::analysisLineId)
                .filter(Objects::nonNull).collect(Collectors.toSet()));
        AnalysisView view = detailInternal(analysisId, false);
        if (!Objects.equals(view.warehouseId(), warehouseId)) {
            throw conflict("联合预览仓库已变化，请重新预览");
        }
        return buildPlanPreview(view, items, routes, bomOverrides, false);
    }

    /** Fail closed when the direct production structure changed after the analysis snapshot. */
    public void requireCurrentBomSnapshot(UUID analysisId, Set<UUID> analysisItemIds) {
        if (analysisItemIds == null || analysisItemIds.isEmpty()) {
            throw validation("必须指定要校验的物料分析产品");
        }
        Map<UUID, SourceLine> sources = loadSourceLines(analysisId, false).stream()
                .filter(source -> analysisItemIds.contains(source.analysisItemId()))
                .collect(Collectors.toMap(SourceLine::analysisItemId, source -> source));
        if (!sources.keySet().equals(analysisItemIds)) {
            throw conflict("待生成计划的产品已不属于当前物料分析");
        }
        for (SourceLine source : sources.values()) {
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
        Object[] row = oneRow(em.createNativeQuery("""
                SELECT id, warehouse_id, status, version, fingerprint,
                       analyzed_at, maker_id, is_deleted
                FROM production_material_analyses
                WHERE id = :id
                FOR UPDATE
                """).setParameter("id", analysisId), "物料分析不存在");
        if (Boolean.TRUE.equals(row[7])) {
            throw notFound("物料分析不存在");
        }
        return new AnalysisHeader(uuid(row[0]), uuid(row[1]), string(row[2]),
                ((Number) row[3]).longValue(), string(row[4]), offsetDateTime(row[5]),
                uuid(row[6]));
    }

    void requireCurrent(AnalysisHeader header, Long version, String fingerprint) {
        if (!List.of(STATUS_ACTIVE, STATUS_PARTIAL).contains(header.status())) {
            throw conflict("物料分析已结束，不能继续修改");
        }
        if (version == null || version != header.version()
                || fingerprint == null
                || !fingerprint.equalsIgnoreCase(header.fingerprint())) {
            throw conflict("物料分析已被刷新或修改，请重新加载");
        }
    }

    void refreshLocked(UUID analysisId) {
        AnalysisHeader header = lockHeader(analysisId);
        if (!List.of(STATUS_ACTIVE, STATUS_PARTIAL).contains(header.status())) {
            throw conflict("物料分析已结束，不能刷新");
        }
        if (header.warehouseId() == null) {
            throw conflict("物料分析未选择目标仓库");
        }
        em.createNativeQuery("""
                SELECT pg_advisory_xact_lock(hashtextextended(:lockKey,0))
                """).setParameter("lockKey",
                        "MATERIAL-ANALYSIS-WAREHOUSE:" + header.warehouseId())
                .getSingleResult();
        reconcileSupplyActionStatuses(analysisId);
        List<SourceLine> sources = loadSourceLines(analysisId, true);
        validateSourceCapacity(sources);
        em.createNativeQuery("""
                UPDATE production_material_analysis_materials
                SET active = FALSE, updated_at = now(), updated_by = :actorId
                WHERE analysis_id = :analysisId AND active = TRUE
                """)
                .setParameter("actorId", currentUser.requireId())
                .setParameter("analysisId", analysisId)
                .executeUpdate();
        List<BomNode> nodes = new ArrayList<>();
        for (SourceLine source : sources) {
            nodes.addAll(loadBomTree(source));
        }
        AvailabilitySnapshot availability = availability(
                analysisId, header.warehouseId(), nodes, sources);
        for (BomNode node : nodes) {
            MaterialDimension key = node.dimension();
            StockValue stock = availability.stock().getOrDefault(key, StockValue.ZERO);
            SourceLine source = sources.stream()
                    .filter(line -> line.analysisItemId().equals(node.analysisItemId()))
                    .findFirst().orElseThrow();
            InboundValue inbound = availability.inboundOnOrBefore(
                    key, source.deliveryDate());
            BigDecimal available = stock.available().subtract(node.safetyStock())
                    .max(BigDecimal.ZERO).setScale(4, RoundingMode.DOWN);
            BigDecimal required = node.snapshotRequiredQty();
            BigDecimal shortage = required.subtract(available)
                    .max(BigDecimal.ZERO).setScale(4, RoundingMode.CEILING);
            boolean lowerPending = node.hasChildren()
                    && "MAKE".equals(node.suggestion()) && shortage.signum() > 0;
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
        persistAllocationSnapshot(
                analysisId, header.warehouseId(), sources, nodes, availability);
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
                        FROM preplan_supply_action_allocations allocation
                        JOIN purchase_request_items item
                          ON item.id = allocation.external_item_id
                         AND item.is_deleted = FALSE
                        JOIN purchase_requests request
                          ON request.id = item.request_id
                         AND request.id = action.external_document_id
                         AND request.is_deleted = FALSE
                         AND request.status IN (0,1)
                         AND request.is_stopped = FALSE
                        WHERE allocation.action_id = action.id))
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
                          AND child.source_type = 'MAKE_COMPONENT'
                          AND child.is_deleted = FALSE))
                  )
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
                  AND EXISTS (
                      SELECT 1
                      FROM purchase_requests request
                      WHERE request.id = action.external_document_id
                        AND request.is_deleted = FALSE
                        AND request.status IN (0,1)
                        AND request.is_stopped = FALSE
                        AND request.is_closed = TRUE)
                  AND action.requested_qty > COALESCE((
                      SELECT SUM(GREATEST(
                          COALESCE((
                              SELECT SUM(CASE
                                  WHEN inspection.id IS NULL
                                  THEN receipt_item.qty
                                      * COALESCE(receipt_item.unit_rate,1)
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
                              WHERE receipt_item.order_item_id = order_item.id
                                AND receipt_item.is_deleted = FALSE
                          ),0) - COALESCE(order_item.returned_qty,0)
                              * COALESCE(order_item.unit_rate,1), 0))
                      FROM purchase_order_items order_item
                      JOIN purchase_orders purchase_order
                        ON purchase_order.id = order_item.order_id
                       AND purchase_order.status = 1
                       AND purchase_order.is_deleted = FALSE
                      WHERE order_item.is_deleted = FALSE
                        AND order_item.request_item_id IN (
                            SELECT allocation.external_item_id
                            FROM preplan_supply_action_allocations allocation
                            WHERE allocation.action_id = action.id
                              AND allocation.external_item_id IS NOT NULL)
                  ),0)
                  AND EXISTS (
                      SELECT 1
                      FROM preplan_supply_action_allocations allocation
                      JOIN purchase_order_items order_item
                        ON order_item.request_item_id = allocation.external_item_id
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
                      JOIN purchase_order_items order_item
                        ON order_item.request_item_id = allocation.external_item_id
                       AND order_item.is_deleted = FALSE
                      JOIN purchase_orders purchase_order
                        ON purchase_order.id = order_item.order_id
                       AND purchase_order.status = 1
                       AND purchase_order.is_deleted = FALSE
                      WHERE allocation.action_id = action.id
                        AND GREATEST(
                            COALESCE(order_item.qty,0)
                            - COALESCE(order_item.received_qty,0)
                            + COALESCE(order_item.returned_qty,0), 0) > 0)
                  AND NOT EXISTS (
                      SELECT 1
                      FROM preplan_supply_action_allocations allocation
                      JOIN purchase_order_items order_item
                        ON order_item.request_item_id = allocation.external_item_id
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
                       AND inspection.status NOT IN ('RESOLVED','REVERSED')
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
                      SELECT SUM(GREATEST(
                          COALESCE((
                              SELECT SUM(CASE
                                  WHEN inspection.id IS NULL
                                  THEN receipt_item.qty
                                      * COALESCE(receipt_item.unit_rate,1)
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
                              WHERE receipt_item.order_item_id = order_item.id
                                AND receipt_item.is_deleted = FALSE
                          ),0) - COALESCE(order_item.returned_qty,0)
                              * COALESCE(order_item.unit_rate,1), 0))
                      FROM subcontract_order_items order_item
                      JOIN subcontract_orders subcontract_order
                        ON subcontract_order.id = order_item.order_id
                       AND subcontract_order.status = 1
                       AND subcontract_order.is_deleted = FALSE
                      WHERE order_item.is_deleted = FALSE
                        AND order_item.application_item_id IN (
                            SELECT allocation.external_item_id
                            FROM preplan_supply_action_allocations allocation
                            WHERE allocation.action_id = action.id
                              AND allocation.external_item_id IS NOT NULL)
                  ),0)
                  AND EXISTS (
                      SELECT 1
                      FROM preplan_supply_action_allocations allocation
                      JOIN subcontract_order_items order_item
                        ON order_item.application_item_id = allocation.external_item_id
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
                      JOIN subcontract_order_items order_item
                        ON order_item.application_item_id = allocation.external_item_id
                       AND order_item.is_deleted = FALSE
                      JOIN subcontract_orders subcontract_order
                        ON subcontract_order.id = order_item.order_id
                       AND subcontract_order.status = 1
                       AND subcontract_order.is_deleted = FALSE
                      WHERE allocation.action_id = action.id
                        AND GREATEST(
                            COALESCE(order_item.qty,0)
                            - COALESCE(order_item.received_qty,0)
                            + COALESCE(order_item.returned_qty,0), 0) > 0)
                  AND NOT EXISTS (
                      SELECT 1
                      FROM preplan_supply_action_allocations allocation
                      JOIN subcontract_order_items order_item
                        ON order_item.application_item_id = allocation.external_item_id
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
                       AND inspection.status NOT IN ('RESOLVED','REVERSED')
                      WHERE allocation.action_id = action.id)
                """).setParameter("actorId", actorId)
                .setParameter("analysisId", analysisId).executeUpdate();

        em.createNativeQuery("""
                UPDATE preplan_supply_actions action
                SET status = 'IN_PROGRESS', updated_at = now()
                WHERE action.analysis_id = :analysisId
                  AND action.status IN ('CREATED','DONE')
                  AND action.external_document_type = 'PURCHASE_REQUEST'
                  AND action.requested_qty > COALESCE((
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
                            SELECT allocation.external_item_id
                            FROM preplan_supply_action_allocations allocation
                            WHERE allocation.action_id = action.id
                              AND allocation.external_item_id IS NOT NULL)
                  ),0)
                  AND (action.status = 'DONE' OR EXISTS (
                      SELECT 1 FROM purchase_order_items item
                      JOIN purchase_orders purchase_order
                        ON purchase_order.id = item.order_id
                       AND purchase_order.status = 1
                       AND purchase_order.is_deleted = FALSE
                      WHERE item.is_deleted = FALSE
                        AND item.request_item_id IN (
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
                            SELECT allocation.external_item_id
                            FROM preplan_supply_action_allocations allocation
                            WHERE allocation.action_id = action.id
                              AND allocation.external_item_id IS NOT NULL)
                  ),0)
                  AND (action.status = 'DONE' OR EXISTS (
                      SELECT 1 FROM subcontract_order_items item
                      JOIN subcontract_orders subcontract_order
                        ON subcontract_order.id = item.order_id
                       AND subcontract_order.status = 1
                       AND subcontract_order.is_deleted = FALSE
                      WHERE item.is_deleted = FALSE
                        AND item.application_item_id IN (
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
                  AND action.external_document_type = 'PREPLAN_MAKE_TASK'
                  AND EXISTS (
                      SELECT 1
                      FROM production_material_analysis_items child
                      WHERE child.id = action.external_document_id
                        AND child.analysis_id = action.analysis_id
                        AND child.source_type = 'MAKE_COMPONENT'
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
                WHERE action.analysis_id = :analysisId
                  AND action.status IN ('CREATED','IN_PROGRESS')
                  AND action.external_document_type = 'PURCHASE_REQUEST'
                  AND action.requested_qty <= COALESCE((
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
                  AND action.external_document_type = 'PREPLAN_MAKE_TASK'
                  AND EXISTS (
                      SELECT 1
                      FROM production_material_analysis_items child
                      WHERE child.id = action.external_document_id
                        AND child.analysis_id = action.analysis_id
                        AND child.source_type = 'MAKE_COMPONENT'
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
        NestedDiagnosticPlan nestedDiagnostic = allocateNestedDiagnostics(
                sources, nodes,
                subtractCommitments(stockAfterSafety, externalHardCommitments),
                effectiveRoutes);
        nodes = nestedDiagnostic.nodes();
        StagePlan stagePlan = allocateNestedStages(
                sources, directBySource, stockAfterSafety, externalHardCommitments);
        StageAllocation finishAllocation = stagePlan.finish();
        StageExtension shipAllocation = stagePlan.ship();
        StageExtension startAllocation = stagePlan.start();
        TimePhasedPool readyByPool = new TimePhasedPool(
                finishAllocation.remainingPool(), availability.inbound());
        for (SourceLine source : orderedSources(sources)) {
            BigDecimal demand = source.remainingAnalysisQty();
            List<BomNode> direct = directBySource.getOrDefault(
                    source.analysisItemId(), List.of());
            List<BomNode> productionGates = direct.stream()
                    .filter(MaterialAnalysisService::productionGate).toList();
            boolean missingRequiredBom = direct.isEmpty()
                    && "BOM_REQUIRED".equals(source.productionBomPolicy());
            BigDecimal readyStart = startAllocation.readyByItem().getOrDefault(
                    source.analysisItemId(), BigDecimal.ZERO.setScale(4));
            BigDecimal readyFinish = finishAllocation.readyByItem().getOrDefault(
                    source.analysisItemId(), BigDecimal.ZERO.setScale(4));
            BigDecimal readyShip = shipAllocation.readyByItem().getOrDefault(
                    source.analysisItemId(), BigDecimal.ZERO.setScale(4));
            BigDecimal readyByDate = missingRequiredBom
                    ? BigDecimal.ZERO.setScale(4)
                    : readyByPool.maxReadyFromBaseExact(
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
                    .setParameter("readyStart", readyStart)
                    .setParameter("readyFinish", readyFinish)
                    .setParameter("readyShip", readyShip)
                    .setParameter("readyByDate", readyByDate)
                    .setParameter("actorId", currentUser.requireId())
                    .setParameter("itemId", source.analysisItemId())
                    .setParameter("analysisId", analysisId)
                    .executeUpdate();
        }

        Map<String, NodeAllocation> hardAllocations = new LinkedHashMap<>(
                finishAllocation.nodeAllocations());
        mergeAllocations(hardAllocations, shipAllocation.nodeAllocations());
        mergeAllocations(hardAllocations, startAllocation.nodeAllocations());
        Map<String, NodeAllocation> allocations = allocateDirectMaterials(
                sources, directBySource, startAllocation.remainingPool(),
                hardAllocations);

        // Recursive descendants use a separate, single diagnostic pool. A child's demand is
        // exploded from its parent's actual shortage, and shared stock is consumed only once
        // across paths in this projection. These hints are deliberately not added to the
        // conserved actionable depth-one pool until a MAKE demand promotes that child.
        nodes.stream().filter(node -> node.depth() > 1).forEach(node ->
                allocations.put(nodeAllocationKey(node),
                        nestedDiagnostic.nodeAllocations().getOrDefault(
                                nodeAllocationKey(node), NodeAllocation.ZERO)));

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
            boolean lowerPending = node.hasChildren()
                    && "MAKE".equals(effectiveRoutes.getOrDefault(
                            nodeAllocationKey(node), node.suggestion()))
                    && !STAGE_REFERENCE.equals(node.controlStage())
                    && allocation.shortageQty().signum() > 0;
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
     * Cross-analysis soft commitments: current remaining snapshots from other analyses plus
     * every still-SUBMITTED formal draft (including this analysis). Approved plans are excluded
     * because their formal reservations are already reflected by {@code v_stock_available}.
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
                WITH commitments AS (
                    SELECT material.goods_id, material.color_id, material.unit_id,
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
                    WHERE analysis.warehouse_id = :warehouseId
                      AND analysis.id <> :analysisId
                      AND analysis.is_deleted = FALSE
                      AND analysis.status IN ('ACTIVE','PARTIALLY_PLANNED')
                      AND source.requested_qty-source.submitted_qty-source.approved_qty > 0
                      AND material.active = TRUE AND material.depth = 1
                      AND material.hard_gate = TRUE
                      AND material.control_stage IN (:includedStages)
                      AND material.goods_id IN (:goodsIds)
                    GROUP BY material.goods_id, material.color_id, material.unit_id
                    UNION ALL
                    SELECT material.goods_id, material.color_id, material.unit_id,
                           SUM(CASE WHEN material.calculation_mode
                                   = 'LEGACY_CUMULATIVE_PER_UNIT'
                               THEN fn_material_analysis_edge_required(
                                   draft.submitted_qty,
                                   material.per_product_qty,
                                   'PER_UNIT', 1, TRUE)
                               ELSE fn_material_analysis_edge_required(
                                   draft.submitted_qty
                                       * material.parent_per_product_qty,
                                   material.bom_qty,
                                   material.consumption_basis,
                                   material.basis_output_qty,
                                   material.allow_partial_package)
                           END)::numeric
                    FROM (
                        SELECT link.id AS link_id, link.analysis_id,
                               link.analysis_item_id, link.submitted_qty
                        FROM production_material_analysis_plan_links link
                        JOIN production_plans plan
                          ON plan.id = link.plan_id
                         AND plan.status = 0
                         AND plan.is_deleted = FALSE
                         AND plan.is_canceled = FALSE
                        WHERE link.allocation_status = 'SUBMITTED'
                    ) draft
                    JOIN production_material_analyses analysis
                      ON analysis.id = draft.analysis_id
                     AND analysis.is_deleted = FALSE
                     AND analysis.status <> 'CANCELLED'
                    JOIN production_material_analysis_materials material
                     ON material.analysis_id = draft.analysis_id
                     AND material.analysis_item_id = draft.analysis_item_id
                     AND material.active = TRUE AND material.depth = 1
                     AND material.hard_gate = TRUE
                     AND material.control_stage IN (:includedStages)
                    JOIN production_material_analysis_items source
                      ON source.id = draft.analysis_item_id
                     AND source.analysis_id = draft.analysis_id
                     AND source.is_deleted = FALSE
                    WHERE analysis.warehouse_id = :warehouseId
                      AND material.goods_id IN (:goodsIds)
                    GROUP BY material.goods_id, material.color_id, material.unit_id
                )
                SELECT goods_id, color_id, unit_id, SUM(qty)::numeric
                FROM commitments
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
                stock.getOrDefault(dimension, StockValue.ZERO).available()
                        .subtract(safety).max(BigDecimal.ZERO)
                        .setScale(4, RoundingMode.DOWN)));
        return Map.copyOf(result);
    }

    /**
     * Builds the recursive shortage diagnosis from a single stock pool. The gross depth-one
     * requirement is retained, while a descendant is exploded only from the unfilled quantity
     * of a parent whose effective route is MAKE. Hard production gates consume first and
     * warning/reference rows last. SHIP and REFERENCE are never hard gates. This is a
     * diagnostic projection;
     * actionable conservation still uses only depth-one rows in
     * {@link #allocateNestedStages(List, Map, Map, Map)}.
     */
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
        Map<MaterialDimension, BigDecimal> pool = new LinkedHashMap<>();
        rawStock.forEach((dimension, qty) -> pool.put(
                dimension, qty.max(BigDecimal.ZERO).setScale(4, RoundingMode.DOWN)));
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
        List<BomNode> pending = new ArrayList<>(nodes);
        Map<String, BomNode> adjustedByKey = new LinkedHashMap<>();
        Map<String, NodeAllocation> allocations = new LinkedHashMap<>();
        while (!pending.isEmpty()) {
            BomNode node = pending.stream()
                    .filter(candidate -> candidate.depth() == 1
                            || allocations.containsKey(candidate.analysisItemId()
                                    + "|" + candidate.parentNodeKey()))
                    .min(allocationOrder)
                    .orElseThrow(() -> conflict(
                            "BOM 层级路径不完整，无法按父件短缺展开子件需求"));
            pending.remove(node);
            BigDecimal required = node.snapshotRequiredQty();
            if (node.depth() > 1) {
                String parentKey = node.analysisItemId() + "|" + node.parentNodeKey();
                NodeAllocation parent = allocations.get(parentKey);
                BomNode parentNode = adjustedByKey.get(parentKey);
                String parentRoute = effectiveRoutes.getOrDefault(
                        parentKey, parentNode.suggestion());
                required = "MAKE".equals(parentRoute)
                        && !STAGE_REFERENCE.equals(parentNode.controlStage())
                        ? node.requiredForParentOutput(parent.shortageQty())
                        : BigDecimal.ZERO.setScale(4);
            }
            BomNode adjusted = node.withSnapshotRequiredQty(required);
            String key = nodeAllocationKey(adjusted);
            BigDecimal available = pool.getOrDefault(
                    adjusted.dimension(), BigDecimal.ZERO.setScale(4));
            BigDecimal allocated = required.min(available);
            pool.put(adjusted.dimension(), available.subtract(allocated)
                    .max(BigDecimal.ZERO));
            adjustedByKey.put(key, adjusted);
            allocations.put(key, new NodeAllocation(
                    allocated, required.subtract(allocated).max(BigDecimal.ZERO)));
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
        Map<MaterialDimension, BigDecimal> finishStock = subtractCommitments(
                stockAfterSafety, externalHardCommitments);
        StageAllocation finish = allocateStageReadiness(
                sources, directBySource, finishStock,
                Set.of(STAGE_START, STAGE_ASSEMBLY, STAGE_FINISH));
        StageExtension ship = allocateStageExtension(
                sources, directBySource, finish.remainingPool(),
                STAGE_SHIP, Map.of(), finish.readyByItem());
        Map<UUID, BigDecimal> demandByItem = sources.stream().collect(
                Collectors.toMap(SourceLine::analysisItemId,
                        SourceLine::remainingAnalysisQty));
        StageExtension start = allocateStageExtension(
                sources, directBySource, ship.remainingPool(),
                STAGE_START, finish.readyByItem(), demandByItem);
        return new StagePlan(finish, ship, start);
    }

    static StageAllocation allocateStageReadiness(
            List<SourceLine> sources,
            Map<UUID, List<BomNode>> directBySource,
            Map<MaterialDimension, BigDecimal> rawStock,
            Set<String> includedStages) {
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
            boolean missingRequiredBom = directBySource
                    .getOrDefault(source.analysisItemId(), List.of()).isEmpty()
                    && "BOM_REQUIRED".equals(source.productionBomPolicy());
            BigDecimal ready = missingRequiredBom
                    ? BigDecimal.ZERO.setScale(4)
                    : maxReadyExact(source.remainingAnalysisQty(), gates, pool);
            readiness.put(source.analysisItemId(), ready);
            for (BomNode node : gates) {
                BigDecimal required = node.requiredForOutput(ready);
                BigDecimal available = pool.getOrDefault(
                        node.dimension(), BigDecimal.ZERO);
                if (required.compareTo(available) > 0) {
                    throw new IllegalStateException(
                            "complete-kit allocation exceeded the verified material pool");
                }
                pool.put(node.dimension(), available.subtract(required)
                        .max(BigDecimal.ZERO));
                allocations.put(nodeAllocationKey(node), new NodeAllocation(
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
            if (canConsumeExact(candidate, nodes, pool)) {
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
                    normalizedBase, candidate, nodes).entrySet().stream()
                    .allMatch(entry -> entry.getValue().compareTo(
                            pool.getOrDefault(entry.getKey(), BigDecimal.ZERO)) <= 0);
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
                    source.analysisItemId(), source.remainingAnalysisQty());
            boolean missingRequiredBom = allDirect.isEmpty()
                    && "BOM_REQUIRED".equals(source.productionBomPolicy());
            BigDecimal ready = missingRequiredBom
                    ? BigDecimal.ZERO.setScale(4)
                    : maxReadyIncrementExact(base, upper, gates, pool);
            readiness.put(source.analysisItemId(), ready);
            for (BomNode node : gates) {
                BigDecimal additional = node.requiredForOutput(ready)
                        .subtract(node.requiredForOutput(base)).max(BigDecimal.ZERO);
                BigDecimal available = pool.getOrDefault(
                        node.dimension(), BigDecimal.ZERO);
                if (additional.compareTo(available) > 0) {
                    throw new IllegalStateException(
                            "stage extension exceeded the verified material pool");
                }
                pool.put(node.dimension(), available.subtract(additional)
                        .max(BigDecimal.ZERO));
                allocations.put(nodeAllocationKey(node), new NodeAllocation(
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
            Map<MaterialDimension, BigDecimal> pool) {
        return exactRequirements(productQty, nodes).entrySet().stream().allMatch(entry ->
                entry.getValue().compareTo(
                        pool.getOrDefault(entry.getKey(), BigDecimal.ZERO)) <= 0);
    }

    private static Map<MaterialDimension, BigDecimal> exactRequirements(
            BigDecimal productQty, List<BomNode> nodes) {
        Map<MaterialDimension, BigDecimal> result = new LinkedHashMap<>();
        nodes.forEach(node -> result.merge(
                node.dimension(), node.requiredForOutput(productQty), BigDecimal::add));
        return result;
    }

    private static Map<MaterialDimension, BigDecimal> incrementalRequirements(
            BigDecimal baseProductQty,
            BigDecimal totalProductQty,
            List<BomNode> nodes) {
        Map<MaterialDimension, BigDecimal> base = exactRequirements(
                baseProductQty, nodes);
        Map<MaterialDimension, BigDecimal> total = exactRequirements(
                totalProductQty, nodes);
        Map<MaterialDimension, BigDecimal> result = new LinkedHashMap<>();
        total.forEach((dimension, required) -> result.put(
                dimension,
                required.subtract(base.getOrDefault(dimension, BigDecimal.ZERO))
                        .max(BigDecimal.ZERO)));
        return result;
    }

    static Map<String, NodeAllocation> allocateDirectMaterials(
            List<SourceLine> sources,
            Map<UUID, List<BomNode>> directBySource,
            Map<MaterialDimension, BigDecimal> remainingStock,
            Map<String, NodeAllocation> kitAllocations) {
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
                if (node.hardGate()
                        && !STAGE_REFERENCE.equals(node.controlStage())) {
                    NodeAllocation existing = result.getOrDefault(
                            nodeAllocationKey(node), NodeAllocation.ZERO);
                    BigDecimal allocated = existing.allocatedQty()
                            .min(node.snapshotRequiredQty());
                    result.put(nodeAllocationKey(node), new NodeAllocation(
                            allocated,
                            node.snapshotRequiredQty().subtract(allocated)
                                    .max(BigDecimal.ZERO)));
                    continue;
                }
                BigDecimal required = node.snapshotRequiredQty();
                NodeAllocation existing = result.getOrDefault(
                        nodeAllocationKey(node), NodeAllocation.ZERO);
                BigDecimal residual = required.subtract(existing.allocatedQty())
                        .max(BigDecimal.ZERO);
                BigDecimal available = pool.getOrDefault(
                        node.dimension(), BigDecimal.ZERO);
                BigDecimal extra = residual.min(available);
                BigDecimal allocated = existing.allocatedQty().add(extra)
                        .min(required);
                pool.put(node.dimension(), available.subtract(extra)
                        .max(BigDecimal.ZERO));
                result.put(nodeAllocationKey(node), new NodeAllocation(
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
            access.requireReadable(header.makerId(), "物料分析不存在");
        }
        List<SourceLine> sources = loadSourceLines(analysisId, false);
        List<MaterialRow> materialRows = loadMaterialRows(analysisId);
        List<WarehouseView> warehouses = warehouses(header.warehouseId());
        Map<MaterialDimension, List<WarehouseBreakdown>> breakdown =
                warehouseBreakdown(materialRows);
        Map<UUID, List<DownstreamReference>> references = downstreamReferences(analysisId);
        Map<UUID, String> sourceLabels = sources.stream().collect(Collectors.toMap(
                SourceLine::analysisItemId,
                source -> displayLabel(source.goodsCode(), source.goodsName())));
        List<MaterialView> materials = materialRows.stream()
                .map(row -> row.toView(
                        breakdown.getOrDefault(row.dimension(), List.of()),
                        references.getOrDefault(row.id(), List.of()),
                        displayPath(row, materialRows, sourceLabels),
                        parentLabel(row, materialRows, sourceLabels)))
                .toList();
        List<ProductView> products = sources.stream().map(source -> {
            BigDecimal remaining = source.remainingAnalysisQty();
            BigDecimal ratio = remaining.signum() == 0
                    ? BigDecimal.ONE
                    : source.readyNowQty().divide(remaining, 4, RoundingMode.DOWN)
                        .min(BigDecimal.ONE);
            return source.toView(ratio);
        }).toList();
        return new AnalysisView(
                header.id(), header.status(), header.version(), header.fingerprint(),
                header.fingerprint(),
                header.warehouseId(), header.analyzedAt(), products, materials,
                warehouses, supplyActions(analysisId), allowedActions(header));
    }

    private PlanPreview buildPlanPreview(
            AnalysisView view,
            List<PlanQuantity> requested,
            List<RouteDecision> rawRoutes,
            List<BomOverride> rawBomOverrides,
            boolean persistFingerprint) {
        if (requested == null || requested.isEmpty()) {
            throw validation("至少选择一个待生成计划的产品");
        }
        Map<UUID, ProductView> productById = view.products().stream()
                .collect(Collectors.toMap(ProductView::analysisLineId, value -> value));
        Map<UUID, String> routeEdits = new HashMap<>();
        if (rawRoutes != null && !rawRoutes.isEmpty()) {
            throw validation("路线决定必须先通过 PUT /routes 持久确认，联合预览不接受临时路线");
        }
        Map<UUID, String> bomOverrides = new LinkedHashMap<>();
        if (rawBomOverrides != null) {
            for (BomOverride override : rawBomOverrides) {
                if (override == null || override.analysisLineId() == null
                        || blankToNull(override.reason()) == null) {
                    throw validation("无 BOM 例外必须逐产品填写原因");
                }
                if (bomOverrides.putIfAbsent(
                        override.analysisLineId(), blankToNull(override.reason())) != null) {
                    throw validation("同一产品不能重复提交无 BOM 例外");
                }
            }
            if (!bomOverrides.isEmpty()
                    && !access.hasAuthority("production_material_analysis:bom_override")) {
                throw new ApiException(ErrorCode.FORBIDDEN, "无 BOM 生产例外需要独立权限");
            }
        }
        Set<UUID> seen = new HashSet<>();
        List<PlanPreviewItem> items = new ArrayList<>();
        List<PlanDraftPreview> plans = new ArrayList<>();
        List<String> fingerprintParts = new ArrayList<>(List.of(
                "MATERIAL-ANALYSIS-PLAN-PREVIEW-V2", view.analysisId().toString(),
                Long.toString(view.version()), view.fingerprint(),
                Objects.toString(view.warehouseId(), "ALL")));
        boolean allReady = true;
        for (PlanQuantity selected : requested) {
            if (selected == null || selected.analysisLineId() == null
                    || selected.qty() == null || selected.qty().signum() <= 0
                    || !seen.add(selected.analysisLineId())) {
                throw validation("待生成计划的产品为空、重复或数量无效");
            }
            ProductView product = productById.get(selected.analysisLineId());
            if (product == null) throw validation("待生成计划的产品不属于当前分析");
            if (selected.qty().compareTo(product.remainingQty()) > 0) {
                throw conflict("生成数量超过分析需求剩余量");
            }
            List<MaterialView> direct = view.flatMaterials().stream()
                    .filter(material -> material.analysisLineId().equals(selected.analysisLineId()))
                    .filter(material -> material.level() == 1)
                    .filter(MaterialAnalysisService::productionGate)
                    .toList();
            String overrideReason = bomOverrides.get(product.analysisLineId());
            boolean requiresOverride = product.missingBom()
                    && "BOM_REQUIRED".equals(product.productionBomPolicy());
            if (overrideReason != null && !requiresOverride) {
                throw validation("仅缺少必需 BOM 的产品可提交无 BOM 例外");
            }
            boolean missingBlocked = requiresOverride && overrideReason == null;
            BigDecimal ready = authoritativeReadyForPlanPreview(
                    selected.qty(), product.readyNowQty(),
                    requiresOverride && overrideReason != null);
            boolean canGenerate = canGenerateReadyBatch(
                    missingBlocked, selected.qty(), ready);
            String reason = missingBlocked ? "产品缺少必需 BOM，需逐产品提交例外原因"
                    : canGenerate ? null : "生产阶段硬门槛物料未完整齐套";
            allReady &= canGenerate;
            List<PlanMaterialPreview> planMaterials = new ArrayList<>();
            Map<MaterialDimension, BigDecimal> previewRemaining = new LinkedHashMap<>();
            direct.forEach(material -> previewRemaining.merge(
                    new MaterialDimension(
                            material.goodsId(), material.colorId(), material.unitId()),
                    material.allocatedAvailableQty(), BigDecimal::add));
            for (MaterialView material : direct) {
                BigDecimal requiredQty = requiredForOutput(material, selected.qty());
                MaterialDimension key = new MaterialDimension(
                        material.goodsId(), material.colorId(), material.unitId());
                BigDecimal available = previewRemaining.getOrDefault(key, BigDecimal.ZERO);
                BigDecimal allocated = requiredQty.min(available);
                previewRemaining.put(key, available.subtract(allocated).max(BigDecimal.ZERO));
                planMaterials.add(new PlanMaterialPreview(
                        material.materialLineId(), requiredQty, available, allocated,
                        requiredQty.subtract(allocated).max(BigDecimal.ZERO),
                        routeEdits.getOrDefault(material.materialLineId(),
                                material.sourceConfirmed() == null
                                        ? material.sourceSuggestion() : material.sourceConfirmed())));
            }
            items.add(new PlanPreviewItem(product.analysisLineId(), product.remainingQty(),
                    ready, selected.qty(), canGenerate, reason));
            plans.add(new PlanDraftPreview(product.analysisLineId().toString(),
                    product.goodsId(), selected.qty(), ready,
                    canGenerate ? "READY" : "WAITING", List.copyOf(planMaterials)));
            fingerprintParts.add(String.join("|", "ITEM", product.analysisLineId().toString(),
                    decimalText(selected.qty()), decimalText(ready), Boolean.toString(canGenerate),
                    Objects.toString(overrideReason, "")));
            planMaterials.forEach(material -> fingerprintParts.add(String.join("|", "MATERIAL",
                    material.materialLineId().toString(), decimalText(material.requiredQty()),
                    decimalText(material.availableQty()), material.route())));
        }
        if (!seen.containsAll(bomOverrides.keySet())) {
            throw validation("无 BOM 例外不属于本次选择的产品");
        }
        String previewFingerprint = PlanningPackageFingerprint.sha256(fingerprintParts);
        if (persistFingerprint) {
            em.createNativeQuery("""
                    UPDATE production_material_analyses
                    SET preview_fingerprint = :fingerprint,
                        updated_at = now(), updated_by = :actorId
                    WHERE id = :id
                    """)
                    .setParameter("fingerprint", previewFingerprint)
                    .setParameter("actorId", currentUser.requireId())
                    .setParameter("id", view.analysisId())
                    .executeUpdate();
        }
        return new PlanPreview(view.analysisId(), view.version(), view.fingerprint(),
                view.fingerprint(),
                previewFingerprint, view.warehouseId(), OffsetDateTime.now(ZoneOffset.UTC),
                allReady, List.copyOf(items), List.copyOf(plans), view.allowedActions());
    }

    static BigDecimal authoritativeReadyForPlanPreview(
            BigDecimal selectedQty, BigDecimal persistedReadyNow, boolean bomOverride) {
        return (bomOverride ? selectedQty : persistedReadyNow.min(selectedQty))
                .setScale(4, RoundingMode.DOWN);
    }

    static boolean canGenerateReadyBatch(
            boolean missingBomBlocked, BigDecimal selectedQty,
            BigDecimal persistedReadyQty) {
        return !missingBomBlocked && selectedQty != null
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
                "MATERIAL-ANALYSIS-V2", analysisId.toString()));
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
                SELECT action_group_key, generation, route, requested_qty, status,
                       external_document_type, external_document_id,
                       predecessor_action_id
                FROM preplan_supply_actions
                WHERE analysis_id = :id
                ORDER BY action_group_key, generation, id
                """).setParameter("id", analysisId)).forEach(row -> parts.add(
                "ACTION|" + java.util.Arrays.stream(row)
                        .map(value -> Objects.toString(value, ""))
                        .collect(Collectors.joining("|"))));
        return PlanningPackageFingerprint.sha256(parts);
    }

    private List<PreviewItem> normalizePreviewItems(List<PreviewItem> raw) {
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
                  AND source_type <> 'MAKE_COMPONENT'
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
            List<PreviewItem> requestedItems) {
        if (!Objects.equals(header.warehouseId(), warehouseId)) {
            throw reusablePayloadConflict();
        }
        List<Object[]> rows = NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT source_type, sales_order_item_id, goods_id, color_id,
                       unit_id, source_ref, requested_qty, delivery_date, source_reason
                FROM production_material_analysis_items
                WHERE analysis_id = :analysisId AND is_deleted = FALSE
                  AND source_type <> 'MAKE_COMPONENT'
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
        return conflict("所选来源已有进行中的物料分析，但数量、交期或仓库不同；"
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
            if ("NOT_PRODUCED".equals(master.productionBomPolicy())) {
                throw validation("所选货品明确标记为不生产，不能进入生产物料分析");
            }
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

    private void syncRequestedQuantities(UUID analysisId, List<PreviewItem> items) {
        Map<SourceIdentity, PreviewItem> requestedByIdentity = items.stream()
                .collect(Collectors.toMap(this::sourceIdentity, item -> item));
        List<Object[]> rows = NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT id, source_type, sales_order_item_id, goods_id, color_id,
                       unit_id, source_ref, submitted_qty, approved_qty, requested_qty
                FROM production_material_analysis_items
                WHERE analysis_id = :id AND is_deleted = FALSE
                  AND source_type <> 'MAKE_COMPONENT'
                ORDER BY id FOR UPDATE
                """).setParameter("id", analysisId));
        if (rows.size() != requestedByIdentity.size()) throw conflict("分析来源集合已变化");
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
            if (committed.signum() > 0
                    && requested.compareTo(decimal(row[9])) > 0) {
                throw conflict("已有待审批或已批准批次后不能扩大原分析需求量；"
                        + "请新建需求，或先撤回全部批次后重建分析");
            }
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
                  AND source_type <> 'MAKE_COMPONENT'
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
                       g.production_bom_policy,
                       EXISTS (SELECT 1 FROM goods_bom_items b
                               WHERE b.goods_id = ai.goods_id AND b.is_deleted = FALSE),
                       COALESCE(soi.qty, ai.requested_qty),
                       COALESCE(soi.shipped_qty,0), COALESCE(soi.returned_qty,0),
                       COALESCE(soi.flag_qty,0), COALESCE(soi.reserved_qty,0),
                       COALESCE(soi.planned_qty,0), COALESCE(soi.produced_qty,0),
                       COALESCE(draft.qty,0), so.status, so.is_stopped,
                       so.is_closed, so.is_deleted, soi.is_deleted,
                       ai.source_ref, ai.source_reason, ai.line_priority,
                       ai.ready_now_qty, ai.ready_by_date_qty,
                       ai.ready_start_qty, ai.ready_finish_qty, ai.ready_ship_qty
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
                WHERE ai.analysis_id = :id AND ai.is_deleted = FALSE
                ORDER BY ai.line_priority, ai.delivery_date NULLS LAST, ai.id
                """).setParameter("id", analysisId));
        return rows.stream().map(SourceLine::from).toList();
    }

    private void validateSourceCapacity(List<SourceLine> sources) {
        for (SourceLine source : sources) {
            if ("NOT_PRODUCED".equals(source.productionBomPolicy())) {
                throw conflict("生产需求货品已改为不生产，请取消分析");
            }
            if (!SOURCE_SALES.equals(source.sourceType())) continue;
            if (source.orderStatus() == null || source.orderStatus() != 1
                    || source.orderStopped() || source.orderClosed()
                    || source.orderDeleted() || source.orderItemDeleted()) {
                throw conflict("销售订单未审核、已中止、已关闭或已删除");
            }
            BigDecimal outstanding = source.salesQty().subtract(source.shippedQty())
                    .add(source.returnedQty()).subtract(source.flagQty());
            BigDecimal unfinishedApproved = source.plannedQty()
                    .subtract(source.producedQty()).max(BigDecimal.ZERO);
            BigDecimal available = outstanding.subtract(source.reservedQty())
                    .subtract(unfinishedApproved).subtract(source.activeDraftQty())
                    .add(source.submittedQty()).add(source.approvedQty());
            if (available.signum() < 0) throw conflict("销售订单行剩余可排数量为负，请先核对累计量");
            if (source.remainingAnalysisQty().compareTo(available) > 0) {
                throw conflict("物料分析剩余需求超过销售订单剩余可排数量");
            }
        }
    }

    private List<BomNode> loadBomTree(SourceLine source) {
        validateBomGraph(source.goodsId(), source.unitRate());
        List<Object[]> rows = NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                WITH RECURSIVE exp AS (
                    SELECT b.id AS bom_item_id, b.goods_id AS parent_goods_id,
                           b.component_goods_id AS goods_id,
                           COALESCE(b.color_id, legacy_color.id, component.color_id) AS color_id,
                           COALESCE(component.unit_id, legacy_unit.id) AS unit_id,
                           1 AS depth, ARRAY[b.id]::uuid[] AS bom_path,
                           CAST(:unitRate AS numeric) AS parent_per_product_qty,
                           b.qty AS bom_qty,
                           (CAST(:unitRate AS numeric) * b.qty /
                                CASE WHEN b.consumption_basis = 'PER_UNIT' THEN 1
                                     ELSE b.basis_output_qty END
                           )::numeric AS per_product_qty,
                           component.code, component.name, component.spec,
                           resolved_color.name AS color_name,
                           COALESCE(component_unit.name, legacy_unit.name) AS unit_name,
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
                    LEFT JOIN colors legacy_color ON legacy_color.legacy_id = NULLIF(b.color_legacy_id,0)
                                                   AND legacy_color.is_deleted = FALSE
                    LEFT JOIN colors resolved_color ON resolved_color.id =
                        COALESCE(b.color_id, legacy_color.id, component.color_id)
                    LEFT JOIN units legacy_unit ON legacy_unit.legacy_id = component.unit_legacy_id
                                                AND legacy_unit.is_deleted = FALSE
                    LEFT JOIN units component_unit ON component_unit.id = component.unit_id
                    WHERE b.goods_id = :goodsId AND b.is_deleted = FALSE
                    UNION ALL
                    SELECT b.id, b.goods_id, b.component_goods_id,
                           COALESCE(b.color_id, legacy_color.id, component.color_id),
                           COALESCE(component.unit_id, legacy_unit.id),
                           exp.depth + 1, exp.bom_path || b.id,
                           exp.per_product_qty,
                           b.qty,
                           (exp.per_product_qty * b.qty /
                                CASE WHEN b.consumption_basis = 'PER_UNIT' THEN 1
                                     ELSE b.basis_output_qty END
                           )::numeric,
                           component.code, component.name, component.spec,
                           resolved_color.name,
                           COALESCE(component_unit.name, legacy_unit.name),
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
                    LEFT JOIN colors legacy_color ON legacy_color.legacy_id = NULLIF(b.color_legacy_id,0)
                                                   AND legacy_color.is_deleted = FALSE
                    LEFT JOIN colors resolved_color ON resolved_color.id =
                        COALESCE(b.color_id, legacy_color.id, component.color_id)
                    LEFT JOIN units legacy_unit ON legacy_unit.legacy_id = component.unit_legacy_id
                                                AND legacy_unit.is_deleted = FALSE
                    LEFT JOIN units component_unit ON component_unit.id = component.unit_id
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
                parentOutputQty = source.remainingAnalysisQty().multiply(source.unitRate());
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
                            OR COALESCE(component.unit_id, legacy_unit.id) IS NULL
                            OR (NULLIF(b.color_legacy_id,0) IS NOT NULL
                                AND legacy_color.id IS NULL)
                            OR (b.color_id IS NOT NULL
                                AND (direct_color.id IS NULL OR direct_color.is_deleted))) AS invalid
                    FROM goods_bom_items b
                    JOIN goods component ON component.id = b.component_goods_id
                    LEFT JOIN units legacy_unit ON legacy_unit.legacy_id = component.unit_legacy_id
                                                AND legacy_unit.is_deleted = FALSE
                    LEFT JOIN colors legacy_color ON legacy_color.legacy_id = NULLIF(b.color_legacy_id,0)
                                                   AND legacy_color.is_deleted = FALSE
                    LEFT JOIN colors direct_color ON direct_color.id = b.color_id
                    WHERE b.goods_id = :goodsId AND b.is_deleted = FALSE
                    UNION ALL
                    SELECT b.id, b.component_goods_id, walk.depth + 1,
                           walk.path || b.id, b.id = ANY(walk.path),
                           (walk.invalid OR b.qty <= 0 OR component.is_deleted
                            OR COALESCE(component.unit_id, legacy_unit.id) IS NULL
                            OR (NULLIF(b.color_legacy_id,0) IS NOT NULL
                                AND legacy_color.id IS NULL)
                            OR (b.color_id IS NOT NULL
                                AND (direct_color.id IS NULL OR direct_color.is_deleted)))
                    FROM walk
                    JOIN goods_bom_items b ON b.goods_id = walk.goods_id
                                          AND b.is_deleted = FALSE
                    JOIN goods component ON component.id = b.component_goods_id
                    LEFT JOIN units legacy_unit ON legacy_unit.legacy_id = component.unit_legacy_id
                                                AND legacy_unit.is_deleted = FALSE
                    LEFT JOIN colors legacy_color ON legacy_color.legacy_id = NULLIF(b.color_legacy_id,0)
                                                   AND legacy_color.is_deleted = FALSE
                    LEFT JOIN colors direct_color ON direct_color.id = b.color_id
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

    private AvailabilitySnapshot availability(
            UUID analysisId, UUID warehouseId,
            List<BomNode> nodes, List<SourceLine> sources) {
        Set<UUID> goodsIds = nodes.stream().map(BomNode::goodsId)
                .collect(Collectors.toCollection(TreeSet::new));
        if (goodsIds.isEmpty()) return new AvailabilitySnapshot(Map.of(), List.of());
        List<Object[]> stockRows = NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT v.warehouse_id, w.code, w.name, v.goods_id, v.color_id,
                       COALESCE(v.on_hand_qty,0), COALESCE(v.reserved_qty,0),
                       GREATEST(COALESCE(v.available_qty,0),0)
                FROM v_stock_available v
                JOIN warehouses w ON w.id = v.warehouse_id
                WHERE v.goods_id IN (:goodsIds)
                  AND w.is_deleted = FALSE AND w.is_accountable = TRUE
                  AND (:warehouseId IS NULL OR v.warehouse_id = :warehouseId)
                ORDER BY v.warehouse_id, v.goods_id, v.color_id NULLS FIRST
                """)
                .setParameter("goodsIds", goodsIds)
                .setParameter("warehouseId", warehouseId));
        Map<MaterialDimension, StockValue> stock = new LinkedHashMap<>();
        for (Object[] row : stockRows) {
            MaterialDimension dimension = nodes.stream()
                    .filter(node -> node.goodsId().equals(uuid(row[3]))
                            && Objects.equals(node.colorId(), uuid(row[4])))
                    .map(BomNode::dimension).findFirst().orElse(null);
            if (dimension == null) continue;
            stock.merge(dimension, new StockValue(decimal(row[5]), decimal(row[6]), decimal(row[7])),
                    StockValue::add);
        }
        List<Object[]> inboundRows = NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                WITH action_caps AS (
                    SELECT action.external_document_type,
                           allocation.external_item_id,
                           material.goods_id, material.color_id, material.unit_id,
                           SUM(allocation.allocated_qty)::numeric AS allocated_qty
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
                    GROUP BY action.external_document_type,
                             allocation.external_item_id,
                             material.goods_id, material.color_id, material.unit_id
                )
                , confirmed_supply AS (
                    SELECT cap.external_document_type AS document_type,
                           cap.external_item_id, cap.goods_id, cap.color_id,
                           cap.unit_id, cap.allocated_qty,
                           COALESCE(i.deliver_date,o.deliver_date) AS eta,
                           i.id AS supply_item_id,
                           (GREATEST(COALESCE(i.qty,0)-COALESCE(i.received_qty,0)
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
                    JOIN purchase_order_items i ON i.request_item_id = cap.external_item_id
                    JOIN purchase_orders o ON o.id = i.order_id
                    WHERE cap.external_document_type = 'PURCHASE_REQUEST'
                      AND o.status = 1 AND o.is_deleted = FALSE AND o.is_closed = FALSE
                      AND i.is_deleted = FALSE
                      AND COALESCE(i.deliver_date,o.deliver_date) IS NOT NULL
                      AND (:warehouseId IS NULL OR o.warehouse_id = :warehouseId)
                    UNION ALL
                    SELECT cap.external_document_type, cap.external_item_id,
                           cap.goods_id, cap.color_id, cap.unit_id,
                           cap.allocated_qty,
                           COALESCE(i.deliver_date,o.deliver_date), i.id,
                           (GREATEST(COALESCE(i.qty,0)-COALESCE(i.received_qty,0)
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
                    JOIN subcontract_order_items i
                      ON i.application_item_id = cap.external_item_id
                    JOIN subcontract_orders o ON o.id = i.order_id
                    WHERE cap.external_document_type = 'SUBCONTRACT_APPLICATION'
                      AND o.status = 1 AND o.is_deleted = FALSE AND o.is_closed = FALSE
                      AND i.is_deleted = FALSE
                      AND COALESCE(i.deliver_date,o.deliver_date) IS NOT NULL
                      AND (:warehouseId IS NULL OR o.warehouse_id = :warehouseId)
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
                """)
                .setParameter("analysisId", analysisId)
                .setParameter("warehouseId", warehouseId));
        List<InboundLot> inbound = new ArrayList<>();
        for (Object[] row : inboundRows) {
            BomNode matching = nodes.stream().filter(node ->
                    node.goodsId().equals(uuid(row[0]))
                            && Objects.equals(node.colorId(), uuid(row[1]))
                            && Objects.equals(node.unitId(), uuid(row[2])))
                    .findFirst().orElse(null);
            if (matching != null) inbound.add(new InboundLot(
                    matching.dimension(), date(row[3]), decimal(row[4])));
        }
        return new AvailabilitySnapshot(Map.copyOf(stock), List.copyOf(inbound));
    }

    private List<MaterialRow> loadMaterialRows(UUID analysisId) {
        return NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT m.id, m.analysis_item_id, m.goods_id, g.code, g.name, g.spec,
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
                       g.production_bom_policy,
                       EXISTS (SELECT 1 FROM goods_bom_items child
                               WHERE child.goods_id = m.goods_id
                                 AND child.is_deleted = FALSE),
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

    private Map<MaterialDimension, List<WarehouseBreakdown>> warehouseBreakdown(
            List<MaterialRow> materials) {
        Set<UUID> goodsIds = materials.stream().map(MaterialRow::goodsId)
                .collect(Collectors.toSet());
        if (goodsIds.isEmpty()) return Map.of();
        Map<MaterialDimension, List<WarehouseBreakdown>> result = new HashMap<>();
        List<Object[]> rows = NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT v.goods_id, v.color_id, v.warehouse_id, w.code, w.name,
                       COALESCE(v.on_hand_qty,0), COALESCE(v.reserved_qty,0),
                       GREATEST(COALESCE(v.available_qty,0)-GREATEST(COALESCE(g.min_qty,0),0),0)
                FROM v_stock_available v
                JOIN warehouses w ON w.id = v.warehouse_id
                JOIN goods g ON g.id = v.goods_id
                WHERE v.goods_id IN (:goodsIds)
                  AND w.is_deleted = FALSE AND w.is_accountable = TRUE
                ORDER BY w.code, w.id
                """).setParameter("goodsIds", goodsIds));
        for (Object[] row : rows) {
            MaterialRow matching = materials.stream().filter(material ->
                    material.goodsId().equals(uuid(row[0]))
                            && Objects.equals(material.colorId(), uuid(row[1])))
                    .findFirst().orElse(null);
            if (matching == null) continue;
            result.computeIfAbsent(matching.dimension(), ignored -> new ArrayList<>())
                    .add(new WarehouseBreakdown(uuid(row[2]), string(row[3]), string(row[4]),
                            decimal(row[5]), decimal(row[6]), decimal(row[7])));
        }
        return result;
    }

    private List<WarehouseView> warehouses(UUID selected) {
        return NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT id, code, name
                FROM warehouses
                WHERE is_deleted = FALSE AND is_accountable = TRUE
                ORDER BY code, name, id
                """)).stream().map(row -> new WarehouseView(
                uuid(row[0]), string(row[1]), string(row[2]),
                Objects.equals(selected, uuid(row[0])))).toList();
    }

    private List<String> allowedActions(AnalysisHeader header) {
        if (!List.of(STATUS_ACTIVE, STATUS_PARTIAL).contains(header.status())) {
            return List.of("VIEW");
        }
        if (!access.canWrite(header.makerId(), access.scope())) {
            return List.of("VIEW");
        }
        List<String> result = new ArrayList<>(List.of("VIEW"));
        if (access.hasAuthority("production_material_analysis:manage")) {
            result.add("REFRESH");
        }
        if (access.hasAuthority("production_material_analysis:route")) {
            result.add("CONFIRM_ROUTES");
        }
        if (access.hasAuthority("production_material_analysis:notify")) {
            result.add("NOTIFY_SUPPLY");
        }
        if (access.hasAuthority("production_material_analysis:reallocate")) {
            result.add("REALLOCATE");
        }
        if (access.hasAuthority("production_material_analysis:generate")) {
            result.add("PLAN_PREVIEW");
            result.add("GENERATE_PLAN");
            if (access.hasAuthority("production_plan:approve")) {
                result.add("GENERATE_AND_APPROVE");
            }
        }
        if (access.hasAuthority("production_material_analysis:bom_override")) {
            result.add("BOM_OVERRIDE");
        }
        return List.copyOf(result);
    }

    private List<String> displayPath(
            MaterialRow material, List<MaterialRow> materials,
            Map<UUID, String> sourceLabels) {
        Map<String, MaterialRow> nodes = materials.stream()
                .filter(row -> row.analysisItemId().equals(material.analysisItemId()))
                .collect(Collectors.toMap(MaterialRow::path, row -> row));
        List<String> reversed = new ArrayList<>();
        MaterialRow cursor = material;
        Set<String> seen = new HashSet<>();
        while (cursor != null && seen.add(cursor.path())) {
            reversed.add(displayLabel(cursor.goodsCode(), cursor.goodsName()));
            cursor = cursor.parentNodeKey() == null
                    ? null : nodes.get(cursor.parentNodeKey());
        }
        java.util.Collections.reverse(reversed);
        String source = sourceLabels.get(material.analysisItemId());
        if (source != null) reversed.addFirst(source);
        return List.copyOf(reversed);
    }

    private String parentLabel(
            MaterialRow material, List<MaterialRow> materials,
            Map<UUID, String> sourceLabels) {
        if (material.parentNodeKey() == null) {
            return sourceLabels.get(material.analysisItemId());
        }
        return materials.stream()
                .filter(row -> row.analysisItemId().equals(material.analysisItemId()))
                .filter(row -> row.path().equals(material.parentNodeKey()))
                .findFirst()
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

    private String previewRequestHash(PreviewRequest request, List<PreviewItem> items) {
        List<String> parts = new ArrayList<>(List.of(
                "MATERIAL-ANALYSIS-PREVIEW-V1",
                Objects.toString(request.analysisId(), "NEW"),
                Objects.toString(request.version(), ""),
                Objects.toString(request.fingerprint(), ""),
                request.warehouseId().toString()));
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
                       allocation.allocated_qty
                FROM preplan_supply_action_allocations allocation
                JOIN preplan_supply_actions action ON action.id = allocation.action_id
                WHERE action.analysis_id = :id
                ORDER BY action.created_at, action.id, allocation.id
                """).setParameter("id", analysisId));
        for (Object[] row : rows) {
            result.computeIfAbsent(uuid(row[0]), ignored -> new ArrayList<>()).add(
                    new DownstreamReference(uuid(row[1]), string(row[2]), string(row[3]),
                            string(row[4]), uuid(row[5]), string(row[6]), decimal(row[7])));
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
            if (representative.depth() != 1) {
                throw validation("递归下层物料仅作依赖提示，不能直接确认供应路线");
            }
            groupKey = representative.actionGroupKey();
        }
        final String resolved = groupKey;
        List<MaterialRow> group = materials.stream()
                .filter(row -> row.depth() == 1)
                .filter(row -> row.actionGroupKey().equals(resolved)).toList();
        if (group.isEmpty()) throw validation("物料操作组不存在或已过期");
        return group;
    }

    private List<MaterialView> resolveMaterialViewGroup(
            List<MaterialView> materials, RouteDecision decision) {
        if (decision == null || (decision.materialLineId() == null
                && blankToNull(decision.actionGroupKey()) == null)) {
            throw validation("物料路线必须提交 actionGroupKey 或代表节点");
        }
        String groupKey = blankToNull(decision.actionGroupKey());
        if (groupKey == null) {
            MaterialView representative = materials.stream()
                    .filter(row -> row.materialLineId().equals(decision.materialLineId()))
                    .findFirst().orElseThrow(() -> validation("物料分析代表节点不存在"));
            if (!representative.actionable()) {
                throw validation("递归下层物料仅作依赖提示，不能直接确认供应路线");
            }
            groupKey = representative.actionGroupKey();
        }
        final String resolved = groupKey;
        List<MaterialView> group = materials.stream()
                .filter(MaterialView::actionable)
                .filter(row -> row.actionGroupKey().equals(resolved)).toList();
        if (group.isEmpty()) throw validation("物料操作组不存在或已过期");
        return group;
    }

    List<SupplyActionView> supplyActions(UUID analysisId) {
        return NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT id, action_group_key, generation, predecessor_action_id,
                       route, status, goods_id, color_id, unit_id,
                       requested_qty, need_date, external_document_type,
                       external_document_id, external_document_no
                FROM preplan_supply_actions
                WHERE analysis_id = :id
                ORDER BY created_at, id
                """).setParameter("id", analysisId)).stream()
                .map(row -> new SupplyActionView(uuid(row[0]), string(row[1]), integer(row[2]),
                        uuid(row[3]), string(row[4]), string(row[5]), uuid(row[6]),
                        uuid(row[7]), uuid(row[8]), decimal(row[9]), date(row[10]),
                        string(row[11]), uuid(row[12]), string(row[13])))
                .toList();
    }

    private SourceMaster salesSourceMaster(UUID salesOrderItemId) {
        Object[] row = oneRow(em.createNativeQuery("""
                SELECT i.goods_id, i.color_id, i.unit_id,
                       COALESCE(i.deliver_date,o.deliver_date),
                       g.production_bom_policy,
                       o.status, o.is_stopped, o.is_closed, o.is_deleted, i.is_deleted
                FROM sales_order_items i
                JOIN sales_orders o ON o.id = i.order_id
                JOIN goods g ON g.id = i.goods_id
                WHERE i.id = :id
                """).setParameter("id", salesOrderItemId), "销售订单行不存在");
        if (((Number) row[5]).shortValue() != 1 || Boolean.TRUE.equals(row[6])
                || Boolean.TRUE.equals(row[7]) || Boolean.TRUE.equals(row[8])
                || Boolean.TRUE.equals(row[9])) {
            throw conflict("销售订单未审核、已中止、已关闭或已删除");
        }
        if (row[2] == null) throw conflict("销售订单行未维护有效单位");
        return new SourceMaster(uuid(row[0]), uuid(row[1]), uuid(row[2]),
                date(row[3]), string(row[4]));
    }

    private SourceMaster manualSourceMaster(UUID goodsId, UUID colorId, UUID unitId) {
        Object[] row = oneRow(em.createNativeQuery("""
                SELECT g.id, :colorId, u.id, g.production_bom_policy,
                       COALESCE(g.unit_id, legacy_unit.id) AS base_unit_id
                FROM goods g
                JOIN units u ON u.id = :unitId AND u.is_deleted = FALSE
                LEFT JOIN units legacy_unit ON legacy_unit.legacy_id = g.unit_legacy_id
                                             AND legacy_unit.is_deleted = FALSE
                WHERE g.id = :goodsId AND g.is_deleted = FALSE
                """).setParameter("colorId", colorId).setParameter("unitId", unitId)
                .setParameter("goodsId", goodsId), "手工生产来源的货品或单位不存在");
        if (row[4] == null || !Objects.equals(uuid(row[2]), uuid(row[4]))) {
            throw validation("手工生产来源只能使用货品主档的基本单位");
        }
        return new SourceMaster(uuid(row[0]), uuid(row[1]), uuid(row[2]), null, string(row[3]));
    }

    private AnalysisHeader readHeader(UUID analysisId) {
        Object[] row = oneRow(em.createNativeQuery("""
                SELECT id, warehouse_id, status, version, fingerprint,
                       analyzed_at, maker_id, is_deleted
                FROM production_material_analyses WHERE id = :id
                """).setParameter("id", analysisId), "物料分析不存在");
        if (Boolean.TRUE.equals(row[7])) throw notFound("物料分析不存在");
        return new AnalysisHeader(uuid(row[0]), uuid(row[1]), string(row[2]),
                ((Number) row[3]).longValue(), string(row[4]), offsetDateTime(row[5]),
                uuid(row[6]));
    }

    private void requireWarehouse(UUID warehouseId) {
        if (warehouseId == null) return;
        Number count = (Number) em.createNativeQuery("""
                SELECT COUNT(*) FROM warehouses
                WHERE id = :id AND is_deleted = FALSE AND is_accountable = TRUE
                """).setParameter("id", warehouseId).getSingleResult();
        if (count.longValue() != 1) throw notFound("目标仓库不存在或不参与库存核算");
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
            Map<String, NodeAllocation> nodeAllocations) {
    }

    record AnalysisHeader(UUID id, UUID warehouseId, String status, long version,
                          String fingerprint, OffsetDateTime analyzedAt, UUID makerId) {
    }

    record MaterialDimension(UUID goodsId, UUID colorId, UUID unitId) {
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
                        LocalDate deliveryDate, String productionBomPolicy) {
    }

    record SourceLine(
            UUID analysisItemId, String sourceType, UUID salesOrderItemId,
            UUID salesOrderId, String salesOrderNo, LocalDate orderDate,
            LocalDate deliveryDate, String clientName,
            UUID goodsId, String goodsCode, String goodsName, String spec,
            UUID colorId, String colorName, UUID unitId, String unitName,
            BigDecimal unitRate, BigDecimal requestedQty, BigDecimal submittedQty,
            BigDecimal approvedQty, String productionBomPolicy, boolean hasBom,
            BigDecimal salesQty, BigDecimal shippedQty, BigDecimal returnedQty,
            BigDecimal flagQty, BigDecimal reservedQty, BigDecimal plannedQty,
            BigDecimal producedQty, BigDecimal activeDraftQty,
            Short orderStatus, boolean orderStopped, boolean orderClosed,
            boolean orderDeleted, boolean orderItemDeleted,
            String sourceRef, String sourceReason, int allocationPriority,
            BigDecimal readyNowQty, BigDecimal readyByDateQty,
            BigDecimal readyStartQty, BigDecimal readyFinishQty,
            BigDecimal readyShipQty) {

        static SourceLine from(Object[] row) {
            return new SourceLine(uuid(row[0]), string(row[1]), uuid(row[2]), uuid(row[3]),
                    string(row[4]), date(row[5]), date(row[6]), string(row[7]),
                    uuid(row[8]), string(row[9]), string(row[10]), string(row[11]),
                    uuid(row[12]), string(row[13]), uuid(row[14]), string(row[15]),
                    decimal(row[16]), decimal(row[17]), decimal(row[18]), decimal(row[19]),
                    string(row[20]), Boolean.TRUE.equals(row[21]), decimal(row[22]),
                    decimal(row[23]), decimal(row[24]), decimal(row[25]), decimal(row[26]),
                    decimal(row[27]), decimal(row[28]), decimal(row[29]),
                    row[30] == null ? null : ((Number) row[30]).shortValue(),
                    Boolean.TRUE.equals(row[31]), Boolean.TRUE.equals(row[32]),
                    Boolean.TRUE.equals(row[33]), Boolean.TRUE.equals(row[34]),
                    string(row[35]), string(row[36]), integer(row[37]),
                    decimal(row[38]), decimal(row[39]), decimal(row[40]),
                    decimal(row[41]), decimal(row[42]));
        }

        BigDecimal remainingAnalysisQty() {
            return requestedQty.subtract(submittedQty).subtract(approvedQty)
                    .max(BigDecimal.ZERO).setScale(4, RoundingMode.DOWN);
        }

        boolean missingBom() {
            return !hasBom;
        }

        ProductView toView(BigDecimal ratio) {
            return new ProductView(analysisItemId, sourceType, sourceRef, sourceReason,
                    salesOrderItemId,
                    salesOrderId, salesOrderNo, orderDate, deliveryDate, clientName,
                    goodsId, goodsCode, goodsName, spec, colorId, colorName, unitId,
                    unitName, unitRate, requestedQty, submittedQty, approvedQty,
                    remainingAnalysisQty(), allocationPriority,
                    readyNowQty, readyByDateQty,
                    readyStartQty, readyFinishQty, readyShipQty, ratio,
                    productionBomPolicy, missingBom(),
                    missingBom() && "BOM_REQUIRED".equals(productionBomPolicy));
        }
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
            boolean hardGate) {
        MaterialDimension dimension() {
            return new MaterialDimension(goodsId, colorId, unitId);
        }
        BigDecimal requiredForOutput(BigDecimal productQty) {
            return requiredForParentOutput(productQty.multiply(parentPerProductQty));
        }
        BigDecimal requiredForParentOutput(BigDecimal parentOutputQty) {
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
                    basisOutputQty, allowPartialPackage, hardGate);
        }
        String path() {
            return nodeKey;
        }
    }

    record StockValue(BigDecimal onHand, BigDecimal reserved, BigDecimal available) {
        static final StockValue ZERO = new StockValue(
                BigDecimal.ZERO, BigDecimal.ZERO, BigDecimal.ZERO);
        StockValue add(StockValue other) {
            return new StockValue(onHand.add(other.onHand), reserved.add(other.reserved),
                    available.add(other.available));
        }
    }

    record InboundLot(MaterialDimension dimension, LocalDate expectedDate, BigDecimal qty) {
    }

    record InboundValue(BigDecimal qty, LocalDate expectedDate) {
        static final InboundValue ZERO = new InboundValue(BigDecimal.ZERO, null);
    }

    record AvailabilitySnapshot(Map<MaterialDimension, StockValue> stock,
                                List<InboundLot> inbound) {
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

    record MaterialRow(
            UUID id, UUID analysisItemId, UUID goodsId, String goodsCode,
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
            String routeReason, String productionBomPolicy,
            boolean hasActiveBom, boolean lowerLevelPending) {
        static MaterialRow from(Object[] row) {
            return new MaterialRow(uuid(row[0]), uuid(row[1]), uuid(row[2]), string(row[3]),
                    string(row[4]), string(row[5]), uuid(row[6]), string(row[7]),
                    uuid(row[8]), string(row[9]), integer(row[10]), string(row[11]),
                    string(row[12]), uuid(row[13]), string(row[14]), string(row[15]),
                    decimal(row[16]), Boolean.TRUE.equals(row[17]),
                    Boolean.TRUE.equals(row[18]), decimal(row[19]), decimal(row[20]),
                    decimal(row[21]), decimal(row[22]), decimal(row[23]), decimal(row[24]),
                    decimal(row[25]), decimal(row[26]), decimal(row[27]), decimal(row[28]),
                    date(row[29]), string(row[30]), string(row[31]), string(row[32]),
                    string(row[33]), Boolean.TRUE.equals(row[34]),
                    Boolean.TRUE.equals(row[35]));
        }
        MaterialDimension dimension() {
            return new MaterialDimension(goodsId, colorId, unitId);
        }
        MaterialView toView(List<WarehouseBreakdown> breakdown,
                            List<DownstreamReference> references,
                            List<String> displayPath, String parentLabel) {
            List<String> notified = references.stream().map(DownstreamReference::route)
                    .distinct().sorted().toList();
            return new MaterialView(id, analysisItemId, path, actionGroupKey(), materialKey(),
                    goodsId, goodsCode, goodsName,
                    spec, colorId, colorName, unitId, unitName, depth, displayPath,
                    parentNodeKey, parentGoodsId, parentLabel,
                    controlStage, consumptionBasis, basisOutputQty,
                    allowPartialPackage, hardGate, bomQty, parentPerProductQty,
                    perProductQty, requiredQty,
                    availableQty, allocatedAvailableQty, reservedQty,
                    safetyStockQty, inboundQty, shortageQty,
                    expectedReadyDate, suggestion, confirmedRoute,
                    confirmedRoute != null, routeReason, productionBomPolicy,
                    hasActiveBom, depth == 1, lowerLevelPending, notified,
                    breakdown, references);
        }

        String actionGroupKey() {
            return PlanningPackageFingerprint.sha256(List.of(
                    "MATERIAL-ACTION-GROUP-V2", analysisItemId.toString(),
                    "DEPTH-" + depth,
                    goodsId.toString(), Objects.toString(colorId, "NONE"), unitId.toString()));
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
