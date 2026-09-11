package com.uten.imp.features.warehouse.inbound;

import com.uten.imp.application.port.PreplanInboundAllocationReadPort;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.features.warehouse.inbound.ProcurementIqcStockInContracts.ReleasedSlice;
import com.uten.imp.features.warehouse.inbound.ProcurementIqcStockInContracts.InboundAllocation;
import com.uten.imp.features.warehouse.inbound.ProcurementIqcStockInContracts.StockInHistoryItem;
import com.uten.imp.features.warehouse.inbound.WarehouseQualityResultContracts.InspectionLineItem;
import com.uten.imp.features.warehouse.inbound.WarehouseQualityResultContracts.RejectionCaseItem;
import com.uten.imp.features.warehouse.inbound.WarehouseQualityResultContracts.TaskDetail;
import com.uten.imp.features.warehouse.inbound.WarehouseQualityResultContracts.TaskSummary;
import com.uten.imp.security.SecurityContextCurrentUser;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.security.core.Authentication;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.time.ZoneOffset;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.UUID;

/**
 * 品质部检查结果合并页（原 IQC 合格待入库 + IQC 不合格实物退回）的查询聚合：
 * 按收货单聚合品质结论、放行待入库切片与待登记退回案件，推导统一「作业状态」；
 * 仓库动作（确认入库 / 登记退回）仍走各自权威服务，本服务只读不写业务事实。
 *
 * <p>读路径按“数据量大了也快”设计（V448 索引配套）：
 * <ul>
 * <li>所有聚合 CTE 先 JOIN 类型/状态收窄后的 receipt_scope，再 GROUP BY——
 *     筛了采购或委外时只扫一类收货单的事实行，聚合规模随筛选收窄而不是全库恒定；</li>
 * <li>判定列全部走 V448 覆盖/部分索引（index-only scan），不做回表；</li>
 * <li>角标 countPending/pendingTypeCounts 与列表同一聚合管线按 (类型, 状态)
 *     分组后排除「已完结」——未完结口径（等待+待入库+需退回）全端统一；</li>
 * <li>详情用单收货单直查 + Java 侧状态推导，与列表 STATUS_CASE 同一口径。</li>
 * </ul>
 */
@Service
@RequiredArgsConstructor
public class WarehouseQualityResultService {

    /** 作业状态：等待检查结果 / 全部合格待入库 / 部分合格 / 全部不合格需退回 / 已完结。 */
    public static final String WAITING_INSPECTION = "WAITING_INSPECTION";
    public static final String ALL_PASSED = "ALL_PASSED";
    public static final String PARTIAL_PASSED = "PARTIAL_PASSED";
    public static final String RETURN_REQUIRED = "RETURN_REQUIRED";
    public static final String COMPLETED = "COMPLETED";

    private static final String PURCHASE = "PURCHASE";
    private static final String SUBCONTRACT = "SUBCONTRACT";

    private static final Set<String> STATUSES = Set.of(
            WAITING_INSPECTION, ALL_PASSED, PARTIAL_PASSED,
            RETURN_REQUIRED, COMPLETED);

    /**
     * 统一作业状态推导（列表 / 状态分组的 SQL 口径；详情在
     * {@link #deriveWorkStatus} 用同一分支顺序实现）：
     * 1) 仍有品质放行待入库切片 → 明细含不合格或检验未完 = 部分合格，否则全部合格；
     * 2) 无待入库但有待登记退回 → 有合格明细 = 部分合格，否则全部不合格需退回；
     * 3) 仍有未出结果明细 → 等待检查结果；否则已完结。
     */
    private static final String STATUS_CASE = """
            CASE
              WHEN COALESCE(pending_release.pending_slice_count, 0) > 0
                   AND (inspection.failed_line_count > 0
                        OR inspection.open_item_count > 0) THEN 'PARTIAL_PASSED'
              WHEN COALESCE(pending_release.pending_slice_count, 0) > 0
                   THEN 'ALL_PASSED'
              WHEN COALESCE(pending_return.pending_return_count, 0) > 0
                   AND inspection.passed_line_count > 0 THEN 'PARTIAL_PASSED'
              WHEN COALESCE(pending_return.pending_return_count, 0) > 0
                   THEN 'RETURN_REQUIRED'
              WHEN inspection.open_item_count > 0 THEN 'WAITING_INSPECTION'
              ELSE 'COMPLETED'
            END
            """;

    /**
     * 聚合管线：scope 先按 :type 收窄（两段 UNION 各自判定，只扫需要的收货表），
     * 各事实聚合再 JOIN scope，聚合量随筛选收窄。判定列由 V448 覆盖索引供给。
     */
    private static final String AGGREGATE_CTE = """
            WITH event_stocked AS (
                SELECT item.pass_event_id,
                       COALESCE(SUM(item.base_qty), 0) AS stocked_qty
                FROM procurement_iqc_stock_in_batch_items item
                GROUP BY item.pass_event_id
            ), receipt_scope AS (
                SELECT 'PURCHASE'::text AS receipt_type,
                       receipt.id AS receipt_id, receipt.bill_no, receipt.bill_date,
                       receipt.supplier_id, receipt.warehouse_id
                FROM purchase_receipts receipt
                WHERE receipt.status = 1
                  AND COALESCE(receipt.is_deleted, FALSE) = FALSE
                  AND (:type = 'ALL' OR 'PURCHASE'::text = :type)
                UNION ALL
                SELECT 'SUBCONTRACT'::text,
                       receipt.id, receipt.bill_no, receipt.bill_date,
                       receipt.supplier_id, receipt.warehouse_id
                FROM subcontract_receipts receipt
                WHERE receipt.status = 1
                  AND COALESCE(receipt.is_deleted, FALSE) = FALSE
                  AND (:type = 'ALL' OR 'SUBCONTRACT'::text = :type)
            ), inspection AS (
                SELECT inspection.receipt_type,
                       inspection.receipt_id,
                       COUNT(*) AS item_count,
                       COUNT(*) FILTER (WHERE inspection.passed_base_qty > 0)
                           AS passed_line_count,
                       COUNT(*) FILTER (WHERE inspection.failed_base_qty > 0)
                           AS failed_line_count,
                       COUNT(*) FILTER (WHERE inspection.status IN ('PENDING','PARTIAL'))
                           AS open_item_count
                FROM procurement_inspection_items inspection
                JOIN receipt_scope scope
                  ON scope.receipt_type = inspection.receipt_type
                 AND scope.receipt_id = inspection.receipt_id
                WHERE inspection.status <> 'REVERSED'
                GROUP BY inspection.receipt_type, inspection.receipt_id
            ), pending_release AS (
                SELECT inspection.receipt_type,
                       inspection.receipt_id,
                       COUNT(DISTINCT event.id) AS pending_slice_count
                FROM procurement_inspection_events event
                JOIN procurement_inspection_items inspection
                  ON inspection.id = event.inspection_item_id
                JOIN receipt_scope scope
                  ON scope.receipt_type = inspection.receipt_type
                 AND scope.receipt_id = inspection.receipt_id
                LEFT JOIN event_stocked
                  ON event_stocked.pass_event_id = event.id
                WHERE event.action = 'PASS'
                  AND event.requires_warehouse_stock_in = TRUE
                  AND inspection.status <> 'REVERSED'
                  AND event.base_qty > COALESCE(event_stocked.stocked_qty, 0)
                GROUP BY inspection.receipt_type, inspection.receipt_id
            ), pending_return AS (
                SELECT inspection.receipt_type,
                       inspection.receipt_id,
                       COUNT(*) AS pending_return_count
                FROM procurement_iqc_rejection_cases rejection
                JOIN procurement_inspection_items inspection
                  ON inspection.id = rejection.inspection_item_id
                JOIN receipt_scope scope
                  ON scope.receipt_type = inspection.receipt_type
                 AND scope.receipt_id = inspection.receipt_id
                WHERE COALESCE(rejection.is_deleted, FALSE) = FALSE
                  AND rejection.return_recorded_at IS NULL
                  AND rejection.status <> 'REVERSED'
                  AND inspection.status <> 'REVERSED'
                GROUP BY inspection.receipt_type, inspection.receipt_id
            ), last_event AS (
                SELECT inspection.receipt_type,
                       inspection.receipt_id,
                       MAX(event.occurred_at) AS last_event_at
                FROM procurement_inspection_events event
                JOIN procurement_inspection_items inspection
                  ON inspection.id = event.inspection_item_id
                JOIN receipt_scope scope
                  ON scope.receipt_type = inspection.receipt_type
                 AND scope.receipt_id = inspection.receipt_id
                WHERE inspection.status <> 'REVERSED'
                GROUP BY inspection.receipt_type, inspection.receipt_id
            )
            """;

    /** 聚合主体（列表 / 计数 / 状态分组共用 FROM+JOIN；绑定 type、keyword、pattern）。 */
    private static final String AGGREGATE_FROM = """
            FROM receipt_scope scope
            JOIN inspection
              ON inspection.receipt_type = scope.receipt_type
             AND inspection.receipt_id = scope.receipt_id
            LEFT JOIN pending_release
              ON pending_release.receipt_type = scope.receipt_type
             AND pending_release.receipt_id = scope.receipt_id
            LEFT JOIN pending_return
              ON pending_return.receipt_type = scope.receipt_type
             AND pending_return.receipt_id = scope.receipt_id
            LEFT JOIN last_event
              ON last_event.receipt_type = scope.receipt_type
             AND last_event.receipt_id = scope.receipt_id
            LEFT JOIN suppliers supplier
              ON supplier.id = scope.supplier_id
            LEFT JOIN warehouses warehouse
              ON warehouse.id = scope.warehouse_id
            """;

    /** 关键字过滤（收货单 / 供应商 / 仓库 / 货品编码或名称）。 */
    private static final String KEYWORD_WHERE = """
            WHERE (:type = 'ALL' OR scope.receipt_type = :type)
              AND (
                  :keyword = ''
                  OR LOWER(COALESCE(scope.bill_no, ''))
                       LIKE :pattern ESCAPE '\\'
                  OR LOWER(COALESCE(supplier.name, ''))
                       LIKE :pattern ESCAPE '\\'
                  OR LOWER(COALESCE(warehouse.name, ''))
                       LIKE :pattern ESCAPE '\\'
                  OR EXISTS (
                      SELECT 1
                        FROM procurement_inspection_items keyword_inspection
                        LEFT JOIN goods keyword_goods
                          ON keyword_goods.id = keyword_inspection.goods_id
                       WHERE keyword_inspection.receipt_type = scope.receipt_type
                         AND keyword_inspection.receipt_id = scope.receipt_id
                         AND keyword_inspection.status <> 'REVERSED'
                         AND (LOWER(COALESCE(keyword_goods.code, ''))
                                  LIKE :pattern ESCAPE '\\'
                              OR LOWER(COALESCE(keyword_goods.name, ''))
                                  LIKE :pattern ESCAPE '\\')
                  )
              )
            """;

    /**
     * 日期范围过滤（列表专用；状态/来源分段计数不跟随日期，保持角标全量口径）。
     * null 参数一律 CAST 后判空，见 PG 42P18 坑。
     */
    private static final String DATE_WHERE = """
              AND (CAST(:date_from AS date) IS NULL OR scope.bill_date >= CAST(:date_from AS date))
              AND (CAST(:date_to AS date) IS NULL OR scope.bill_date <= CAST(:date_to AS date))
            """;

    private final EntityManager em;
    private final SecurityContextCurrentUser currentUser;
    private PreplanInboundAllocationReadPort inboundAllocationRead =
            PreplanInboundAllocationReadPort.NOOP;

    @Autowired
    void setInboundAllocationRead(PreplanInboundAllocationReadPort value) {
        this.inboundAllocationRead = value;
    }

    @Transactional(readOnly = true)
    @PreAuthorize("hasAuthority('" + WarehouseQualityResultPermissions.STOCK_IN_VIEW + "')"
            + " or hasAuthority('" + WarehouseQualityResultPermissions.RETURN_VIEW + "')")
    public PageResponse<TaskSummary> list(
            String keyword,
            String receiptType,
            String status,
            LocalDate dateFrom,
            LocalDate dateTo,
            int page,
            int size) {
        int normalizedPage = Math.max(page, 1);
        int normalizedSize = Math.min(Math.max(size, 1), 100);
        String workStatus = normalizeStatus(status);
        String type = normalizeFilterType(receiptType);
        String search = normalizeSearch(keyword);
        String statusFilter = statusFilter(workStatus);
        String filters = KEYWORD_WHERE + statusFilter + DATE_WHERE;

        Query data = aggregateQuery(type, search, workStatus, """
                SELECT (%s) AS work_status,
                       scope.receipt_type,
                       scope.receipt_id,
                       scope.bill_no,
                       scope.bill_date,
                       scope.supplier_id,
                       supplier.name,
                       scope.warehouse_id,
                       warehouse.name,
                       inspection.item_count,
                       inspection.passed_line_count,
                       inspection.failed_line_count,
                       inspection.open_item_count,
                       COALESCE(pending_release.pending_slice_count, 0),
                       COALESCE(pending_return.pending_return_count, 0),
                       last_event.last_event_at
                %s%s
                ORDER BY (CASE WHEN (%s) = 'COMPLETED' THEN 1 ELSE 0 END),
                         COALESCE(last_event.last_event_at,
                                  scope.bill_date::timestamptz) DESC NULLS LAST,
                         scope.bill_no, scope.receipt_id
                LIMIT :limit OFFSET :offset
                """.formatted(STATUS_CASE, AGGREGATE_FROM, filters, STATUS_CASE))
                .setParameter("date_from", dateFrom)
                .setParameter("date_to", dateTo)
                .setParameter("limit", normalizedSize)
                .setParameter("offset", (normalizedPage - 1) * normalizedSize);
        @SuppressWarnings("unchecked")
        List<Object[]> rows = (List<Object[]>) data.getResultList();

        long total = number(aggregateQuery(type, search, workStatus, """
                SELECT COUNT(*)
                %s%s
                """.formatted(AGGREGATE_FROM, filters))
                .setParameter("date_from", dateFrom)
                .setParameter("date_to", dateTo)
                .getSingleResult()).longValue();
        List<TaskSummary> items = rows.stream().map(row -> new TaskSummary(
                str(row[0]), str(row[1]), uuid(row[2]), str(row[3]), localDate(row[4]),
                uuid(row[5]), str(row[6]), uuid(row[7]), str(row[8]),
                number(row[9]).longValue(), number(row[10]).longValue(),
                number(row[11]).longValue(), number(row[12]).longValue(),
                number(row[13]).longValue(), number(row[14]).longValue(),
                offsetDateTime(row[15]))).toList();
        int totalPages = total == 0 ? 0
                : (int) ((total + normalizedSize - 1) / normalizedSize);
        return new PageResponse<>(
                items, normalizedPage, normalizedSize, total, totalPages);
    }

    /** 顶部状态分段计数：与列表同口径的全量分组计数（按类型/关键字过滤后）。 */
    @Transactional(readOnly = true)
    @PreAuthorize("hasAuthority('" + WarehouseQualityResultPermissions.STOCK_IN_VIEW + "')"
            + " or hasAuthority('" + WarehouseQualityResultPermissions.RETURN_VIEW + "')")
    public Map<String, Long> statusCounts(String receiptType, String keyword) {
        String type = normalizeFilterType(receiptType);
        String search = normalizeSearch(keyword);
        @SuppressWarnings("unchecked")
        List<Object[]> rows = (List<Object[]>) aggregateQuery(type, search, "", """
                SELECT (%s) AS work_status, COUNT(*)
                %s%s
                GROUP BY (%s)
                """.formatted(STATUS_CASE, AGGREGATE_FROM, KEYWORD_WHERE, STATUS_CASE))
                .getResultList();
        Map<String, Long> counts = new LinkedHashMap<>();
        for (String known : List.of(
                WAITING_INSPECTION, ALL_PASSED, PARTIAL_PASSED,
                RETURN_REQUIRED, COMPLETED)) {
            counts.put(known, 0L);
        }
        for (Object[] row : rows) {
            counts.put(str(row[0]), number(row[1]).longValue());
        }
        return counts;
    }

    /**
     * 角标计数（口径 = <b>轮到仓库动手</b>的任务数：待入库 + 需退回）。
     *
     * <p>2026-09-11 起<b>剔除「等待检查结果」</b>（{@code WAITING_INSPECTION}）：
     * 那一档球在品质部手上，仓库看得见但办不了，计进红徽章等于天天挂着一个
     * 点进去什么也做不了的数字（用户原话：「等待检查这个不计入消息累计，
     * 只有检查结束后通知」）。它仍在页内分段里以中性计数呈现，只是不上卷。
     * 「已完结」是终态，本就排除。
     *
     * <p>复用列表聚合管线按 (来源类型, 作业状态) 分组，与页内分段同一
     * STATUS_CASE，口径不漂移；hub 卡角标与父分类分段计数共用。
     */
    @Transactional(readOnly = true)
    @PreAuthorize("hasAuthority('" + WarehouseQualityResultPermissions.STOCK_IN_VIEW + "')"
            + " or hasAuthority('" + WarehouseQualityResultPermissions.RETURN_VIEW + "')")
    public Map<String, Long> pendingTypeCounts() {
        @SuppressWarnings("unchecked")
        List<Object[]> rows = (List<Object[]>) aggregateQuery("ALL", "", "", """
                SELECT scope.receipt_type, (%s) AS work_status, COUNT(*)
                %s%s
                GROUP BY scope.receipt_type, (%s)
                """.formatted(STATUS_CASE, AGGREGATE_FROM, KEYWORD_WHERE, STATUS_CASE))
                .getResultList();
        Map<String, Long> counts = new LinkedHashMap<>();
        for (String known : List.of(PURCHASE, SUBCONTRACT)) {
            counts.put(known, 0L);
        }
        for (Object[] row : rows) {
            String workStatus = str(row[1]);
            // 终态不数；等待检查结果不数（见方法注释：那一档不是仓库的待办）。
            if (COMPLETED.equals(workStatus) || WAITING_INSPECTION.equals(workStatus)) {
                continue;
            }
            counts.merge(str(row[0]), number(row[2]).longValue(), Long::sum);
        }
        return counts;
    }

    /** 合并页角标：全部来源未完结任务数（各类型之和）。 */
    @Transactional(readOnly = true)
    @PreAuthorize("hasAuthority('" + WarehouseQualityResultPermissions.STOCK_IN_VIEW + "')"
            + " or hasAuthority('" + WarehouseQualityResultPermissions.RETURN_VIEW + "')")
    public long countPending() {
        return pendingTypeCounts().values().stream().mapToLong(Long::longValue).sum();
    }

    @Transactional(readOnly = true)
    @PreAuthorize("hasAuthority('" + WarehouseQualityResultPermissions.STOCK_IN_VIEW + "')"
            + " or hasAuthority('" + WarehouseQualityResultPermissions.RETURN_VIEW + "')")
    public TaskDetail detail(String receiptType, UUID receiptId) {
        String type = normalizeReceiptType(receiptType);
        Object[] header = headerRow(type, receiptId);
        Counts counts = counts(type, receiptId);
        List<InspectionLineItem> lines = lines(type, receiptId);
        List<ReleasedSlice> slices = slices(type, receiptId);
        List<StockInHistoryItem> history = history(type, receiptId);
        List<RejectionCaseItem> rejections = rejections(type, receiptId);
        UUID actorEmployeeId = currentUser.employeeId().orElse(null);
        // 单人维护场景允许同人完成「品质放行 + 仓库确认」：containsOwnRelease 只作为
        // 前端复核提示的标记，不再阻断入库确认。
        boolean containsOwnRelease = actorEmployeeId != null
                && containsOwnRelease(type, receiptId, actorEmployeeId);
        boolean canConfirm = hasAuthority(ProcurementIqcStockInPermissions.CONFIRM)
                && !slices.isEmpty();
        String workStatus = deriveWorkStatus(
                slices.size(), counts.failedLineCount(), counts.openItemCount(),
                counts.passedLineCount(), counts.pendingReturnCount());
        return new TaskDetail(
                workStatus, type, receiptId,
                str(header[0]), localDate(header[1]),
                uuid(header[2]), str(header[3]), uuid(header[4]), str(header[5]),
                qualityStatus(type, receiptId),
                counts.itemCount(), counts.passedLineCount(),
                counts.failedLineCount(), counts.openItemCount(),
                slices.size(), counts.pendingReturnCount(),
                workStatus.equals(COMPLETED),
                containsOwnRelease,
                canConfirm ? List.of("CONFIRM") : List.of(),
                lines, slices, history, rejections);
    }

    /**
     * 作业状态的 Java 推导（详情直查用）：分支顺序与 {@link #STATUS_CASE} 完全一致，
     * 由契约测试锁定两处口径不漂移。
     */
    static String deriveWorkStatus(
            int pendingSliceCount,
            long failedLineCount,
            long openItemCount,
            long passedLineCount,
            long pendingReturnCount) {
        if (pendingSliceCount > 0) {
            return (failedLineCount > 0 || openItemCount > 0)
                    ? PARTIAL_PASSED : ALL_PASSED;
        }
        if (pendingReturnCount > 0) {
            return passedLineCount > 0 ? PARTIAL_PASSED : RETURN_REQUIRED;
        }
        return openItemCount > 0 ? WAITING_INSPECTION : COMPLETED;
    }

    // ————————————————————————— 私有查询 —————————————————————————

    private Query aggregateQuery(
            String type, String search, String workStatus, String bodySql) {
        Query query = em.createNativeQuery(AGGREGATE_CTE + bodySql)
                .setParameter("type", type)
                .setParameter("keyword", search)
                .setParameter("pattern", likePattern(search));
        if (!workStatus.isEmpty()) {
            query.setParameter("status", workStatus);
        }
        return query;
    }

    private static String statusFilter(String workStatus) {
        return workStatus.isEmpty() ? ""
                : "AND (" + STATUS_CASE + ") = :status\n";
    }

    /** 单收货单直查聚合（详情用；全部命中 (receipt_type, receipt_id) 索引）。 */
    private record Counts(
            long itemCount,
            long passedLineCount,
            long failedLineCount,
            long openItemCount,
            long pendingReturnCount) {
    }

    private Counts counts(String type, UUID receiptId) {
        List<?> inspectionRows = em.createNativeQuery("""
                SELECT COUNT(*),
                       COUNT(*) FILTER (WHERE inspection.passed_base_qty > 0),
                       COUNT(*) FILTER (WHERE inspection.failed_base_qty > 0),
                       COUNT(*) FILTER (WHERE inspection.status IN ('PENDING','PARTIAL'))
                FROM procurement_inspection_items inspection
                WHERE inspection.receipt_type = :receiptType
                  AND inspection.receipt_id = :receiptId
                  AND inspection.status <> 'REVERSED'
                """)
                .setParameter("receiptType", type)
                .setParameter("receiptId", receiptId)
                .getResultList();
        if (inspectionRows.isEmpty()) {
            // 草稿/未送检收货单无检验明细，不进入本页；深链按不存在失败关闭。
            throw new ApiException(ErrorCode.NOT_FOUND,
                    "该收货单尚无品质检查结果（未送检或不存在）");
        }
        Object[] inspectionRow = (Object[]) inspectionRows.getFirst();
        Object returnRow = em.createNativeQuery("""
                SELECT COUNT(*)
                FROM procurement_iqc_rejection_cases rejection
                JOIN procurement_inspection_items inspection
                  ON inspection.id = rejection.inspection_item_id
                WHERE rejection.receipt_type = :receiptType
                  AND rejection.receipt_id = :receiptId
                  AND COALESCE(rejection.is_deleted, FALSE) = FALSE
                  AND rejection.return_recorded_at IS NULL
                  AND rejection.status <> 'REVERSED'
                  AND inspection.status <> 'REVERSED'
                """)
                .setParameter("receiptType", type)
                .setParameter("receiptId", receiptId)
                .getSingleResult();
        return new Counts(
                number(inspectionRow[0]).longValue(),
                number(inspectionRow[1]).longValue(),
                number(inspectionRow[2]).longValue(),
                number(inspectionRow[3]).longValue(),
                number(returnRow).longValue());
    }

    private Object[] headerRow(String type, UUID receiptId) {
        String table = PURCHASE.equals(type)
                ? "purchase_receipts" : "subcontract_receipts";
        @SuppressWarnings("unchecked")
        List<Object[]> rows = em.createNativeQuery("""
                        SELECT receipt.bill_no, receipt.bill_date,
                               receipt.supplier_id, supplier.name,
                               receipt.warehouse_id, warehouse.name
                        FROM %s receipt
                        LEFT JOIN suppliers supplier
                          ON supplier.id = receipt.supplier_id
                        LEFT JOIN warehouses warehouse
                          ON warehouse.id = receipt.warehouse_id
                        WHERE receipt.id = :receiptId
                          AND COALESCE(receipt.is_deleted, FALSE) = FALSE
                        """.formatted(table))
                .setParameter("receiptId", receiptId)
                .getResultList();
        if (rows.isEmpty()) {
            throw new ApiException(ErrorCode.NOT_FOUND, "收货单不存在");
        }
        return (Object[]) rows.getFirst();
    }

    /**
     * 检查结果明细行（详情页逐货品行判定表的数据源）：每行给出收货 / 合格 /
     * 不合格 / 已入库数量与待入库余量，前端据此渲染 合格(绿) / 不合格(红禁) /
     * 部分合格(黄警) / 待检(蓝沙漏) 前导图标。
     */
    @SuppressWarnings("unchecked")
    private List<InspectionLineItem> lines(String receiptType, UUID receiptId) {
        List<Object[]> rows = em.createNativeQuery("""
                WITH pending_release AS (
                    SELECT event.inspection_item_id,
                           SUM(event.base_qty
                               - COALESCE(event_stocked.stocked_qty, 0))
                               AS pending_qty
                    FROM procurement_inspection_events event
                    LEFT JOIN LATERAL (
                        SELECT COALESCE(SUM(item.base_qty), 0) AS stocked_qty
                        FROM procurement_iqc_stock_in_batch_items item
                        WHERE item.pass_event_id = event.id
                    ) event_stocked ON TRUE
                    WHERE event.action = 'PASS'
                      AND event.requires_warehouse_stock_in = TRUE
                      AND event.inspection_item_id IN (
                          SELECT inspection.id
                          FROM procurement_inspection_items inspection
                          WHERE inspection.receipt_type = :receiptType
                            AND inspection.receipt_id = :receiptId)
                      AND event.base_qty
                          > COALESCE(event_stocked.stocked_qty, 0)
                    GROUP BY event.inspection_item_id
                )
                        SELECT inspection.id,
                               inspection.goods_id,
                               goods.code,
                               goods.name,
                               color.name,
                               COALESCE(goods.unit_id, inspection.unit_id),
                               COALESCE(base_unit.name, source_unit.name),
                               inspection.status,
                               inspection.received_base_qty,
                               inspection.passed_base_qty,
                               inspection.failed_base_qty,
                               inspection.warehouse_stocked_base_qty,
                               COALESCE(pending_release.pending_qty, 0)
                        FROM procurement_inspection_items inspection
                        LEFT JOIN goods ON goods.id = inspection.goods_id
                        LEFT JOIN colors color ON color.id = inspection.color_id
                        LEFT JOIN units source_unit
                          ON source_unit.id = inspection.unit_id
                        LEFT JOIN units base_unit ON base_unit.id = goods.unit_id
                        LEFT JOIN pending_release
                          ON pending_release.inspection_item_id = inspection.id
                        WHERE inspection.receipt_type = :receiptType
                          AND inspection.receipt_id = :receiptId
                          AND inspection.status <> 'REVERSED'
                        ORDER BY inspection.received_at, inspection.id
                        """)
                .setParameter("receiptType", receiptType)
                .setParameter("receiptId", receiptId)
                .getResultList();
        return rows.stream().map(row -> new InspectionLineItem(
                uuid(row[0]), uuid(row[1]), str(row[2]), str(row[3]),
                str(row[4]), uuid(row[5]), str(row[6]), str(row[7]),
                decimal(row[8]), decimal(row[9]), decimal(row[10]),
                decimal(row[11]), decimal(row[12]))).toList();
    }

    /** 品质放行待入库切片（与 IQC 待入库详情同口径、只读不加锁）。 */
    @SuppressWarnings("unchecked")
    private List<ReleasedSlice> slices(String receiptType, UUID receiptId) {
        List<Object[]> rows = em.createNativeQuery("""
                        SELECT event.id,
                               inspection.id,
                               inspection.goods_id,
                               goods.code,
                               goods.name,
                               color.name,
                               COALESCE(goods.unit_id, inspection.unit_id),
                               COALESCE(base_unit.name, source_unit.name),
                               COALESCE(purchase_order.bill_no,
                                        subcontract_order.bill_no),
                               inspection.received_base_qty,
                               inspection.passed_base_qty,
                               inspection.warehouse_stocked_base_qty,
                               event.base_qty,
                               COALESCE(event_stocked.stocked_qty, 0),
                               event.base_qty - COALESCE(event_stocked.stocked_qty, 0),
                               event.released_weight,
                               event.released_weight_unit_id,
                               weight_unit.name,
                               COALESCE(preference.place,
                                        NULLIF(BTRIM(goods.stock_place), '')),
                               event.reason,
                               employee.full_name,
                               event.occurred_at
                        FROM procurement_inspection_events event
                        JOIN procurement_inspection_items inspection
                          ON inspection.id = event.inspection_item_id
                        LEFT JOIN LATERAL (
                            SELECT COALESCE(SUM(item.base_qty), 0) AS stocked_qty
                            FROM procurement_iqc_stock_in_batch_items item
                            WHERE item.pass_event_id = event.id
                        ) event_stocked ON TRUE
                        LEFT JOIN goods ON goods.id = inspection.goods_id
                        LEFT JOIN colors color ON color.id = inspection.color_id
                        LEFT JOIN units source_unit
                          ON source_unit.id = inspection.unit_id
                        LEFT JOIN units base_unit ON base_unit.id = goods.unit_id
                        LEFT JOIN units weight_unit
                          ON weight_unit.id = event.released_weight_unit_id
                        LEFT JOIN warehouse_goods_place_preferences preference
                          ON preference.warehouse_id = inspection.warehouse_id
                         AND preference.goods_id = inspection.goods_id
                         AND preference.color_id
                             IS NOT DISTINCT FROM inspection.color_id
                        LEFT JOIN employees employee
                          ON employee.id = event.actor_employee_id
                        LEFT JOIN purchase_receipt_items purchase_item
                          ON inspection.receipt_type = 'PURCHASE'
                         AND purchase_item.id = inspection.receipt_item_id
                        LEFT JOIN purchase_order_items purchase_order_item
                          ON purchase_order_item.id = purchase_item.order_item_id
                        LEFT JOIN purchase_orders purchase_order
                          ON purchase_order.id = purchase_order_item.order_id
                        LEFT JOIN subcontract_receipt_items subcontract_item
                          ON inspection.receipt_type = 'SUBCONTRACT'
                         AND subcontract_item.id = inspection.receipt_item_id
                        LEFT JOIN subcontract_order_items subcontract_order_item
                          ON subcontract_order_item.id = subcontract_item.order_item_id
                        LEFT JOIN subcontract_orders subcontract_order
                          ON subcontract_order.id = subcontract_order_item.order_id
                        WHERE inspection.receipt_type = :receiptType
                          AND inspection.receipt_id = :receiptId
                          AND inspection.status <> 'REVERSED'
                          AND event.action = 'PASS'
                          AND event.requires_warehouse_stock_in = TRUE
                          AND event.base_qty > COALESCE(event_stocked.stocked_qty, 0)
                        ORDER BY event.occurred_at, event.id
                        """)
                .setParameter("receiptType", receiptType)
                .setParameter("receiptId", receiptId)
                .getResultList();
        List<ReleasedSlice> base = rows.stream().map(row -> new ReleasedSlice(
                uuid(row[0]), uuid(row[1]), uuid(row[2]),
                str(row[3]), str(row[4]), str(row[5]),
                uuid(row[6]), str(row[7]), str(row[8]),
                decimal(row[9]), decimal(row[10]), decimal(row[11]),
                decimal(row[12]), decimal(row[13]), decimal(row[14]),
                nullableDecimal(row[15]), uuid(row[16]), str(row[17]),
                str(row[18]), str(row[19]), str(row[20]),
                offsetDateTime(row[21]))).toList();
        Map<UUID, List<PreplanInboundAllocationReadPort.AllocationView>> expected =
                inboundAllocationRead.expectedForPassEvents(
                        receiptType, receiptId,
                        base.stream().map(ReleasedSlice::passEventId).toList());
        return base.stream().map(slice -> new ReleasedSlice(
                slice.passEventId(), slice.inspectionItemId(), slice.goodsId(),
                slice.goodsCode(), slice.goodsName(), slice.colorName(),
                slice.unitId(), slice.unitName(), slice.sourceOrderNo(),
                slice.receivedBaseQty(), slice.qualityPassedBaseQty(),
                slice.warehouseStockedBaseQty(), slice.releasedBaseQty(),
                slice.stockedForReleaseBaseQty(), slice.remainingBaseQty(),
                slice.releasedWeight(), slice.weightUnitId(), slice.weightUnitName(),
                slice.placeHint(), slice.releaseNote(), slice.releasedBy(),
                slice.releasedAt(), expected.getOrDefault(slice.passEventId(), List.of())
                        .stream().map(WarehouseQualityResultService::toAllocation)
                        .toList())).toList();
    }

    private static InboundAllocation toAllocation(
            PreplanInboundAllocationReadPort.AllocationView value) {
        return new InboundAllocation(
                value.passEventId(), value.stockInBatchItemId(), value.kind(),
                value.qty(), value.actualWarehouseId(), value.actualWarehouseName(),
                value.targetWarehouseId(), value.targetWarehouseName(),
                value.intendedWarehouseNames(), value.warehouseMatches(),
                value.analysisId(), value.analysisMaterialId(),
                value.productCode(), value.productName(), value.sourceLabel(),
                value.planId(), value.planNo(), value.executionSegmentId(),
                value.executionSegmentCode(), value.workshopDepartmentId(),
                value.workshopName(), value.responsibleEmployeeId(),
                value.responsibleEmployeeName(), value.formationStatus());
    }

    /** 仓库入库历史（与 IQC 待入库详情同口径）。 */
    @SuppressWarnings("unchecked")
    private List<StockInHistoryItem> history(String receiptType, UUID receiptId) {
        List<Object[]> rows = em.createNativeQuery("""
                        SELECT item.id, batch.id, item.pass_event_id,
                               item.goods_id, goods.code, goods.name,
                               color.name, COALESCE(base_unit.name, source_unit.name),
                               item.base_qty, item.weight, weight_unit.name,
                               item.place_snapshot, employee.full_name,
                               batch.confirmed_at
                        FROM procurement_iqc_stock_in_batch_items item
                        JOIN procurement_iqc_stock_in_batches batch
                          ON batch.id = item.batch_id
                        JOIN procurement_inspection_items inspection
                          ON inspection.id = item.inspection_item_id
                        LEFT JOIN goods ON goods.id = item.goods_id
                        LEFT JOIN colors color ON color.id = item.color_id
                        LEFT JOIN units source_unit
                          ON source_unit.id = inspection.unit_id
                        LEFT JOIN units base_unit ON base_unit.id = goods.unit_id
                        LEFT JOIN units weight_unit
                          ON weight_unit.id = item.weight_unit_id
                        LEFT JOIN employees employee
                          ON employee.id = batch.actor_employee_id
                        WHERE batch.receipt_type = :receiptType
                          AND batch.receipt_id = :receiptId
                        ORDER BY batch.confirmed_at DESC, item.position
                        LIMIT 200
                        """)
                .setParameter("receiptType", receiptType)
                .setParameter("receiptId", receiptId)
                .getResultList();
        return rows.stream().map(row -> new StockInHistoryItem(
                uuid(row[0]), uuid(row[1]), uuid(row[2]), uuid(row[3]),
                str(row[4]), str(row[5]), str(row[6]), str(row[7]),
                decimal(row[8]), nullableDecimal(row[9]), str(row[10]),
                str(row[11]), str(row[12]), offsetDateTime(row[13]))).toList();
    }

    /** 检查不合格的实物退回案件（V440 拒收案件在仓库侧的投影）。 */
    @SuppressWarnings("unchecked")
    private List<RejectionCaseItem> rejections(String receiptType, UUID receiptId) {
        boolean canRecord = hasAuthority(WarehouseQualityResultPermissions.RECORD_RETURN);
        List<Object[]> rows = em.createNativeQuery("""
                        SELECT rejection.id,
                               rejection.inspection_item_id,
                               rejection.goods_id,
                               goods.code,
                               goods.name,
                               color.name,
                               unit.name,
                               rejection.failed_qty,
                               CASE
                                 WHEN rejection.return_recorded_at IS NOT NULL
                                   THEN 'RETURN_RECORDED'
                                 WHEN rejection.status = 'REVERSED' THEN 'VOIDED'
                                 ELSE 'PENDING_RETURN'
                               END,
                               rejection.return_reference,
                               rejection.return_date,
                               rejection.return_note,
                               COALESCE(return_employee.full_name,
                                        return_user.login_account),
                               rejection.return_recorded_at,
                               rejection.row_version,
                               CASE WHEN rejection.status IN
                                         ('PENDING_RETURN','FINANCE_EXCEPTION')
                                     AND inspection.status = 'RESOLVED'
                                     AND NOT EXISTS (
                                         SELECT 1 FROM business_outbox pending_outbox
                                         WHERE pending_outbox.event_type =
                                               'PROCUREMENT_IQC_REJECTION_DETECTED'
                                           AND pending_outbox.aggregate_id = inspection.id
                                           AND pending_outbox.status <> 1)
                                    THEN TRUE ELSE FALSE END
                        FROM procurement_iqc_rejection_cases rejection
                        JOIN procurement_inspection_items inspection
                          ON inspection.id = rejection.inspection_item_id
                        LEFT JOIN goods ON goods.id = rejection.goods_id
                        LEFT JOIN colors color ON color.id = rejection.color_id
                        LEFT JOIN units unit ON unit.id = rejection.unit_id
                        LEFT JOIN users return_user
                          ON return_user.id = rejection.return_recorded_by
                        LEFT JOIN employees return_employee
                          ON return_employee.id = return_user.employee_id
                        WHERE rejection.receipt_type = :receiptType
                          AND rejection.receipt_id = :receiptId
                          AND COALESCE(rejection.is_deleted, FALSE) = FALSE
                        ORDER BY rejection.created_at, rejection.id
                        """)
                .setParameter("receiptType", receiptType)
                .setParameter("receiptId", receiptId)
                .getResultList();
        return rows.stream().map(row -> new RejectionCaseItem(
                uuid(row[0]), uuid(row[1]), uuid(row[2]),
                str(row[3]), str(row[4]), str(row[5]), str(row[6]),
                nullableDecimal(row[7]), str(row[8]), str(row[9]),
                localDate(row[10]), str(row[11]), str(row[12]),
                offsetDateTime(row[13]), number(row[14]).longValue(),
                canRecord && bool(row[15]))).toList();
    }

    private String qualityStatus(String type, UUID receiptId) {
        Object[] row = (Object[]) em.createNativeQuery("""
                        SELECT COUNT(*),
                               COUNT(*) FILTER (WHERE status = 'PENDING'),
                               COUNT(*) FILTER (WHERE status = 'PARTIAL'),
                               COUNT(*) FILTER (WHERE status = 'RESOLVED'),
                               COUNT(*) FILTER (WHERE status = 'REVERSED')
                        FROM procurement_inspection_items
                        WHERE receipt_type = :receiptType
                          AND receipt_id = :receiptId
                        """)
                .setParameter("receiptType", type)
                .setParameter("receiptId", receiptId)
                .getSingleResult();
        if (number(row[0]).longValue() == 0) return "UNKNOWN";
        if (number(row[4]).longValue() > 0) return "REVERSED";
        if (number(row[1]).longValue() > 0 || number(row[2]).longValue() > 0) {
            return "IN_PROGRESS";
        }
        return "RESOLVED";
    }

    /** 品质放行人本人不得再执行仓库确认（职责分离）：检查待入库切片是否由当前员工放行。 */
    private boolean containsOwnRelease(String type, UUID receiptId, UUID employeeId) {
        Object result = em.createNativeQuery("""
                        SELECT EXISTS (
                            SELECT 1
                            FROM procurement_inspection_events event
                            JOIN procurement_inspection_items inspection
                              ON inspection.id = event.inspection_item_id
                            LEFT JOIN LATERAL (
                                SELECT COALESCE(SUM(item.base_qty), 0) AS stocked_qty
                                FROM procurement_iqc_stock_in_batch_items item
                                WHERE item.pass_event_id = event.id
                            ) event_stocked ON TRUE
                            WHERE inspection.receipt_type = :receiptType
                              AND inspection.receipt_id = :receiptId
                              AND inspection.status <> 'REVERSED'
                              AND event.action = 'PASS'
                              AND event.requires_warehouse_stock_in = TRUE
                              AND event.base_qty
                                  > COALESCE(event_stocked.stocked_qty, 0)
                              AND event.actor_employee_id = :employeeId
                        )
                        """)
                .setParameter("receiptType", type)
                .setParameter("receiptId", receiptId)
                .setParameter("employeeId", employeeId)
                .getSingleResult();
        return bool(result);
    }

    private static String normalizeStatus(String value) {
        String normalized = value == null ? "" : value.strip().toUpperCase(Locale.ROOT);
        if (normalized.isEmpty() || "ALL".equals(normalized)) return "";
        if (!STATUSES.contains(normalized)) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED,
                    "作业状态仅支持 WAITING_INSPECTION/ALL_PASSED/PARTIAL_PASSED"
                            + "/RETURN_REQUIRED/COMPLETED");
        }
        return normalized;
    }

    private static String normalizeReceiptType(String value) {
        String type = value == null ? "" : value.strip().toUpperCase(Locale.ROOT);
        if (!PURCHASE.equals(type) && !SUBCONTRACT.equals(type)) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED,
                    "收货单类型仅支持 PURCHASE 或 SUBCONTRACT");
        }
        return type;
    }

    private static String normalizeFilterType(String value) {
        if (value == null || value.isBlank() || "ALL".equalsIgnoreCase(value)) {
            return "ALL";
        }
        return normalizeReceiptType(value);
    }

    private static String normalizeSearch(String value) {
        return value == null ? "" : value.strip().toLowerCase(Locale.ROOT);
    }

    private static String likePattern(String value) {
        return "%" + value.replace("\\", "\\\\")
                .replace("%", "\\%").replace("_", "\\_") + "%";
    }

    private static boolean hasAuthority(String authority) {
        Authentication authentication =
                SecurityContextHolder.getContext().getAuthentication();
        return authentication != null && authentication.isAuthenticated()
                && authentication.getAuthorities().stream()
                .anyMatch(granted -> authority.equals(granted.getAuthority()));
    }

    private static UUID uuid(Object value) {
        return value == null ? null : (UUID) value;
    }

    private static String str(Object value) {
        return value == null ? "" : value.toString();
    }

    private static Number number(Object value) {
        return value == null ? 0L : (Number) value;
    }

    private static BigDecimal decimal(Object value) {
        return value == null ? BigDecimal.ZERO : (BigDecimal) value;
    }

    private static BigDecimal nullableDecimal(Object value) {
        return value == null ? null : (BigDecimal) value;
    }

    private static boolean bool(Object value) {
        return value instanceof Boolean flag
                ? flag : Boolean.parseBoolean(String.valueOf(value));
    }

    private static LocalDate localDate(Object value) {
        if (value == null) return null;
        if (value instanceof LocalDate date) return date;
        if (value instanceof java.sql.Date date) return date.toLocalDate();
        return LocalDate.parse(value.toString());
    }

    private static OffsetDateTime offsetDateTime(Object value) {
        if (value == null) return null;
        if (value instanceof OffsetDateTime dateTime) return dateTime;
        if (value instanceof java.time.Instant instant) {
            return instant.atOffset(ZoneOffset.UTC);
        }
        if (value instanceof java.sql.Timestamp timestamp) {
            return timestamp.toInstant().atOffset(ZoneOffset.UTC);
        }
        return OffsetDateTime.parse(value.toString());
    }
}
