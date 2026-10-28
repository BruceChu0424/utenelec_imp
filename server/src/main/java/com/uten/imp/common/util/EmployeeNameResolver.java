package com.uten.imp.common.util;

import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;
import org.springframework.transaction.annotation.Transactional;

import java.util.Collection;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.UUID;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;

/**
 * 员工姓名解析：制单员/审核员等业务人名 ID → 员工姓名。
 *
 * <p>制单员/审核员字段统一存 employees.id（建单/审核时由 SecurityContextCurrentUser.requireEmployeeId 写入）。
 * 兼容两类历史数据：
 * <ol>
 *   <li>回填前写入的 users.id（账号 ID）→ 经 users.employee_id 解析其绑定员工姓名；</li>
 *   <li>老库迁移行：maker/approver 为 NULL，姓名使用 maker_name / approver_name 冻结名（报表层处理）；旧账号编号不映射员工。</li>
 * </ol>
 */
@Component
@RequiredArgsConstructor
public class EmployeeNameResolver {

    private final EntityManager em;

    static final int READ_BATCH_SIZE = 256;

    /**
     * Page-local read projection with the same employee-first/legacy-user fallback as nameOf.
     * Null and unknown ids resolve to null, duplicates are read once, and deleted employees
     * remain readable as historical identities. The returned map is immutable, not cached.
     */
    @Transactional(readOnly = true)
    public Map<UUID, String> namesOf(Collection<UUID> ids) {
        return readNames(ids, false);
    }

    /** Same bounded lookup as namesOf, preserving nameWithCodeOf's SQL value semantics. */
    @Transactional(readOnly = true)
    public Map<UUID, String> namesWithCodeOf(Collection<UUID> ids) {
        return readNames(ids, true);
    }

    private Map<UUID, String> readNames(Collection<UUID> ids, boolean withCode) {
        if (ids == null || ids.isEmpty()) return Collections.emptyMap();
        List<UUID> unique = ids.stream().filter(Objects::nonNull).distinct().toList();
        if (unique.isEmpty()) return Collections.emptyMap();
        String sql = """
                WITH requested_ids(id) AS (VALUES %s)
                SELECT requested.id, COALESCE(%s, %s)
                FROM requested_ids requested
                LEFT JOIN employees direct_employee ON direct_employee.id = fn_canonical_employee_identity(requested.id)
                LEFT JOIN users legacy_user ON legacy_user.id = requested.id
                LEFT JOIN users retained_user ON retained_user.id = fn_employee_merge_retained_user(requested.id)
                LEFT JOIN employees legacy_employee ON legacy_employee.id = fn_canonical_employee_identity(
                    COALESCE(legacy_user.employee_id,retained_user.employee_id))
                """.formatted("%s", readNameExpression("direct_employee", withCode),
                        readNameExpression("legacy_employee", withCode));
        Map<UUID, String> result = new LinkedHashMap<>();
        for (int start = 0; start < unique.size(); start += READ_BATCH_SIZE) {
            List<UUID> batch = unique.subList(start, Math.min(start + READ_BATCH_SIZE, unique.size()));
            String values = java.util.stream.IntStream.range(0,batch.size())
                    .mapToObj(index -> "(CAST(:raw" + index + " AS uuid))")
                    .collect(java.util.stream.Collectors.joining(","));
            var query = em.createNativeQuery(sql.formatted(values));
            for (int index=0;index<batch.size();index++) query.setParameter("raw"+index,batch.get(index));
            for (Object[] row : NativeQueryResults.objectArrayRows(
                    query)) {
                if (row[1] != null) result.put((UUID) row[0], row[1].toString());
            }
        }
        // Unlike Map.copyOf, this map also permits a null lookup for optional employee ids.
        return Collections.unmodifiableMap(result);
    }

    private static String readNameExpression(String alias, boolean withCode) {
        return alias + ".full_name" + (withCode ? " || '(' || " + alias + ".code || ')'" : "");
    }

    /** 按 employees.id 直查；查不到再按 users.id 兼容解析。皆无返回 null。 */
    public String nameOf(UUID id) {
        if (id == null) return null;
        Object direct = findFirst(
                "SELECT full_name FROM employees WHERE id = fn_canonical_employee_identity(:id)", id);
        if (direct != null) return direct.toString();
        Object viaUser = findFirst(
                "SELECT e.full_name FROM users u JOIN employees e ON e.id = fn_canonical_employee_identity(u.employee_id)"
                        + " WHERE u.id = COALESCE((SELECT id FROM users WHERE id=:id),fn_employee_merge_retained_user(:id))", id);
        return viaUser != null ? viaUser.toString() : null;
    }

    /**
     * 「姓名(工号)」解析：进度追踪/责任追溯场景用，避免重名歧义。
     * 解析路径与 {@link #nameOf} 相同（employees.id 直查 → users.id 兼容）；
     * 工号缺失时退化为纯姓名，皆无返回 null。
     */
    public String nameWithCodeOf(UUID id) {
        if (id == null) return null;
        Object direct = findFirst(
                "SELECT full_name || '(' || code || ')' FROM employees WHERE id = fn_canonical_employee_identity(:id)", id);
        if (direct != null) return direct.toString();
        Object viaUser = findFirst(
                "SELECT e.full_name || '(' || e.code || ')' FROM users u"
                        + " JOIN employees e ON e.id = fn_canonical_employee_identity(u.employee_id)"
                        + " WHERE u.id = COALESCE((SELECT id FROM users WHERE id=:id),fn_employee_merge_retained_user(:id))", id);
        return viaUser != null ? viaUser.toString() : null;
    }

    /** B_Worker roles only. Account actors and current ownership have no legacy fallback here. */
    public enum HistoricalWorkerRole {
        PURCHASE_REQUEST_APPLICANT("purchase_requests", "applicant_id", "applicant_legacy_id"),
        PURCHASE_ORDER_PURCHASER("purchase_orders", "purchaser_id", "purchaser_legacy_id"),
        PURCHASE_RECEIPT_SENDER("purchase_receipts", "sender_id", "sender_legacy_id"),
        PURCHASE_RECEIPT_RECEIVER("purchase_receipts", "receiver_id", "receiver_legacy_id"),
        PURCHASE_RECEIPT_PURCHASER("purchase_receipts", "purchaser_id", "purchaser_legacy_id"),
        SUBCONTRACT_RECEIPT_RECEIVER("subcontract_receipts", "sender_id", "receiver_legacy_id"),
        SUBCONTRACT_MATERIAL_ISSUE_OPERATOR("subcontract_material_issues", "worker_id", "operator_legacy_id"),
        SUBCONTRACT_MATERIAL_RETURN_OPERATOR("subcontract_material_returns", "worker_id", "operator_legacy_id"),
        SALES_ORDER_SELLER("sales_orders", "seller_id", "seller_legacy_id"),
        SALES_SHIPMENT_SELLER("sales_shipments", "seller_id", "seller_legacy_id"),
        SALES_SHIPMENT_SENDER("sales_shipments", "sender_id", "sender_legacy_id"),
        SALES_OTHER_SHIPMENT_SELLER("sales_other_shipments", "seller_id", "seller_legacy_id"),
        SALES_OTHER_SHIPMENT_SENDER("sales_other_shipments", "sender_id", "sender_legacy_id"),
        SALES_RETURN_SELLER("sales_returns", "seller_id", "seller_legacy_id");

        private final String table;
        private final String employeeColumn;
        private final String legacyColumn;

        HistoricalWorkerRole(String table, String employeeColumn, String legacyColumn) {
            this.table = table;
            this.employeeColumn = employeeColumn;
            this.legacyColumn = legacyColumn;
        }
    }

    /**
     * Read projection for a previously authorized historical document. A non-null UUID remains
     * authoritative, including when its name is unknown. Only a positive legacy document id,
     * the exact document UUID and an explicitly supported B_Worker role permit the fallback.
     * The role's UUID must also be null in the stored row. Old employee ids are read from that
     * row, never inferred from a name, a new employee code, Sys_Operator or a current owner.
     * Resigned/deleted historical identities remain readable; nothing is written or cached.
     */
    @Transactional(readOnly = true)
    public String historicalWorkerNameWithCodeOf(UUID employeeId, UUID documentId,
                                                Integer documentLegacyId, HistoricalWorkerRole role) {
        if (employeeId != null) return nameWithCodeOf(employeeId);
        if (documentId == null || documentLegacyId == null || documentLegacyId <= 0 || role == null) return null;
        // All identifiers are fixed enum constants; only values enter query parameters.
        String sql = """
                SELECT employee.full_name || '(' || employee.code || ')'
                FROM %s document
                JOIN employees employee ON employee.id = fn_employee_identity_from_legacy_worker(NULLIF(document.%s, 0))
                WHERE document.id = :documentId AND document.legacy_id = :documentLegacyId
                  AND document.%s IS NULL
                """.formatted(role.table, role.legacyColumn, role.employeeColumn);
        List<?> rows = em.createNativeQuery(sql)
                .setParameter("documentId", documentId)
                .setParameter("documentLegacyId", documentLegacyId)
                .setMaxResults(2)
                .getResultList();
        return rows.size() == 1 && rows.getFirst() != null ? rows.getFirst().toString() : null;
    }

    /**
     * Resolves a writable employee reference without allowing legacy shadows to become an
     * independent source of truth.
     *
     * <p>Normal API writes are UUID-only. Legacy ids and names are accepted only as consistency
     * shadows beside a UUID; they can never create an employee relationship. Historical imports
     * use the dedicated migration SQL/adapter path instead of this online-write resolver.</p>
     */
    public EmployeeReference resolveForWrite(
            UUID id, Integer legacyId, String legacyName, String label) {
        String subject = label == null || label.isBlank() ? "员工" : label.trim();
        String requestedName = normalize(legacyName);
        Integer requestedLegacyId = normalizeLegacyId(legacyId, subject);

        if (id != null) {
            EmployeeReference target = findEmployeeById(id);
            if (target == null) {
                throw invalid(subject + " UUID 不存在或员工已删除");
            }
            requireMatchingShadows(target, requestedLegacyId, requestedName, subject);
            return target;
        }

        if (requestedLegacyId != null || requestedName != null) {
            throw invalid(subject + "必须使用员工 UUID；旧编号和姓名仅作历史快照");
        }
        return null;
    }

    private EmployeeReference findEmployeeById(UUID id) {
        List<?> rows = em.createNativeQuery("""
                        SELECT id, legacy_id, full_name
                        FROM employees
                        WHERE id = :id
                          AND COALESCE(is_deleted, false) = false
                        """)
                .setParameter("id", id)
                .setMaxResults(1)
                .getResultList();
        return rows.isEmpty() ? null : employeeReference(rows.getFirst());
    }

    private static EmployeeReference employeeReference(Object row) {
        Object[] values = (Object[]) row;
        Integer legacyId = values[1] == null ? null : ((Number) values[1]).intValue();
        return new EmployeeReference((UUID) values[0], legacyId,
                values[2] == null ? null : values[2].toString());
    }

    private static void requireMatchingShadows(
            EmployeeReference target, Integer legacyId, String name, String subject) {
        if (legacyId != null && !Objects.equals(legacyId, target.legacyId())) {
            throw conflict(subject + " UUID 与旧编号指向不同员工");
        }
        if (name != null && !Objects.equals(name, normalize(target.name()))) {
            throw conflict(subject + " UUID/旧编号与姓名指向不同员工");
        }
    }

    private static Integer normalizeLegacyId(Integer legacyId, String subject) {
        if (legacyId == null) return null;
        if (legacyId <= 0) {
            throw invalid(subject + "旧编号必须大于 0");
        }
        return legacyId;
    }

    private static String normalize(String value) {
        if (value == null) return null;
        String normalized = value.trim();
        return normalized.isEmpty() ? null : normalized;
    }

    private static ApiException invalid(String message) {
        return new ApiException(ErrorCode.VALIDATION_FAILED, message);
    }

    private static ApiException conflict(String message) {
        return new ApiException(ErrorCode.CONFLICT, message);
    }

    public record EmployeeReference(UUID id, Integer legacyId, String name) {}

    private Object findFirst(String sql, UUID id) {
        List<?> rows = em.createNativeQuery(sql)
                .setParameter("id", id)
                .setMaxResults(1)
                .getResultList();
        return rows.isEmpty() ? null : rows.getFirst();
    }
}
