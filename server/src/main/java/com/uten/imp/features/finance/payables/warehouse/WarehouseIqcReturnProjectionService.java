package com.uten.imp.features.finance.payables.warehouse;

import com.uten.imp.common.util.NativeQueryResults;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.finance.payables.ProcurementIqcRejectionContracts.RecordReturnRequest;
import com.uten.imp.features.finance.payables.ProcurementIqcRejectionService;
import com.uten.imp.security.SecurityContextCurrentUser;
import jakarta.persistence.EntityManager;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.sql.Date;
import java.sql.Timestamp;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.time.ZoneOffset;
import java.util.List;
import java.util.UUID;

/**
 * Warehouse-only projection and command adapter over the authoritative V440 case flow.
 * The paged list projection retired with the 2026-09-01 merge into
 * {@code WarehouseQualityResultService}; this adapter keeps the deep-link detail
 * read and the return-voucher command.
 */
@Service
public class WarehouseIqcReturnProjectionService {

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
