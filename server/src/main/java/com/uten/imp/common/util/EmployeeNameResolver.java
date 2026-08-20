package com.uten.imp.common.util;

import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;

import java.util.List;
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
 *   <li>老库迁移行：maker/approver 为 NULL，姓名走 maker_legacy_id / maker_name 等遗留列（报表层处理）。</li>
 * </ol>
 */
@Component
@RequiredArgsConstructor
public class EmployeeNameResolver {

    private final EntityManager em;

    /** 按 employees.id 直查；查不到再按 users.id 兼容解析。皆无返回 null。 */
    public String nameOf(UUID id) {
        if (id == null) return null;
        Object direct = findFirst(
                "SELECT full_name FROM employees WHERE id = :id", id);
        if (direct != null) return direct.toString();
        Object viaUser = findFirst(
                "SELECT e.full_name FROM users u JOIN employees e ON e.id = u.employee_id WHERE u.id = :id", id);
        return viaUser != null ? viaUser.toString() : null;
    }

    /**
     * 「姓名（工号）」解析：进度追踪/责任追溯场景用，避免重名歧义。
     * 解析路径与 {@link #nameOf} 相同（employees.id 直查 → users.id 兼容）；
     * 工号缺失时退化为纯姓名，皆无返回 null。
     */
    public String nameWithCodeOf(UUID id) {
        if (id == null) return null;
        Object direct = findFirst(
                "SELECT full_name || '（' || code || '）' FROM employees WHERE id = :id", id);
        if (direct != null) return direct.toString();
        Object viaUser = findFirst(
                "SELECT e.full_name || '（' || e.code || '）' FROM users u"
                        + " JOIN employees e ON e.id = u.employee_id WHERE u.id = :id", id);
        return viaUser != null ? viaUser.toString() : null;
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
