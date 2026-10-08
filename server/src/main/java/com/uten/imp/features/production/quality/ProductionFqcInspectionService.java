package com.uten.imp.features.production.quality;

import com.uten.imp.application.port.BusinessEventPublisher;
import com.uten.imp.application.port.ProductionFinishedInboundReleasePort;
import com.uten.imp.application.port.ProductionPreStockedInboundPort;
import com.uten.imp.application.port.ProductionFqcRecoveryPort;
import com.uten.imp.application.port.ProductionQualityInspectionPort;
import com.uten.imp.application.port.ProductionOverLimitReleasePort;
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
import com.uten.imp.common.production.OutputLotText;
import com.uten.imp.features.production.quality.ProductionFqcContracts.InspectionLotMemberView;
import com.uten.imp.features.production.quality.ProductionFqcContracts.InspectionLotView;
import com.uten.imp.features.production.quality.ProductionFqcContracts.InspectionSheetDetailView;
import com.uten.imp.features.production.quality.ProductionFqcContracts.LotDecisionRequest;
import com.uten.imp.features.production.quality.ProductionFqcContracts.LotDecisionResult;
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
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Objects;
import java.util.UUID;

/**
 * Production FQC projection, append-only decisions, and PASS release gate.
 *
 * <p>This service owns quality decisions and exact release allocations. Physical
 * inbound and MAKE handoffs belong to the stock port in the same transaction;
 * ordinary PASS still leaves a warehouse draft, while proven pre-stocked lots
 * are accepted immediately.</p>
 *
 * <p>ADR-148 实物交接批：同一报工、同一产出批次、同一去向的各份(需求 / 计划公共 / 实际超产)是一批实物，
 * 品质按批一次判定合格与不良数量，服务端按瀑布分给各份(合格先满足需求份、不良先扣实际超产)，
 * 各份仍写自己的决定事件与恢复链；同一命令的合格放行按实物交接合成一张入库单。
 * 分成多份的批不允许逐份判定。</p>
 */
@Service
@RequiredArgsConstructor
public class ProductionFqcInspectionService
        implements ProductionQualityInspectionPort, ProductionOverLimitReleasePort {

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
     * 先入库后质检的合格自动点收(V597)。stock 侧反过来依赖本服务的放行校验
     * (ProductionQualityInspectionPort)，构造注入会成环，这里按
     * ProductionExecutionReadinessService 的既有做法用 ObjectProvider 取。
     */
    private final org.springframework.beans.factory.ObjectProvider<
            ProductionPreStockedInboundPort> stockDocs;

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
                toSheetView(heads.getFirst()), inspections, lotsOf(inspections));
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
                           -- 先入库后检(V597)：仍等结论且已上架的行数，队列按它标红。
                           COUNT(sheet_item.id) FILTER (
                               WHERE inspection.status IN ('PENDING', 'PARTIAL')
                                 AND sheet_registration.stock_in_before_inspection
                           )::integer AS pre_stocked_count,
                           string_agg(DISTINCT report.bill_no, '、') AS report_nos,
                           -- 与产成品待点收任务同一摘要口径「名称 (编号 · 颜色)」：
                           -- 一张检查单常含同名不同色的多行，只给名称必然认错货。
                           string_agg(
                               DISTINCT COALESCE(
                                   NULLIF(goods.name, ''),
                                   NULLIF(goods.code, ''),
                                   '未命名货品')
                                   || COALESCE(' (' || NULLIF(concat_ws(' · ',
                                       CASE WHEN NULLIF(goods.name, '') IS NULL
                                            THEN NULL ELSE NULLIF(goods.code, '') END,
                                       NULLIF(line_color.name, '')), '') || ')', ''),
                               '、') AS goods_summary,
                           pending.text AS pending_qty_text,
                           -- 登记库位去重清单（2026-09-17）：待检队列「库位号」列——
                           -- 成品登记时逐行必填库位，品质部按此到储放区域检验。
                           string_agg(DISTINCT NULLIF(reg_place.place_snapshot, ''), '、')
                               FILTER (WHERE inspection.status IN ('PENDING', 'PARTIAL'))
                               AS place_summary
                    FROM production_fqc_inspection_sheets sheet
                    JOIN production_fqc_inspection_sheet_items sheet_item
                      ON sheet_item.sheet_id = sheet.id
                    JOIN production_fqc_inspections inspection
                      ON inspection.id = sheet_item.inspection_id
                    JOIN production_daily_reports report
                      ON report.id = inspection.source_report_id
                    JOIN goods goods ON goods.id = inspection.goods_id
                    LEFT JOIN production_finished_arrival_registration_items reg_place
                      ON reg_place.id = sheet_item.registration_item_id
                    LEFT JOIN colors line_color
                      ON line_color.id = COALESCE(inspection.color_id, goods.color_id)
                     AND line_color.is_deleted = FALSE
                    LEFT JOIN production_finished_arrival_registrations sheet_registration
                      ON sheet_registration.id = (
                          SELECT registration_item.registration_id
                          FROM production_finished_arrival_registration_items registration_item
                          WHERE registration_item.id = sheet_item.registration_item_id)
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
                string(row[14]), string(row[12]), string(row[13]),
                activeCount > 0 ? "ACTIVE" : "CLOSED",
                NativeValueConverters.toOffsetDateTime(row[8]),
                ((Number) row[11]).intValue(),
                string(row[15]));
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

    @Transactional(readOnly = true, isolation = org.springframework.transaction.annotation.Isolation.REPEATABLE_READ,
            propagation = org.springframework.transaction.annotation.Propagation.REQUIRES_NEW)
    @PreAuthorize("hasAuthority('production_quality_inspection:view')")
    public ProductionFqcContracts.DecisionResolution decisionReceipt(UUID inspectionId, String rawKey) {
        String key = normalizeDecisionKey(rawKey);
        requireReadable(detailInternal(inspectionId).reportMakerId());
        var rows = NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT id, created_by, decision, pass_qty, fail_qty, disposition_code, reason,
                       request_hash, decided_at
                FROM production_fqc_decision_events WHERE inspection_id=:inspection AND idempotency_key=:key
                """).setParameter("inspection", inspectionId).setParameter("key", key));
        if (rows.isEmpty()) return new ProductionFqcContracts.DecisionResolution("UNKNOWN", key, null, null);
        Object[] row = rows.getFirst();
        if (row[1] == null) return new ProductionFqcContracts.DecisionResolution("LEGACY", key, null, null);
        if (!currentUser.requireId().equals(row[1])) {
            return new ProductionFqcContracts.DecisionResolution("UNKNOWN", key, null, null);
        }
        // Read current projection after observing the committed event, never a pre-commit stale detail.
        InspectionView view = detailInternal(inspectionId);
        requireReadable(view.reportMakerId());
        return new ProductionFqcContracts.DecisionResolution("COMMITTED", key,
                new DecisionResult((UUID) row[0], view, true),
                new ProductionFqcContracts.DecisionFacts(string(row[2]), dec(row[3]), dec(row[4]),
                        string(row[5]), string(row[6]), string(row[7]), NativeValueConverters.toOffsetDateTime(row[8])));
    }

    @Transactional(readOnly = true, isolation = org.springframework.transaction.annotation.Isolation.REPEATABLE_READ,
            propagation = org.springframework.transaction.annotation.Propagation.REQUIRES_NEW)
    @PreAuthorize("hasAuthority('production_quality_inspection:view')")
    public ProductionFqcContracts.PassAllResolution passAllReceipt(String rawKey) {
        String key = normalizeDecisionKey(rawKey);
        var rows = NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT id, inspection_count FROM production_fqc_pass_all_batches
                WHERE created_by=:actor AND idempotency_key=:key
                """).setParameter("actor", currentUser.requireId()).setParameter("key", key));
        if (rows.isEmpty()) return new ProductionFqcContracts.PassAllResolution("UNKNOWN", key, null);
        Object[] row = rows.getFirst();
        PassAllBatchResult result = loadPassAllBatch((UUID) row[0], true);
        for (var item : result.items()) requireReadable(item.inspection().reportMakerId());
        return new ProductionFqcContracts.PassAllResolution("COMMITTED", key, result);
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
        requireSingleSliceLot(inspectionId);

        return decideLocked(inspectionId, normalized, inspection, sourceGuard::verifyUnchanged);
    }

    /**
     * 整批判定(ADR-148)：一批实物一次判合格与不良数量，服务端按瀑布分给批内各份，
     * 每份写自己的决定事件(复用恢复/补产链)，合格放行合成一张入库单。
     * 同一操作人 + 同一幂等键 + 同一内容重放原结果；换了内容 409。
     */
    @Transactional
    @PreAuthorize("hasAuthority('production_quality_inspection:view')"
            + " and hasAuthority('production_quality_inspection:approve')")
    public LotDecisionResult decideLot(UUID lotId, LotDecisionRequest request) {
        tx.bind();
        taskAccess.requireQualityPool("当前账号不在品质任务组织范围");
        NormalizedLotDecision normalized = normalizeLotDecision(lotId, request);
        UUID actorUserId = currentUser.requireId();
        em.createNativeQuery("SELECT pg_advisory_xact_lock(hashtextextended(:key, 801))")
                .setParameter("key", "FQC-LOT-DECISION:" + actorUserId + ':' + normalized.idempotencyKey())
                .getSingleResult();
        LotCommandRef existing = findLotCommand(actorUserId, normalized.idempotencyKey());
        if (existing != null) {
            if (!existing.lotId().equals(lotId) || !existing.requestHash().equals(normalized.requestHash())) {
                throw conflict("同一防重复提交标识已用于不同的批或不同数量，请刷新后重试");
            }
            return new LotDecisionResult(existing.id(), requireLotView(lotId), true);
        }
        List<LotMemberRef> members = lotMembers(List.of(lotId)).get(lotId);
        if (members == null || members.isEmpty()) {
            throw notFound("这一批实物没有待检任务，请刷新后重试");
        }
        List<UUID> inspectionIds = members.stream().map(LotMemberRef::inspectionId)
                .sorted(UUID_ORDER).toList();
        var sourceGuard = mutationFootprint.beginInspections(inspectionIds);
        Map<UUID, Object[]> locked = lockPassAllDecisionDimensions(inspectionIds);
        sourceGuard.verifyUnchanged();
        LotWrite write = writeLotDecisionLocked(lotId, members, locked, normalized.passQty(),
                normalized.failQty(), normalized.dispositionCode(), normalized.reason(),
                normalized.idempotencyKey(), normalized.requestHash(), null);
        stockDocs.getObject().withBatch(inboundBatch -> releaseLocked(write.releases(), inboundBatch));
        for (InspectionView view : detailViews(inspectionIds).values()) publishResolved(view);
        return new LotDecisionResult(write.commandId(), requireLotView(lotId), false);
    }

    /** 当前可见的一批实物(检查单页刷新后重读)。 */
    @Transactional(readOnly = true)
    @PreAuthorize("hasAuthority('production_quality_inspection:view')")
    public InspectionLotView lotDetail(UUID lotId) {
        InspectionLotView view = requireLotView(lotId);
        for (InspectionLotMemberView member : view.members()) {
            requireReadable(detailInternal(member.inspectionId()).reportMakerId());
        }
        return view;
    }

    private InspectionLotView requireLotView(UUID lotId) {
        List<InspectionView> views = NativeQueryResults.objectArrayRows(em.createNativeQuery(viewSql(
                        "source_item.output_lot_id = :lotId AND inspection.status <> 'CANCELLED'")
                        + " ORDER BY inspection.id")
                .setParameter("lotId", lotId)).stream()
                .map(ProductionFqcInspectionService::toView)
                .toList();
        if (views.isEmpty()) throw notFound("这一批实物没有待检任务");
        return lotsOf(views).getFirst();
    }

    /**
     * 逐份决定只用于单份的批；分成需求 / 公共 / 超产几份的批必须整批判定(数据库守卫兜底)。
     */
    private void requireSingleSliceLot(UUID inspectionId) {
        Number members = (Number) em.createNativeQuery("""
                        SELECT COUNT(*)
                        FROM production_fqc_inspections target
                        JOIN production_daily_report_items target_item
                          ON target_item.id = target.source_report_item_id
                        JOIN production_daily_report_items sibling_item
                          ON sibling_item.output_lot_id = target_item.output_lot_id
                        JOIN production_fqc_inspections sibling
                          ON sibling.source_report_item_id = sibling_item.id
                         AND sibling.status <> 'CANCELLED'
                        WHERE target.id = :inspectionId
                        """)
                .setParameter("inspectionId", inspectionId)
                .getSingleResult();
        if (members != null && members.longValue() > 1) {
            throw validation("这批实物分成了需求、计划公共备货或实际超产几份，请在检查单里按整批判定合格与不良数量");
        }
    }

    /**
     * Atomically resolves every selected physical lot as PASS for its current
     * remaining quantity. The client supplies identities only; a selected slice
     * stands for its whole handoff lot (ADR-148), and all quantities are derived
     * after the complete lock set has been acquired. One lot decision command per
     * lot; all PASS releases of the command share handoff documents.
     */
    @Transactional
    @PreAuthorize("hasAuthority('production_quality_inspection:view')"
            + " and hasAuthority('production_quality_inspection:approve')")
    public PassAllBatchResult passAll(PassAllBatchRequest request) {
        tx.bind();
        taskAccess.requireQualityPool("当前账号不在品质任务组织范围");
        NormalizedPassAllBatch normalized = normalizePassAllBatch(request);
        UUID actorUserId = currentUser.requireId();
        // 选中一份 = 选中它所在的整批实物(批内各份同时判定)；批的成员身份不随状态变化。
        Map<UUID, List<LotMemberRef>> lots = lotMembers(lotsOfInspections(normalized.inspectionIds()));
        List<UUID> expanded = lots.values().stream().flatMap(List::stream)
                .map(LotMemberRef::inspectionId).distinct().sorted(UUID_ORDER).toList();
        var sourceGuard = mutationFootprint.beginInspections(expanded.isEmpty() ? normalized.inspectionIds() : expanded);
        BatchCommand existing = findPassAllBatch(actorUserId, normalized);
        if (existing != null) return loadPassAllBatch(existing.id(), true);
        if (expanded.isEmpty() || !expanded.containsAll(normalized.inspectionIds())) {
            throw notFound("部分生产质检任务不存在，请刷新后重试");
        }
        Map<UUID, Object[]> locked = lockPassAllDecisionDimensions(expanded);
        for (UUID inspectionId : normalized.inspectionIds()) {
            requireActiveDecisionRow(locked.get(inspectionId));
        }
        sourceGuard.verifyUnchanged();
        List<UUID> active = expanded.stream()
                .filter(id -> remainingOf(locked.get(id)).signum() > 0
                        && List.of("PENDING", "PARTIAL").contains(string(locked.get(id)[4])))
                .toList();
        if (active.size() > 100) {
            throw validation("一次全合格最多 100 份待检，请分批处理");
        }
        BatchCommand batch = claimPassAllBatch(actorUserId, normalized, active.size());
        if (batch.replay()) return loadPassAllBatch(batch.id(), true);

        Map<UUID, UUID> decisions = new LinkedHashMap<>();
        List<PendingRelease> releases = new ArrayList<>();
        for (Map.Entry<UUID, List<LotMemberRef>> lot : lots.entrySet()) {
            BigDecimal remaining = BigDecimal.ZERO;
            for (LotMemberRef member : lot.getValue()) {
                Object[] row = locked.get(member.inspectionId());
                if (List.of("PENDING", "PARTIAL").contains(string(row[4]))) {
                    remaining = remaining.add(remainingOf(row));
                }
            }
            if (remaining.signum() <= 0) continue;
            String lotKey = "FQC-BATCH-LOT:" + batch.id() + ':' + lot.getKey();
            String lotHash = sha256(List.of("PRODUCTION-FQC-LOT-DECISION-V1", lot.getKey().toString(),
                    canonicalQty(remaining), "0", "", ""));
            LotWrite write = writeLotDecisionLocked(lot.getKey(), lot.getValue(), locked,
                    remaining, BigDecimal.ZERO.setScale(4), null, null, lotKey, lotHash, batch.id());
            decisions.putAll(write.decisions());
            releases.addAll(write.releases());
        }
        int lineNo = 0;
        for (UUID inspectionId : active) {
            UUID decisionEventId = decisions.get(inspectionId);
            if (decisionEventId == null) {
                throw conflict("批量全合格未能覆盖所选的全部待检份，请刷新后重试");
            }
            em.createNativeQuery("""
                            INSERT INTO production_fqc_pass_all_batch_items(
                                batch_id, inspection_id, decision_event_id,
                                line_no)
                            VALUES (:batchId, :inspectionId, :decisionEventId,
                                    :lineNo)
                            """)
                    .setParameter("batchId", batch.id())
                    .setParameter("inspectionId", inspectionId)
                    .setParameter("decisionEventId", decisionEventId)
                    .setParameter("lineNo", ++lineNo)
                    .executeUpdate();
        }
        stockDocs.getObject().withBatch(inboundBatch -> releaseLocked(releases, inboundBatch));
        Map<UUID, InspectionView> views = detailViews(active);
        List<PassAllBatchItem> items = new ArrayList<>(active.size());
        // Durable outbox rows become consumable only after commit. Each item's
        // RELEASED still precedes its RESOLVED; no consumer observes this batch
        // between its individual decisions and the final complete view query.
        for (UUID inspectionId : active) {
            InspectionView view = views.get(inspectionId);
            publishResolved(view);
            items.add(new PassAllBatchItem(inspectionId, decisions.get(inspectionId), view));
        }
        return new PassAllBatchResult(batch.id(), items, false);
    }

    /**
     * 车间直送的班组自检：建一条 WORKSHOP_SELF 检验，锚点是本车间线边仓(V584/V585)。
     *
     * <p>与仓库送检登记那条链的唯一差别是「入哪个仓这件事由谁证明」——ARRIVAL 认仓库的
     * 送检登记行，WORKSHOP_SELF 认车间的直送行，数据库守卫
     * {@code fn_guard_production_fqc_inspection} 按 kind 分流校验。
     *
     * <p>权限与车间归属由调用方(车间直送服务，{@code production_direct_transfer:approve})
     * 校验完毕；本方法只做「这条报工行确实是 WORKSHOP 去向且尚未检验过」的前置。
     */
    @Transactional(propagation = Propagation.MANDATORY)
    public UUID registerWorkshopSelfInspection(
            UUID reportId, UUID reportItemId, UUID lineSideWarehouseId) {
        if (reportId == null || reportItemId == null || lineSideWarehouseId == null) {
            throw validation("班组自检缺少报工行或内料仓");
        }
        List<Object[]> rows = NativeQueryResults.objectArrayRows(
                em.createNativeQuery("""
                                SELECT report.id, report.maker_id,
                                       item.id, item.plan_item_id,
                                       item.execution_segment_id,
                                       item.execution_segment_sales_allocation_id,
                                       item.goods_id, item.color_id, item.unit_id,
                                       COALESCE(item.unit_rate, 1), item.qty
                                FROM production_daily_reports report
                                JOIN production_daily_report_items item
                                  ON item.report_id = report.id
                                 AND item.is_deleted = FALSE
                                WHERE report.id = :reportId
                                  AND item.id = :reportItemId
                                  AND report.status = 1
                                  AND report.is_deleted = FALSE
                                  AND report.maker_id IS NOT NULL
                                  AND item.destination = 'WORKSHOP'
                                  AND item.execution_segment_id IS NOT NULL
                                FOR UPDATE OF report, item
                                """)
                        .setParameter("reportId", reportId)
                        .setParameter("reportItemId", reportItemId));
        if (rows.size() != 1) {
            throw conflict("班组自检的报工行已变化或不是转送车间的行");
        }
        Object[] row = rows.getFirst();
        UUID inspectionId = UUID.randomUUID();
        em.createNativeQuery("""
                        INSERT INTO production_fqc_inspections(
                            id, source_report_id, source_report_item_id,
                            source_plan_item_id, execution_segment_id,
                            execution_segment_sales_allocation_id,
                            warehouse_id, goods_id, color_id, unit_id,
                            unit_rate, reported_qty, report_maker_id,
                            inspection_kind, created_by)
                        VALUES (
                            :id, :reportId, :reportItemId,
                            :planItemId, :segmentId, :salesAllocationId,
                            :warehouseId, :goodsId, :colorId, :unitId,
                            :unitRate, :reportedQty, :makerId,
                            'WORKSHOP_SELF', :actorId)
                        """)
                .setParameter("id", inspectionId)
                .setParameter("reportId", row[0])
                .setParameter("reportItemId", row[2])
                .setParameter("planItemId", row[3])
                .setParameter("segmentId", row[4])
                .setParameter("salesAllocationId", row[5])
                .setParameter("warehouseId", lineSideWarehouseId)
                .setParameter("goodsId", row[6])
                .setParameter("colorId", row[7])
                .setParameter("unitId", row[8])
                .setParameter("unitRate", dec(row[9]))
                .setParameter("reportedQty", dec(row[10]))
                .setParameter("makerId", row[1])
                .setParameter("actorId", currentUser.requireId())
                .executeUpdate();
        return inspectionId;
    }

    /**
     * 班组判整批合格并放行，返回由放行生成的成品入库草稿 UUID(入线边仓)。
     *
     * <p>不走 {@link #decide} 的原因不是绕过校验，而是这条链的责任人不同：
     * decide 要求品质部的 {@code production_quality_inspection:approve} 与品质组织范围，
     * 而车间直送的判定人就是车间班组，由 {@code production_direct_transfer:approve} 授权。
     * 记录的决定事实、放行命令、恢复授权与成本覆盖判定与品质部那条链**完全同表同形**，
     * {@code decided_by_employee_id} 留的是自检人——出了问题追得到人。
     *
     * <p>品质部对 WORKSHOP_SELF 检验保留事后翻案权：放行未被消费前仍可追加 FAIL 决定。
     */
    @Transactional(propagation = Propagation.MANDATORY)
    public UUID passWorkshopSelfInspection(UUID inspectionId, String idempotencyKey) {
        prelockDecisionDimensions(inspectionId);
        Object[] inspection = lockInspection(inspectionId);
        NormalizedRequest normalized = normalizeRequest(new DecisionRequest(
                "PASS", null, null, null, "车间内部直送 · 班组自检合格", idempotencyKey));
        DecisionWrite decision = writeDecisionLocked(inspectionId, normalized, inspection, () -> { }, null);
        if (decision.release() != null) releaseLocked(List.of(decision.release()), null);
        List<UUID> documents = NativeQueryResults.typedRows(em.createNativeQuery("""
                        SELECT DISTINCT item.doc_id
                        FROM stock_document_items item
                        JOIN stock_documents document
                          ON document.id = item.doc_id
                         AND document.doc_type = 'FINISHED_IN'
                         AND document.is_deleted = FALSE
                         AND document.status = 0
                        WHERE item.source_daily_report_item_id = :reportItemId
                          AND item.is_deleted = FALSE
                        """).setParameter("reportItemId", inspection[6]), UUID.class);
        if (documents.size() != 1) {
            throw conflict("班组自检放行未能唯一确定入库任务，请刷新后重试");
        }
        return documents.getFirst();
    }

    private DecisionResult decideLocked(
            UUID inspectionId,
            NormalizedRequest normalized,
            Object[] inspection,
            Runnable verifyBeforeFirstWrite) {
        DecisionWrite decision = writeDecisionLocked(inspectionId, normalized, inspection, verifyBeforeFirstWrite, null);
        if (decision.release() != null) releaseLocked(List.of(decision.release()), null);
        InspectionView view = detailInternal(inspectionId);
        if (!decision.replay()) publishResolved(view);
        return new DecisionResult(decision.decisionEventId(), view, decision.replay());
    }

    /**
     * Writes one decision event and its failure adjustment. PASS quantity is returned as a
     * pending release: the caller releases every PASS of its command together, so one physical
     * handoff becomes one warehouse document (ADR-148).
     */
    private DecisionWrite writeDecisionLocked(
            UUID inspectionId,
            NormalizedRequest normalized,
            Object[] inspection,
            Runnable verifyBeforeFirstWrite,
            UUID lotCommandId) {

        List<Object[]> replay = NativeQueryResults.objectArrayRows(
                em.createNativeQuery("""
                                SELECT id, request_hash, created_by
                                FROM production_fqc_decision_events
                                WHERE inspection_id = :inspectionId
                                  AND idempotency_key = :key
                                """)
                        .setParameter("inspectionId", inspectionId)
                        .setParameter("key", normalized.idempotencyKey()));
        if (!replay.isEmpty()) {
            if (replay.getFirst().length < 3 || replay.getFirst()[2] == null
                    || !currentUser.requireId().equals(replay.getFirst()[2])) {
                throw conflict("这个防重复提交标识的原操作人核对不上，请先查看原结果，不能重复提交");
            }
            if (!Objects.equals(replay.getFirst()[1], normalized.requestHash())) {
                throw conflict("同一防重复提交标识已用于不同的质检决定，请刷新后重试");
            }
            return new DecisionWrite((UUID) replay.getFirst()[0], true, null);
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
                            request_hash, decided_by_employee_id, created_by,
                            lot_command_id)
                        VALUES (
                            :id, :inspectionId, :decision, :passQty, :failQty,
                            :dispositionCode, :reason, :key,
                            :requestHash, :employeeId, :userId,
                            CAST(:lotCommandId AS uuid))
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
                .setParameter("lotCommandId", lotCommandId == null ? null : lotCommandId.toString())
                .executeUpdate();

        if (resolved.failQty().signum() > 0) {
            recovery.applyFailureAdjustment(
                    inspectionId,
                    eventId,
                    resolved.failQty(),
                    resolved.dispositionCode());
        }
        PendingRelease release = resolved.passQty().signum() > 0
                ? new PendingRelease(inspectionId, eventId, (UUID) inspection[5],
                        (UUID) inspection[6], resolved.passQty(), false)
                : null;
        return new DecisionWrite(eventId, false, release);
    }

    /**
     * 一个命令的全部合格放行一起建单(ADR-148)：同一实物交接一张入库单，逐份精确放行分配；
     * 先入库后质检的单在本单全部放行分配落定后各自动点收一次。
     */
    private void releaseLocked(
            List<PendingRelease> releases,
            ProductionPreStockedInboundPort.Batch inboundBatch) {
        if (releases.isEmpty()) return;
        // Quality and planning are independent facts. The whole lot can be inspected,
        // while only its authorized slices become available to warehouse receiving.
        @SuppressWarnings("unchecked")
        List<UUID> authorized = em.createNativeQuery("""
                        SELECT id FROM production_daily_report_items
                        WHERE id IN (:items) AND fn_daily_report_output_authorized(id)
                        """)
                .setParameter("items", releases.stream().map(PendingRelease::sourceReportItemId).distinct().toList())
                .getResultList();
        releases = releases.stream().filter(release -> authorized.contains(release.sourceReportItemId())).toList();
        if (releases.isEmpty()) return;
        Map<UUID, ProductionFinishedInboundReleasePort.CreatedDraft> drafts =
                finishedInbound.createReleasedDrafts(releases.stream()
                        .map(release -> new ProductionFinishedInboundReleasePort.ReleaseRequest(
                                release.inspectionId(), release.decisionEventId(),
                                release.sourceReportId(), release.sourceReportItemId(),
                                release.passQty(), release.requireFreshReceipt()))
                        .toList());
        Map<UUID, UUID> autoConfirm = new LinkedHashMap<>();
        for (PendingRelease release : releases) {
            ProductionFinishedInboundReleasePort.CreatedDraft draft = drafts.get(release.decisionEventId());
            if (draft == null) {
                throw conflict("FQC 合格放行未能生成对应的入库明细，请刷新后重试");
            }
            allocateReleasedQuantity(
                    release.sourceReportItemId(),
                    draft.stockDocumentItemId(),
                    release.passQty(),
                    "FQC-FINISHED-IN:" + release.decisionEventId());
            if (draft.preStockedAutoConfirm()) {
                autoConfirm.putIfAbsent(draft.stockDocumentId(), release.decisionEventId());
            }
            Map<String, Object> payload = new LinkedHashMap<>();
            payload.put("inspectionId", release.inspectionId());
            payload.put("decisionEventId", release.decisionEventId());
            payload.put("sourceReportId", release.sourceReportId());
            payload.put("sourceReportItemId", release.sourceReportItemId());
            payload.put("passQty", release.passQty());
            payload.put("stockDocumentId", draft.stockDocumentId());
            payload.put("stockDocumentItemId", draft.stockDocumentItemId());
            outbox.publishOnce(
                    EVENT_RELEASED,
                    "PRODUCTION_FQC_INSPECTION",
                    release.inspectionId(),
                    payload,
                    EVENT_RELEASED + ':' + release.decisionEventId());
        }
        // V597 先入库后质检：仓库登记时已按成品仓 + 库位上架并承诺全量入库，
        // 合格就在同一事务里按那个位置自动点收，仓库不再收到「待点收」任务。
        // 放行分配必须先落(放行命令守卫要求单据仍是草稿)，再自动点收推到已审核。
        for (Map.Entry<UUID, UUID> document : autoConfirm.entrySet()) {
            String key = "FQC-PRESTOCK:" + document.getValue();
            if (inboundBatch == null) {
                stockDocs.getObject().confirmPreStockedFinishedInbound(document.getKey(), key);
            } else {
                inboundBatch.confirm(document.getKey(), key);
            }
        }
    }

    @Override
    @Transactional(propagation = Propagation.MANDATORY)
    public void releasePendingForReportItem(UUID sourceReportItemId) {
        tx.bind();
        if (sourceReportItemId == null) throw validation("超限放行缺少原报工明细");
        if (!Boolean.TRUE.equals(em.createNativeQuery("SELECT fn_daily_report_output_authorized(:item)")
                .setParameter("item", sourceReportItemId).getSingleResult())) {
            throw conflict("本批超限产出尚未批准接收，不能生成入库任务");
        }
        @SuppressWarnings("unchecked")
        List<UUID> inspectionIds = em.createNativeQuery("""
                        SELECT id FROM production_fqc_inspections
                        WHERE fn_daily_report_output_authorization_root(source_report_item_id)=:item
                            AND status<>'CANCELLED' ORDER BY id
                        """).setParameter("item", sourceReportItemId).getResultList();
        if (inspectionIds.isEmpty()) return;
        inspectionIds.forEach(mutationFootprint::requireInspection);
        lockPassAllDecisionDimensions(inspectionIds);
        List<Object[]> pending = NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                        SELECT inspection.id,inspection.source_report_id,inspection.source_report_item_id,
                               decision.id, decision.pass_qty-COALESCE(SUM(allocation.qty),0)
                        FROM production_fqc_decision_events decision
                        JOIN production_fqc_inspections inspection ON inspection.id=decision.inspection_id
                        JOIN production_daily_reports report ON report.id=inspection.source_report_id
                        LEFT JOIN production_fqc_release_allocations allocation ON allocation.decision_event_id=decision.id
                        WHERE decision.inspection_id IN (:inspections) AND inspection.status<>'CANCELLED'
                          AND report.status=1 AND NOT report.is_deleted AND decision.pass_qty>0
                        GROUP BY inspection.id,inspection.source_report_id,inspection.source_report_item_id,
                                 decision.id,decision.pass_qty,decision.decided_at
                        HAVING decision.pass_qty-COALESCE(SUM(allocation.qty),0)>0
                        ORDER BY decision.decided_at,decision.id
                        """).setParameter("inspections", inspectionIds));
        List<PendingRelease> releases = pending.stream().map(row -> new PendingRelease(
                (UUID) row[0], (UUID) row[3], (UUID) row[1], (UUID) row[2], dec(row[4]), true)).toList();
        releaseLocked(releases, null);
    }

    /**
     * 一批的整批决定：插入命令，按瀑布(合格升序、不良降序)分给各份，逐份写决定事件；
     * 合格放行留给调用方与同命令的其它批一起建单。数据库延迟约束按同一瀑布重算核对。
     */
    private LotWrite writeLotDecisionLocked(
            UUID lotId,
            List<LotMemberRef> members,
            Map<UUID, Object[]> locked,
            BigDecimal passQty,
            BigDecimal failQty,
            String dispositionCode,
            String reason,
            String idempotencyKey,
            String requestHash,
            UUID passAllBatchId) {
        List<BigDecimal> remaining = new ArrayList<>(members.size());
        BigDecimal total = BigDecimal.ZERO;
        UUID reportId = null;
        for (LotMemberRef member : members) {
            Object[] row = locked.get(member.inspectionId());
            if (row == null) throw conflict("这一批实物的待检任务已变化，请刷新后重试");
            BigDecimal left = List.of("PENDING", "PARTIAL").contains(string(row[4]))
                    ? remainingOf(row) : BigDecimal.ZERO.setScale(4);
            remaining.add(left);
            total = total.add(left);
            reportId = (UUID) row[5];
        }
        if (total.signum() <= 0) {
            throw conflict("这一批实物已全部判定，请刷新后查看结果");
        }
        if (passQty.add(failQty).compareTo(total) > 0) {
            throw conflict("合格 " + OutputLotText.plain(passQty) + " 加不良 " + OutputLotText.plain(failQty)
                    + " 超过这一批还没判定的数量 " + OutputLotText.plain(total));
        }
        List<BigDecimal> pass = waterfallPass(remaining, passQty);
        List<BigDecimal> fail = waterfallFail(remaining, pass, failQty);

        UUID commandId = UUID.randomUUID();
        em.createNativeQuery("""
                        INSERT INTO production_fqc_lot_decision_commands(
                            id, lot_id, source_report_id, pass_qty, fail_qty,
                            disposition_code, reason, idempotency_key, request_hash,
                            pass_all_batch_id, created_by)
                        VALUES (
                            :id, :lotId, :reportId, :passQty, :failQty,
                            :dispositionCode, :reason, :key, :hash,
                            CAST(:batchId AS uuid), :actorId)
                        """)
                .setParameter("id", commandId)
                .setParameter("lotId", lotId)
                .setParameter("reportId", reportId)
                .setParameter("passQty", passQty)
                .setParameter("failQty", failQty)
                .setParameter("dispositionCode", dispositionCode)
                .setParameter("reason", reason)
                .setParameter("key", idempotencyKey)
                .setParameter("hash", requestHash)
                .setParameter("batchId", passAllBatchId == null ? null : passAllBatchId.toString())
                .setParameter("actorId", currentUser.requireId())
                .executeUpdate();

        Map<UUID, UUID> decisions = new LinkedHashMap<>();
        List<PendingRelease> releases = new ArrayList<>();
        for (int index = 0; index < members.size(); index++) {
            BigDecimal memberPass = pass.get(index);
            BigDecimal memberFail = fail.get(index);
            if (memberPass.signum() == 0 && memberFail.signum() == 0) continue;
            UUID inspectionId = members.get(index).inspectionId();
            String decision = memberFail.signum() == 0 ? "PASS" : memberPass.signum() == 0 ? "FAIL" : "PARTIAL";
            NormalizedRequest child = normalizeRequest(new DecisionRequest(
                    decision,
                    "FAIL".equals(decision) ? null : memberPass,
                    "PASS".equals(decision) ? null : memberFail,
                    "PASS".equals(decision) ? null : dispositionCode,
                    reason,
                    "FQC-LOT:" + commandId + ':' + inspectionId));
            DecisionWrite write = writeDecisionLocked(inspectionId, child, locked.get(inspectionId),
                    () -> { /* the whole lot was verified before its first write */ }, commandId);
            if (write.replay()) {
                throw conflict("整批判定子结果已存在，请刷新后查看结果");
            }
            decisions.put(inspectionId, write.decisionEventId());
            if (write.release() != null) releases.add(write.release());
        }
        return new LotWrite(commandId, decisions, releases);
    }

    /** 合格按批内顺序(需求 -> 计划公共 -> 实际超产)依次填满。 */
    static List<BigDecimal> waterfallPass(List<BigDecimal> remaining, BigDecimal passQty) {
        List<BigDecimal> result = new ArrayList<>(remaining.size());
        BigDecimal left = passQty;
        for (BigDecimal capacity : remaining) {
            BigDecimal take = capacity.min(left).max(BigDecimal.ZERO);
            result.add(take.setScale(4, RoundingMode.UNNECESSARY));
            left = left.subtract(take);
        }
        if (left.signum() != 0) throw conflict("合格数量超过这一批还没判定的数量");
        return result;
    }

    /** 不良按批内倒序(实际超产 -> 计划公共 -> 需求)先扣，只扣合格分剩下的部分。 */
    static List<BigDecimal> waterfallFail(List<BigDecimal> remaining, List<BigDecimal> pass, BigDecimal failQty) {
        BigDecimal[] result = new BigDecimal[remaining.size()];
        BigDecimal left = failQty;
        for (int index = remaining.size() - 1; index >= 0; index--) {
            BigDecimal take = remaining.get(index).subtract(pass.get(index)).min(left).max(BigDecimal.ZERO);
            result[index] = take.setScale(4, RoundingMode.UNNECESSARY);
            left = left.subtract(take);
        }
        if (left.signum() != 0) throw conflict("不良数量超过这一批还没判定的数量");
        return List.of(result);
    }

    /** 所选检验所在的批(选中一份 = 选中它的整批)。 */
    private List<UUID> lotsOfInspections(List<UUID> inspectionIds) {
        return NativeQueryResults.typedRows(em.createNativeQuery("""
                        SELECT DISTINCT source_item.output_lot_id
                        FROM production_fqc_inspections inspection
                        JOIN production_daily_report_items source_item
                          ON source_item.id = inspection.source_report_item_id
                        WHERE inspection.id IN (:ids)
                        """).setParameter("ids", inspectionIds), UUID.class);
    }

    /** 每批未取消的各份(按批内归属优先级排好)。 */
    private Map<UUID, List<LotMemberRef>> lotMembers(List<UUID> lotIds) {
        Map<UUID, List<LotMemberRef>> result = new LinkedHashMap<>();
        if (lotIds.isEmpty()) return result;
        for (Object[] row : NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                        SELECT source_item.output_lot_id, inspection.id
                        FROM production_daily_report_items source_item
                        JOIN production_fqc_inspections inspection
                          ON inspection.source_report_item_id = source_item.id
                         AND inspection.status <> 'CANCELLED'
                        WHERE source_item.output_lot_id IN (:lotIds)
                          AND NOT source_item.is_deleted
                        ORDER BY source_item.output_lot_id,
                                 fn_daily_report_output_slice_rank(
                                     source_item.is_public_output, source_item.is_actual_surplus, source_item.is_over_limit),
                                 source_item.line_no NULLS LAST, source_item.id
                        """).setParameter("lotIds", lotIds))) {
            result.computeIfAbsent((UUID) row[0], ignored -> new ArrayList<>())
                    .add(new LotMemberRef((UUID) row[1]));
        }
        return result;
    }

    private LotCommandRef findLotCommand(UUID actorUserId, String key) {
        List<Object[]> rows = NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                        SELECT id, lot_id, request_hash
                        FROM production_fqc_lot_decision_commands
                        WHERE created_by = :actorId AND idempotency_key = :key
                        """).setParameter("actorId", actorUserId).setParameter("key", key));
        if (rows.isEmpty()) return null;
        Object[] row = rows.getFirst();
        return new LotCommandRef((UUID) row[0], (UUID) row[1], string(row[2]).strip());
    }

    private static BigDecimal remainingOf(Object[] inspection) {
        return dec(inspection[1]).subtract(dec(inspection[2])).subtract(dec(inspection[3]));
    }

    private record DecisionWrite(UUID decisionEventId, boolean replay, PendingRelease release) {}

    private record PendingRelease(UUID inspectionId, UUID decisionEventId, UUID sourceReportId,
                                  UUID sourceReportItemId, BigDecimal passQty, boolean requireFreshReceipt) {}

    private record LotWrite(UUID commandId, Map<UUID, UUID> decisions, List<PendingRelease> releases) {}

    private record LotMemberRef(UUID inspectionId) {}

    private record LotCommandRef(UUID id, UUID lotId, String requestHash) {}

    private void publishResolved(InspectionView result) {
        if ("RESOLVED".equals(result.status())) {
            outbox.publishOnce(
                    EVENT_RESOLVED,
                    "PRODUCTION_FQC_INSPECTION",
                    result.id(),
                    Map.of(
                            "sourceReportId", result.sourceReportId(),
                            "sourceReportItemId", result.sourceReportItemId(),
                            "passedQty", result.passedQty(),
                            "failedQty", result.failedQty()),
                    EVENT_RESOLVED + ':' + result.id());
        }
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
                throw conflict("同一防重复提交标识已用于不同的 FQC 入库请求，请刷新后重试");
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
            throw validation("品质检查单来源类型不正确");
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
            NormalizedPassAllBatch normalized,
            int inspectionCount) {
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
                .setParameter("count", inspectionCount)
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
            throw conflict("批量全合格的处理记录未能建立，请重试");
        }
        Object[] row = rows.getFirst();
        requirePassAllReplayCompatible(string(row[1]), normalized);
        UUID batchId = (UUID) row[0];
        if (inserted == 1 && !candidateId.equals(batchId)) {
            throw conflict("批量全合格的处理记录信息冲突，请刷新后重试");
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
        requirePassAllReplayCompatible(string(row[1]),normalized);
        return new BatchCommand((UUID)row[0],true);
    }

    private PassAllBatchResult loadPassAllBatch(
            UUID batchId,
            boolean replay) {
        int expectedCount = ((Number) em.createNativeQuery("""
                        SELECT inspection_count FROM production_fqc_pass_all_batches WHERE id = :batchId
                        """).setParameter("batchId", batchId).getSingleResult()).intValue();
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
        Map<UUID, InspectionView> views = detailViews(rows.stream().map(row -> (UUID) row[0]).toList());
        List<PassAllBatchItem> items = rows.stream()
                .map(row -> {
                    UUID inspectionId = (UUID) row[0];
                    return new PassAllBatchItem(
                            inspectionId,
                            (UUID) row[1],
                            views.get(inspectionId));
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

    /**
     * One final snapshot, including every existing detail field. Batch members
     * have distinct active inspection/source-report-item identities; later PASS
     * decisions do not change a previous member's quantities or release total.
     * Callers restore normalized UUID order or persisted line_no order themselves.
     */
    private Map<UUID, InspectionView> detailViews(List<UUID> inspectionIds) {
        List<Object[]> rows = NativeQueryResults.objectArrayRows(
                em.createNativeQuery(viewSql("inspection.id IN (:inspectionIds)"))
                        .setParameter("inspectionIds", inspectionIds));
        Map<UUID, InspectionView> result = new LinkedHashMap<>();
        for (Object[] row : rows) {
            InspectionView view = toView(row);
            if (result.putIfAbsent(view.id(), view) != null) {
                throw conflict("批量生产质检视图出现重复来源，请联系管理员核查");
            }
        }
        if (result.size() != inspectionIds.size() || !result.keySet().containsAll(inspectionIds)) {
            throw conflict("批量生产质检视图不完整，请联系管理员核查");
        }
        return result;
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

    /**
     * 该报工明细的现行送检登记是否勾了「先入库后质检」(V597)。
     * 撤回的登记行不算；没有登记行(历史豁免任务)自然走原流程。
     */
    private boolean preStockedForAutoConfirm(UUID sourceReportItemId) {
        if (sourceReportItemId == null) return false;
        return Boolean.TRUE.equals(em.createNativeQuery("""
                        SELECT EXISTS (
                            SELECT 1
                            FROM production_finished_arrival_registration_items registration_item
                            JOIN production_finished_arrival_registrations registration
                              ON registration.id = registration_item.registration_id
                            WHERE registration_item.source_report_item_id = :reportItemId
                              AND registration_item.reversal_id IS NULL
                              AND registration.stock_in_before_inspection
                              AND fn_finished_arrival_count_is_proven(registration_item.id))
                        """)
                .setParameter("reportItemId", sourceReportItemId)
                .getSingleResult());
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
                       registration.receiver_name_snapshot,
                       registration.stock_in_before_inspection,
                       registration.pre_stocked_at,
                       registration.pre_stocked_by_name,
                       source_item.output_lot_id,
                       fn_daily_report_output_slice_rank(
                           source_item.is_public_output, source_item.is_actual_surplus, source_item.is_over_limit) AS slice_rank,
                       (SELECT COUNT(*)
                        FROM production_daily_report_items sibling_item
                        JOIN production_fqc_inspections sibling
                          ON sibling.source_report_item_id = sibling_item.id
                         AND sibling.status <> 'CANCELLED'
                        WHERE sibling_item.output_lot_id = source_item.output_lot_id) AS lot_slice_count
                FROM production_fqc_inspections inspection
                JOIN production_daily_reports report
                  ON report.id = inspection.source_report_id
                JOIN production_daily_report_items source_item
                  ON source_item.id = inspection.source_report_item_id
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
                           registration_header.receiver_name_snapshot,
                           registration_header.stock_in_before_inspection,
                           registration_header.pre_stocked_at,
                           pre_stocked_by.full_name AS pre_stocked_by_name
                    FROM production_finished_arrival_registration_items
                             registration_item
                    JOIN production_finished_arrival_registrations
                             registration_header
                      ON registration_header.id = registration_item.registration_id
                    LEFT JOIN employees pre_stocked_by
                      ON pre_stocked_by.id = registration_header.pre_stocked_by_employee_id
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
                string(row[29]), string(row[30]), string(row[31]),
                preStocked(row),
                (UUID) row[35],
                row[36] == null ? 0 : ((Number) row[36]).intValue(),
                OutputLotText.kind(row[36] == null ? 0 : ((Number) row[36]).intValue()),
                row[37] == null ? 1 : ((Number) row[37]).intValue());
    }

    /**
     * 逐份视图按实物交接批分组(批的顺序 = 批内第一份出现的顺序)：合计、拆分与状态服务端算一次。
     */
    static List<InspectionLotView> lotsOf(List<InspectionView> inspections) {
        Map<UUID, List<InspectionView>> byLot = new LinkedHashMap<>();
        for (InspectionView inspection : inspections) {
            UUID lotId = inspection.lotId() == null ? inspection.id() : inspection.lotId();
            byLot.computeIfAbsent(lotId, ignored -> new ArrayList<>()).add(inspection);
        }
        List<InspectionLotView> result = new ArrayList<>(byLot.size());
        for (Map.Entry<UUID, List<InspectionView>> lot : byLot.entrySet()) {
            List<InspectionView> members = new ArrayList<>(lot.getValue());
            members.sort(Comparator.comparingInt(InspectionView::sliceRank)
                    .thenComparing(view -> view.sourceReportItemId().toString()));
            BigDecimal reported = BigDecimal.ZERO;
            BigDecimal passed = BigDecimal.ZERO;
            BigDecimal failed = BigDecimal.ZERO;
            BigDecimal remaining = BigDecimal.ZERO;
            BigDecimal demand = BigDecimal.ZERO;
            BigDecimal publicQty = BigDecimal.ZERO;
            BigDecimal surplus = BigDecimal.ZERO;
            BigDecimal overLimit = BigDecimal.ZERO;
            boolean allCancelled = true;
            List<InspectionLotMemberView> memberViews = new ArrayList<>(members.size());
            for (InspectionView member : members) {
                if (!"CANCELLED".equals(member.status())) {
                    allCancelled = false;
                    reported = reported.add(member.reportedQty());
                    passed = passed.add(member.passedQty());
                    failed = failed.add(member.failedQty());
                    remaining = remaining.add(member.remainingQty());
                    switch (member.sliceRank()) {
                        case OutputLotText.RANK_OVER_LIMIT -> {
                            surplus = surplus.add(member.reportedQty());
                            overLimit = overLimit.add(member.reportedQty());
                        }
                        case OutputLotText.RANK_ACTUAL_SURPLUS -> surplus = surplus.add(member.reportedQty());
                        case OutputLotText.RANK_PUBLIC -> publicQty = publicQty.add(member.reportedQty());
                        default -> demand = demand.add(member.reportedQty());
                    }
                }
                memberViews.add(new InspectionLotMemberView(
                        member.id(), member.sourceReportItemId(), member.sliceRank(), member.sliceKind(),
                        member.reportedQty(), member.passedQty(), member.failedQty(), member.remainingQty(),
                        member.status()));
            }
            String status = allCancelled ? "CANCELLED"
                    : remaining.signum() == 0 ? "RESOLVED"
                    : passed.add(failed).signum() == 0 ? "PENDING" : "PARTIAL";
            InspectionView head = members.getFirst();
            result.add(new InspectionLotView(
                    lot.getKey(), head.sourceReportId(), head.reportNo(), head.planId(), head.planNo(),
                    head.goodsId(), head.goodsCode(), head.goodsName(), head.colorId(), head.colorName(),
                    head.unitId(), head.unitName(), reported, passed, failed, remaining,
                    demand, publicQty, surplus, OutputLotText.split(demand, publicQty, surplus, overLimit),
                    status, head.warehouseId(), head.warehouseName(), head.place(), head.preStocked(),
                    memberViews));
        }
        return result;
    }

    /** 整批判定请求规范化：数量非负、合计大于 0、有不良必须写处置方式与原因。 */
    static NormalizedLotDecision normalizeLotDecision(UUID lotId, LotDecisionRequest request) {
        if (lotId == null || request == null) throw validation("整批判定请求不能为空");
        BigDecimal pass = nonNegativeQty(request.passQty(), "合格数量");
        BigDecimal fail = nonNegativeQty(request.failQty(), "不合格数量");
        if (pass.add(fail).signum() <= 0) {
            throw validation("合格数量与不合格数量不能同时为 0");
        }
        String disposition = request.dispositionCode() == null || request.dispositionCode().isBlank()
                ? null : request.dispositionCode().strip().toUpperCase(Locale.ROOT);
        if (fail.signum() == 0) {
            if (disposition != null) throw validation("全部合格时不能填写不良处置方式");
        } else if (disposition == null || !List.of("REWORK", "SCRAP", "REJECT").contains(disposition)) {
            throw validation("有不合格数量时必须选择处置方式(返工、报废或退回)");
        }
        String reason = request.reason() == null || request.reason().isBlank() ? null : request.reason().strip();
        if (fail.signum() > 0 && reason == null) {
            throw validation("有不合格数量时必须填写差异原因");
        }
        if (reason != null && (reason.length() < 2 || reason.length() > 1000)) {
            throw validation("质检原因必须为 2 到 1000 个字符");
        }
        String key = normalizeDecisionKey(request.idempotencyKey());
        String hash = sha256(List.of("PRODUCTION-FQC-LOT-DECISION-V1", lotId.toString(),
                canonicalQty(pass), canonicalQty(fail),
                disposition == null ? "" : disposition, reason == null ? "" : reason));
        return new NormalizedLotDecision(pass, fail, disposition, reason, key, hash);
    }

    private static BigDecimal nonNegativeQty(BigDecimal value, String label) {
        if (value == null || value.signum() < 0) throw validation(label + "不能小于 0");
        try {
            return value.setScale(4, RoundingMode.UNNECESSARY);
        } catch (ArithmeticException ex) {
            throw validation(label + "最多保留 4 位小数");
        }
    }

    record NormalizedLotDecision(
            BigDecimal passQty,
            BigDecimal failQty,
            String dispositionCode,
            String reason,
            String idempotencyKey,
            String requestHash) {
    }

    /** 已上架待检行的实物位置：落仓 = 登记头的成品仓(= inspection.warehouse_id)。 */
    private static ProductionFqcContracts.PreStockedLocationView preStocked(Object[] row) {
        if (!Boolean.TRUE.equals(row[32]) || row[9] == null) return null;
        return new ProductionFqcContracts.PreStockedLocationView(
                (UUID) row[9], string(row[28]), string(row[29]),
                NativeValueConverters.toOffsetDateTime(row[33]), string(row[34]));
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
            NormalizedPassAllBatch request) {
        if (!Objects.equals(existingHash == null ? null : existingHash.strip(), request.requestHash())) {
            throw conflict("同一防重复提交标识已用于不同的批量全合格任务集合，请刷新后重试");
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
            throw validation("生产质检状态筛选值不正确");
        }
        return value;
    }

    static String normalizeSheetStatusFilter(String raw) {
        String value = raw == null || raw.isBlank()
                ? "ACTIVE" : raw.strip().toUpperCase(Locale.ROOT);
        if (!List.of("ACTIVE", "CLOSED", "ALL").contains(value)) {
            throw validation("品质检查单状态筛选值不正确");
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
            throw validation("防重复提交标识必须为 8 到 160 位字母、数字或 ._:-");
        }
        return value;
    }

    static String normalizeDecisionKey(String raw) {
        String value = normalizeKey(raw);
        if (value.length() > 128) {
            throw validation("质检决定的防重复提交标识不能超过 128 位");
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
                default -> throw validation("质检决定不正确");
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
