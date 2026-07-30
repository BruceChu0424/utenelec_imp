package com.uten.imp.features.admin;

import com.uten.imp.common.util.NativeQueryResults;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.util.ArrayList;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.UUID;

/**
 * 数据范围授权管理（V89 user_data_scopes）：按人配置「能看哪些业务员的客户/外贸货品」。
 *
 * <p>三档可见性的中间档：自己（+公共）/ <b>自己+授权归属人</b> / 全部（*:view:all）。
 * scope：goods（外贸货品）/ client（客户资料）。整体替换语义，同权限覆盖管理。
 */
@Service
@RequiredArgsConstructor
@PreAuthorize("hasAuthority('authorization:manage') and principal.superAdmin")
public class DataScopeAdminService {

    /** 合法业务范围（与 user_data_scopes.scope CHECK 一致）。 */
    private static final List<String> SCOPES = List.of("goods", "client", "sales");

    private final EntityManager em;
    private final TxSessionVars tx;
    private final AdminUserSupport support;
    private final SecurityContextCurrentUser currentUser;

    /** 某用户在某范围的授权归属人列表（员工 id）。 */
    @Transactional(readOnly = true)
    public List<UUID> getDataScopes(UUID userId, String scope) {
        support.requireCurrentSuperAdmin();
        support.require(userId);
        requireScope(scope);
        return NativeQueryResults.typedRows(em.createNativeQuery(
                        "SELECT owner_employee_id FROM user_data_scopes WHERE user_id = :uid AND scope = :scope ORDER BY created_at")
                .setParameter("uid", userId).setParameter("scope", scope), UUID.class);
    }

    /** 整体替换某用户在某范围的授权归属人。 */
    @Transactional
    public void setDataScopes(UUID userId, String scope, List<UUID> ownerEmployeeIds) {
        tx.bind();
        var target = support.require(userId);
        support.requireAuthorizationTarget(target);
        requireScope(scope);
        em.createNativeQuery("DELETE FROM user_data_scopes WHERE user_id = :uid AND scope = :scope")
                .setParameter("uid", userId).setParameter("scope", scope).executeUpdate();
        for (UUID empId : new LinkedHashSet<>(ownerEmployeeIds == null ? List.of() : ownerEmployeeIds)) {
            // 归属人必须存在（员工表 FK 兜底，这里先给友好报错）
            List<?> existingEmployees = em.createNativeQuery(
                            "SELECT 1 FROM employees WHERE id = :eid AND is_deleted = false LIMIT 1")
                    .setParameter("eid", empId)
                    .getResultList();
            if (existingEmployees.isEmpty()) {
                throw new ApiException(ErrorCode.BUSINESS, "归属员工不存在: " + empId);
            }
            em.createNativeQuery(
                            "INSERT INTO user_data_scopes (user_id, scope, owner_employee_id, created_by) VALUES (:uid, :scope, :eid, :by)")
                    .setParameter("uid", userId).setParameter("scope", scope)
                    .setParameter("eid", empId).setParameter("by", currentUser.id().orElse(null))
                    .executeUpdate();
        }
    }

    /** 授权归属人候选：该范围内实际拥有归属数据的员工（id + 姓名 + 数量）。 */
    @Transactional(readOnly = true)
    public List<Map<String, Object>> ownerCandidates(String scope) {
        support.requireCurrentSuperAdmin();
        requireScope(scope);
        String fromClause = switch (scope) {
            case "goods" -> "goods t";
            case "client" -> "clients t";
            case "sales" -> """
                    (SELECT owner_employee_id FROM sales_orders WHERE owner_employee_id IS NOT NULL
                     UNION ALL SELECT owner_employee_id FROM sales_shipments WHERE owner_employee_id IS NOT NULL
                     UNION ALL SELECT owner_employee_id FROM sales_other_shipments WHERE owner_employee_id IS NOT NULL
                     UNION ALL SELECT owner_employee_id FROM sales_returns WHERE owner_employee_id IS NOT NULL) t""";
            default -> throw new IllegalStateException();
        };
        List<Object[]> rows = NativeQueryResults.objectArrayRows(em.createNativeQuery(
                        "SELECT e.id, e.full_name, count(*) AS cnt FROM " + fromClause
                                + " JOIN employees e ON e.id = t.owner_employee_id"
                                + " GROUP BY e.id, e.full_name ORDER BY cnt DESC, e.full_name LIMIT 200"));
        List<Map<String, Object>> out = new ArrayList<>(rows.size());
        for (Object[] r : rows) {
            out.add(Map.of("employeeId", r[0], "name", r[1], "count", ((Number) r[2]).longValue()));
        }
        return out;
    }

    private static void requireScope(String scope) {
        if (scope == null || !SCOPES.contains(scope)) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "未知数据范围: " + scope + "（可选: " + SCOPES + "）");
        }
    }
}
