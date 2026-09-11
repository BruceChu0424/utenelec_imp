package com.uten.imp.features.production.quality;

import com.uten.imp.application.port.BusinessEventPublisher;
import com.uten.imp.application.port.ProductionFinishedInboundReleasePort;
import com.uten.imp.application.port.ProductionFqcRecoveryPort;
import com.uten.imp.application.port.ProductionQualityInspectionPort;
import com.uten.imp.common.docnumber.DocNumberPrefix;
import com.uten.imp.common.docnumber.DocNumberService;
import com.uten.imp.common.util.NativeQueryResults;
import com.uten.imp.common.util.NativeValueConverters;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.common.web.Pageables;
import com.uten.imp.features.production.ProductionDocumentAccessPolicy;
import com.uten.imp.features.production.quality.ProductionFqcContracts.DecisionRequest;
import com.uten.imp.features.production.quality.ProductionFqcContracts.DecisionResult;
import com.uten.imp.features.production.quality.ProductionFqcContracts.InspectionSheetDetailView;
import com.uten.imp.features.production.quality.ProductionFqcContracts.InspectionSheetView;
import com.uten.imp.features.production.quality.ProductionFqcContracts.InspectionView;
import com.uten.imp.features.production.quality.ProductionFqcContracts.PassAllBatchItem;
import com.uten.imp.features.production.quality.ProductionFqcContracts.PassAllBatchRequest;
import com.uten.imp.features.production.quality.ProductionFqcContracts.PassAllBatchResult;
import com.uten.imp.security.DocumentAccessPolicy.NativeReadScope;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.data.domain.PageRequest;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.math.RoundingMode;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.HexFormat;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Objects;
import java.util.UUID;

/**
 * Production FQC projection, append-only decisions, and PASS release gate.
 *
 * <p>This service never writes stock, {@code fqty}, {@code iqty}, or MAKE
 * readiness.  A PASS emits an outbox request and becomes consumable only through
 * {@link #allocateReleasedQuantity}; the caller owns FINISHED_IN construction in
 * the same transaction.</p>
 */
@Service
@RequiredArgsConstructor
public class ProductionFqcInspectionService
        implements ProductionQualityInspectionPort {

    static final String VIEW_AUTHORITY = "production_quality_inspection:view";
    static final String APPROVE_AUTHORITY =
            "production_quality_inspection:approve";
    static final String EVENT_PENDING = "PRODUCTION_FQC_PENDING";
    static final String EVENT_RELEASED = "PRODUCTION_FQC_RELEASED";
    static final String EVENT_RESOLVED = "PRODUCTION_FQC_RESOLVED";
    private static final Comparator<UUID> UUID_ORDER =
            Comparator.comparing(UUID::toString);

    private final EntityManager em;
    private final SecurityContextCurrentUser currentUser;
    private final TxSessionVars tx;
    private final ProductionDocumentAccessPolicy productionAccess;
    private final ProductionFqcTaskAccessPolicy taskAccess;
    private final ProductionFqcRecoveryPort recovery;
    private final ProductionFinishedInboundReleasePort finishedInbound;
    private final BusinessEventPublisher outbox;
    private final ProductionQualityMutationFootprintService mutationFootprint;
    private final DocNumberService docNumbers;

    /**
     * Called by the warehouse-arrival registration transaction after the
     * source report status is 1 and the selected exact lines have placement
     * snapshots. Unselected report lines remain in the warehouse registration
     * queue and are not silently turned into FQC facts.
     * There is intentionally no historical batch/backfill entry point.
     */
    @Override
    @Transactional(propagation = Propagation.MANDATORY)
    public void registerApprovedReportItems(
            UUID reportId,
            List<UUID> reportItemIds,
            UUID registrationId) {
        tx.bind();
        if (reportId == null || registrationId == null
                || reportItemIds == null || reportItemIds.isEmpty()
                || reportItemIds.stream().anyMatch(Objects::isNull)) {
            throw validation("生产质检登记缺少报工单、登记批次或明细 UUID");
        }
        List<UUID> requestedIds = reportItemIds.stream()
                .distinct()
                .sorted(UUID_ORDER)
                .toList();
        if (requestedIds.size() != reportItemIds.size()) {
            throw validation("生产质检登记不能重复选择同一报工明细");
        }
        List<Object[]> rows = NativeQueryResults.objectArrayRows(
                em.createNativeQuery("""
                                SELECT report.id, report.status,
                                       registration.warehouse_id, report.maker_id,
                                       report.is_deleted,
                                       item.id, item.plan_item_id,
                                       item.execution_segment_id,
                                       item.execution_segment_sales_allocation_id,
                                       item.goods_id, item.color_id, item.unit_id,
                                       COALESCE(item.unit_rate, 1), item.qty,
                                       item.is_deleted,
                                       segment.plan_id, segment.status,
                                       segment.is_deleted,
                                       package.status, package.is_deleted
                                FROM production_daily_reports report
                                JOIN production_daily_report_items item
                                  ON item.report_id = report.id
                                JOIN production_finished_arrival_registrations registration
                                  ON registration.source_report_id = report.id
                                JOIN production_finished_arrival_registration_items
                                          registration_item
                                  ON registration_item.registration_id = registration.id
                                 AND registration_item.source_report_item_id = item.id
                                LEFT JOIN production_execution_segments segment
                                  ON segment.id = item.execution_segment_id
                                LEFT JOIN production_planning_packages package
                                  ON package.id = segment.package_id
                                WHERE report.id = :reportId
                                  AND registration.id = :registrationId
                                  AND item.id IN (:reportItemIds)
                                  AND item.execution_segment_id IS NOT NULL
                                ORDER BY item.line_no NULLS LAST, item.id
                                FOR UPDATE OF report, item
                                """)
                        .setParameter("reportId", reportId)
                        .setParameter("registrationId", registrationId)
                        .setParameter("reportItemIds", requestedIds));
        if (rows.size() != requestedIds.size()) {
            throw conflict("送检登记明细已变化或不属于当前登记批次，请刷新后重试");
        }
        UUID actorId = currentUser.requireId();
        for (Object[] row : rows) {
            requireEligibleReportLine(row);
            em.createNativeQuery("""
                            INSERT INTO production_fqc_inspections(
                                id, source_report_id, source_report_item_id,
                                source_plan_item_id, execution_segment_id,
                                execution_segment_sales_allocation_id,
                                warehouse_id, goods_id, color_id, unit_id,
                                unit_rate, reported_qty, report_maker_id,
                                created_by)
                            VALUES (
                                :id, :reportId, :reportItemId,
                                :planItemId, :segmentId, :salesAllocationId,
                                :warehouseId, :goodsId, :colorId, :unitId,
                                :unitRate, :reportedQty, :makerId, :actorId)
                            """)
                    .setParameter("id", UUID.randomUUID())
                    .setParameter("reportId", row[0])
                    .setParameter("reportItemId", row[5])
                    .setParameter("planItemId", row[6])
                    .setParameter("segmentId", row[7])
                    .setParameter("salesAllocationId", row[8])
                    .setParameter("warehouseId", row[2])
                    .setParameter("goodsId", row[9])
                    .setParameter("colorId", row[10])
                    .setParameter("unitId", row[11])
                    .setParameter("unitRate", dec(row[12]))
                    .setParameter("reportedQty", dec(row[13]))
                    .setParameter("makerId", row[3])
                    .setParameter("actorId", actorId)
                    .executeUpdate();
        }
        outbox.publishOnce(
                EVENT_PENDING,
                "PRODUCTION_DAILY_REPORT",
                reportId,
                Map.of(
                        "inspectionCount", rows.size(),
                        "registrationId", registrationId.toString()),
                EVENT_PENDING + ':' + registrationId);
    }

    @Transactional(readOnly = true)
    @PreAuthorize("hasAuthority('production_quality_inspection:view')")
    public PageResponse<InspectionView> list(
            String rawStatus,
            String rawKeyword,
            String rawSheetScope,
            int requestedPage,
            int requestedSize) {
        String status = normalizeStatusFilter(rawStatus);
        String keyword = rawKeyword == null
                ? "" : rawKeyword.strip().toLowerCase(Locale.ROOT);
        SheetScope sheetScope = normalizeSheetScope(rawSheetScope);
        PageRequest pageable = Pageables.of(requestedPage, requestedSize);
        int page = pageable.getPageNumber() + 1;
        int size = pageable.getPageSize();
        boolean qualityPool = taskAccess.canAccessQualityPool();
        NativeReadScope ownerScope = qualityPool
                ? null
                : productionAccess.nativeReadScope(
                        "report.maker_id", "fqcOwners");
        String ownerPredicate = qualityPool ? "1=1" : ownerScope.predicate();
        String statusPredicate = switch (status) {
            case "ALL" -> "1=1";
            case "ACTIVE" -> "inspection.status IN ('PENDING','PARTIAL')";
            default -> "inspection.status = :status";
        };
        String keywordPredicate = """
                (:keyword = '' OR LOWER(
                    COALESCE(report.bill_no, '') || ' ' ||
                    COALESCE(plan.bill_no, '') || ' ' ||
                    COALESCE(goods.code, '') || ' ' ||
                    COALESCE(goods.name, '') || ' ' ||
                    COALESCE(color.name, '') || ' ' ||
                    COALESCE(sheet.sheet_no, '')
                ) LIKE :keywordLike)
                """;
        // V547：sheet=NONE 只列无检查单的历史任务（待检处置「无检查单」行）；
        // sheet=<uuid> 列该检查单的任务；缺省不按检查单过滤。
        String sheetPredicate = switch (sheetScope.kind()) {
            case NONE -> "sheet_item.sheet_id IS NULL";
            case EXACT -> "sheet_item.sheet_id = :sheetId";
            default -> "1=1";
        };
        String pageSql = viewSql(
                ownerPredicate + " AND " + statusPredicate
                        + " AND " + keywordPredicate
                        + " AND " + sheetPredicate);
        Query countQuery = em.createNativeQuery(
                "SELECT COUNT(*) FROM (" + pageSql + ") fqc_page");
        bindInspectionPage(
                countQuery, ownerScope, status, keyword, sheetScope);
        long total = ((Number) countQuery.getSingleResult()).longValue();

        Query query = em.createNativeQuery(pageSql
                + " ORDER BY inspection.created_at, inspection.id"
                + " OFFSET :offset LIMIT :limit");
        bindInspectionPage(query, ownerScope, status, keyword, sheetScope);
        query.setParameter("offset", pageable.getOffset());
        query.setParameter("limit", size);
        List<InspectionView> items =
                NativeQueryResults.objectArrayRows(query).stream()
                .map(ProductionFqcInspectionService::toView)
                .toList();
        int totalPages = total == 0
                ? 0 : (int) ((total + size - 1) / size);
        return new PageResponse<>(
                items, page, size, total, totalPages);
    }

    private static void bindInspectionPage(
            Query query,
            NativeReadScope ownerScope,
            String status,
            String keyword,
            SheetScope sheetScope) {
        if (ownerScope != null) ownerScope.bind(query);
        if (!"ALL".equals(status) && !"ACTIVE".equals(status)) {
            query.setParameter("status", status);
        }
        query.setParameter("keyword", keyword);
        query.setParameter("keywordLike", "%" + keyword + "%");
        if (sheetScope.kind() == SheetScopeKind.EXACT) {
            query.setParameter("sheetId", sheetScope.sheetId());
        }
    }

    /**
     * V547 品质检查单队列：一行一张检查单（ACTIVE = 仍有 PENDING/PARTIAL 行；
     * CLOSED = 全部 RESOLVED/CANCELLED）。数量文本按单位分组汇总，不跨单位相加。
     */
    @Transactional(readOnly = true)
    @PreAuthorize("hasAuthority('production_quality_inspection:view')")
    public PageResponse<InspectionSheetView> listSheets(
            String rawStatus,
            String rawKeyword,
            int requestedPage,
            int requestedSize) {
        String status = normalizeSheetStatusFilter(rawStatus);
        String keyword = rawKeyword == null
                ? "" : rawKeyword.strip().toLowerCase(Locale.ROOT);
        PageRequest pageable = Pageables.of(requestedPage, requestedSize);
        int page = pageable.getPageNumber() + 1;
        int size = pageable.getPageSize();
        boolean qualityPool = taskAccess.canAccessQualityPool();
        NativeReadScope ownerScope = qualityPool
                ? null
                : productionAccess.nativeReadScope(
                        "owner_report.maker_id", "fqcSheetOwners");
        String statusPredicate = switch (status) {
            case "ALL" -> "1=1";
            case "CLOSED" -> "sheet_row.active_count = 0";
            default -> "sheet_row.active_count > 0";
        };
        String keywordPredicate = """
                (:keyword = '' OR LOWER(
                    COALESCE(sheet_row.sheet_no, '') || ' ' ||
                    COALESCE(sheet_row.warehouse_name, '') || ' ' ||
                    COALESCE(sheet_row.receiver_name, '') || ' ' ||
                    COALESCE(sheet_row.report_nos, '') || ' ' ||
                    COALESCE(sheet_row.goods_summary, '')
                ) LIKE :keywordLike)
                """;
        String pageSql = sheetSql(sheetOwnerPredicate(ownerScope))
                + " WHERE " + statusPredicate + " AND " + keywordPredicate;
        Query countQuery = em.createNativeQuery(
                "SELECT COUNT(*) FROM (" + pageSql + ") fqc_sheet_page");
        bindSheetPage(countQuery, ownerScope, keyword);
        long total = ((Number) countQuery.getSingleResult()).longValue();

        Query query = em.createNativeQuery(pageSql
                + " ORDER BY sheet_row.created_at, sheet_row.id"
                + " OFFSET :offset LIMIT :limit");
        bindSheetPage(query, ownerScope, keyword);
        query.setParameter("offset", pageable.getOffset());
        query.setParameter("limit", size);
        List<InspectionSheetView> items =
                NativeQueryResults.objectArrayRows(query).stream()
                        .map(ProductionFqcInspectionService::toSheetView)
                        .toList();
        int totalPages = total == 0
                ? 0 : (int) ((total + size - 1) / size);
        return new PageResponse<>(items, page, size, total, totalPages);
    }

    /** 检查单办理视图：头 + 该单逐条 inspection（对象范围内不可见的行不返回）。 */
    @Transactional(readOnly = true)
    @PreAuthorize("hasAuthority('production_quality_inspection:view')")
    public InspectionSheetDetailView sheetDetail(UUID sheetId) {
        if (sheetId == null) throw notFound("品质检查单不存在");
        boolean qualityPool = taskAccess.canAccessQualityPool();
        NativeReadScope ownerScope = qualityPool
                ? null
                : productionAccess.nativeReadScope(
                        "owner_report.maker_id", "fqcSheetOwners");
        Query headQuery = em.createNativeQuery(
                sheetSql(sheetOwnerPredicate(ownerScope))
                        + " WHERE sheet_row.id = :sheetId");
        if (ownerScope != null) ownerScope.bind(headQuery);
        headQuery.setParameter("sheetId", sheetId);
        List<Object[]> heads = NativeQueryResults.objectArrayRows(headQuery);
        if (heads.size() != 1) throw notFound("品质检查单不存在");

        NativeReadScope lineScope = qualityPool
                ? null
                : productionAccess.nativeReadScope(
                        "report.maker_id", "fqcOwners");
        Query lineQuery = em.createNativeQuery(viewSql(
                (lineScope == null ? "1=1" : lineScope.predicate())
                        + " AND sheet_item.sheet_id = :sheetId")
                + " ORDER BY sheet_item.line_no, inspection.id");
        if (lineScope != null) lineScope.bind(lineQuery);
        lineQuery.setParameter("sheetId", sheetId);
        List<InspectionView> inspections =
                NativeQueryResults.objectArrayRows(lineQuery).stream()
                        .map(ProductionFqcInspectionService::toView)
                        .toList();
        if (inspections.isEmpty()) throw notFound("品质检查单不存在");
        return new InspectionSheetDetailView(
                toSheetView(heads.getFirst()), inspections);
    }

    private static String sheetOwnerPredicate(NativeReadScope ownerScope) {
        if (ownerScope == null) return "1=1";
        return """
                EXISTS (
                    SELECT 1
                    FROM production_fqc_inspection_sheet_items owner_item
                    JOIN production_fqc_inspections owner_inspection
                      ON owner_inspection.id = owner_item.inspection_id
                    JOIN production_daily_reports owner_report
                      ON owner_report.id = owner_inspection.source_report_id
                    WHERE owner_item.sheet_id = sheet.id
                      AND %s)
                """.formatted(ownerScope.predicate());
    }

    private static void bindSheetPage(
            Query query,
            NativeReadScope ownerScope,
            String keyword) {
        if (ownerScope != null) ownerScope.bind(query);
        query.setParameter("keyword", keyword);
        query.setParameter("keywordLike", "%" + keyword + "%");
    }

    /** 检查单头投影；调用方在其后追加 WHERE（列名以 sheet_row.* 引用）。 */
    private static String sheetSql(String ownerPredicate) {
        return """
                SELECT sheet_row.*
                FROM (
                    SELECT sheet.id,
                           sheet.sheet_no,
                           sheet.warehouse_id,
                           sheet.warehouse_name_snapshot AS warehouse_name,
                           sheet.receiver_employee_id,
                           sheet.receiver_name_snapshot AS receiver_name,
                           sheet.remark,
                           sheet.source_kind,
                           sheet.created_at,
                           COUNT(sheet_item.id)::integer AS item_count,
                           COUNT(sheet_item.id) FILTER (
                               WHERE inspection.status IN ('PENDING', 'PARTIAL')
                           )::integer AS active_count,
                           string_agg(DISTINCT report.bill_no, '、') AS report_nos,
                           string_agg(
                               DISTINCT COALESCE(
                                   NULLIF(goods.name, ''),
                                   NULLIF(goods.code, ''),
                                   '未命名货品'),
                               '、') AS goods_summary,
                           pending.text AS pending_qty_text
                    FROM production_fqc_inspection_sheets sheet
                    JOIN production_fqc_inspection_sheet_items sheet_item
                      ON sheet_item.sheet_id = sheet.id
                    JOIN production_fqc_inspections inspection
                      ON inspection.id = sheet_item.inspection_id
                    JOIN production_daily_reports report
                      ON report.id = inspection.source_report_id
                    JOIN goods goods ON goods.id = inspection.goods_id
                    LEFT JOIN LATERAL (
                        SELECT string_agg(
                                   unit_total.qty_text || ' ' || unit_total.unit_name,
                                   ' · ' ORDER BY unit_total.unit_name) AS text
                        FROM (
                            SELECT COALESCE(unit.name, '') AS unit_name,
                                   rtrim(rtrim(SUM(
                                       pending_inspection.reported_qty
                                       - pending_inspection.passed_qty
                                       - pending_inspection.failed_qty)::text,
                                       '0'), '.') AS qty_text
                            FROM production_fqc_inspection_sheet_items pending_item
                            JOIN production_fqc_inspections pending_inspection
                              ON pending_inspection.id = pending_item.inspection_id
                             AND pending_inspection.status IN ('PENDING', 'PARTIAL')
                            LEFT JOIN units unit
                              ON unit.id = pending_inspection.unit_id
                            WHERE pending_item.sheet_id = sheet.id
                            GROUP BY COALESCE(unit.name, '')
                        ) unit_total
                    ) pending ON TRUE
                    WHERE %s
                    GROUP BY sheet.id, sheet.sheet_no, sheet.warehouse_id,
                             sheet.warehouse_name_snapshot,
                             sheet.receiver_employee_id,
                             sheet.receiver_name_snapshot, sheet.remark,
                             sheet.source_kind, sheet.created_at, pending.text
                ) sheet_row
                """.formatted(ownerPredicate);
    }

    private static InspectionSheetView toSheetView(Object[] row) {
        int activeCount = ((Number) row[10]).intValue();
        return new InspectionSheetView(
                (UUID) row[0], string(row[1]), (UUID) row[2], string(row[3]),
                (UUID) row[4], string(row[5]), string(row[6]), string(row[7]),
                ((Number) row[9]).intValue(), activeCount,
                string(row[13]), string(row[11]), string(row[12]),
                activeCount > 0 ? "ACTIVE" : "CLOSED",
                NativeValueConverters.toOffsetDateTime(row[8]));
    }

    @Transactional(readOnly = true)
    @PreAuthorize("hasAuthority('production_quality_inspection:view')")
    public long countActive() {
        boolean qualityPool = taskAccess.canAccessQualityPool();
        NativeReadScope ownerScope = qualityPool
                ? null
                : productionAccess.nativeReadScope(
                        "report.maker_id", "fqcCountOwners");
        String ownerPredicate = qualityPool
                ? "1=1"
                : ownerScope.predicate();
        // V547 角标口径 = 待检处置队列行数：一张检查单计 1，无检查单的历史任务逐条计 1。
        Query query = em.createNativeQuery("""
                        SELECT COUNT(DISTINCT COALESCE(sheet_item.sheet_id, inspection.id))
                        FROM production_fqc_inspections inspection
                        JOIN production_daily_reports report
                          ON report.id = inspection.source_report_id
                         AND report.is_deleted = FALSE
                        LEFT JOIN production_fqc_inspection_sheet_items sheet_item
                          ON sheet_item.inspection_id = inspection.id
                        WHERE inspection.status IN ('PENDING','PARTIAL')
                          AND %s
                        """.formatted(ownerPredicate));
        if (ownerScope != null) ownerScope.bind(query);
        return ((Number) query.getSingleResult()).longValue();
    }

    @Transactional(readOnly = true)
    @PreAuthorize("hasAuthority('production_quality_inspection:view')")
    public InspectionView detail(UUID inspectionId) {
        InspectionView view = detailInternal(inspectionId);
        requireReadable(view.reportMakerId());
        return view;
    }

    @Transactional
    @PreAuthorize("hasAuthority('production_quality_inspection:view')"
            + " and hasAuthority('production_quality_inspection:approve')")
    public DecisionResult decide(UUID inspectionId, DecisionRequest request) {
        tx.bind();
        taskAccess.requireQualityPool("当前账号不在品质任务组织范围");
        if (inspectionId == null || request == null) {
            throw validation("生产质检决定请求不能为空");
        }
        NormalizedRequest normalized = normalizeRequest(request);
        var sourceGuard = mutationFootprint.beginInspections(List.of(inspectionId));
        prelockDecisionDimensions(inspectionId);
        Object[] inspection = lockInspection(inspectionId);

        return decideLocked(inspectionId, normalized, inspection, sourceGuard::verifyUnchanged);
    }

    /**
     * Atomically resolves every selected inspection as PASS for its current
     * remaining quantity. The client supplies identities only; all quantities
     * are derived after the complete lock set has been acquired.
     */
    @Transactional
    @PreAuthorize("hasAuthority('production_quality_inspection:view')"
            + " and hasAuthority('production_quality_inspection:approve')")
    public PassAllBatchResult passAll(PassAllBatchRequest request) {
        tx.bind();
        taskAccess.requireQualityPool("当前账号不在品质任务组织范围");
        NormalizedPassAllBatch normalized = normalizePassAllBatch(request);
        UUID actorUserId = currentUser.requireId();
        var sourceGuard = mutationFootprint.beginInspections(normalized.inspectionIds());
        BatchCommand existing = findPassAllBatch(actorUserId, normalized);
        if (existing != null) return loadPassAllBatch(existing.id(), true, normalized.inspectionIds().size());
        Map<UUID, Object[]> locked = lockPassAllDecisionDimensions(
                normalized.inspectionIds());
        for (UUID inspectionId : normalized.inspectionIds()) {
            requireActiveDecisionRow(locked.get(inspectionId));
        }
        sourceGuard.verifyUnchanged();
        BatchCommand batch = claimPassAllBatch(actorUserId, normalized);
        if (batch.replay()) return loadPassAllBatch(batch.id(), true, normalized.inspectionIds().size());

        List<PassAllBatchItem> items = new ArrayList<>(
                normalized.inspectionIds().size());
        int lineNo = 0;
        for (UUID inspectionId : normalized.inspectionIds()) {
            NormalizedRequest child = normalizeRequest(new DecisionRequest(
                    "PASS", null, null, null, null,
                    passAllChildKey(batch.id(), inspectionId)));
            DecisionResult decision = decideLocked(
                    inspectionId, child, locked.get(inspectionId), () -> { /* whole batch verified before its first write */ });
            if (decision.replay()) {
                throw conflict("批量全合格子结果已存在但缺少批次关联，请联系管理员核查");
            }
            int nextLine = ++lineNo;
            em.createNativeQuery("""
                            INSERT INTO production_fqc_pass_all_batch_items(
                                batch_id, inspection_id, decision_event_id,
                                line_no)
                            VALUES (:batchId, :inspectionId, :decisionEventId,
                                    :lineNo)
                            """)
                    .setParameter("batchId", batch.id())
                    .setParameter("inspectionId", inspectionId)
                    .setParameter("decisionEventId", decision.decisionEventId())
                    .setParameter("lineNo", nextLine)
                    .executeUpdate();
            items.add(new PassAllBatchItem(
                    inspectionId,
                    decision.decisionEventId(),
                    decision.inspection()));
        }
        return new PassAllBatchResult(batch.id(), items, false);
    }

    private DecisionResult decideLocked(
            UUID inspectionId,
            NormalizedRequest normalized,
            Object[] inspection,
            Runnable verifyBeforeFirstWrite) {

        List<Object[]> replay = NativeQueryResults.objectArrayRows(
                em.createNativeQuery("""
                                SELECT id, request_hash
                                FROM production_fqc_decision_events
                                WHERE inspection_id = :inspectionId
                                  AND idempotency_key = :key
                                """)
                        .setParameter("inspectionId", inspectionId)
                        .setParameter("key", normalized.idempotencyKey()));
        if (!replay.isEmpty()) {
            if (!Objects.equals(replay.getFirst()[1], normalized.requestHash())) {
                throw conflict("该质检幂等键已用于不同决定，请刷新后重试");
            }
            return new DecisionResult(
                    (UUID) replay.getFirst()[0],
                    detailInternal(inspectionId),
                    true);
        }

        BigDecimal reported = dec(inspection[1]);
        BigDecimal passed = dec(inspection[2]);
        BigDecimal failed = dec(inspection[3]);
        String currentStatus = string(inspection[4]);
        if (!List.of("PENDING", "PARTIAL").contains(currentStatus)) {
            throw conflict("该生产质检任务已全部决定");
        }
        BigDecimal remaining = reported.subtract(passed).subtract(failed);
        ResolvedDecision resolved = normalized.resolve(remaining);
        verifyBeforeFirstWrite.run();

        UUID eventId = UUID.randomUUID();
        UUID actorUserId = currentUser.requireId();
        UUID actorEmployeeId = currentUser.requireEmployeeId();
        em.createNativeQuery("""
                        INSERT INTO production_fqc_decision_events(
                            id, inspection_id, decision, pass_qty, fail_qty,
                            disposition_code, reason, idempotency_key,
                            request_hash, decided_by_employee_id, created_by)
                        VALUES (
                            :id, :inspectionId, :decision, :passQty, :failQty,
                            :dispositionCode, :reason, :key,
                            :requestHash, :employeeId, :userId)
                        """)
                .setParameter("id", eventId)
                .setParameter("inspectionId", inspectionId)
                .setParameter("decision", resolved.decision())
                .setParameter("passQty", resolved.passQty())
                .setParameter("failQty", resolved.failQty())
                .setParameter("dispositionCode", resolved.dispositionCode())
                .setParameter("reason", resolved.reason())
                .setParameter("key", normalized.idempotencyKey())
                .setParameter("requestHash", normalized.requestHash())
                .setParameter("employeeId", actorEmployeeId)
                .setParameter("userId", actorUserId)
                .executeUpdate();

        if (resolved.failQty().signum() > 0) {
            recovery.applyFailureAdjustment(
                    inspectionId,
                    eventId,
                    resolved.failQty(),
                    resolved.dispositionCode());
        }

        if (resolved.passQty().signum() > 0) {
            ProductionFinishedInboundReleasePort.CreatedDraft draft =
                    finishedInbound.createReleasedDraft(
                            new ProductionFinishedInboundReleasePort.ReleaseRequest(
                                    inspectionId,
                                    eventId,
                                    (UUID) inspection[5],
                                    (UUID) inspection[6],
                                    resolved.passQty()));
            allocateReleasedQuantity(
                    (UUID) inspection[6],
                    draft.stockDocumentItemId(),
                    resolved.passQty(),
                    "FQC-FINISHED-IN:" + eventId);
            Map<String, Object> payload = new LinkedHashMap<>();
            payload.put("inspectionId", inspectionId);
            payload.put("decisionEventId", eventId);
            payload.put("sourceReportId", inspection[5]);
            payload.put("sourceReportItemId", inspection[6]);
            payload.put("passQty", resolved.passQty());
            payload.put("stockDocumentId", draft.stockDocumentId());
            payload.put(
                    "stockDocumentItemId",
                    draft.stockDocumentItemId());
            outbox.publishOnce(
                    EVENT_RELEASED,
                    "PRODUCTION_FQC_INSPECTION",
                    inspectionId,
                    payload,
                    EVENT_RELEASED + ':' + eventId);
        }
        InspectionView result = detailInternal(inspectionId);
        if ("RESOLVED".equals(result.status())) {
            outbox.publishOnce(
                    EVENT_RESOLVED,
                    "PRODUCTION_FQC_INSPECTION",
                    inspectionId,
                    Map.of(
                            "sourceReportId", result.sourceReportId(),
                            "sourceReportItemId", result.sourceReportItemId(),
                            "passedQty", result.passedQty(),
                            "failedQty", result.failedQty()),
                    EVENT_RESOLVED + ':' + inspectionId);
        }
        return new DecisionResult(eventId, result, false);
    }

    @Override
    @Transactional(propagation = Propagation.MANDATORY)
    public ReleaseAuthorization allocateReleasedQuantity(
            UUID sourceReportItemId,
            UUID stockDocumentItemId,
            BigDecimal quantity,
            String idempotencyKey) {
        tx.bind();
        if (sourceReportItemId == null || stockDocumentItemId == null) {
            throw validation("FQC 入库放行缺少报工行或库存行 UUID");
        }
        BigDecimal requested = normalizeQty(quantity, "FQC 入库放行数量");
        String key = normalizeKey(idempotencyKey);
        String requestHash = sha256(List.of(
                "PRODUCTION-FQC-FINISHED-IN-V1",
                sourceReportItemId.toString(),
                stockDocumentItemId.toString(),
                canonicalQty(requested)));

        // V548 后同一报工行可有多条 CANCELLED（登记撤回）历史 inspection，
        // 只有未取消的那条（部分唯一索引保证至多一条）可以放行。
        List<Object[]> inspections = NativeQueryResults.objectArrayRows(
                em.createNativeQuery("""
                                SELECT id, status
                                FROM production_fqc_inspections
                                WHERE source_report_item_id = :reportItemId
                                ORDER BY (status = 'CANCELLED'), created_at DESC, id
                                FOR UPDATE
                                """)
                        .setParameter("reportItemId", sourceReportItemId));
        if (inspections.isEmpty()) {
            throw conflict("该报工明细没有显式 FQC 待检事实，禁止生成合格入库");
        }
        UUID inspectionId = (UUID) inspections.getFirst()[0];
        if ("CANCELLED".equals(inspections.getFirst()[1])) {
            throw conflict("该生产质检已随来源报工红冲或登记撤回取消，禁止生成入库");
        }
        List<Object[]> replay = NativeQueryResults.objectArrayRows(
                em.createNativeQuery("""
                                SELECT id, source_report_item_id,
                                       stock_document_item_id, requested_qty,
                                       request_hash
                                FROM production_fqc_release_commands
                                WHERE inspection_id = :inspectionId
                                  AND idempotency_key = :key
                                """)
                        .setParameter("inspectionId", inspectionId)
                        .setParameter("key", key));
        if (!replay.isEmpty()) {
            Object[] existing = replay.getFirst();
            if (!Objects.equals(existing[1], sourceReportItemId)
                    || !Objects.equals(existing[2], stockDocumentItemId)
                    || dec(existing[3]).compareTo(requested) != 0
                    || !Objects.equals(existing[4], requestHash)) {
                throw conflict("该 FQC 入库幂等键已用于不同请求");
            }
            return new ReleaseAuthorization(
                    (UUID) existing[0], inspectionId,
                    sourceReportItemId, stockDocumentItemId, requested);
        }

        List<Object[]> lots = NativeQueryResults.objectArrayRows(
                em.createNativeQuery("""
                                SELECT decision.id,
                                       decision.pass_qty
                                           - COALESCE(SUM(allocation.qty), 0)
                                           AS remaining_qty
                                FROM production_fqc_decision_events decision
                                LEFT JOIN production_fqc_release_allocations allocation
                                  ON allocation.decision_event_id = decision.id
                                WHERE decision.inspection_id = :inspectionId
                                  AND decision.pass_qty > 0
                                GROUP BY decision.id, decision.pass_qty,
                                         decision.decided_at
                                HAVING decision.pass_qty
                                           - COALESCE(SUM(allocation.qty), 0) > 0
                                ORDER BY decision.decided_at, decision.id
                                """)
                        .setParameter("inspectionId", inspectionId));
        BigDecimal available = lots.stream()
                .map(row -> dec(row[1]))
                .reduce(BigDecimal.ZERO, BigDecimal::add);
        if (available.compareTo(requested) < 0) {
            throw conflict("FQC 合格未分配量不足，当前仅可入库 "
                    + available.stripTrailingZeros().toPlainString());
        }

        UUID commandId = UUID.randomUUID();
        UUID actorId = currentUser.requireId();
        em.createNativeQuery("""
                        INSERT INTO production_fqc_release_commands(
                            id, inspection_id, source_report_item_id,
                            stock_document_item_id, requested_qty,
                            idempotency_key, request_hash, created_by)
                        VALUES (
                            :id, :inspectionId, :reportItemId,
                            :stockItemId, :qty, :key, :hash, :actorId)
                        """)
                .setParameter("id", commandId)
                .setParameter("inspectionId", inspectionId)
                .setParameter("reportItemId", sourceReportItemId)
                .setParameter("stockItemId", stockDocumentItemId)
                .setParameter("qty", requested)
                .setParameter("key", key)
                .setParameter("hash", requestHash)
                .setParameter("actorId", actorId)
                .executeUpdate();

        BigDecimal remaining = requested;
        for (Object[] lot : lots) {
            if (remaining.signum() == 0) break;
            BigDecimal chunk = remaining.min(dec(lot[1]));
            em.createNativeQuery("""
                            INSERT INTO production_fqc_release_allocations(
                                id, release_command_id, inspection_id,
                                decision_event_id, qty, created_by)
                            VALUES (
                                :id, :commandId, :inspectionId,
                                :decisionId, :qty, :actorId)
                            """)
                    .setParameter("id", UUID.randomUUID())
                    .setParameter("commandId", commandId)
                    .setParameter("inspectionId", inspectionId)
                    .setParameter("decisionId", lot[0])
                    .setParameter("qty", chunk)
                    .setParameter("actorId", actorId)
                    .executeUpdate();
            remaining = remaining.subtract(chunk);
        }
        return new ReleaseAuthorization(
                commandId, inspectionId, sourceReportItemId,
                stockDocumentItemId, requested);
    }

    @Override
    @Transactional(readOnly = true)
    public boolean managesReportItem(UUID sourceReportItemId) {
        if (sourceReportItemId == null) return false;
        Number count = (Number) em.createNativeQuery("""
                        SELECT COUNT(*)
                        FROM production_fqc_inspections
                        WHERE source_report_item_id = :reportItemId
                        """)
                .setParameter("reportItemId", sourceReportItemId)
                .getSingleResult();
        return count != null && count.longValue() >= 1;
    }

    @Override
    @Transactional(propagation = Propagation.MANDATORY)
    public void prelockForReportReversal(UUID reportId) {
        tx.bind();
        if (reportId == null) {
            throw validation("FQC 红冲预锁缺少来源报工 UUID");
        }
        em.createNativeQuery("""
                        SELECT id
                        FROM production_fqc_inspections
                        WHERE source_report_id = :reportId
                        ORDER BY id
                        FOR UPDATE
                        """)
                .setParameter("reportId", reportId)
                .getResultList();
    }

    @Override
    @Transactional(propagation = Propagation.MANDATORY)
    public void cancelForReversedReport(UUID reportId) {
        tx.bind();
        if (reportId == null) {
            throw validation("FQC 取消缺少来源报工 UUID");
        }
        List<Object[]> inspections = NativeQueryResults.objectArrayRows(
                em.createNativeQuery("""
                                SELECT id, status
                                FROM production_fqc_inspections
                                WHERE source_report_id = :reportId
                                ORDER BY id
                                FOR UPDATE
                                """)
                        .setParameter("reportId", reportId));
        UUID actorId = currentUser.requireId();
        for (Object[] row : inspections) {
            UUID inspectionId = (UUID) row[0];
            if ("CANCELLED".equals(row[1])) continue;
            em.createNativeQuery("""
                            INSERT INTO production_fqc_cancellation_events(
                                id, inspection_id, source_report_id,
                                reason_code, idempotency_key, created_by)
                            VALUES (
                                :id, :inspectionId, :reportId,
                                'SOURCE_REPORT_REVERSED', :key, :actorId)
                            ON CONFLICT (inspection_id) DO NOTHING
                            """)
                    .setParameter("id", UUID.randomUUID())
                    .setParameter("inspectionId", inspectionId)
                    .setParameter("reportId", reportId)
                    .setParameter(
                            "key",
                            "SOURCE-REPORT-REVERSED:" + reportId)
                    .setParameter("actorId", actorId)
                    .executeUpdate();
        }
    }

    /**
     * V547：把本次登记命令下同一成品仓新建的 PENDING inspection 归入一张品质检查单。
     * 检查单只是展示/办理聚合；replay 按 (actor, 命令键, 仓库) 返回既有单。
     */
    @Override
    @Transactional(propagation = Propagation.MANDATORY)
    public InspectionSheetRef openInspectionSheet(InspectionSheetRequest request) {
        tx.bind();
        if (request == null || request.warehouseId() == null
                || request.receiverEmployeeId() == null
                || request.registrationIds().isEmpty()
                || request.registrationIds().stream().anyMatch(Objects::isNull)
                || request.warehouseName() == null
                || request.warehouseName().isBlank()
                || request.receiverName() == null
                || request.receiverName().isBlank()) {
            throw validation("品质检查单缺少仓库、收货人或登记批次");
        }
        if (!List.of("ARRIVAL_SINGLE", "ARRIVAL_BATCH")
                .contains(request.sourceKind())) {
            throw validation("品质检查单来源类型无效");
        }
        String commandKey = normalizeDecisionKey(request.commandKey());
        String remark = request.remark() == null ? null : request.remark().strip();
        if (remark != null && remark.isEmpty()) remark = null;
        if (remark != null && remark.length() > 500) {
            throw validation("备注不能超过 500 个字符");
        }
        UUID actorId = currentUser.requireId();
        List<Object[]> existing = NativeQueryResults.objectArrayRows(
                em.createNativeQuery("""
                                SELECT sheet.id, sheet.sheet_no,
                                       (SELECT COUNT(*)
                                        FROM production_fqc_inspection_sheet_items sheet_item
                                        WHERE sheet_item.sheet_id = sheet.id)
                                FROM production_fqc_inspection_sheets sheet
                                WHERE sheet.created_by = :actorId
                                  AND sheet.batch_idempotency_key = :commandKey
                                  AND sheet.warehouse_id = :warehouseId
                                """)
                        .setParameter("actorId", actorId)
                        .setParameter("commandKey", commandKey)
                        .setParameter("warehouseId", request.warehouseId()));
        if (!existing.isEmpty()) {
            Object[] row = existing.getFirst();
            return new InspectionSheetRef(
                    (UUID) row[0], string(row[1]), ((Number) row[2]).intValue());
        }
        List<Object[]> lines = NativeQueryResults.objectArrayRows(
                em.createNativeQuery("""
                                SELECT inspection.id,
                                       registration_item.registration_id,
                                       registration_item.id
                                FROM production_finished_arrival_registration_items
                                         registration_item
                                JOIN production_finished_arrival_registrations registration
                                  ON registration.id = registration_item.registration_id
                                JOIN production_daily_report_items report_item
                                  ON report_item.id = registration_item.source_report_item_id
                                JOIN production_fqc_inspections inspection
                                  ON inspection.source_report_item_id =
                                     registration_item.source_report_item_id
                                 AND inspection.status = 'PENDING'
                                WHERE registration_item.registration_id IN (:registrationIds)
                                  AND registration_item.reversal_id IS NULL
                                  AND registration.warehouse_id = :warehouseId
                                  AND NOT EXISTS (
                                      SELECT 1
                                      FROM production_fqc_inspection_sheet_items existing_item
                                      WHERE existing_item.inspection_id = inspection.id)
                                ORDER BY registration.created_at, registration.id,
                                         report_item.line_no NULLS LAST, report_item.id
                                """)
                        .setParameter("registrationIds", request.registrationIds())
                        .setParameter("warehouseId", request.warehouseId()));
        if (lines.isEmpty()) {
            throw conflict("所选登记批次没有可归入品质检查单的待检行");
        }
        UUID sheetId = UUID.randomUUID();
        String sheetNo = docNumbers.nextNumber(DocNumberPrefix.PRODUCTION_FQC_SHEET);
        em.createNativeQuery("""
                        INSERT INTO production_fqc_inspection_sheets(
                            id, sheet_no, warehouse_id, warehouse_name_snapshot,
                            receiver_employee_id, receiver_name_snapshot, remark,
                            source_kind, batch_idempotency_key, created_by)
                        VALUES (
                            :id, :sheetNo, :warehouseId, :warehouseName,
                            :receiverId, :receiverName, :remark,
                            :sourceKind, :commandKey, :actorId)
                        """)
                .setParameter("id", sheetId)
                .setParameter("sheetNo", sheetNo)
                .setParameter("warehouseId", request.warehouseId())
                .setParameter("warehouseName", request.warehouseName().strip())
                .setParameter("receiverId", request.receiverEmployeeId())
                .setParameter("receiverName", request.receiverName().strip())
                .setParameter("remark", remark)
                .setParameter("sourceKind", request.sourceKind())
                .setParameter("commandKey", commandKey)
                .setParameter("actorId", actorId)
                .executeUpdate();
        int lineNo = 0;
        for (Object[] line : lines) {
            em.createNativeQuery("""
                            INSERT INTO production_fqc_inspection_sheet_items(
                                id, sheet_id, inspection_id, registration_id,
                                registration_item_id, line_no)
                            VALUES (
                                gen_random_uuid(), :sheetId, :inspectionId,
                                :registrationId, :registrationItemId, :lineNo)
                            """)
                    .setParameter("sheetId", sheetId)
                    .setParameter("inspectionId", line[0])
                    .setParameter("registrationId", line[1])
                    .setParameter("registrationItemId", line[2])
                    .setParameter("lineNo", ++lineNo)
                    .executeUpdate();
        }
        return new InspectionSheetRef(sheetId, sheetNo, lines.size());
    }

    /**
     * V548：登记撤回事务内逐条追加 REGISTRATION_REVERSED 取消事件；数据库守卫要求
     * 该 inspection 仍 PENDING、无决定/放行/恢复授权，且撤回记录已标记其登记行。
     */
    @Override
    @Transactional(propagation = Propagation.MANDATORY)
    public int cancelForReversedRegistration(UUID registrationId, UUID reversalId) {
        tx.bind();
        if (registrationId == null || reversalId == null) {
            throw validation("登记撤回缺少登记批次或撤回记录 UUID");
        }
        List<Object[]> inspections = NativeQueryResults.objectArrayRows(
                em.createNativeQuery("""
                                SELECT inspection.id, inspection.source_report_id,
                                       inspection.status
                                FROM production_finished_arrival_registration_items
                                         registration_item
                                JOIN production_fqc_inspections inspection
                                  ON inspection.source_report_item_id =
                                     registration_item.source_report_item_id
                                 AND inspection.status <> 'CANCELLED'
                                WHERE registration_item.registration_id = :registrationId
                                  AND registration_item.reversal_id = :reversalId
                                ORDER BY inspection.id
                                FOR UPDATE OF inspection
                                """)
                        .setParameter("registrationId", registrationId)
                        .setParameter("reversalId", reversalId));
        UUID actorId = currentUser.requireId();
        for (Object[] row : inspections) {
            if (!"PENDING".equals(row[2])) {
                throw conflict("该登记批次已有品质处理，不能撤回登记");
            }
            UUID inspectionId = (UUID) row[0];
            em.createNativeQuery("""
                            INSERT INTO production_fqc_cancellation_events(
                                id, inspection_id, source_report_id,
                                reason_code, idempotency_key, created_by)
                            VALUES (
                                :id, :inspectionId, :reportId,
                                'REGISTRATION_REVERSED', :key, :actorId)
                            """)
                    .setParameter("id", UUID.randomUUID())
                    .setParameter("inspectionId", inspectionId)
                    .setParameter("reportId", row[1])
                    .setParameter(
                            "key",
                            "REGISTRATION-REVERSED:" + reversalId + ':' + inspectionId)
                    .setParameter("actorId", actorId)
                    .executeUpdate();
        }
        return inspections.size();
    }

    @Override
    @Transactional(propagation = Propagation.MANDATORY)
    public void requireInboundReleased(
            UUID sourceReportItemId,
            UUID stockDocumentItemId,
            BigDecimal quantity) {
        if (sourceReportItemId == null || stockDocumentItemId == null) {
            throw conflict("成品点收缺少报工行或库存行 UUID");
        }
        BigDecimal pendingQty = normalizeQty(
                quantity, "成品待点收数量");
        List<?> managed = em.createNativeQuery("""
                        SELECT id
                        FROM production_fqc_inspections
                        WHERE source_report_item_id = :reportItemId
                        """)
                .setParameter("reportItemId", sourceReportItemId)
                .getResultList();
        if (managed.isEmpty()) {
            recovery.requireLegacyExemption(sourceReportItemId);
            return;
        }
        List<Object[]> releases = NativeQueryResults.objectArrayRows(
                em.createNativeQuery("""
                                WITH RECURSIVE lineage(item_id) AS (
                                    SELECT CAST(:stockItemId AS uuid)
                                    UNION
                                    SELECT parent.item_id
                                    FROM lineage child
                                    JOIN LATERAL (
                                        SELECT confirmation_item.stock_document_item_id
                                                   AS item_id
                                        FROM production_finished_in_confirmation_items
                                             confirmation_item
                                        WHERE confirmation_item
                                                  .residual_stock_document_item_id =
                                              child.item_id
                                        UNION
                                        SELECT confirmation_item.stock_document_item_id
                                                   AS item_id
                                        FROM production_finished_in_confirmation_reversal_items
                                             reversal_item
                                        JOIN production_finished_in_confirmation_items
                                             confirmation_item
                                          ON confirmation_item.id =
                                             reversal_item.confirmation_item_id
                                        WHERE reversal_item
                                                  .replacement_stock_document_item_id =
                                              child.item_id
                                    ) parent ON TRUE
                                )
                                SELECT command.requested_qty,
                                       inspection.status
                                FROM lineage
                                JOIN production_fqc_release_commands command
                                  ON command.stock_document_item_id =
                                     lineage.item_id
                                JOIN production_fqc_inspections inspection
                                  ON inspection.id = command.inspection_id
                                 AND inspection.source_report_item_id =
                                     :reportItemId
                                ORDER BY command.created_at, command.id
                                LIMIT 1
                                """)
                        .setParameter(
                                "stockItemId", stockDocumentItemId)
                        .setParameter(
                                "reportItemId", sourceReportItemId));
        if (releases.size() != 1
                || "CANCELLED".equals(releases.getFirst()[1])
                || dec(releases.getFirst()[0])
                        .compareTo(pendingQty) < 0) {
            throw conflict(
                    "该成品待点收行没有足额 FQC PASS 放行来源，禁止增加库存或 iqty");
        }
    }

    @Override
    @Transactional(readOnly = true, propagation = Propagation.MANDATORY)
    public void requireLegacyExemption(UUID sourceReportItemId) {
        recovery.requireLegacyExemption(sourceReportItemId);
    }

    private BatchCommand claimPassAllBatch(
            UUID actorUserId,
            NormalizedPassAllBatch normalized) {
        UUID candidateId = UUID.randomUUID();
        int inserted = em.createNativeQuery("""
                        INSERT INTO production_fqc_pass_all_batches(
                            id, idempotency_key, request_hash,
                            inspection_count, created_by)
                        VALUES (:id, :key, :hash, :count, :actorId)
                        ON CONFLICT (created_by, idempotency_key) DO NOTHING
                        """)
                .setParameter("id", candidateId)
                .setParameter("key", normalized.idempotencyKey())
                .setParameter("hash", normalized.requestHash())
                .setParameter("count", normalized.inspectionIds().size())
                .setParameter("actorId", actorUserId)
                .executeUpdate();
        List<Object[]> rows = NativeQueryResults.objectArrayRows(
                em.createNativeQuery("""
                                SELECT id, request_hash, inspection_count
                                FROM production_fqc_pass_all_batches
                                WHERE created_by = :actorId
                                  AND idempotency_key = :key
                                FOR UPDATE
                                """)
                        .setParameter("actorId", actorUserId)
                        .setParameter("key", normalized.idempotencyKey()));
        if (rows.size() != 1) {
            throw conflict("批量全合格幂等命令未能建立，请重试");
        }
        Object[] row = rows.getFirst();
        requirePassAllReplayCompatible(
                string(row[1]),
                ((Number) row[2]).intValue(),
                normalized);
        UUID batchId = (UUID) row[0];
        if (inserted == 1 && !candidateId.equals(batchId)) {
            throw conflict("批量全合格幂等命令身份冲突，请刷新后重试");
        }
        return new BatchCommand(batchId, inserted == 0);
    }

    private BatchCommand findPassAllBatch(UUID actorUserId, NormalizedPassAllBatch normalized) {
        List<Object[]> rows = NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT id, request_hash, inspection_count FROM production_fqc_pass_all_batches
                WHERE created_by=:actorId AND idempotency_key=:key
                """).setParameter("actorId",actorUserId).setParameter("key",normalized.idempotencyKey()));
        if(rows.isEmpty())return null;
        Object[] row=rows.getFirst();
        requirePassAllReplayCompatible(string(row[1]),((Number)row[2]).intValue(),normalized);
        return new BatchCommand((UUID)row[0],true);
    }

    private PassAllBatchResult loadPassAllBatch(
            UUID batchId,
            boolean replay,
            int expectedCount) {
        List<Object[]> rows = NativeQueryResults.objectArrayRows(
                em.createNativeQuery("""
                                SELECT inspection_id, decision_event_id
                                FROM production_fqc_pass_all_batch_items
                                WHERE batch_id = :batchId
                                ORDER BY line_no
                                """)
                        .setParameter("batchId", batchId));
        if (rows.size() != expectedCount) {
            throw conflict("批量全合格历史结果不完整，请联系管理员核查");
        }
        List<PassAllBatchItem> items = rows.stream()
                .map(row -> {
                    UUID inspectionId = (UUID) row[0];
                    return new PassAllBatchItem(
                            inspectionId,
                            (UUID) row[1],
                            detailInternal(inspectionId));
                })
                .toList();
        return new PassAllBatchResult(batchId, items, replay);
    }

    /**
     * Locks every selected row before any decision write, then locks the
     * shared execution dimensions in UUID order. This is the batch form of the
     * single-item inspection -> segment -> plan-item lock hierarchy.
     */
    private Map<UUID, Object[]> lockPassAllDecisionDimensions(
            List<UUID> inspectionIds) {
        List<Object[]> rows = NativeQueryResults.objectArrayRows(
                em.createNativeQuery("""
                                SELECT id, reported_qty, passed_qty, failed_qty,
                                       status, source_report_id,
                                       source_report_item_id, report_maker_id,
                                       execution_segment_id,
                                       source_plan_item_id
                                FROM production_fqc_inspections
                                WHERE id IN (:inspectionIds)
                                ORDER BY id
                                FOR UPDATE
                                """)
                        .setParameter("inspectionIds", inspectionIds));
        if (rows.size() != inspectionIds.size()) {
            throw notFound("部分生产质检任务不存在，请刷新后重试");
        }
        List<UUID> lockedInspectionIds = rows.stream()
                .map(row -> (UUID) row[0])
                .toList();
        if (!lockedInspectionIds.equals(inspectionIds)) {
            throw conflict("生产质检批量锁定顺序异常，请刷新后重试");
        }

        List<UUID> segmentIds = rows.stream()
                .map(row -> (UUID) row[8])
                .filter(Objects::nonNull)
                .distinct()
                .sorted(UUID_ORDER)
                .toList();
        List<UUID> planItemIds = rows.stream()
                .map(row -> (UUID) row[9])
                .filter(Objects::nonNull)
                .distinct()
                .sorted(UUID_ORDER)
                .toList();
        if (segmentIds.isEmpty() || planItemIds.isEmpty()) {
            throw conflict("生产质检任务缺少执行段或计划明细，禁止批量决定");
        }
        for (UUID segmentId : segmentIds) {
            lockOne("production_execution_segments", segmentId);
        }
        for (UUID planItemId : planItemIds) {
            lockOne("production_plan_items", planItemId);
        }

        Map<UUID, Object[]> result = new LinkedHashMap<>();
        for (Object[] row : rows) {
            result.put((UUID) row[0], row);
        }
        return result;
    }

    private static void requireActiveDecisionRow(Object[] inspection) {
        if (inspection == null) throw notFound("生产质检任务不存在");
        String status = string(inspection[4]);
        BigDecimal remaining = dec(inspection[1])
                .subtract(dec(inspection[2]))
                .subtract(dec(inspection[3]));
        if (!List.of("PENDING", "PARTIAL").contains(status)
                || remaining.signum() <= 0) {
            throw conflict("所选生产质检任务包含已决定项，请刷新后重试");
        }
    }

    private InspectionView detailInternal(UUID inspectionId) {
        if (inspectionId == null) throw notFound("生产质检任务不存在");
        List<Object[]> rows = NativeQueryResults.objectArrayRows(
                em.createNativeQuery(viewSql("inspection.id = :inspectionId"))
                        .setParameter("inspectionId", inspectionId));
        if (rows.size() != 1) throw notFound("生产质检任务不存在");
        return toView(rows.getFirst());
    }

    private void requireReadable(UUID reportMakerId) {
        if (taskAccess.canAccessQualityPool()) return;
        productionAccess.requireReadable(
                reportMakerId, "生产质检任务不存在");
    }

    private Object[] lockInspection(UUID inspectionId) {
        List<Object[]> rows = NativeQueryResults.objectArrayRows(
                em.createNativeQuery("""
                                SELECT id, reported_qty, passed_qty, failed_qty,
                                       status, source_report_id,
                                       source_report_item_id, report_maker_id
                                FROM production_fqc_inspections
                                WHERE id = :inspectionId
                                FOR UPDATE
                                """)
                        .setParameter("inspectionId", inspectionId));
        if (rows.size() != 1) throw notFound("生产质检任务不存在");
        return rows.getFirst();
    }

    /** Common decision/reversal row-lock order: inspection -> segment -> plan item. */
    private void prelockDecisionDimensions(UUID inspectionId) {
        List<Object[]> dimensions = NativeQueryResults.objectArrayRows(
                em.createNativeQuery("""
                                SELECT source_report_id, execution_segment_id,
                                       source_plan_item_id
                                FROM production_fqc_inspections
                                WHERE id = :inspectionId
                                """)
                        .setParameter("inspectionId", inspectionId));
        if (dimensions.size() != 1) {
            throw notFound("生产质检任务不存在");
        }
        Object[] ids = dimensions.getFirst();
        lockOne("production_fqc_inspections", inspectionId);
        lockOne("production_execution_segments", (UUID) ids[1]);
        lockOne("production_plan_items", (UUID) ids[2]);
    }

    private void lockOne(String table, UUID id) {
        List<?> locked = em.createNativeQuery(
                        "SELECT id FROM " + table + " WHERE id = :id FOR UPDATE")
                .setParameter("id", id)
                .getResultList();
        if (locked.size() != 1) {
            throw notFound("生产质检任务不存在");
        }
    }

    private static String viewSql(String predicate) {
        return """
                SELECT inspection.id,
                       inspection.source_report_id,
                       inspection.source_report_item_id,
                       report.bill_no,
                       inspection.source_plan_item_id,
                       segment.plan_id,
                       plan.bill_no,
                       inspection.execution_segment_id,
                       inspection.execution_segment_sales_allocation_id,
                       inspection.warehouse_id,
                       inspection.goods_id, goods.code, goods.name,
                       inspection.color_id, color.name,
                       inspection.unit_id, unit.name,
                       inspection.unit_rate, inspection.reported_qty,
                       inspection.passed_qty, inspection.failed_qty,
                       COALESCE(release.authorized_qty, 0),
                       inspection.status, inspection.report_maker_id,
                       inspection.created_at, inspection.updated_at,
                       sheet.id, sheet.sheet_no, warehouse.name,
                       registration.place_snapshot, registration.remark,
                       registration.receiver_name_snapshot
                FROM production_fqc_inspections inspection
                JOIN production_daily_reports report
                  ON report.id = inspection.source_report_id
                JOIN production_execution_segments segment
                  ON segment.id = inspection.execution_segment_id
                JOIN production_plans plan ON plan.id = segment.plan_id
                JOIN goods goods ON goods.id = inspection.goods_id
                LEFT JOIN colors color ON color.id = inspection.color_id
                JOIN units unit ON unit.id = inspection.unit_id
                LEFT JOIN warehouses warehouse
                  ON warehouse.id = inspection.warehouse_id
                LEFT JOIN production_fqc_inspection_sheet_items sheet_item
                  ON sheet_item.inspection_id = inspection.id
                LEFT JOIN production_fqc_inspection_sheets sheet
                  ON sheet.id = sheet_item.sheet_id
                LEFT JOIN LATERAL (
                    SELECT registration_item.place_snapshot,
                           registration_header.remark,
                           registration_header.receiver_name_snapshot
                    FROM production_finished_arrival_registration_items
                             registration_item
                    JOIN production_finished_arrival_registrations
                             registration_header
                      ON registration_header.id = registration_item.registration_id
                    WHERE registration_item.source_report_item_id =
                          inspection.source_report_item_id
                      AND CASE
                              WHEN sheet_item.registration_item_id IS NOT NULL
                                  THEN registration_item.id =
                                       sheet_item.registration_item_id
                              ELSE registration_header.created_at
                                       <= inspection.created_at
                          END
                    ORDER BY registration_header.created_at DESC,
                             registration_header.id DESC
                    LIMIT 1
                ) registration ON TRUE
                LEFT JOIN LATERAL (
                    SELECT SUM(command.requested_qty) AS authorized_qty
                    FROM production_fqc_release_commands command
                    WHERE command.inspection_id = inspection.id
                ) release ON TRUE
                WHERE %s
                """.formatted(predicate);
    }

    private static InspectionView toView(Object[] row) {
        BigDecimal reported = dec(row[18]);
        BigDecimal passed = dec(row[19]);
        BigDecimal failed = dec(row[20]);
        return new InspectionView(
                (UUID) row[0], (UUID) row[1], (UUID) row[2], string(row[3]),
                (UUID) row[4], (UUID) row[5], string(row[6]),
                (UUID) row[7], (UUID) row[8], (UUID) row[9],
                (UUID) row[10], string(row[11]), string(row[12]),
                (UUID) row[13], string(row[14]), (UUID) row[15],
                string(row[16]), dec(row[17]), reported, passed, failed,
                reported.subtract(passed).subtract(failed), dec(row[21]),
                string(row[22]), (UUID) row[23],
                NativeValueConverters.toOffsetDateTime(row[24]),
                NativeValueConverters.toOffsetDateTime(row[25]),
                (UUID) row[26], string(row[27]), string(row[28]),
                string(row[29]), string(row[30]), string(row[31]));
    }

    private static void requireEligibleReportLine(Object[] row) {
        if (((Number) row[1]).shortValue() != 1
                || Boolean.TRUE.equals(row[4])
                || row[2] == null || row[3] == null
                || row[5] == null || row[6] == null || row[7] == null
                || row[9] == null || row[11] == null
                || dec(row[12]).signum() <= 0
                || dec(row[13]).signum() <= 0
                || Boolean.TRUE.equals(row[14])
                || row[15] == null
                || !"IN_PROGRESS".equals(row[16])
                || Boolean.TRUE.equals(row[17])
                || !"CONFIRMED".equals(row[18])
                || Boolean.TRUE.equals(row[19])) {
            throw conflict("仅已审核且精确关联 IN_PROGRESS 执行段的报工明细可登记 FQC");
        }
    }

    static NormalizedPassAllBatch normalizePassAllBatch(
            PassAllBatchRequest request) {
        if (request == null || request.inspectionIds() == null
                || request.inspectionIds().isEmpty()
                || request.inspectionIds().size() > 100) {
            throw validation("批量全合格必须包含 1-100 个生产质检任务");
        }
        HashSet<UUID> unique = new HashSet<>();
        List<UUID> inspectionIds = new ArrayList<>(
                request.inspectionIds().size());
        for (UUID inspectionId : request.inspectionIds()) {
            if (inspectionId == null) {
                throw validation("批量全合格任务 UUID 不能为空");
            }
            if (!unique.add(inspectionId)) {
                throw validation("批量全合格任务 UUID 不能重复");
            }
            inspectionIds.add(inspectionId);
        }
        inspectionIds.sort(UUID_ORDER);
        String key = normalizeDecisionKey(request.idempotencyKey());
        List<String> hashParts = new ArrayList<>(inspectionIds.size() + 1);
        hashParts.add("PRODUCTION-FQC-PASS-ALL-BATCH-V1");
        inspectionIds.stream().map(UUID::toString).forEach(hashParts::add);
        return new NormalizedPassAllBatch(
                inspectionIds, key, sha256(hashParts));
    }

    static void requirePassAllReplayCompatible(
            String existingHash,
            int existingCount,
            NormalizedPassAllBatch request) {
        if (!Objects.equals(existingHash, request.requestHash())
                || existingCount != request.inspectionIds().size()) {
            throw conflict("该批量全合格幂等键已用于不同任务集合，请刷新后重试");
        }
    }

    static String passAllChildKey(UUID batchId, UUID inspectionId) {
        if (batchId == null || inspectionId == null) {
            throw validation("批量全合格子命令缺少 UUID");
        }
        return "FQC-BATCH:" + batchId + ':' + inspectionId;
    }

    static NormalizedRequest normalizeRequest(DecisionRequest request) {
        if (request == null) throw validation("生产质检决定请求不能为空");
        String decision = normalizeDecision(request.decision());
        BigDecimal passQty = optionalQty(request.passQty(), "合格数量");
        BigDecimal failQty = optionalQty(request.failQty(), "不合格数量");
        String dispositionCode = normalizeDispositionCode(
                decision, request.dispositionCode());
        String reason = normalizeReason(decision, request.reason());
        String key = normalizeDecisionKey(request.idempotencyKey());
        String hash = sha256(List.of(
                "PRODUCTION-FQC-DECISION-V1", decision,
                passQty == null ? "AUTO" : canonicalQty(passQty),
                failQty == null ? "AUTO" : canonicalQty(failQty),
                dispositionCode == null ? "" : dispositionCode,
                reason == null ? "" : reason));
        return new NormalizedRequest(
                decision, passQty, failQty,
                dispositionCode, reason, key, hash);
    }

    static String normalizeDecision(String raw) {
        String value = raw == null ? "" : raw.strip().toUpperCase(Locale.ROOT);
        if (!List.of("PASS", "PARTIAL", "FAIL").contains(value)) {
            throw validation("质检决定仅支持 PASS、PARTIAL 或 FAIL");
        }
        return value;
    }

    static String normalizeStatusFilter(String raw) {
        String value = raw == null || raw.isBlank()
                ? "ACTIVE" : raw.strip().toUpperCase(Locale.ROOT);
        if (!List.of(
                "ACTIVE", "PENDING", "PARTIAL",
                "RESOLVED", "CANCELLED", "ALL")
                .contains(value)) {
            throw validation("生产质检状态筛选无效");
        }
        return value;
    }

    static String normalizeSheetStatusFilter(String raw) {
        String value = raw == null || raw.isBlank()
                ? "ACTIVE" : raw.strip().toUpperCase(Locale.ROOT);
        if (!List.of("ACTIVE", "CLOSED", "ALL").contains(value)) {
            throw validation("品质检查单状态筛选无效");
        }
        return value;
    }

    static SheetScope normalizeSheetScope(String raw) {
        String value = raw == null ? "" : raw.strip();
        if (value.isEmpty()) return new SheetScope(SheetScopeKind.ANY, null);
        if ("NONE".equalsIgnoreCase(value)) {
            return new SheetScope(SheetScopeKind.NONE, null);
        }
        try {
            return new SheetScope(SheetScopeKind.EXACT, UUID.fromString(value));
        } catch (IllegalArgumentException ex) {
            throw validation("检查单筛选必须是 NONE 或检查单 UUID");
        }
    }

    static BigDecimal normalizeQty(BigDecimal value, String label) {
        if (value == null || value.signum() <= 0) {
            throw validation(label + "必须大于 0");
        }
        try {
            return value.setScale(4, RoundingMode.UNNECESSARY);
        } catch (ArithmeticException ex) {
            throw validation(label + "最多保留 4 位小数");
        }
    }

    private static BigDecimal optionalQty(BigDecimal value, String label) {
        return value == null ? null : normalizeQty(value, label);
    }

    static String normalizeKey(String raw) {
        String value = raw == null ? "" : raw.strip();
        if (value.length() < 8 || value.length() > 160
                || !value.matches("[A-Za-z0-9._:-]+")) {
            throw validation("幂等键必须为 8 到 160 位字母、数字或 ._:-");
        }
        return value;
    }

    static String normalizeDecisionKey(String raw) {
        String value = normalizeKey(raw);
        if (value.length() > 128) {
            throw validation("质检决定幂等键不能超过 128 位");
        }
        return value;
    }

    private static String normalizeDispositionCode(
            String decision, String raw) {
        String value = raw == null || raw.isBlank()
                ? null : raw.strip().toUpperCase(Locale.ROOT);
        if ("PASS".equals(decision)) {
            if (value != null) throw validation("全量合格决定不能填写不良处置码");
            return null;
        }
        if (value == null
                || !List.of("REWORK", "SCRAP", "REJECT").contains(value)) {
            throw validation("不合格处置码仅支持 REWORK、SCRAP 或 REJECT");
        }
        return value;
    }

    private static String normalizeReason(String decision, String raw) {
        String value = raw == null || raw.isBlank() ? null : raw.strip();
        if (!"PASS".equals(decision) && value == null) {
            throw validation("部分合格或不合格必须填写差异原因");
        }
        if (value != null && (value.length() < 2 || value.length() > 1000)) {
            throw validation("质检原因必须为 2 到 1000 个字符");
        }
        return value;
    }

    static String sha256(List<String> parts) {
        try {
            MessageDigest digest = MessageDigest.getInstance("SHA-256");
            for (String part : parts) {
                byte[] bytes = part.getBytes(StandardCharsets.UTF_8);
                digest.update((byte) (bytes.length >>> 24));
                digest.update((byte) (bytes.length >>> 16));
                digest.update((byte) (bytes.length >>> 8));
                digest.update((byte) bytes.length);
                digest.update(bytes);
            }
            return HexFormat.of().formatHex(digest.digest());
        } catch (NoSuchAlgorithmException ex) {
            throw new IllegalStateException("SHA-256 unavailable", ex);
        }
    }

    private static String canonicalQty(BigDecimal value) {
        return value.stripTrailingZeros().toPlainString();
    }

    private static BigDecimal dec(Object value) {
        if (value == null) return BigDecimal.ZERO.setScale(4);
        return value instanceof BigDecimal decimal
                ? decimal : new BigDecimal(value.toString());
    }

    private static String string(Object value) {
        return value == null ? null : value.toString();
    }

    private static ApiException validation(String message) {
        return new ApiException(ErrorCode.VALIDATION_FAILED, message);
    }

    private static ApiException conflict(String message) {
        return new ApiException(ErrorCode.CONFLICT, message);
    }

    private static ApiException notFound(String message) {
        return new ApiException(ErrorCode.NOT_FOUND, message);
    }

    record NormalizedPassAllBatch(
            List<UUID> inspectionIds,
            String idempotencyKey,
            String requestHash) {

        NormalizedPassAllBatch {
            inspectionIds = List.copyOf(inspectionIds);
        }
    }

    record BatchCommand(UUID id, boolean replay) {
    }

    enum SheetScopeKind { ANY, NONE, EXACT }

    record SheetScope(SheetScopeKind kind, UUID sheetId) {
    }

    record NormalizedRequest(
            String decision,
            BigDecimal requestedPassQty,
            BigDecimal requestedFailQty,
            String dispositionCode,
            String reason,
            String idempotencyKey,
            String requestHash) {

        ResolvedDecision resolve(BigDecimal remaining) {
            if (remaining == null || remaining.signum() <= 0) {
                throw conflict("该生产质检任务已无待决定数量");
            }
            BigDecimal pass;
            BigDecimal fail;
            switch (decision) {
                case "PASS" -> {
                    if (requestedFailQty != null) {
                        throw validation("PASS 决定不能填写不合格数量");
                    }
                    pass = requestedPassQty == null ? remaining : requestedPassQty;
                    fail = BigDecimal.ZERO.setScale(4);
                }
                case "FAIL" -> {
                    if (requestedPassQty != null) {
                        throw validation("FAIL 决定不能填写合格数量");
                    }
                    pass = BigDecimal.ZERO.setScale(4);
                    fail = requestedFailQty == null ? remaining : requestedFailQty;
                }
                case "PARTIAL" -> {
                    if (requestedPassQty == null || requestedFailQty == null) {
                        throw validation("PARTIAL 决定必须同时填写合格和不合格数量");
                    }
                    pass = requestedPassQty;
                    fail = requestedFailQty;
                }
                default -> throw validation("质检决定无效");
            }
            if (pass.add(fail).compareTo(remaining) > 0) {
                throw conflict("质检决定数量超过待检数量 "
                        + remaining.stripTrailingZeros().toPlainString());
            }
            return new ResolvedDecision(
                    decision, pass, fail, dispositionCode, reason);
        }
    }

    record ResolvedDecision(
            String decision,
            BigDecimal passQty,
            BigDecimal failQty,
            String dispositionCode,
            String reason) {
    }
}
