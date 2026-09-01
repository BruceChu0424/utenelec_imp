package com.uten.imp.features.warehouse.inbound;

import com.uten.imp.common.util.NativeQueryResults;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
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
import java.time.Instant;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.time.ZoneOffset;
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

    private final EntityManager em;

    @Transactional(readOnly = true)
    @PreAuthorize("hasAuthority('procurement_inspection:view')")
    public InspectionDecisionRecordPage list(
            String rawDecision,
            String rawKeyword,
            OffsetDateTime from,
            OffsetDateTime to,
            int requestedPage,
            int requestedSize) {
        NormalizedFilter filter = normalizeFilter(
                rawDecision, rawKeyword, from, to,
                requestedPage, requestedSize);
        String predicate = filteredPredicate(filter, true);
        String records = "(" + recordSql() + ") record";

        Query countQuery = em.createNativeQuery(
                "SELECT COUNT(*) FROM " + records + " WHERE " + predicate);
        bindFilters(countQuery, filter, true);
        long total = ((Number) countQuery.getSingleResult()).longValue();

        Query pageQuery = em.createNativeQuery(
                "SELECT record.* FROM " + records
                        + " WHERE " + predicate
                        + " ORDER BY record.decided_at DESC, record.record_id DESC"
                        + " OFFSET :offset LIMIT :limit");
        bindFilters(pageQuery, filter, true);
        pageQuery.setParameter("offset", filter.offset());
        pageQuery.setParameter("limit", filter.size());
        List<InspectionDecisionRecord> items =
                NativeQueryResults.objectArrayRows(pageQuery).stream()
                        .map(ProcurementInspectionRecordQueryService::toView)
                        .toList();

        Map<String, Long> metrics = metrics(filter, records);
        int totalPages = total == 0
                ? 0 : (int) Math.min(Integer.MAX_VALUE,
                (total + filter.size() - 1) / filter.size());
        return new InspectionDecisionRecordPage(
                items, filter.page(), filter.size(), total, totalPages, metrics);
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
            String records) {
        String predicate = filteredPredicate(filter, false);
        Query query = em.createNativeQuery(
                "SELECT record.decision, COUNT(*) FROM " + records
                        + " WHERE " + predicate
                        + " GROUP BY record.decision");
        bindFilters(query, filter, false);
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

    private static String filteredPredicate(
            NormalizedFilter filter,
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
        if (includeDecision && !"ALL".equals(filter.decision())) {
            predicate.append(" AND record.decision = :decision");
        }
        return predicate.toString();
    }

    private static void bindFilters(
            Query query,
            NormalizedFilter filter,
            boolean includeDecision) {
        query.setParameter("keyword", filter.keyword());
        query.setParameter("keywordLike", "%" + filter.keyword() + "%");
        if (filter.from() != null) query.setParameter("fromAt", filter.from());
        if (filter.to() != null) query.setParameter("toAt", filter.to());
        if (includeDecision && !"ALL".equals(filter.decision())) {
            query.setParameter("decision", filter.decision());
        }
    }

    static NormalizedFilter normalizeFilter(
            String rawDecision,
            String rawKeyword,
            OffsetDateTime from,
            OffsetDateTime to,
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
                pageable.getPageNumber() + 1,
                pageable.getPageSize(),
                pageable.getOffset());
    }

    static record NormalizedFilter(
            String decision,
            String keyword,
            OffsetDateTime from,
            OffsetDateTime to,
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
                nullableString(row[6]),
                localDate(row[7]),
                nullableString(row[8]),
                (UUID) row[9],
                nullableString(row[10]),
                (UUID) row[11],
                nullableString(row[12]),
                (UUID) row[13],
                nullableString(row[14]),
                nullableString(row[15]),
                (UUID) row[16],
                nullableString(row[17]),
                (UUID) row[18],
                nullableString(row[19]),
                dec(row[20]),
                dec(row[21]),
                dec(row[22]),
                dec(row[23]),
                string(row[24]),
                dec(row[25]),
                dec(row[26]),
                nullableString(row[27]),
                nullableString(row[28]),
                (UUID) row[29],
                nullableString(row[30]),
                offsetDateTime(row[31]),
                string(row[32]),
                Boolean.TRUE.equals(row[33]));
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
        if (value instanceof Instant instant) return instant.atOffset(ZoneOffset.UTC);
        if (value instanceof java.sql.Timestamp timestamp) {
            return timestamp.toInstant().atOffset(ZoneOffset.UTC);
        }
        if (value instanceof java.util.Date date) {
            return date.toInstant().atOffset(ZoneOffset.UTC);
        }
        return OffsetDateTime.parse(value.toString());
    }

    private static BigDecimal dec(Object value) {
        if (value == null) return BigDecimal.ZERO;
        if (value instanceof BigDecimal decimal) return decimal;
        return new BigDecimal(value.toString());
    }

    private static String string(Object value) {
        return value == null ? "" : value.toString();
    }

    private static String nullableString(Object value) {
        return value == null ? null : value.toString();
    }

    private static ApiException notFound() {
        return new ApiException(ErrorCode.NOT_FOUND, "IQC 检测决定记录不存在");
    }
}
