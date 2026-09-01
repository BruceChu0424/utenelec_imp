package com.uten.imp.features.finance.payables.warehouse;

import com.uten.imp.common.util.NativeQueryResults;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.common.web.Pageables;
import com.uten.imp.features.finance.payables.ProcurementIqcRejectionContracts.RecordReturnRequest;
import com.uten.imp.features.finance.payables.ProcurementIqcRejectionService;
import com.uten.imp.security.SecurityContextCurrentUser;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.springframework.data.domain.PageRequest;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.sql.Date;
import java.sql.Timestamp;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.time.ZoneOffset;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.UUID;

/** Warehouse-only projection and command adapter over the authoritative V440 case flow. */
@Service
public class WarehouseIqcReturnProjectionService {

    private static final Set<String> RECEIPT_TYPES = Set.of("PURCHASE", "SUBCONTRACT");
    private static final Set<String> PHYSICAL_STATUSES =
            Set.of("PENDING_RETURN", "RETURN_RECORDED", "VOIDED");

    private final EntityManager entityManager;
    private final SecurityContextCurrentUser currentUser;
    private final ProcurementIqcRejectionService rejectionService;

    public WarehouseIqcReturnProjectionService(
            EntityManager entityManager,
            SecurityContextCurrentUser currentUser,
            ProcurementIqcRejectionService rejectionService) {
        this.entityManager = entityManager;
        this.currentUser = currentUser;
        this.rejectionService = rejectionService;
    }

    @Transactional(readOnly = true)
    public PageResponse<WarehouseIqcReturnView> list(
            String rawReceiptType,
            String rawPhysicalStatus,
            String keyword,
            int page,
            int size) {
        String receiptType = receiptType(rawReceiptType);
        String physicalStatus = physicalStatus(rawPhysicalStatus);
        String normalizedKeyword = normalize(keyword);
        PageRequest pageable = Pageables.of(page, size);
        int safePage = pageable.getPageNumber() + 1;
        int safeSize = pageable.getPageSize();
        StringBuilder where = new StringBuilder(
                " WHERE COALESCE(rejection.is_deleted,FALSE)=FALSE");
        Map<String, Object> parameters = new LinkedHashMap<>();
        if (receiptType != null) {
            where.append(" AND rejection.receipt_type=:receiptType");
            parameters.put("receiptType", receiptType);
        }
        if (physicalStatus != null) {
            where.append("""
                     AND (CASE
                            WHEN rejection.return_recorded_at IS NOT NULL
                              THEN 'RETURN_RECORDED'
                            WHEN rejection.status='REVERSED' THEN 'VOIDED'
                            ELSE 'PENDING_RETURN'
                          END)=:physicalStatus
                    """);
            parameters.put("physicalStatus", physicalStatus);
        }
        if (normalizedKeyword != null) {
            where.append(" AND (LOWER(rejection.receipt_bill_no) LIKE :keyword")
                    .append(" OR LOWER(COALESCE(rejection.order_bill_no,'')) LIKE :keyword")
                    .append(" OR LOWER(COALESCE(supplier.name,'')) LIKE :keyword")
                    .append(" OR LOWER(COALESCE(goods.code,'')) LIKE :keyword")
                    .append(" OR LOWER(COALESCE(goods.name,'')) LIKE :keyword)");
            parameters.put("keyword", "%" + normalizedKeyword.toLowerCase(Locale.ROOT) + "%");
        }
        Query data = entityManager.createNativeQuery(selectSql() + fromSql() + where
                + " ORDER BY rejection.created_at DESC,rejection.id DESC"
                + " LIMIT :limit OFFSET :offset");
        bind(data, parameters);
        data.setParameter("limit", safeSize);
        data.setParameter("offset", pageable.getOffset());
        boolean canRecord = has(WarehouseIqcReturnPermissions.RECORD_RETURN);
        List<WarehouseIqcReturnView> items = NativeQueryResults.objectArrayRows(data).stream()
                .map(row -> view(row, canRecord))
                .toList();

        Query count = entityManager.createNativeQuery("SELECT COUNT(*)" + fromSql() + where);
        bind(count, parameters);
        long total = ((Number) count.getSingleResult()).longValue();
        int totalPages = (int) ((total + safeSize - 1) / safeSize);
        return new PageResponse<>(items, safePage, safeSize, total, totalPages);
    }

    @Transactional(readOnly = true)
    public WarehouseIqcReturnView detail(UUID id) {
        List<Object[]> rows = NativeQueryResults.objectArrayRows(
                entityManager.createNativeQuery(selectSql() + fromSql() + """
                                WHERE COALESCE(rejection.is_deleted,FALSE)=FALSE
                                  AND rejection.id=:id
                                """)
                        .setParameter("id", id)
                        .setMaxResults(1));
        if (rows.isEmpty()) {
            throw new ApiException(ErrorCode.NOT_FOUND, "IQC不合格实物退回任务不存在");
        }
        return view(rows.getFirst(), has(WarehouseIqcReturnPermissions.RECORD_RETURN));
    }

    @Transactional
    public WarehouseIqcReturnView recordReturn(UUID id, RecordReturnRequest request) {
        rejectionService.recordReturn(id, request);
        return detail(id);
    }

    static String selectSql() {
        return """
                SELECT rejection.id,
                       rejection.receipt_type,
                       rejection.receipt_id,
                       rejection.receipt_item_id,
                       rejection.inspection_item_id,
                       rejection.receipt_bill_no,
                       rejection.order_bill_no,
                       rejection.supplier_id,
                       supplier.name AS supplier_name,
                       inspection.warehouse_id,
                       warehouse.name AS warehouse_name,
                       rejection.goods_id,
                       goods.code AS goods_code,
                       goods.name AS goods_name,
                       rejection.color_id,
                       color.name AS color_name,
                       rejection.unit_id,
                       unit.name AS unit_name,
                       inspection.status AS inspection_status,
                       rejection.failed_base_qty,
                       rejection.failed_qty,
                       CASE
                         WHEN rejection.return_recorded_at IS NOT NULL THEN 'RETURN_RECORDED'
                         WHEN rejection.status='REVERSED' THEN 'VOIDED'
                         ELSE 'PENDING_RETURN'
                       END AS physical_return_status,
                       rejection.row_version,
                       rejection.return_reference,
                       rejection.return_date,
                       rejection.return_note,
                       COALESCE(return_employee.full_name,return_user.login_account)
                           AS return_recorded_by_name,
                       rejection.return_recorded_at,
                       CASE WHEN rejection.status IN ('PENDING_RETURN','FINANCE_EXCEPTION')
                                  AND inspection.status='RESOLVED'
                                  AND NOT EXISTS (
                                      SELECT 1 FROM business_outbox pending_outbox
                                      WHERE pending_outbox.event_type='PROCUREMENT_IQC_REJECTION_DETECTED'
                                        AND pending_outbox.aggregate_id=inspection.id
                                        AND pending_outbox.status<>1)
                            THEN TRUE ELSE FALSE END AS can_record_return
                """;
    }

    static String fromSql() {
        return """
                 FROM procurement_iqc_rejection_cases rejection
                 JOIN suppliers supplier ON supplier.id=rejection.supplier_id
                 JOIN goods goods ON goods.id=rejection.goods_id
                 JOIN procurement_inspection_items inspection
                   ON inspection.id=rejection.inspection_item_id
                 LEFT JOIN warehouses warehouse ON warehouse.id=inspection.warehouse_id
                 LEFT JOIN colors color ON color.id=rejection.color_id
                 LEFT JOIN units unit ON unit.id=rejection.unit_id
                 LEFT JOIN users return_user ON return_user.id=rejection.return_recorded_by
                 LEFT JOIN employees return_employee ON return_employee.id=return_user.employee_id
                """;
    }

    private WarehouseIqcReturnView view(Object[] row, boolean canRecord) {
        boolean serverAllowsRecord = bool(row[28]);
        return new WarehouseIqcReturnView(
                uuid(row[0]),
                text(row[1]),
                uuid(row[2]),
                uuid(row[3]),
                uuid(row[4]),
                text(row[5]),
                text(row[6]),
                uuid(row[7]),
                text(row[8]),
                uuid(row[9]),
                text(row[10]),
                uuid(row[11]),
                text(row[12]),
                text(row[13]),
                uuid(row[14]),
                text(row[15]),
                uuid(row[16]),
                text(row[17]),
                text(row[18]),
                decimal(row[19]),
                decimal(row[20]),
                text(row[21]),
                ((Number) row[22]).longValue(),
                text(row[23]),
                localDate(row[24]),
                text(row[25]),
                text(row[26]),
                offsetDateTime(row[27]),
                canRecord && serverAllowsRecord ? List.of("RECORD_RETURN") : List.of());
    }

    private boolean has(String permission) {
        return currentUser.get()
                .map(user -> user.isSuperAdmin() || user.getPermissions().contains(permission))
                .orElse(false);
    }

    private static String receiptType(String value) {
        String normalized = normalize(value);
        if (normalized == null) return null;
        normalized = normalized.toUpperCase(Locale.ROOT);
        if (!RECEIPT_TYPES.contains(normalized)) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED,
                    "收货类型仅支持 PURCHASE/SUBCONTRACT");
        }
        return normalized;
    }

    private static String physicalStatus(String value) {
        String normalized = normalize(value);
        if (normalized == null) return null;
        normalized = normalized.toUpperCase(Locale.ROOT);
        if (!PHYSICAL_STATUSES.contains(normalized)) {
            throw new ApiException(
                    ErrorCode.VALIDATION_FAILED,
                    "实物退回状态仅支持 PENDING_RETURN/RETURN_RECORDED/VOIDED");
        }
        return normalized;
    }

    private static String normalize(String value) {
        if (value == null || value.isBlank()) return null;
        return value.trim();
    }

    private static void bind(Query query, Map<String, Object> parameters) {
        parameters.forEach(query::setParameter);
    }

    private static UUID uuid(Object value) {
        if (value == null) return null;
        return value instanceof UUID id ? id : UUID.fromString(value.toString());
    }

    private static String text(Object value) {
        return value == null ? null : value.toString();
    }

    private static BigDecimal decimal(Object value) {
        if (value == null) return null;
        return value instanceof BigDecimal number ? number : new BigDecimal(value.toString());
    }

    private static LocalDate localDate(Object value) {
        if (value == null) return null;
        if (value instanceof LocalDate date) return date;
        if (value instanceof Date date) return date.toLocalDate();
        return LocalDate.parse(value.toString());
    }

    private static OffsetDateTime offsetDateTime(Object value) {
        if (value == null) return null;
        if (value instanceof OffsetDateTime dateTime) return dateTime;
        if (value instanceof Timestamp timestamp) {
            return timestamp.toInstant().atOffset(ZoneOffset.UTC);
        }
        return OffsetDateTime.parse(value.toString());
    }

    private static boolean bool(Object value) {
        return value instanceof Boolean flag
                ? flag : Boolean.parseBoolean(String.valueOf(value));
    }
}
