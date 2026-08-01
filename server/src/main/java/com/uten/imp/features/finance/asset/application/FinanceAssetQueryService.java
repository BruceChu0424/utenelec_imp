package com.uten.imp.features.finance.asset.application;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.common.web.Pageables;
import com.uten.imp.features.finance.asset.api.AssetWorkbenchResponses;
import com.uten.imp.features.finance.asset.domain.AssetPeriod;
import com.uten.imp.features.finance.asset.domain.StraightLineScheduleCalculator;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import lombok.RequiredArgsConstructor;
import org.springframework.data.domain.Pageable;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.math.RoundingMode;
import java.sql.Date;
import java.sql.Timestamp;
import java.time.Instant;
import java.time.LocalDate;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;

/** Typed CQRS read side for the asset workbench. */
@Service
@RequiredArgsConstructor
public class FinanceAssetQueryService {

    private final EntityManager em;
    private final FinanceAssetAuthorization authorization;
    private final FinanceAssetFeatureGate featureGate;

    @Transactional(readOnly = true)
    @PreAuthorize("hasAuthority('finance_asset:view')")
    public AssetWorkbenchResponses.Overview overview() {
        authorization.require(FinanceAssetAuthorization.VIEW);
        Object[] fixed = row(em.createNativeQuery("""
                SELECT COALESCE(SUM(a.original_value),0),
                       COALESCE(SUM(a.original_value - COALESCE(x.accumulated,0)),0)
                FROM fixed_assets a
                LEFT JOIN LATERAL (
                    SELECT SUM(l.amount) accumulated
                    FROM fa_depreciation_log l
                    WHERE l.asset_id=a.id AND l.entry_kind='NORMAL'
                      AND l.status='ACTIVE' AND l.is_deleted=false
                ) x ON TRUE
                WHERE a.is_deleted=false AND a.lifecycle_status IN ('ACTIVE','DISPOSAL_PENDING')
                """).getSingleResult());
        BigDecimal deferred = decimal(em.createNativeQuery("""
                SELECT COALESCE(SUM(a.total_amount - COALESCE(x.accumulated,0)),0)
                FROM deferred_expenses a
                LEFT JOIN LATERAL (
                    SELECT SUM(l.amount) accumulated
                    FROM da_amortization_log l
                    WHERE l.deferred_id=a.id AND l.entry_kind='NORMAL'
                      AND l.status='ACTIVE' AND l.is_deleted=false
                ) x ON TRUE
                WHERE a.is_deleted=false AND a.lifecycle_status IN ('ACTIVE','TERMINATION_PENDING')
                """).getSingleResult());
        long pending = number(em.createNativeQuery("""
                SELECT (SELECT COUNT(*) FROM fixed_assets
                        WHERE lifecycle_status='PENDING_APPROVAL' AND is_deleted=false)
                     + (SELECT COUNT(*) FROM deferred_expenses
                        WHERE lifecycle_status='PENDING_APPROVAL' AND is_deleted=false)
                     + (SELECT COUNT(*) FROM finance_asset_posting_runs
                        WHERE status='SUBMITTED')
                """).getSingleResult()).longValue();
        long exceptions = number(em.createNativeQuery("""
                SELECT COUNT(*)
                FROM finance_asset_posting_runs r
                WHERE r.status IN ('PREVIEWED','SUBMITTED','APPROVED')
                  AND EXISTS (
                      SELECT 1 FROM jsonb_array_elements(r.exception_snapshot) issue
                      WHERE COALESCE(issue->>'severity','BLOCKING')='BLOCKING')
                """).getSingleResult()).longValue();
        List<String> missing = new ArrayList<>();
        if (!hasReadyCategory("FIXED_ASSET")) missing.add("FIXED_ASSET_CATEGORY_POLICY");
        if (!hasReadyCategory("DEFERRED_EXPENSE")) missing.add("DEFERRED_EXPENSE_CATEGORY_POLICY");
        boolean postedWorkflowsEnabled = featureGate.postedWorkflowsEnabled();
        List<String> blockers = postedWorkflowsEnabled ? List.of() : List.of(
                "Initial recognition, disposal and termination posting are disabled until dedicated maker-checker business-event reversal is delivered");
        return new AssetWorkbenchResponses.Overview(
                decimal(fixed[0]), decimal(fixed[1]), deferred,
                pending, exceptions, pending + exceptions, Instant.now().toString(),
                missing.isEmpty(), List.copyOf(missing), postedWorkflowsEnabled, blockers);
    }

    @Transactional(readOnly = true)
    @PreAuthorize("hasAuthority('finance_asset:view')")
    public PageResponse<AssetWorkbenchResponses.Summary> listFixedAssets(
            String q, String status, UUID categoryId, UUID departmentId, int page, int size) {
        authorization.require(FinanceAssetAuthorization.VIEW);
        FilterSql filter = filters("a", q, status, categoryId, departmentId);
        String select = """
                SELECT a.id, 'FIXED_ASSET', a.code, a.name, a.lifecycle_status,
                       a.category_id, c.name, a.department_id, d.name,
                       a.custodian_employee_id, e.full_name, a.location_text,
                       a.original_value, NULL::numeric,
                       CASE WHEN a.lifecycle_status='DISPOSED' THEN 0
                            ELSE a.original_value-COALESCE(x.accumulated,0) END, NULL::numeric,
                       a.salvage_rate, a.useful_months, a.start_period,
                       a.ready_for_use_on, NULL::date, a.operating_status,
                       a.source_type, a.source_ref, a.remark, a.row_version,
                       CASE WHEN a.lifecycle_status='DISPOSAL_PENDING' THEN
                           (SELECT s.actor_user_id FROM finance_asset_approval_steps s
                            WHERE s.object_type='FIXED_ASSET' AND s.object_id=a.id
                              AND s.workflow_type='DISPOSAL' AND s.action='SUBMIT'
                            ORDER BY s.step_no DESC LIMIT 1)
                           ELSE COALESCE(a.submitted_by,a.created_by) END,
                       a.acquired_on,a.accepted_on,a.serial_number,a.asset_tag,a.cost_center_code,
                       NULL::date,a.source_id,a.source_line_ref,a.source_document_date,NULL::uuid
                FROM fixed_assets a
                LEFT JOIN finance_asset_categories c ON c.id=a.category_id
                LEFT JOIN departments d ON d.id=a.department_id
                LEFT JOIN employees e ON e.id=a.custodian_employee_id
                LEFT JOIN LATERAL (
                    SELECT SUM(l.amount) accumulated FROM fa_depreciation_log l
                    WHERE l.asset_id=a.id AND l.entry_kind='NORMAL'
                      AND l.status='ACTIVE' AND l.is_deleted=false
                ) x ON TRUE
                WHERE a.is_deleted=false
                """ + filter.where() + " ORDER BY a.code,a.id";
        return page(select, "SELECT COUNT(*) FROM fixed_assets a WHERE a.is_deleted=false" + filter.where(),
                filter, page, size, false);
    }

    @Transactional(readOnly = true)
    @PreAuthorize("hasAuthority('finance_asset:view')")
    public PageResponse<AssetWorkbenchResponses.Summary> listDeferredExpenses(
            String q, String status, UUID categoryId, UUID departmentId, int page, int size) {
        authorization.require(FinanceAssetAuthorization.VIEW);
        FilterSql filter = filters("a", q, status, categoryId, departmentId);
        String select = """
                SELECT a.id, 'DEFERRED_EXPENSE', a.code, a.name, a.lifecycle_status,
                       a.category_id, c.name, a.department_id, d.name,
                       a.responsible_employee_id, e.full_name, a.location_text,
                       NULL::numeric, a.total_amount,
                       NULL::numeric, CASE WHEN a.lifecycle_status IN ('COMPLETED','TERMINATED') THEN 0
                            ELSE a.total_amount-COALESCE(x.accumulated,0) END,
                       NULL::numeric, a.useful_months, a.start_period,
                       NULL::date, a.service_start_on, NULL::text,
                       a.source_type, a.source_ref, a.remark, a.row_version,
                       CASE WHEN a.lifecycle_status='TERMINATION_PENDING' THEN
                           (SELECT s.actor_user_id FROM finance_asset_approval_steps s
                            WHERE s.object_type='DEFERRED_EXPENSE' AND s.object_id=a.id
                              AND s.workflow_type='TERMINATION' AND s.action='SUBMIT'
                            ORDER BY s.step_no DESC LIMIT 1)
                           ELSE COALESCE(a.submitted_by,a.created_by) END,
                       NULL::date,NULL::date,NULL::text,NULL::text,a.cost_center_code,
                       a.benefit_end_on,a.source_id,a.source_line_ref,a.source_document_date,
                       a.responsible_employee_id
                FROM deferred_expenses a
                LEFT JOIN finance_asset_categories c ON c.id=a.category_id
                LEFT JOIN departments d ON d.id=a.department_id
                LEFT JOIN employees e ON e.id=a.responsible_employee_id
                LEFT JOIN LATERAL (
                    SELECT SUM(l.amount) accumulated FROM da_amortization_log l
                    WHERE l.deferred_id=a.id AND l.entry_kind='NORMAL'
                      AND l.status='ACTIVE' AND l.is_deleted=false
                ) x ON TRUE
                WHERE a.is_deleted=false
                """ + filter.where() + " ORDER BY a.code,a.id";
        return page(select, "SELECT COUNT(*) FROM deferred_expenses a WHERE a.is_deleted=false" + filter.where(),
                filter, page, size, true);
    }

    @Transactional(readOnly = true)
    @PreAuthorize("hasAuthority('finance_asset:view')")
    public AssetWorkbenchResponses.Detail fixedAsset(UUID id) {
        authorization.require(FinanceAssetAuthorization.VIEW);
        AssetWorkbenchResponses.Summary summary = summaryById(id, false);
        List<AssetWorkbenchResponses.Balance> books = fixedBooks(id);
        List<AssetWorkbenchResponses.ScheduleLine> schedule = fixedSchedule(id);
        return detail(summary, books, schedule, "FIXED_ASSET");
    }

    @Transactional(readOnly = true)
    @PreAuthorize("hasAuthority('finance_asset:view')")
    public AssetWorkbenchResponses.Detail deferredExpense(UUID id) {
        authorization.require(FinanceAssetAuthorization.VIEW);
        AssetWorkbenchResponses.Summary summary = summaryById(id, true);
        List<AssetWorkbenchResponses.Balance> balances = List.of(new AssetWorkbenchResponses.Balance(
                "CORPORATE", summary.totalAmount(), BigDecimal.ZERO,
                summary.totalAmount().subtract(summary.remainingAmount()), summary.remainingAmount(),
                monthly(summary.totalAmount(), summary.usefulMonths()), summary.startPeriod(), summary.status()));
        return detail(summary, balances, deferredSchedule(id), "DEFERRED_EXPENSE");
    }

    private AssetWorkbenchResponses.Detail detail(
            AssetWorkbenchResponses.Summary summary,
            List<AssetWorkbenchResponses.Balance> books,
            List<AssetWorkbenchResponses.ScheduleLine> schedule,
            String objectType) {
        List<AssetWorkbenchResponses.ApprovalStep> approvals = approvalSteps(objectType, summary.id());
        List<AssetWorkbenchResponses.Event> events = events(objectType, summary.id());
        List<String> vouchers = voucherNumbers(objectType, summary.id());
        List<String> documents = summary.sourceRef() == null ? List.of() : List.of(summary.sourceRef());
        return new AssetWorkbenchResponses.Detail(
                summary, books, books, schedule, approvals, events, vouchers, documents,
                summary.allowedActions());
    }

    private AssetWorkbenchResponses.Summary summaryById(UUID id, boolean deferred) {
        PageResponse<AssetWorkbenchResponses.Summary> result = deferred
                ? listDeferredExpenses(null, null, null, null, 1, 100)
                : listFixedAssets(null, null, null, null, 1, 100);
        return result.getItems().stream().filter(item -> item.id().equals(id)).findFirst()
                .orElseGet(() -> summaryDirect(id, deferred));
    }

    private AssetWorkbenchResponses.Summary summaryDirect(UUID id, boolean deferred) {
        // Direct fallback keeps detail O(1) even when the requested card is outside the first list page.
        String table = deferred ? "deferred_expenses" : "fixed_assets";
        Number found = (Number) em.createNativeQuery("SELECT COUNT(*) FROM " + table + " WHERE id=:id AND is_deleted=false")
                .setParameter("id", id).getSingleResult();
        if (found.longValue() == 0) throw new ApiException(ErrorCode.NOT_FOUND, "Asset record not found");
        PageResponse<AssetWorkbenchResponses.Summary> all = deferred
                ? listDeferredExpenses(id.toString(), null, null, null, 1, 1)
                : listFixedAssets(id.toString(), null, null, null, 1, 1);
        if (all.getItems().isEmpty()) throw new ApiException(ErrorCode.NOT_FOUND, "Asset record not found");
        return all.getItems().getFirst();
    }

    private PageResponse<AssetWorkbenchResponses.Summary> page(
            String sql,
            String countSql,
            FilterSql filter,
            int page,
            int size,
            boolean deferred) {
        Pageable pageable = Pageables.of(page, size);
        Query data = bind(em.createNativeQuery(sql), filter);
        Query count = bind(em.createNativeQuery(countSql), filter);
        @SuppressWarnings("unchecked")
        List<Object[]> rows = data.setFirstResult((int) pageable.getOffset())
                .setMaxResults(pageable.getPageSize()).getResultList();
        long total = number(count.getSingleResult()).longValue();
        List<AssetWorkbenchResponses.Summary> items = rows.stream()
                .map(row -> summary(row, deferred)).toList();
        return new PageResponse<>(items, pageable.getPageNumber() + 1, pageable.getPageSize(), total,
                (int) Math.ceil((double) total / pageable.getPageSize()));
    }

    private AssetWorkbenchResponses.Summary summary(Object[] row, boolean deferred) {
        String status = text(row[4]);
        UUID maker = uuid(row[26]);
        Set<String> actions = authorization.allowedActions(status, maker, deferred);
        return new AssetWorkbenchResponses.Summary(
                uuid(row[0]), text(row[1]), text(row[2]), text(row[3]), status, null,
                uuid(row[5]), text(row[6]), uuid(row[7]), text(row[8]), uuid(row[9]), text(row[10]), text(row[11]),
                decimalOrNull(row[12]), decimalOrNull(row[13]), decimalOrNull(row[14]), decimalOrNull(row[15]),
                decimalOrNull(row[16]), row[17] == null ? null : number(row[17]).intValue(), text(row[18]),
                date(row[19]), date(row[20]), text(row[21]), text(row[22]), text(row[23]), text(row[24]),
                number(row[25]).longValue(), actions,
                date(row[27]), date(row[28]), text(row[29]), text(row[30]), text(row[31]),
                date(row[32]), uuid(row[33]), text(row[34]), date(row[35]), uuid(row[36]));
    }

    private List<AssetWorkbenchResponses.Balance> fixedBooks(UUID assetId) {
        @SuppressWarnings("unchecked")
        List<Object[]> rows = em.createNativeQuery("""
                SELECT book_type, original_value, residual_amount, accumulated_amount,
                       net_book_value, depreciable_amount, useful_months, start_period, status
                FROM finance_asset_books
                WHERE asset_id=:asset AND is_deleted=false
                ORDER BY book_type
                """).setParameter("asset", assetId).getResultList();
        return rows.stream().map(row -> new AssetWorkbenchResponses.Balance(
                text(row[0]), decimal(row[1]), decimal(row[2]), decimal(row[3]), decimal(row[4]),
                monthly(decimal(row[5]), number(row[6]).intValue()), text(row[7]), text(row[8]))).toList();
    }

    private List<AssetWorkbenchResponses.ScheduleLine> fixedSchedule(UUID assetId) {
        @SuppressWarnings("unchecked")
        List<Object[]> books = em.createNativeQuery("""
                SELECT id, original_value, residual_rate, useful_months, start_period
                FROM finance_asset_books
                WHERE asset_id=:asset AND book_type='CORPORATE' AND is_deleted=false
                """).setParameter("asset", assetId).getResultList();
        if (books.isEmpty()) return List.of();
        Object[] book = books.getFirst();
        Map<String, Object[]> posted = new LinkedHashMap<>();
        @SuppressWarnings("unchecked")
        List<Object[]> logs = em.createNativeQuery("""
                SELECT l.id, l.period, l.voucher_id, v.voucher_no
                FROM fa_depreciation_log l
                LEFT JOIN gl_vouchers v ON v.id=l.voucher_id
                WHERE l.asset_id=:asset AND l.asset_book_id=:book AND l.entry_kind='NORMAL'
                  AND l.status='ACTIVE' AND l.is_deleted=false
                """).setParameter("asset", assetId).setParameter("book", uuid(book[0])).getResultList();
        for (Object[] log : logs) posted.put(text(log[1]), log);
        var schedule = StraightLineScheduleCalculator.calculate(
                decimal(book[1]), decimal(book[2]), number(book[3]).intValue(), AssetPeriod.parse(text(book[4])));
        List<AssetWorkbenchResponses.ScheduleLine> result = new ArrayList<>(schedule.lines().size());
        for (var line : schedule.lines()) {
            Object[] log = posted.get(line.period());
            result.add(new AssetWorkbenchResponses.ScheduleLine(
                    log == null ? null : uuid(log[0]), line.sequence(), line.period(),
                    schedule.originalAmount().subtract(line.openingAccumulated()),
                    line.amount(), line.closingAccumulated(), line.closingNetAmount(),
                    log == null ? "PLANNED" : "POSTED", log == null ? null : text(log[3])));
        }
        return List.copyOf(result);
    }

    private List<AssetWorkbenchResponses.ScheduleLine> deferredSchedule(UUID deferredId) {
        @SuppressWarnings("unchecked")
        List<Object[]> rows = em.createNativeQuery("""
                SELECT l.id, l.sequence, l.period, l.opening_balance, l.amount,
                       l.accumulated_amount, l.closing_balance,
                       CASE
                           WHEN a.id IS NOT NULL THEN 'POSTED'
                           WHEN d.lifecycle_status='TERMINATED'
                                AND l.period>=to_char(d.terminated_on,'YYYY-MM') THEN 'CANCELLED'
                           ELSE 'PLANNED'
                       END, v.voucher_no
                FROM finance_deferral_schedule_lines l
                JOIN finance_deferral_schedule_versions s ON s.id=l.schedule_version_id
                JOIN deferred_expenses d ON d.id=s.deferred_id
                LEFT JOIN da_amortization_log a ON a.schedule_line_id=l.id
                    AND a.entry_kind='NORMAL' AND a.status='ACTIVE' AND a.is_deleted=false
                LEFT JOIN gl_vouchers v ON v.id=a.voucher_id
                WHERE s.deferred_id=:deferred AND s.status='APPROVED'
                  AND s.is_deleted=false AND l.is_deleted=false
                ORDER BY l.sequence
                """).setParameter("deferred", deferredId).getResultList();
        return rows.stream().map(row -> new AssetWorkbenchResponses.ScheduleLine(
                uuid(row[0]), number(row[1]).intValue(), text(row[2]), decimal(row[3]), decimal(row[4]),
                decimal(row[5]), decimal(row[6]), text(row[7]), text(row[8]))).toList();
    }

    private List<AssetWorkbenchResponses.ApprovalStep> approvalSteps(String objectType, UUID objectId) {
        @SuppressWarnings("unchecked")
        List<Object[]> rows = em.createNativeQuery("""
                SELECT s.id, s.action, s.status, s.actor_user_id,
                       COALESCE(e.full_name,u.login_account), s.comment, s.occurred_at
                FROM finance_asset_approval_steps s
                JOIN users u ON u.id=s.actor_user_id
                LEFT JOIN employees e ON e.id=u.employee_id
                WHERE s.object_type=:type AND s.object_id=:id
                ORDER BY s.step_no
                """).setParameter("type", objectType).setParameter("id", objectId).getResultList();
        return rows.stream().map(row -> new AssetWorkbenchResponses.ApprovalStep(
                uuid(row[0]), text(row[1]), text(row[2]), uuid(row[3]), text(row[4]), text(row[5]), instant(row[6]))).toList();
    }

    private List<AssetWorkbenchResponses.Event> events(String objectType, UUID objectId) {
        @SuppressWarnings("unchecked")
        List<Object[]> rows = em.createNativeQuery("""
                SELECT x.id, x.event_type, x.title, x.description, x.actor_user_id,
                       COALESCE(e.full_name,u.login_account), x.effective_date, x.occurred_at
                FROM finance_asset_events x
                JOIN users u ON u.id=x.actor_user_id
                LEFT JOIN employees e ON e.id=u.employee_id
                WHERE x.object_type=:type AND x.object_id=:id
                ORDER BY x.occurred_at DESC, x.id
                """).setParameter("type", objectType).setParameter("id", objectId).getResultList();
        return rows.stream().map(row -> new AssetWorkbenchResponses.Event(
                uuid(row[0]), text(row[1]), text(row[2]), text(row[3]), uuid(row[4]), text(row[5]),
                date(row[6]), instant(row[7]))).toList();
    }

    private List<String> voucherNumbers(String objectType, UUID objectId) {
        String sourcePrefix = objectType + ":" + objectId;
        String logTable = "FIXED_ASSET".equals(objectType)
                ? "fa_depreciation_log" : "da_amortization_log";
        String objectColumn = "FIXED_ASSET".equals(objectType) ? "asset_id" : "deferred_id";
        String sql = """
                WITH related_vouchers(id) AS (
                    SELECT id FROM gl_vouchers
                    WHERE source_ref=:sourceRef AND is_deleted=false
                    UNION
                    SELECT voucher_id FROM %s
                    WHERE %s=:objectId AND voucher_id IS NOT NULL AND is_deleted=false
                )
                SELECT DISTINCT v.voucher_no
                FROM gl_vouchers v
                WHERE v.is_deleted=false
                  AND (v.id IN (SELECT id FROM related_vouchers)
                       OR v.reversal_of_voucher_id IN (SELECT id FROM related_vouchers))
                ORDER BY v.voucher_no
                """.formatted(logTable, objectColumn);
        @SuppressWarnings("unchecked")
        List<String> rows = em.createNativeQuery(sql)
                .setParameter("sourceRef", sourcePrefix)
                .setParameter("objectId", objectId)
                .getResultList();
        return List.copyOf(rows);
    }

    private boolean hasReadyCategory(String objectType) {
        String accumulated = "FIXED_ASSET".equals(objectType) ? "AND accumulated_style_id IS NOT NULL" : "";
        Number count = (Number) em.createNativeQuery("""
                SELECT COUNT(*) FROM finance_asset_categories
                WHERE object_type=:type AND status='ACTIVE' AND is_deleted=false
                  AND cost_style_id IS NOT NULL AND expense_style_id IS NOT NULL
                  AND clearing_style_id IS NOT NULL AND default_method='STRAIGHT_LINE'
                  AND default_months IS NOT NULL AND effective_from IS NOT NULL
                """ + accumulated)
                .setParameter("type", objectType).getSingleResult();
        return count.longValue() > 0;
    }

    private static FilterSql filters(String alias, String q, String status, UUID categoryId, UUID departmentId) {
        StringBuilder where = new StringBuilder();
        Map<String, Object> parameters = new LinkedHashMap<>();
        if (q != null && !q.isBlank()) {
            try {
                parameters.put("exactId", UUID.fromString(q.trim()));
                where.append(" AND ").append(alias).append(".id=:exactId");
            } catch (IllegalArgumentException ignored) {
                where.append(" AND (").append(alias).append(".code ILIKE :q OR ")
                        .append(alias).append(".name ILIKE :q OR COALESCE(")
                        .append(alias).append(".source_ref,'') ILIKE :q)");
                parameters.put("q", "%" + q.trim() + "%");
            }
        }
        if (status != null && !status.isBlank()) {
            where.append(" AND ").append(alias).append(".lifecycle_status=:status");
            parameters.put("status", status.trim());
        }
        if (categoryId != null) {
            where.append(" AND ").append(alias).append(".category_id=:categoryId");
            parameters.put("categoryId", categoryId);
        }
        if (departmentId != null) {
            where.append(" AND ").append(alias).append(".department_id=:departmentId");
            parameters.put("departmentId", departmentId);
        }
        return new FilterSql(where.toString(), parameters);
    }

    private static Query bind(Query query, FilterSql filter) {
        filter.parameters().forEach(query::setParameter);
        return query;
    }

    private static BigDecimal monthly(BigDecimal amount, Integer months) {
        if (amount == null || months == null || months == 0) return null;
        return amount.divide(BigDecimal.valueOf(months), 2, RoundingMode.HALF_UP);
    }

    private static Object[] row(Object value) {
        return (Object[]) value;
    }

    private static UUID uuid(Object value) {
        return value == null ? null : value instanceof UUID id ? id : UUID.fromString(value.toString());
    }

    private static String text(Object value) {
        return value == null ? null : value.toString();
    }

    private static Number number(Object value) {
        return (Number) value;
    }

    private static BigDecimal decimal(Object value) {
        return value == null ? BigDecimal.ZERO : (BigDecimal) value;
    }

    private static BigDecimal decimalOrNull(Object value) {
        return value == null ? null : (BigDecimal) value;
    }

    private static LocalDate date(Object value) {
        if (value == null) return null;
        return value instanceof LocalDate date ? date : ((Date) value).toLocalDate();
    }

    private static Instant instant(Object value) {
        if (value == null) return null;
        if (value instanceof Instant instant) return instant;
        if (value instanceof Timestamp timestamp) return timestamp.toInstant();
        return ((java.time.OffsetDateTime) value).toInstant();
    }

    private record FilterSql(String where, Map<String, Object> parameters) {}
}
