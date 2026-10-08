package com.uten.imp.features.warehouse.inbound;

import com.uten.imp.common.util.NativeQueryResults;
import com.uten.imp.common.util.NativeValueConverters;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.web.NativeFacets;
import com.uten.imp.common.web.Pageables;
import com.uten.imp.features.warehouse.inbound.ProcurementInspectionRecordContracts.InspectionDecisionRecord;
import com.uten.imp.features.warehouse.inbound.ProcurementInspectionRecordContracts.InspectionDecisionRecordPage;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.UUID;

/** Read-only, event-level history for purchase/subcontract IQC decisions. */
@Service
@RequiredArgsConstructor
public class ProcurementInspectionRecordQueryService {

    private static final List<String> DECISIONS =
            List.of("ALL", "PASS", "PARTIAL", "FAIL", "CANCELLED");

    /** 表头筛选白名单（2026-09-16）：检验类型=收货来源（IQC 无生产来源）；当前效力按
     *  列展示口径拆三档（当前有效/历史失效/撤销有效）；不良处置码与决定/撤销事件同源。 */
    private static final List<String> SOURCE_TYPES = List.of("PURCHASE", "SUBCONTRACT");
    private static final List<String> EFFECTS = List.of("ACTIVE", "EXPIRED", "CANCELLED");
    private static final List<String> DISPOSITIONS = List.of(
            "REWORK", "SCRAP", "REJECT",
            "SOURCE_REPORT_REVERSED", "REGISTRATION_REVERSED", "RECEIPT_REVERSED");

    private final EntityManager em;

    @Transactional(readOnly = true)
    @PreAuthorize("hasAuthority('procurement_inspection:view')")
    public InspectionDecisionRecordPage list(
            String rawDecision,
            String rawKeyword,
            OffsetDateTime from,
            OffsetDateTime to,
            String rawSourceType,
            String rawEffective,
            String rawDisposition,
            int requestedPage,
            int requestedSize,
            String rawSort,
            String rawOrder,
            String rawSourceNo,
            String rawReferenceNo) {
        NormalizedFilter filter = normalizeFilter(
                rawDecision, rawKeyword, from, to,
                rawSourceType, rawEffective, rawDisposition,
                requestedPage, requestedSize);
        DocNoFilter docNo = DocNoFilter.of(rawSourceNo, rawReferenceNo);
        String predicate = filteredPredicate(filter, docNo, true);
        String records = "(" + recordSql() + ") record";

        Query countQuery = em.createNativeQuery(
                "SELECT COUNT(*) FROM " + records + " WHERE " + predicate);
        bindFilters(countQuery, filter, docNo, true);
        long total = ((Number) countQuery.getSingleResult()).longValue();

        Query pageQuery = em.createNativeQuery(
                "SELECT record.* FROM " + records
                        + " WHERE " + predicate
                        + " " + orderBy(rawSort, rawOrder)
                        + " OFFSET :offset LIMIT :limit");
        bindFilters(pageQuery, filter, docNo, true);
        pageQuery.setParameter("offset", filter.offset());
        pageQuery.setParameter("limit", filter.size());
        List<InspectionDecisionRecord> items =
                NativeQueryResults.objectArrayRows(pageQuery).stream()
                        .map(ProcurementInspectionRecordQueryService::toView)
                        .toList();

        Map<String, Long> metrics = metrics(filter, docNo, records);
        int totalPages = total == 0
                ? 0 : (int) Math.min(Integer.MAX_VALUE,
                (total + filter.size() - 1) / filter.size());
        return new InspectionDecisionRecordPage(
                items, filter.page(), filter.size(), total, totalPages, metrics);
    }

    /**
     * 单号列 facets（2026-09-25 单号列统一）：{sourceNo/referenceNo/sheetNo:[…]}。
     * 与列表同一份谓词（含 decision/keyword/日期/表头三列筛选，不含单号列自身的值
     * 筛选），桶按单号升序、空串剔除。IQC 行没有检查单号（sheetNo 恒空），该桶
     * 返回空列表保持两端契约同形。
     */
    @Transactional(readOnly = true)
    @PreAuthorize("hasAuthority('procurement_inspection:view')")
    public Map<String, List<Map<String, Object>>> facets(
            String rawDecision,
            String rawKeyword,
            OffsetDateTime from,
            OffsetDateTime to,
            String rawSourceType,
            String rawEffective,
            String rawDisposition) {
        NormalizedFilter filter = normalizeFilter(
                rawDecision, rawKeyword, from, to,
                rawSourceType, rawEffective, rawDisposition,
                1, 40);
        String predicate = filteredPredicate(filter, DocNoFilter.EMPTY, true);
        String records = "(" + recordSql() + ") record";
        Map<String, List<Map<String, Object>>> result = new LinkedHashMap<>();
        for (String column : List.of("sourceNo", "referenceNo")) {
            // The public camel-case field keys map to snake-case SQL aliases.
            String expression = switch (column) {
                case "sourceNo" -> "record.source_no";
                case "referenceNo" -> "record.reference_no";
                default -> throw new IllegalArgumentException("Unknown document number field");
            };
            Query query = em.createNativeQuery(
                    "SELECT COALESCE(" + expression + ", ''), COUNT(*)"
                            + " FROM " + records + " WHERE " + predicate
                            + " GROUP BY 1 HAVING COALESCE(" + expression
                            + ", '') <> '' ORDER BY 1")
                    .setMaxResults(500);
            bindFilters(query, filter, DocNoFilter.EMPTY, true);
            result.put(column, NativeFacets.rows(NativeQueryResults.objectArrayRows(query)));
        }
        result.put("sheetNo", List.of());
        return result;
    }

    @Transactional(readOnly = true)
    @PreAuthorize("hasAuthority('procurement_inspection:view')")
    public InspectionDecisionRecord detail(UUID recordId) {
        if (recordId == null) throw notFound();
        Query query = em.createNativeQuery(
                "SELECT record.* FROM (" + recordSql() + ") record"
                        + " WHERE record.record_id = :recordId");
        query.setParameter("recordId", recordId);
        List<Object[]> rows = NativeQueryResults.objectArrayRows(query);
        if (rows.size() != 1) throw notFound();
        return toView(rows.getFirst());
    }

    private Map<String, Long> metrics(
            NormalizedFilter filter,
            DocNoFilter docNo,
            String records) {
        String predicate = filteredPredicate(filter, docNo, false);
        Query query = em.createNativeQuery(
                "SELECT record.decision, COUNT(*) FROM " + records
                        + " WHERE " + predicate
                        + " GROUP BY record.decision");
        bindFilters(query, filter, docNo, false);
        LinkedHashMap<String, Long> metrics = emptyMetrics();
        long all = 0;
        for (Object[] row : NativeQueryResults.objectArrayRows(query)) {
            String decision = string(row[0]);
            long count = ((Number) row[1]).longValue();
            if (metrics.containsKey(decision) && !"ALL".equals(decision)) {
                metrics.put(decision, count);
            }
            all += count;
        }
        metrics.put("ALL", all);
        return metrics;
    }

    /** 单号列值筛选（2026-09-25 单号列统一）：精确匹配、命名参数绑定，空=不过滤。 */
    record DocNoFilter(String sourceNo, String referenceNo) {

        static final DocNoFilter EMPTY = new DocNoFilter(null, null);

        static DocNoFilter of(String rawSourceNo, String rawReferenceNo) {
            return new DocNoFilter(
                    blankToNull(rawSourceNo), blankToNull(rawReferenceNo));
        }

        boolean isEmpty() {
            return sourceNo == null && referenceNo == null;
        }
    }

    private static String blankToNull(String raw) {
        return raw == null || raw.isBlank() ? null : raw.strip();
    }

    /** 排序白名单（2026-09-25 单号列统一）：sourceNo/referenceNo；未知/空回落默认
     *  「决定时间倒序 + 记录 id」；稳定键固定追加默认两段。 */
    private static String orderBy(String rawSort, String rawOrder) {
        String direction = "desc".equalsIgnoreCase(rawOrder) ? "DESC" : "ASC";
        return switch (rawSort == null ? "" : rawSort.strip()) {
            case "sourceNo" -> "ORDER BY record.source_no " + direction
                    + " NULLS LAST, record.decided_at DESC, record.record_id DESC";
            case "referenceNo" -> "ORDER BY record.reference_no " + direction
                    + " NULLS LAST, record.decided_at DESC, record.record_id DESC";
            default -> "ORDER BY record.decided_at DESC, record.record_id DESC";
        };
    }

    private static String filteredPredicate(
            NormalizedFilter filter,
            DocNoFilter docNo,
            boolean includeDecision) {
        StringBuilder predicate = new StringBuilder("""
                (:keyword = '' OR LOWER(CONCAT_WS(' ',
                    record.source_no, record.reference_no,
                    record.partner_name, record.warehouse_name,
                    record.goods_code, record.goods_name,
                    record.color_name, record.unit_name,
                    record.inspector_name, record.reason
                )) LIKE :keywordLike)
                """);
        if (filter.from() != null) {
            predicate.append(" AND record.decided_at >= :fromAt");
        }
        if (filter.to() != null) {
            predicate.append(" AND record.decided_at <= :toAt");
        }
        // 表头筛选三列（2026-09-16）：检验类型/当前效力/不良处置，全部参数化白名单等值。
        if (filter.sourceType() != null) {
            predicate.append(" AND record.source_type = :sourceType");
        }
        if (filter.effective() != null) {
            // 与前端 effectLabel 三档一一对应：当前有效=effective 且非撤销；
            // 历史失效=来源已红冲；撤销有效=decision CANCELLED（其 effective 恒真）。
            predicate.append(switch (filter.effective()) {
                case "ACTIVE" -> " AND record.effective AND record.decision <> 'CANCELLED'";
                case "EXPIRED" -> " AND NOT record.effective";
                case "CANCELLED" -> " AND record.decision = 'CANCELLED'";
                default -> throw new IllegalStateException(
                        "unreachable effective filter " + filter.effective());
            });
        }
        if (filter.disposition() != null) {
            predicate.append(" AND record.disposition_code = :disposition");
        }
        if (includeDecision && !"ALL".equals(filter.decision())) {
            predicate.append(" AND record.decision = :decision");
        }
        // 单号列值筛选（2026-09-25 单号列统一）：参数化等值，随条件出现才绑定。
        if (docNo.sourceNo() != null) {
            predicate.append(" AND COALESCE(record.source_no, '') = :sourceNo");
        }
        if (docNo.referenceNo() != null) {
            predicate.append(
                    " AND COALESCE(record.reference_no, '') = :referenceNo");
        }
        return predicate.toString();
    }

    private static void bindFilters(
            Query query,
            NormalizedFilter filter,
            DocNoFilter docNo,
            boolean includeDecision) {
        query.setParameter("keyword", filter.keyword());
        query.setParameter("keywordLike", "%" + filter.keyword() + "%");
        if (filter.from() != null) query.setParameter("fromAt", filter.from());
        if (filter.to() != null) query.setParameter("toAt", filter.to());
        if (filter.sourceType() != null) {
            query.setParameter("sourceType", filter.sourceType());
        }
        if (filter.disposition() != null) {
            query.setParameter("disposition", filter.disposition());
        }
        if (includeDecision && !"ALL".equals(filter.decision())) {
            query.setParameter("decision", filter.decision());
        }
        if (docNo.sourceNo() != null) {
            query.setParameter("sourceNo", docNo.sourceNo());
        }
        if (docNo.referenceNo() != null) {
            query.setParameter("referenceNo", docNo.referenceNo());
        }
    }

    static NormalizedFilter normalizeFilter(
            String rawDecision,
            String rawKeyword,
            OffsetDateTime from,
            OffsetDateTime to,
            String rawSourceType,
            String rawEffective,
            String rawDisposition,
            int requestedPage,
            int requestedSize) {
        String decision = rawDecision == null || rawDecision.isBlank()
                ? "ALL"
                : rawDecision.strip().toUpperCase(Locale.ROOT);
        if (!DECISIONS.contains(decision)) {
            throw new ApiException(
                    ErrorCode.VALIDATION_FAILED,
                    "检测记录结论仅支持 ALL、PASS、PARTIAL、FAIL 或 CANCELLED");
        }
        String sourceType = normalizeWhitelist(
                rawSourceType, SOURCE_TYPES, "检测记录检验类型仅支持 PURCHASE 或 SUBCONTRACT");
        String effective = normalizeWhitelist(
                rawEffective, EFFECTS, "检测记录当前效力仅支持 ACTIVE、EXPIRED 或 CANCELLED");
        String disposition = normalizeWhitelist(
                rawDisposition, DISPOSITIONS, "检测记录的不良处置方式不正确");
        String keyword = rawKeyword == null
                ? "" : rawKeyword.strip().toLowerCase(Locale.ROOT);
        if (keyword.length() > 200) {
            throw new ApiException(
                    ErrorCode.VALIDATION_FAILED,
                    "检测记录搜索词最多 200 个字符");
        }
        if (from != null && to != null && from.isAfter(to)) {
            throw new ApiException(
                    ErrorCode.VALIDATION_FAILED,
                    "检测记录开始时间不得晚于结束时间");
        }
        var pageable = Pageables.of(requestedPage, requestedSize);
        return new NormalizedFilter(
                decision,
                keyword,
                from,
                to,
                sourceType,
                effective,
                disposition,
                pageable.getPageNumber() + 1,
                pageable.getPageSize(),
                pageable.getOffset());
    }

    /** 表头筛选枚举归一：空白 → null（不过滤）；非法值 fail-closed 抛校验错。 */
    private static String normalizeWhitelist(
            String raw, List<String> allowed, String message) {
        if (raw == null || raw.isBlank()) {
            return null;
        }
        String normalized = raw.strip().toUpperCase(Locale.ROOT);
        if (!allowed.contains(normalized)) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, message);
        }
        return normalized;
    }

    static record NormalizedFilter(
            String decision,
            String keyword,
            OffsetDateTime from,
            OffsetDateTime to,
            String sourceType,
            String effective,
            String disposition,
            int page,
            int size,
            long offset) {
    }

    private static LinkedHashMap<String, Long> emptyMetrics() {
        LinkedHashMap<String, Long> result = new LinkedHashMap<>();
        DECISIONS.forEach(decision -> result.put(decision, 0L));
        return result;
    }

    private static String recordSql() {
        return """
                SELECT event.id AS record_id,
                       'IQC'::text AS domain,
                       inspection.receipt_type AS source_type,
                       inspection.id AS inspection_id,
                       inspection.receipt_id AS source_id,
                       inspection.receipt_item_id AS source_item_id,
                       COALESCE(purchase_receipt.bill_no,
                                subcontract_receipt.bill_no) AS source_no,
                       COALESCE(purchase_receipt.bill_date,
                                subcontract_receipt.bill_date) AS source_date,
                       COALESCE(purchase_order.bill_no,
                                 subcontract_order.bill_no) AS reference_no,
                       supplier.id AS partner_id,
                       supplier.name AS partner_name,
                       inspection.warehouse_id AS warehouse_id,
                       warehouse.name AS warehouse_name,
                       inspection.goods_id,
                       goods.code AS goods_code,
                       goods.name AS goods_name,
                       inspection.color_id AS color_id,
                       color.name AS color_name,
                       inspection.unit_id AS unit_id,
                       unit.name AS unit_name,
                       inspection.received_base_qty AS inspected_qty,
                       inspection.passed_base_qty AS current_passed_qty,
                       inspection.failed_base_qty AS current_failed_qty,
                       CASE WHEN inspection.status = 'REVERSED'
                            THEN 0::numeric
                            ELSE GREATEST(
                                inspection.received_base_qty
                                - inspection.passed_base_qty
                                - inspection.failed_base_qty,
                                0::numeric)
                       END AS current_remaining_qty,
                       CASE event.action
                           WHEN 'RECEIPT_REVERSED' THEN 'CANCELLED'
                           ELSE event.action
                       END AS decision,
                       CASE WHEN event.action = 'PASS'
                            THEN event.base_qty ELSE 0::numeric END AS pass_qty,
                       CASE WHEN event.action = 'FAIL'
                            THEN event.base_qty ELSE 0::numeric END AS fail_qty,
                       NULL::text AS disposition_code,
                       event.reason,
                       event.actor_employee_id AS inspector_employee_id,
                       employee.full_name AS inspector_name,
                       event.occurred_at AS decided_at,
                       inspection.status AS current_status,
                       CASE WHEN event.action = 'RECEIPT_REVERSED' THEN TRUE
                            ELSE inspection.status <> 'REVERSED'
                       END AS effective
                FROM procurement_inspection_events event
                JOIN procurement_inspection_items inspection
                  ON inspection.id = event.inspection_item_id
                LEFT JOIN purchase_receipts purchase_receipt
                  ON inspection.receipt_type = 'PURCHASE'
                 AND purchase_receipt.id = inspection.receipt_id
                LEFT JOIN subcontract_receipts subcontract_receipt
                  ON inspection.receipt_type = 'SUBCONTRACT'
                 AND subcontract_receipt.id = inspection.receipt_id
                LEFT JOIN purchase_receipt_items purchase_receipt_item
                  ON inspection.receipt_type = 'PURCHASE'
                 AND purchase_receipt_item.id = inspection.receipt_item_id
                LEFT JOIN purchase_order_items purchase_order_item
                  ON purchase_order_item.id = purchase_receipt_item.order_item_id
                LEFT JOIN purchase_orders purchase_order
                  ON purchase_order.id = purchase_order_item.order_id
                LEFT JOIN subcontract_receipt_items subcontract_receipt_item
                  ON inspection.receipt_type = 'SUBCONTRACT'
                 AND subcontract_receipt_item.id = inspection.receipt_item_id
                LEFT JOIN subcontract_order_items subcontract_order_item
                  ON subcontract_order_item.id = subcontract_receipt_item.order_item_id
                LEFT JOIN subcontract_orders subcontract_order
                  ON subcontract_order.id = subcontract_order_item.order_id
                LEFT JOIN suppliers supplier
                  ON supplier.id = COALESCE(
                      purchase_receipt.supplier_id,
                      subcontract_receipt.supplier_id)
                LEFT JOIN warehouses warehouse
                  ON warehouse.id = inspection.warehouse_id
                LEFT JOIN goods goods ON goods.id = inspection.goods_id
                LEFT JOIN colors color ON color.id = inspection.color_id
                LEFT JOIN units unit ON unit.id = inspection.unit_id
                LEFT JOIN employees employee
                  ON employee.id = event.actor_employee_id
                WHERE event.action IN ('PASS', 'FAIL', 'RECEIPT_REVERSED')
                """;
    }

    private static InspectionDecisionRecord toView(Object[] row) {
        return new InspectionDecisionRecord(
                (UUID) row[0],
                string(row[1]),
                string(row[2]),
                (UUID) row[3],
                (UUID) row[4],
                (UUID) row[5],
                NativeValueConverters.text(row[6]),
                NativeValueConverters.toLocalDate(row[7]),
                NativeValueConverters.text(row[8]),
                (UUID) row[9],
                NativeValueConverters.text(row[10]),
                (UUID) row[11],
                NativeValueConverters.text(row[12]),
                (UUID) row[13],
                NativeValueConverters.text(row[14]),
                NativeValueConverters.text(row[15]),
                (UUID) row[16],
                NativeValueConverters.text(row[17]),
                (UUID) row[18],
                NativeValueConverters.text(row[19]),
                NativeValueConverters.toBigDecimal(row[20]),
                NativeValueConverters.toBigDecimal(row[21]),
                NativeValueConverters.toBigDecimal(row[22]),
                NativeValueConverters.toBigDecimal(row[23]),
                string(row[24]),
                NativeValueConverters.toBigDecimal(row[25]),
                NativeValueConverters.toBigDecimal(row[26]),
                NativeValueConverters.text(row[27]),
                NativeValueConverters.text(row[28]),
                (UUID) row[29],
                NativeValueConverters.text(row[30]),
                NativeValueConverters.toOffsetDateTime(row[31]),
                string(row[32]),
                Boolean.TRUE.equals(row[33]));
    }

    private static String string(Object value) {
        return value == null ? "" : value.toString();
    }

    private static ApiException notFound() {
        return new ApiException(ErrorCode.NOT_FOUND, "IQC 检测决定记录不存在");
    }
}
