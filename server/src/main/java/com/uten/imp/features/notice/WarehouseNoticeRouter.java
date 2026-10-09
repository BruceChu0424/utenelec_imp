package com.uten.imp.features.notice;

import com.uten.imp.application.port.WarehouseTaskScopePort;
import org.springframework.stereotype.Component;

import java.util.Collection;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Objects;
import java.util.Set;
import java.util.UUID;
import java.util.function.Predicate;

/**
 * 仓库类通知的唯一分发规则(ADR-149)。链式通知(ChainNoticeService)、车间内料仓通知、盘点审核通知
 * 都只经这里决定发给谁, 不再各写一套「负责人 ∩ 池, 为空就发整个池」。
 *
 * <ol>
 *   <li>{@link #pool}: 原通知池(仓库部门 × 该通知所需权限) + 这张单涉及的仓的子仓负责人与指定的主管
 *       (仓储部门负责人、主仓负责人)里同样持有所需权限的部门外的人——与「子仓负责人不论部门都按登记的仓
 *       看任务」的角色判定一致; 别的仓的负责人不进来。</li>
 *   <li>{@link #recipients}: 该仓链上的子仓负责人 ∩ 池; 没有则指定的主管 ∩ 池; 再没有(还没配置)才发整个池。
 *       超管不因超管身份算作这一级的主管，也不因全量权限镜像进池(2026-10-09 ADR-063 追加修订：
 *       任务卡池按「真实授出权限」解析——池里没有真实持码的超管)。
 *       规则本身在数据库函数 {@code fn_warehouse_notice_recipients}, 与列表范围同一套负责关系。</li>
 * </ol>
 */
@Component
public class WarehouseNoticeRouter {

    private final WarehouseTaskScopePort scopes;

    public WarehouseNoticeRouter(WarehouseTaskScopePort scopes) {
        this.scopes = scopes;
    }

    /**
     * 通知池: 部门池 + 这张单涉及的仓的子仓负责人与指定的主管里满足同样条件(在职、权限)的部门外的人,
     * 保持部门池顺序。
     */
    public List<UUID> pool(Collection<UUID> departmentPool, Predicate<UUID> qualifies, Collection<UUID> warehouseIds) {
        Set<UUID> pool = new LinkedHashSet<>();
        if (departmentPool != null) departmentPool.stream().filter(Objects::nonNull).forEach(pool::add);
        for (UUID candidate : scopes.noticeCandidateUserIds(warehouseIds == null ? List.of() : warehouseIds)) {
            if (!pool.contains(candidate) && qualifies.test(candidate)) pool.add(candidate);
        }
        return List.copyOf(pool);
    }

    /** 该仓链上子仓负责人 ∩ 池; 没有则主管 ∩ 池; 再没有才发整个池。仓库为空 = 未定仓的任务。 */
    public List<UUID> recipients(Collection<UUID> pool, Collection<UUID> warehouseIds) {
        if (pool == null || pool.isEmpty()) return List.of();
        return scopes.noticeRecipients(pool, warehouseIds == null ? List.of() : warehouseIds);
    }
}
