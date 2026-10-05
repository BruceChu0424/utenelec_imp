package com.uten.imp.application.port;

import java.util.Collection;
import java.util.List;
import java.util.UUID;
import java.util.function.Supplier;
import java.util.stream.Collectors;

/**
 * 仓库数据范围端口 v2(ADR-149, 取代 ADR-115 的「我的仓库」可选筛选)。
 *
 * <p>仓库主档(master)拥有负责关系 {@code warehouse_keepers}; 仓库任务的列表、facets、各级计数、
 * 工作台徽章与仓库类通知只经这一个端口问两件事: 「当前账号能看哪些仓」与「这张单据的仓该通知谁」。
 * 角色与可见仓由数据库函数 {@code fn_user_warehouse_access} 一处判定, 实现方按请求缓存。
 *
 * <ul>
 *   <li>主管 SUPERVISOR: 超管、仓储部(SUB_WH 子树)部门负责人、登记在主仓上的负责人。默认看全部,
 *       可挑任一仓(含下级)。</li>
 *   <li>子仓负责人 KEEPER: 登记在主仓以外的仓上。只看自己负责的仓(含下级), 不含未定仓的任务;
 *       负责多个仓时可在这些仓之间切换。</li>
 *   <li>其他人 OTHER: 有任务权限但没登记负责人。看没有有效子仓负责人的仓 + 未定仓的任务;
 *       全公司还没有任何有效子仓负责人时等于全部。不能挑仓。</li>
 * </ul>
 *
 * <p>范围只限制列表、计数、徽章与通知; 单据详情与办理照旧按原权限(顶班由主管处理或重新指定负责人)。
 */
public interface WarehouseTaskScopePort {

    /** 越界选仓的统一提示(403)。 */
    String OUT_OF_SCOPE_MESSAGE = "所选仓库不在你负责的范围内";

    /** 三种角色。 */
    enum Role { SUPERVISOR, KEEPER, OTHER }

    /** 当前账号的仓库数据范围(按请求解析一次)。 */
    WarehouseAccess access();

    /**
     * 列表 / 计数用的生效范围。
     *
     * @param requestedWarehouseId 页面选的仓(含下级); null = 本人默认范围
     *                             (工作台徽章按任务中心所选仓汇总时, null 取汇总请求所选的仓)
     * @throws com.uten.imp.common.web.ApiException 403 所选仓库不在本人可选范围内
     */
    WarehouseTaskScope current(UUID requestedWarehouseId);

    /**
     * 在「本次汇总按某仓计」的上下文里执行: 先校验所选仓(越界 403), 执行期间 {@code current(null)}
     * 取该仓范围。只给 /workbench/badges 的分段计数用, 各计数来源与列表因此同一谓词。
     */
    <T> T withRequestedWarehouse(UUID requestedWarehouseId, Supplier<T> work);

    /**
     * 当前是不是在「本次汇总按某仓计」的上下文里({@link #withRequestedWarehouse} 执行期间)。
     * 本人默认范围里自己的草稿不论仓都算(库存单据), 挑了仓就只看那个仓: 计数来源据此决定要不要带上本人草稿。
     */
    default boolean warehousePicked() {
        return false;
    }

    /** 这些仓(含主仓以下各级上级仓)的有效子仓负责人账号; 登记在主仓上的主管不在此列。 */
    List<UUID> keeperUserIds(Collection<UUID> warehouseIds);

    /** 仓库主管账号(超管、仓储部门负责人、登记在主仓上的负责人)。 */
    List<UUID> supervisorUserIds();

    /**
     * 仓库任务参与者: 登记过负责人(任一仓)或担任仓储部门负责人的账号。通知弹卡资格把他们当作
     * 仓储部门成员(部门外的负责人收到的仓库待办同样弹卡)。
     */
    List<UUID> responsibleUserIds();

    /**
     * 一张仓库类单据的通知池要纳入的部门外账号: 这些仓(含上级链)的子仓负责人 + 指定的主管
     * (仓储部门负责人、登记在主仓上的负责人)。不含别的仓的负责人, 也不含只是超管的账号。
     */
    List<UUID> noticeCandidateUserIds(Collection<UUID> warehouseIds);

    /**
     * 仓库类通知收件人唯一规则: 该仓链上子仓负责人 ∩ 池; 没有则指定的主管 ∩ 池(超管不因超管身份算在这一级,
     * 否则「还没配置」那一级永远到不了); 再没有(还没配置)才发整个池。仓库为空 = 未定仓的任务, 直接走主管那一级。
     */
    List<UUID> noticeRecipients(Collection<UUID> pool, Collection<UUID> warehouseIds);

    /**
     * 当前账号的仓库数据范围。
     *
     * @param keeperWarehouseIds 本人登记负责的在用仓(含主仓)
     * @param defaultScope       不选仓时的生效范围
     * @param warehouseMember    主部门或兼职部门在仓储部子树内
     */
    record WarehouseAccess(Role role, List<UUID> keeperWarehouseIds, WarehouseTaskScope defaultScope,
                           boolean warehouseMember) {
        public WarehouseAccess {
            keeperWarehouseIds = keeperWarehouseIds == null ? List.of() : List.copyOf(keeperWarehouseIds);
            defaultScope = defaultScope == null ? WarehouseTaskScope.NONE : defaultScope;
        }

        /** 仓库任务的参与者: 主管、子仓负责人或仓储部门成员(生产链仓库任务的对象范围)。 */
        public boolean warehouseParticipant() {
            return role != Role.OTHER || warehouseMember;
        }
    }

    /**
     * 解析后的仓库范围。{@link #active()} 为假时不过滤(调用方不拼条件、不绑定参数)。
     *
     * @param warehouseIds      范围内的仓库(已展开下级)
     * @param includeUnassigned 单据还没定仓时是否算在范围内(只有「其他人」的默认范围算)
     */
    record WarehouseTaskScope(boolean active, List<UUID> warehouseIds, boolean includeUnassigned) {

        public static final WarehouseTaskScope ALL = new WarehouseTaskScope(false, List.of(), true);
        /** 什么都看不到(未登录等)。 */
        public static final WarehouseTaskScope NONE = new WarehouseTaskScope(true, List.of(), false);

        public WarehouseTaskScope {
            warehouseIds = warehouseIds == null ? List.of() : List.copyOf(warehouseIds);
        }

        /** 绑定到 {@link #predicate} 占位符的值(逗号分隔 UUID; 空范围为空串 = 空数组)。 */
        public String idsCsv() {
            return warehouseIds.stream().map(UUID::toString).collect(Collectors.joining(","));
        }

        /**
         * 单个仓库列在范围内的 SQL 条件; {@code placeholder} 是调用方的参数占位(如 {@code :warehouseScope}),
         * 条件里只出现一次。只在 {@link #active()} 时使用。
         */
        public String predicate(String column, String placeholder) {
            String inScope = column + " = ANY(" + ids(placeholder) + ")";
            return includeUnassigned ? "(" + column + " IS NULL OR " + inScope + ")" : inScope;
        }

        /**
         * 一个任务涉及多个仓(表头仓 + 各行仓、发出仓 + 调入仓)时: 任一仓在范围内即算; 全都没有 = 未定仓,
         * 只在 {@link #includeUnassigned()} 时算。{@code warehouseArray} 是 uuid[] 表达式(可含 NULL 元素)。
         */
        public String predicateAny(String warehouseArray, String placeholder) {
            String overlap = "(" + warehouseArray + ") && " + ids(placeholder);
            return includeUnassigned
                    ? "(" + overlap + " OR cardinality(array_remove(" + warehouseArray + ", NULL)) = 0)"
                    : "(" + overlap + ")";
        }

        private static String ids(String placeholder) {
            return "CAST(string_to_array(NULLIF(CAST(" + placeholder + " AS text), ''), ',') AS uuid[])";
        }
    }
}
