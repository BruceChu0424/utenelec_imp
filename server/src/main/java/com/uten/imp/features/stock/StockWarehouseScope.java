package com.uten.imp.features.stock;

import jakarta.persistence.EntityManager;
import org.springframework.jdbc.core.namedparam.MapSqlParameterSource;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;

import java.util.List;
import java.util.Set;
import java.util.UUID;

/**
 * 库存查询的仓库范围 (V476): 选中的仓 = 自身 + 全部未软删后代; 叶子仓 = 精确单仓。
 *
 * <p>即时库存、余额、货品出入库流水 (ledger) 与库存分析 (insight) 共用同一口径: 递归 CTE 直查
 * warehouses, 不注入 master 侧组件 (stock→master 是 ArchitectureBoundary 未放行的依赖边, ADR-017)。
 * 锚点查不到 (未知/已软删仓) 时退化为精确单仓, 让结果为空而不是放大成「全部」。
 */
public final class StockWarehouseScope {

    static final String SUBTREE_SQL = """
            WITH RECURSIVE wh AS (
                SELECT id FROM warehouses WHERE id = :rootId AND is_deleted = false
                UNION ALL
                SELECT w.id FROM warehouses w JOIN wh ON w.parent_id = wh.id
                WHERE w.is_deleted = false
            )
            SELECT id FROM wh
            """;

    private StockWarehouseScope() {
    }

    /** JPA 调用方 (即时库存/余额)。warehouseId 为 null 返回 null (= 不限仓库)。 */
    public static Set<UUID> subtreeOf(EntityManager em, UUID warehouseId) {
        if (warehouseId == null) {
            return null;
        }
        @SuppressWarnings("unchecked")
        List<UUID> ids = em.createNativeQuery(SUBTREE_SQL)
                .setParameter("rootId", warehouseId)
                .getResultList();
        return resolve(warehouseId, ids);
    }

    /** JDBC 调用方 (出入库流水/库存分析)。warehouseId 为 null 返回 null (= 不限仓库)。 */
    public static Set<UUID> subtreeOf(NamedParameterJdbcTemplate db, UUID warehouseId) {
        if (warehouseId == null) {
            return null;
        }
        List<UUID> ids = db.queryForList(SUBTREE_SQL, new MapSqlParameterSource("rootId", warehouseId), UUID.class);
        return resolve(warehouseId, ids);
    }

    static Set<UUID> resolve(UUID warehouseId, List<UUID> ids) {
        return ids == null || ids.isEmpty() ? Set.of(warehouseId) : Set.copyOf(ids);
    }

    /** Same warehouse-type policy as instant inventory; an explicit leaf remains exact. */
    public static String typePredicate(String alias, boolean inventoryOnly, boolean exactWarehouse,
                                       boolean includeDefective, boolean includeLineSide) {
        if (!inventoryOnly || exactWarehouse) return "";
        return " AND " + alias + ".is_accountable"
                + (includeDefective ? "" : " AND NOT " + alias + ".is_defective")
                + (includeLineSide ? "" : " AND NOT " + alias + ".is_line_side");
    }

    /** Null means the legacy all-warehouse mode; an empty set means a selected scope with no eligible warehouses. */
    public static Set<UUID> queryScopeOf(EntityManager em, UUID warehouseId, boolean inventoryOnly,
                                        boolean includeDefective, boolean includeLineSide) {
        Set<UUID> scope = subtreeOf(em, warehouseId);
        if (!inventoryOnly || scope != null && scope.size() == 1) return scope;
        var query = em.createNativeQuery(queryScopeSql(scope, includeDefective, includeLineSide));
        if (scope != null) query.setParameter("scopeIds", scope);
        @SuppressWarnings("unchecked") List<UUID> ids = query.getResultList();
        return Set.copyOf(ids);
    }

    public static Set<UUID> queryScopeOf(NamedParameterJdbcTemplate db, UUID warehouseId, boolean inventoryOnly,
                                        boolean includeDefective, boolean includeLineSide) {
        Set<UUID> scope = subtreeOf(db, warehouseId);
        if (!inventoryOnly || scope != null && scope.size() == 1) return scope;
        var params = new MapSqlParameterSource();
        if (scope != null) params.addValue("scopeIds", scope);
        return Set.copyOf(db.queryForList(queryScopeSql(scope, includeDefective, includeLineSide), params, UUID.class));
    }

    private static String queryScopeSql(Set<UUID> scope, boolean includeDefective, boolean includeLineSide) {
        return "SELECT w.id FROM warehouses w WHERE 1=1"
                + (scope == null ? "" : " AND w.id IN (:scopeIds)")
                + typePredicate("w", true, false, includeDefective, includeLineSide);
    }
}
