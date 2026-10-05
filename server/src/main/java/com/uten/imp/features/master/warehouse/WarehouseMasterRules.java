package com.uten.imp.features.master.warehouse;

import com.uten.imp.common.util.NativeQueryResults;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;

import java.util.Collection;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.Set;
import java.util.UUID;
import java.util.stream.Collectors;

/**
 * 仓库主档形态规则(ADR-145)的服务端唯一入口。
 *
 * <p>每条规则都只调 V798 的 SQL 函数, 数据库守卫用的是同一份定义:
 * <ul>
 *   <li>唯一主仓 {@code fn_warehouse_root_id()};</li>
 *   <li>新单可选良品子仓 {@code fn_warehouse_is_good_stock_leaf(id)} (字典 selectableForNew);</li>
 *   <li>新单可选不良品子仓 {@code fn_warehouse_is_defective_leaf(id)} (字典 selectableDefective, ADR-146);</li>
 *   <li>停用/删除前置条件 {@code fn_warehouse_retirement_blockers(id)};</li>
 *   <li>名称比对键 {@code fn_warehouse_name_key(name)}。</li>
 * </ul>
 * Java 这边只把结果翻成中文预检, 数据库守卫 {@code fn_guard_warehouse_master_lifecycle} 兜底。
 */
@Component
@RequiredArgsConstructor
public class WarehouseMasterRules {

    private final EntityManager em;

    /** 唯一主仓 id; 还没有任何仓或主档没收敛时返回 null。 */
    public UUID rootId() {
        Object value = em.createNativeQuery("SELECT fn_warehouse_root_id()").getSingleResult();
        return value == null ? null : (UUID) value;
    }

    /** 这批仓库里新单可选的良品子仓。 */
    public Set<UUID> selectableForNew(Collection<UUID> ids) {
        Set<UUID> distinct = distinct(ids);
        if (distinct.isEmpty()) return Set.of();
        List<UUID> rows = NativeQueryResults.typedRows(em.createNativeQuery("""
                        SELECT id FROM warehouses
                        WHERE id = ANY(CAST(string_to_array(:ids, ',') AS uuid[]))
                          AND fn_warehouse_is_good_stock_leaf(id)
                        """)
                .setParameter("ids", joined(distinct)), UUID.class);
        return Set.copyOf(rows);
    }

    /** 这批仓库里新单可选的不良品子仓(ADR-146: 专门通道、盘点、处置出库能选它们)。 */
    public Set<UUID> selectableDefective(Collection<UUID> ids) {
        Set<UUID> distinct = distinct(ids);
        if (distinct.isEmpty()) return Set.of();
        List<UUID> rows = NativeQueryResults.typedRows(em.createNativeQuery("""
                        SELECT id FROM warehouses
                        WHERE id = ANY(CAST(string_to_array(:ids, ',') AS uuid[]))
                          AND fn_warehouse_is_defective_leaf(id)
                        """)
                .setParameter("ids", joined(distinct)), UUID.class);
        return Set.copyOf(rows);
    }

    /** 新单能不能选这个仓(启用的良品子仓)。 */
    public boolean isSelectableForNew(UUID id) {
        return id != null && selectableForNew(List.of(id)).contains(id);
    }

    /**
     * 新单不能选这个仓的原因(给人看); 可以选返回 null。判定本身仍是 fn_warehouse_is_good_stock_leaf,
     * 这里只把「为什么不行」说清楚。
     */
    public String selectionRefusal(UUID id) {
        if (id == null) return null;
        List<String> rows = NativeQueryResults.typedRows(em.createNativeQuery("""
                        SELECT CASE
                            WHEN fn_warehouse_is_good_stock_leaf(warehouse.id) THEN ''
                            WHEN warehouse.is_deleted THEN '已删除'
                            WHEN warehouse.is_line_side THEN '是车间内料仓'
                            WHEN warehouse.is_defective THEN '是不良品仓'
                            WHEN EXISTS (SELECT 1 FROM warehouses child
                                          WHERE child.parent_id = warehouse.id AND NOT child.is_deleted)
                                THEN '是主仓(只作汇总)'
                            WHEN warehouse.status IS DISTINCT FROM '使用' THEN '已停用'
                            WHEN NOT warehouse.is_accountable THEN '不参与库存核算'
                            ELSE '所属主仓已停用'
                        END
                        FROM warehouses warehouse WHERE warehouse.id = CAST(:id AS uuid)
                        """)
                .setParameter("id", id.toString()), String.class);
        if (rows.isEmpty()) return "不存在";
        String reason = rows.getFirst();
        return reason == null || reason.isEmpty() ? null : reason;
    }

    /**
     * 停用/删除前置条件: 仓库 id -> 不满足的原因(空表示可以停用)。只返回有原因的仓。
     */
    public Map<UUID, List<String>> retirementBlockers(Collection<UUID> ids) {
        return blockers("fn_warehouse_retirement_blockers", ids);
    }

    /**
     * 退出新单可选(改成不核算、改成不良品仓)的前置条件: 仓库 id -> 原因(只返回有原因的仓)。
     * 与停用同一组条件(库存、货品所属、未结预留、内料仓开通与来源仓), 只是不含「它是主仓」。
     */
    public Map<UUID, List<String>> selectionExitBlockers(Collection<UUID> ids) {
        return blockers("fn_warehouse_selection_exit_blockers", ids);
    }

    /** {@code function} 只取本类两个常量函数名(白名单), 不接受外部输入。 */
    private Map<UUID, List<String>> blockers(String function, Collection<UUID> ids) {
        Set<UUID> distinct = distinct(ids);
        if (distinct.isEmpty()) return Map.of();
        List<Object[]> rows = NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                        SELECT id, array_to_string(%s(id), CHR(10))
                        FROM warehouses
                        WHERE id = ANY(CAST(string_to_array(:ids, ',') AS uuid[]))
                        ORDER BY id
                        """.formatted(function))
                .setParameter("ids", joined(distinct)));
        Map<UUID, List<String>> blockers = new LinkedHashMap<>();
        for (Object[] row : rows) {
            String reasons = (String) row[1];
            if (reasons == null || reasons.isBlank()) continue;
            blockers.put((UUID) row[0], List.of(reasons.split("\n")));
        }
        return blockers;
    }

    /** 与数据库守卫同一句话: 仓库「X」现在不能停用/删除: 原因1; 原因2。 */
    public static String retirementMessage(String label, boolean delete, List<String> reasons) {
        return blockedMessage(label, delete ? "删除" : "停用", reasons);
    }

    /** 与数据库守卫同一句话: 仓库「X」现在不能改成不核算/改成不良品仓: 原因1; 原因2。 */
    public static String selectionExitMessage(String label, boolean toDefective, List<String> reasons) {
        return blockedMessage(label, toDefective ? "改成不良品仓" : "改成不核算", reasons);
    }

    private static String blockedMessage(String label, String action, List<String> reasons) {
        return "仓库「" + (label == null || label.isBlank() ? "该仓库" : label.strip()) + "」现在不能"
                + action + ": " + String.join("; ", reasons);
    }

    /** 已有的同名仓库(按名称比对键, 只看未删除的仓, 排除自己); 没有返回 null。 */
    public String duplicateName(String name, UUID selfId) {
        if (name == null || name.isBlank()) return null;
        List<String> rows = NativeQueryResults.typedRows(em.createNativeQuery("""
                        SELECT name FROM warehouses
                        WHERE NOT is_deleted
                          AND fn_warehouse_name_key(name) = fn_warehouse_name_key(:name)
                          AND id <> CAST(:self AS uuid)
                        ORDER BY code NULLS LAST, id
                        LIMIT 1
                        """)
                .setParameter("name", name)
                .setParameter("self", selfKey(selfId)), String.class);
        return rows.isEmpty() ? null : rows.getFirst();
    }

    /** 未删除仓库里是否已有别的仓(排除自己)。 */
    public boolean anyOtherWarehouse(UUID selfId) {
        Number count = (Number) em.createNativeQuery("""
                        SELECT count(*) FROM warehouses
                        WHERE NOT is_deleted
                          AND id <> CAST(:self AS uuid)
                        """)
                .setParameter("self", selfKey(selfId))
                .getSingleResult();
        return count.longValue() > 0;
    }

    /** 新建时没有自己的 id: 用全零 UUID 占位(不会与真实仓重合), 避免绑定无类型的 null 参数。 */
    private static String selfKey(UUID selfId) {
        return (selfId == null ? new UUID(0L, 0L) : selfId).toString();
    }

    private static Set<UUID> distinct(Collection<UUID> ids) {
        if (ids == null) return Set.of();
        return ids.stream().filter(Objects::nonNull).collect(Collectors.toCollection(LinkedHashSet::new));
    }

    private static String joined(Collection<UUID> ids) {
        return ids.stream().map(UUID::toString).collect(Collectors.joining(","));
    }
}
