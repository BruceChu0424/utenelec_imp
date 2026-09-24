package com.uten.imp.application.port;

import java.util.Collection;
import java.util.List;
import java.util.UUID;
import java.util.stream.Collectors;

/**
 * 仓库负责人与「我的仓库」范围端口(ADR-115 / V693)。
 *
 * <p>仓库主档(master)拥有负责关系 {@code warehouse_keepers}; 仓库任务中心各列表
 * (领料/销售出库/委外出仓/预计到货/到货异常/产成品点收/库存单据)与仓库类通知只需要两件事:
 * 「当前账号该看哪些仓」与「这张单据的仓该通知谁」。二者都由数据库函数算
 * ({@code fn_user_warehouse_scope_ids} / {@code fn_warehouse_keeper_user_ids}), 本端口只做解析。
 */
public interface WarehouseTaskScopePort {

    /** 列表参数 {@code warehouseScope} 取值: 当前账号负责的仓库。 */
    String SCOPE_MINE = "MINE";

    /**
     * 解析列表的仓库范围。
     *
     * @param scope       {@code MINE} = 我负责的仓库(含尚未指定负责人的仓、尚未定仓的任务);
     *                    空/其它 = 不按负责人过滤
     * @param warehouseId 指定仓库(该仓 + 全部子仓); 与 MINE 同时给时取指定仓库
     */
    WarehouseTaskScope resolve(String scope, UUID warehouseId);

    /**
     * 仓库类通知收件人: 这些仓库(含各级上级仓)的有效负责人账号(员工在职、账号启用)。
     * 空列表 = 未指定负责人, 调用方照旧发给整个通知池。
     */
    List<UUID> keeperUserIds(Collection<UUID> warehouseIds);

    /**
     * 解析后的仓库范围。{@link #active()} 为假时不过滤(调用方不拼条件、不绑定参数)。
     *
     * @param warehouseIds      范围内的仓库(已展开子仓)
     * @param includeUnassigned 单据仓库为空(尚未定仓)时是否算在范围内——「我的仓库」算
     *                          (没定仓的活谁都可能要接), 指定某个仓时不算
     */
    record WarehouseTaskScope(boolean active, List<UUID> warehouseIds, boolean includeUnassigned) {

        public static final WarehouseTaskScope ALL = new WarehouseTaskScope(false, List.of(), true);

        public WarehouseTaskScope {
            warehouseIds = warehouseIds == null ? List.of() : List.copyOf(warehouseIds);
        }

        /** 绑定到 {@link #predicate} 占位符的值(逗号分隔 UUID; 空范围为空串 = 空数组)。 */
        public String idsCsv() {
            return warehouseIds.stream().map(UUID::toString).collect(Collectors.joining(","));
        }

        /**
         * 仓库列在范围内的 SQL 条件; {@code placeholder} 是调用方的参数占位(如 {@code :warehouseScope}),
         * 条件里只出现一次。只在 {@link #active()} 时使用。
         */
        public String predicate(String column, String placeholder) {
            String inScope = column + " = ANY(CAST(string_to_array(CAST(" + placeholder
                    + " AS text), ',') AS uuid[]))";
            return includeUnassigned ? "(" + column + " IS NULL OR " + inScope + ")" : inScope;
        }
    }
}
