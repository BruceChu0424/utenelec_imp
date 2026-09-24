package com.uten.imp.features.master.warehouse;

import com.uten.imp.application.port.WarehouseTaskScopePort;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.master.warehouse.dto.MyWarehouseScope;
import com.uten.imp.features.master.warehouse.dto.WarehouseKeeper;
import com.uten.imp.features.master.warehouse.dto.WarehouseKeeperAssignment;
import com.uten.imp.features.master.warehouse.dto.WarehouseKeeperSaveRequest;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import lombok.RequiredArgsConstructor;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.sql.Array;
import java.sql.SQLException;
import java.util.ArrayList;
import java.util.Collection;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Objects;
import java.util.Set;
import java.util.UUID;
import java.util.stream.Collectors;

/**
 * 仓库负责人(仓管员)与「我的仓库」(ADR-115 / V692)。
 *
 * <p>负责关系存 {@code warehouse_keepers}(仓库 × 员工), 登记在主仓上即负责其全部子仓。
 * 「谁是某仓的有效负责人」「某账号负责哪些仓」只由数据库函数
 * {@code fn_warehouse_keeper_user_ids} / {@code fn_user_warehouse_scope_ids} 回答,
 * 通知分发与各任务中心列表筛选用同一口径, 不在 Java 里再算一遍。
 */
@Service
@RequiredArgsConstructor
public class WarehouseKeeperService implements WarehouseTaskScopePort {

    /** 员工在仓库部门(主部门或兼职部门落在 SUB_WH 子树内), 与仓库类通知池同口径。 */
    private static final String WAREHOUSE_MEMBER_SQL = """
            EXISTS (
                WITH RECURSIVE warehouse_departments(id) AS (
                    SELECT id FROM departments WHERE code = 'SUB_WH' AND is_deleted = FALSE
                    UNION ALL
                    SELECT child.id FROM departments child
                    JOIN warehouse_departments parent ON child.parent_id = parent.id
                    WHERE child.is_deleted = FALSE)
                SELECT 1 FROM warehouse_departments dept
                WHERE dept.id = e.department_id
                   OR EXISTS (SELECT 1 FROM employee_secondary_departments secondary
                              WHERE secondary.employee_id = e.id
                                AND secondary.department_id = dept.id))
            """;

    private static final String ACTIVE_ACCOUNT_SQL = """
            EXISTS (SELECT 1 FROM users account
                    WHERE account.employee_id = e.id
                      AND account.is_deleted = FALSE
                      AND account.status = 'active')
            """;

    private final JdbcClient jdbc;
    private final TxSessionVars tx;
    private final SecurityContextCurrentUser currentUser;

    // ---- 维护(仓库资料) -------------------------------------------------------------

    @Transactional(readOnly = true)
    public List<WarehouseKeeper> keepers(UUID warehouseId) {
        requireWarehouse(warehouseId, false);
        return jdbc.sql("""
                        SELECT e.id, e.full_name, e.code, d.name AS department_name,
                               %s AS has_account, %s AS warehouse_member
                        FROM warehouse_keepers keeper
                        JOIN employees e ON e.id = keeper.employee_id
                        LEFT JOIN departments d ON d.id = e.department_id
                        WHERE keeper.warehouse_id = :warehouseId
                        ORDER BY e.full_name, e.code
                        """.formatted(ACTIVE_ACCOUNT_SQL, WAREHOUSE_MEMBER_SQL))
                .param("warehouseId", warehouseId)
                .query((rs, row) -> new WarehouseKeeper(
                        rs.getObject("id", UUID.class),
                        rs.getString("full_name"),
                        rs.getString("code"),
                        rs.getString("department_name"),
                        rs.getBoolean("has_account"),
                        rs.getBoolean("warehouse_member")))
                .list();
    }

    /**
     * 整组替换负责人: 只接受在职(未离职、未删除)员工; 同一仓库并发保存按仓库行锁串行,
     * 后提交的一方以自己看到的名单为准(整组替换, 不是增量)。
     */
    @Transactional
    public List<WarehouseKeeper> replaceKeepers(UUID warehouseId, WarehouseKeeperSaveRequest request) {
        tx.bind();
        requireWarehouse(warehouseId, true);
        List<UUID> requested = request == null || request.employeeIds() == null
                ? List.of()
                : request.employeeIds().stream().filter(Objects::nonNull).distinct().toList();
        if (requested.size() > WarehouseKeeperSaveRequest.MAX_KEEPERS) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED,
                    "一个仓库最多登记 " + WarehouseKeeperSaveRequest.MAX_KEEPERS + " 名负责人");
        }
        String ids = csv(requested);
        if (!requested.isEmpty()) {
            Set<UUID> valid = new LinkedHashSet<>(jdbc.sql("""
                            SELECT e.id FROM employees e
                            WHERE e.id = ANY(CAST(string_to_array(:ids, ',') AS uuid[]))
                              AND e.is_deleted = FALSE
                              AND e.status <> 'resigned'
                            """)
                    .param("ids", ids)
                    .query(UUID.class)
                    .list());
            if (valid.size() != requested.size()) {
                throw new ApiException(ErrorCode.VALIDATION_FAILED,
                        "负责人里有已离职或不存在的员工，请刷新后重新选择");
            }
        }
        jdbc.sql("""
                        DELETE FROM warehouse_keepers
                        WHERE warehouse_id = :warehouseId
                          AND NOT (employee_id = ANY(CAST(string_to_array(:ids, ',') AS uuid[])))
                        """)
                .param("warehouseId", warehouseId)
                .param("ids", ids)
                .update();
        if (!requested.isEmpty()) {
            jdbc.sql("""
                            INSERT INTO warehouse_keepers(warehouse_id, employee_id, created_by)
                            SELECT CAST(:warehouseId AS uuid), employee_id, CAST(:actor AS uuid)
                            FROM unnest(CAST(string_to_array(:ids, ',') AS uuid[])) AS employee_id
                            ON CONFLICT (warehouse_id, employee_id) DO NOTHING
                            """)
                    .param("warehouseId", warehouseId)
                    .param("actor", currentUser.id().orElse(null))
                    .param("ids", ids)
                    .update();
        }
        return keepers(warehouseId);
    }

    /** 仓库资料列表「负责人」列: 全部负责关系(仓库量级个位数, 一次带回)。 */
    @Transactional(readOnly = true)
    public List<WarehouseKeeperAssignment> assignments() {
        return jdbc.sql("""
                        SELECT keeper.warehouse_id, e.id, e.full_name
                        FROM warehouse_keepers keeper
                        JOIN employees e ON e.id = keeper.employee_id
                        JOIN warehouses w ON w.id = keeper.warehouse_id AND w.is_deleted = FALSE
                        WHERE e.is_deleted = FALSE AND e.status <> 'resigned'
                        ORDER BY keeper.warehouse_id, e.full_name, e.code
                        """)
                .query((rs, row) -> new WarehouseKeeperAssignment(
                        rs.getObject("warehouse_id", UUID.class),
                        rs.getObject("id", UUID.class),
                        rs.getString("full_name")))
                .list();
    }

    /** 负责人候选: 在职员工, 仓库部门的人排前面; 标出有没有账号、在不在仓库部门。 */
    @Transactional(readOnly = true)
    public List<WarehouseKeeper> candidates(String keyword) {
        String search = keyword == null ? "" : keyword.strip();
        return jdbc.sql("""
                        SELECT * FROM (
                            SELECT e.id, e.full_name, e.code, d.name AS department_name,
                                   %s AS has_account, %s AS warehouse_member
                            FROM employees e
                            LEFT JOIN departments d ON d.id = e.department_id
                            WHERE e.is_deleted = FALSE
                              AND e.status <> 'resigned'
                              AND (:keyword = ''
                                   OR e.full_name ILIKE '%%' || :keyword || '%%'
                                   OR e.code ILIKE '%%' || :keyword || '%%')) candidate
                        ORDER BY warehouse_member DESC, has_account DESC, full_name, code
                        LIMIT 50
                        """.formatted(ACTIVE_ACCOUNT_SQL, WAREHOUSE_MEMBER_SQL))
                .param("keyword", search)
                .query((rs, row) -> new WarehouseKeeper(
                        rs.getObject("id", UUID.class),
                        rs.getString("full_name"),
                        rs.getString("code"),
                        rs.getString("department_name"),
                        rs.getBoolean("has_account"),
                        rs.getBoolean("warehouse_member")))
                .list();
    }

    /** 当前账号的「我的仓库」(任务中心范围选择器)。 */
    @Transactional(readOnly = true)
    public MyWarehouseScope myScope() {
        UUID userId = currentUser.requireId();
        List<MyWarehouseScope.KeeperWarehouse> mine = jdbc.sql("""
                        SELECT DISTINCT w.id, w.code, w.name
                        FROM warehouse_keepers keeper
                        JOIN warehouses w ON w.id = keeper.warehouse_id AND w.is_deleted = FALSE
                        JOIN employees e ON e.id = keeper.employee_id
                         AND e.is_deleted = FALSE AND e.status <> 'resigned'
                        JOIN users account ON account.employee_id = e.id
                         AND account.is_deleted = FALSE AND account.status = 'active'
                        WHERE account.id = :userId
                        ORDER BY w.code, w.name
                        """)
                .param("userId", userId)
                .query((rs, row) -> new MyWarehouseScope.KeeperWarehouse(
                        rs.getObject("id", UUID.class), rs.getString("code"), rs.getString("name")))
                .list();
        ScopeFacts facts = scopeFacts(userId);
        return new MyWarehouseScope(mine, facts.scopeIds(), facts.configured());
    }

    // ---- WarehouseTaskScopePort ----------------------------------------------------

    @Override
    @Transactional(readOnly = true)
    public WarehouseTaskScope resolve(String scope, UUID warehouseId) {
        if (warehouseId != null) {
            List<UUID> ids = jdbc.sql("SELECT unnest(fn_warehouse_scope_ids(ARRAY[CAST(:id AS uuid)]))")
                    .param("id", warehouseId)
                    .query(UUID.class)
                    .list();
            return new WarehouseTaskScope(true, ids, false);
        }
        if (scope == null || !SCOPE_MINE.equalsIgnoreCase(scope.strip())) {
            return WarehouseTaskScope.ALL;
        }
        UUID userId = currentUser.id().orElse(null);
        if (userId == null) return WarehouseTaskScope.ALL;
        ScopeFacts facts = scopeFacts(userId);
        // 还没人登记负责人, 或本人范围已覆盖全部在用仓库: 等于不过滤(连引用已删仓库的旧单据也照常显示)。
        if (!facts.configured() || facts.scopeIds().size() >= facts.activeWarehouses()) {
            return WarehouseTaskScope.ALL;
        }
        return new WarehouseTaskScope(true, facts.scopeIds(), true);
    }

    @Override
    @Transactional(readOnly = true)
    public List<UUID> keeperUserIds(Collection<UUID> warehouseIds) {
        List<UUID> ids = warehouseIds == null ? List.of()
                : warehouseIds.stream().filter(Objects::nonNull).distinct().toList();
        if (ids.isEmpty()) return List.of();
        return jdbc.sql("SELECT unnest(fn_warehouse_keeper_user_ids(CAST(string_to_array(:ids, ',') AS uuid[])))")
                .param("ids", csv(ids))
                .query(UUID.class)
                .list();
    }

    // ---- helpers -------------------------------------------------------------------

    private record ScopeFacts(boolean configured, long activeWarehouses, List<UUID> scopeIds) {
    }

    private ScopeFacts scopeFacts(UUID userId) {
        return jdbc.sql("""
                        SELECT EXISTS (SELECT 1 FROM warehouse_keepers) AS configured,
                               (SELECT count(*) FROM warehouses WHERE is_deleted = FALSE) AS active_count,
                               fn_user_warehouse_scope_ids(:userId) AS scope_ids
                        """)
                .param("userId", userId)
                .query((rs, row) -> new ScopeFacts(
                        rs.getBoolean("configured"),
                        rs.getLong("active_count"),
                        uuids(rs.getArray("scope_ids"))))
                .single();
    }

    private void requireWarehouse(UUID warehouseId, boolean lock) {
        List<UUID> found = jdbc.sql("SELECT id FROM warehouses WHERE id = :id AND is_deleted = FALSE"
                        + (lock ? " FOR UPDATE" : ""))
                .param("id", warehouseId)
                .query(UUID.class)
                .list();
        if (found.isEmpty()) {
            throw new ApiException(ErrorCode.NOT_FOUND, "仓库不存在或已删除");
        }
    }

    private static String csv(Collection<UUID> ids) {
        return ids.stream().map(UUID::toString).collect(Collectors.joining(","));
    }

    private static List<UUID> uuids(Array array) throws SQLException {
        if (array == null) return List.of();
        Object[] values = (Object[]) array.getArray();
        List<UUID> result = new ArrayList<>(values.length);
        for (Object value : values) {
            if (value != null) result.add(value instanceof UUID uuid ? uuid : UUID.fromString(value.toString()));
        }
        return List.copyOf(result);
    }
}
