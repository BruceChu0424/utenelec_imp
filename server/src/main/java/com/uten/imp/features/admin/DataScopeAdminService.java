package com.uten.imp.features.admin;

import com.uten.imp.common.util.NativeQueryResults;
import com.uten.imp.common.validation.RequestLimits;
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
 * 数据范围授权管理（user_data_scopes）：按人配置「能看哪些归属人的某模块单据」。
 *
 * <p>三档可见性的中间档：自己（+公共）/ <b>自己+授权归属人</b> / 全部（*:view:all）。
 * scope：goods / client / sales 使用 owner_employee_id；finance / purchase / subcontract /
 * production_plan / stock_doc 使用 maker_id。整体替换语义，同权限覆盖管理。
 * user_data_scopes 只增加只读可见范围；可写责任必须走正式人员数据交接。
 */
@Service
@RequiredArgsConstructor
@PreAuthorize("hasAuthority('authorization:manage') and principal.superAdmin")
public class DataScopeAdminService {

    /** 合法业务范围（与 user_data_scopes.scope CHECK 一致）。 */
    private static final List<String> SCOPES = List.of(
            "goods", "client", "sales", "finance",
            "purchase", "subcontract", "production_plan", "stock_doc");

    private final EntityManager em;
    private final TxSessionVars tx;
    private final AdminUserSupport support;
    private final SecurityContextCurrentUser currentUser;
    private final DataScopeCasGuard casGuard;

    /** 某用户在某范围的授权归属人列表（员工 id）。 */
    @Transactional(readOnly = true)
    public List<UUID> getDataScopes(UUID userId, String scope) {
        support.requireCurrentSuperAdmin();
        support.require(userId);
        requireScope(scope);
        return NativeQueryResults.typedRows(em.createNativeQuery("""
                        SELECT data_scope.owner_employee_id
                        FROM user_data_scopes data_scope
                        WHERE data_scope.user_id=:uid AND data_scope.scope=:scope
                          AND data_scope.owner_employment_generation=(
                              SELECT count(*) FROM employment_history history
                              WHERE history.employee_id=data_scope.owner_employee_id
                                AND history.event_type='rehire')
                        ORDER BY data_scope.created_at
                        """)
                .setParameter("uid", userId).setParameter("scope", scope), UUID.class);
    }

    /** 整体替换某用户在某范围的授权归属人。 */
    @Transactional
    public void setDataScopes(UUID userId, String scope, List<UUID> ownerEmployeeIds,
                              List<UUID> expectedOwnerEmployeeIds) {
        tx.bind();
        var target = support.require(userId);
        support.requireAuthorizationTarget(target);
        requireScope(scope);
        List<UUID> requestedOwnerIds = normalizeOwnerIds(ownerEmployeeIds);
        casGuard.lockAndVerify(userId, scope, expectedOwnerEmployeeIds);
        lockOwnersAndRecipient(
                target.getEmployeeId(), userId, requestedOwnerIds, !requestedOwnerIds.isEmpty());
        em.createNativeQuery("DELETE FROM user_data_scopes WHERE user_id = :uid AND scope = :scope")
                .setParameter("uid", userId).setParameter("scope", scope).executeUpdate();
        for (UUID empId : requestedOwnerIds) {
            em.createNativeQuery(
                            "INSERT INTO user_data_scopes (user_id, scope, owner_employee_id, created_by) VALUES (:uid, :scope, :eid, :by)")
                    .setParameter("uid", userId).setParameter("scope", scope)
                    .setParameter("eid", empId).setParameter("by", currentUser.id().orElse(null))
                    .executeUpdate();
        }
    }

    private static List<UUID> normalizeOwnerIds(List<UUID> ownerEmployeeIds) {
        List<UUID> raw = ownerEmployeeIds == null ? List.of() : ownerEmployeeIds;
        if (raw.size() > RequestLimits.ADMIN_SCOPE_OWNERS) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "数据范围负责人数量超过上限");
        }
        if (raw.stream().anyMatch(java.util.Objects::isNull)) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "数据范围负责人不能为空");
        }
        return new LinkedHashSet<>(raw).stream().sorted().toList();
    }

    /**
     * Lock every selected owner plus the recipient employee in UUID order, then
     * the recipient account. This is the platform employee -> user order and
     * makes the service check agree with database guards under offboarding.
     * Clearing an empty desired set remains available for resigned/disabled
     * recipients; only a non-empty grant requires current+active eligibility.
     */
    private void lockOwnersAndRecipient(
            UUID recipientEmployeeId,
            UUID recipientUserId,
            List<UUID> ownerEmployeeIds,
            boolean requireGrantEligibility) {
        if (recipientEmployeeId == null) {
            throw new ApiException(ErrorCode.CONFLICT, "目标账号未绑定有效员工，不能设置数据范围");
        }
        LinkedHashSet<UUID> employeeIds = new LinkedHashSet<>(ownerEmployeeIds);
        employeeIds.add(recipientEmployeeId);
        List<UUID> sortedEmployeeIds = employeeIds.stream().sorted().toList();
        List<UUID> existingEmployeeIds = NativeQueryResults.typedRows(
                em.createNativeQuery("""
                                SELECT employee.id
                                FROM employees employee
                                WHERE employee.id IN (:employeeIds)
                                  AND employee.is_deleted = FALSE
                                ORDER BY employee.id
                                FOR SHARE OF employee
                                """)
                        .setParameter("employeeIds", sortedEmployeeIds), UUID.class);
        if (!new LinkedHashSet<>(existingEmployeeIds).equals(employeeIds)) {
            throw new ApiException(
                    ErrorCode.CONFLICT,
                    "数据范围负责人不存在或目标员工无效，请刷新后重试");
        }
        if (requireGrantEligibility) {
            Number currentRecipient = (Number) em.createNativeQuery("""
                        SELECT count(*) FROM employees employee
                        WHERE employee.id=:employeeId
                          AND employee.is_deleted=FALSE
                          AND employee.status IN ('active','probation','onLeave')
                        """)
                .setParameter("employeeId", recipientEmployeeId)
                .getSingleResult();
            if (currentRecipient.longValue() != 1L) {
                throw new ApiException(ErrorCode.CONFLICT, "目标员工已离职，请刷新后重试");
            }
        }
        @SuppressWarnings("unchecked")
        List<Object[]> lockedAccounts = em.createNativeQuery("""
                        SELECT account.employee_id, account.status
                        FROM users account
                        WHERE account.id = :userId
                          AND account.is_deleted = FALSE
                        FOR SHARE OF account
                        """)
                .setParameter("userId", recipientUserId)
                .getResultList();
        if (lockedAccounts.size() != 1
                || !recipientEmployeeId.equals(lockedAccounts.getFirst()[0])) {
            throw new ApiException(ErrorCode.CONFLICT, "目标账号绑定已变化，请刷新后重试");
        }
        if (requireGrantEligibility
                && !"active".equals(String.valueOf(lockedAccounts.getFirst()[1]))) {
            throw new ApiException(ErrorCode.CONFLICT, "目标账号已停用，请刷新后重试");
        }
    }

    /** 授权归属人候选：该范围内实际拥有归属数据的员工（id + 姓名 + 数量）。 */
    @Transactional(readOnly = true)
    public List<Map<String, Object>> ownerCandidates(String scope) {
        support.requireCurrentSuperAdmin();
        requireScope(scope);
        String fromClause = switch (scope) {
            case "goods" -> "(SELECT owner_employee_id FROM goods WHERE owner_employee_id IS NOT NULL AND is_deleted=FALSE) t";
            case "client" -> "(SELECT owner_employee_id FROM clients WHERE owner_employee_id IS NOT NULL AND is_deleted=FALSE AND (code IS NULL OR lower(code) NOT LIKE 'legacy-fin-cl-%')) t";
            case "sales" -> """
                    (SELECT maker_id AS owner_employee_id FROM sales_quotes WHERE maker_id IS NOT NULL AND is_deleted=FALSE
                     UNION ALL SELECT owner_employee_id FROM sales_orders WHERE owner_employee_id IS NOT NULL AND is_deleted=FALSE
                     UNION ALL SELECT owner_employee_id FROM sales_shipments WHERE owner_employee_id IS NOT NULL AND is_deleted=FALSE
                     UNION ALL SELECT owner_employee_id FROM sales_other_shipments WHERE owner_employee_id IS NOT NULL AND is_deleted=FALSE
                     UNION ALL SELECT owner_employee_id FROM sales_returns WHERE owner_employee_id IS NOT NULL AND is_deleted=FALSE) t""";
            case "finance" -> """
                    (SELECT maker_id AS owner_employee_id FROM finance_payments WHERE maker_id IS NOT NULL AND is_deleted=FALSE
                     UNION ALL SELECT maker_id FROM finance_receipts WHERE maker_id IS NOT NULL AND is_deleted=FALSE
                     UNION ALL SELECT maker_id FROM finance_expenses WHERE maker_id IS NOT NULL AND is_deleted=FALSE
                     UNION ALL SELECT maker_id FROM finance_bank_transfers WHERE maker_id IS NOT NULL AND is_deleted=FALSE
                     UNION ALL SELECT maker_id FROM finance_other_incomes WHERE maker_id IS NOT NULL AND is_deleted=FALSE) t""";
            // 采购单据归属列 = maker_id（申请单不隔离，不含 purchase_requests）
            case "purchase" -> """
                    (SELECT maker_id AS owner_employee_id FROM purchase_orders WHERE maker_id IS NOT NULL AND is_deleted=FALSE
                     UNION ALL SELECT maker_id FROM purchase_receipts WHERE maker_id IS NOT NULL AND is_deleted=FALSE
                     UNION ALL SELECT maker_id FROM purchase_returns WHERE maker_id IS NOT NULL AND is_deleted=FALSE) t""";
            // 委外单据归属列 = maker_id（申请单不隔离，不含 subcontract_applications）
            case "subcontract" -> """
                    (SELECT maker_id AS owner_employee_id FROM subcontract_orders WHERE maker_id IS NOT NULL AND is_deleted=FALSE
                     UNION ALL SELECT maker_id FROM subcontract_inquiries WHERE maker_id IS NOT NULL AND is_deleted=FALSE
                     UNION ALL SELECT maker_id FROM subcontract_material_issues WHERE maker_id IS NOT NULL AND is_deleted=FALSE
                     UNION ALL SELECT maker_id FROM subcontract_material_returns WHERE maker_id IS NOT NULL AND is_deleted=FALSE
                     UNION ALL SELECT maker_id FROM subcontract_receipts WHERE maker_id IS NOT NULL AND is_deleted=FALSE
                     UNION ALL SELECT maker_id FROM subcontract_returns WHERE maker_id IS NOT NULL AND is_deleted=FALSE
                     UNION ALL SELECT maker_id FROM subcontract_wastes WHERE maker_id IS NOT NULL AND is_deleted=FALSE) t""";
            // 生产单据归属列 = maker_id（计划 + 日报）
            case "production_plan" -> """
                    (SELECT maker_id AS owner_employee_id FROM production_plans WHERE maker_id IS NOT NULL AND is_deleted=FALSE
                     UNION ALL SELECT maker_id FROM production_daily_reports WHERE maker_id IS NOT NULL AND is_deleted=FALSE
                     UNION ALL SELECT maker_id FROM production_material_analyses WHERE maker_id IS NOT NULL AND is_deleted=FALSE) t""";
            // 仓库单据归属列 = maker_id
            case "stock_doc" -> """
                    (SELECT maker_id AS owner_employee_id FROM stock_documents WHERE maker_id IS NOT NULL AND is_deleted=FALSE) t""";
            default -> throw new IllegalStateException();
        };
        List<Object[]> rows = NativeQueryResults.objectArrayRows(em.createNativeQuery(
                        "SELECT e.id, e.full_name, e.status, count(*) AS cnt FROM " + fromClause
                                + " JOIN employees e ON e.id = t.owner_employee_id"
                                + " AND e.is_deleted=false"
                                + " GROUP BY e.id, e.full_name, e.status ORDER BY cnt DESC, e.full_name, e.id LIMIT 1000"));
        List<Map<String, Object>> out = new ArrayList<>(rows.size());
        for (Object[] r : rows) {
            String status = r[2] == null ? "" : r[2].toString();
            out.add(Map.of("employeeId", r[0], "name", r[1], "status", status,
                    "historicalOnly", !com.uten.imp.common.identity.CurrentEmployeeStatusPolicy.isCurrentEmployee(status),
                    "count", ((Number) r[3]).longValue()));
        }
        return out;
    }

    private static void requireScope(String scope) {
        if (scope == null || !SCOPES.contains(scope)) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "未知数据范围: " + scope + "（可选: " + SCOPES + "）");
        }
    }
}
