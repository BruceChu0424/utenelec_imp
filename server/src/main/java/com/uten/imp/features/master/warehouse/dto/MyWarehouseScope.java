package com.uten.imp.features.master.warehouse.dto;

import java.util.List;
import java.util.UUID;

/**
 * 当前账号的仓库数据范围(ADR-149, GET /api/master/warehouses/my-scope), 任务中心仓库选择器只依赖它。
 *
 * @param role               SUPERVISOR 主管 / KEEPER 子仓负责人 / OTHER 其他人
 * @param canSelectAll       能选「全部仓库」(只有主管)
 * @param selectable         可以切换到的仓(主管 = 全部在用仓, 先主仓后子仓; 子仓负责人 = 自己负责的仓及下级;
 *                           其他人为空)。服务端按同一清单校验 scopeWarehouseId, 越界 403
 * @param keeperWarehouses   本人登记负责的仓(登记在主仓上的也列出)
 * @param defaultWarehouseId 只负责一个仓的子仓负责人 = 那个仓(选择器显示只读标签); 其余为空 = 本人默认范围
 */
public record MyWarehouseScope(
        String role,
        boolean canSelectAll,
        List<Option> selectable,
        List<Option> keeperWarehouses,
        UUID defaultWarehouseId) {

    /** 一个仓库选项。 */
    public record Option(UUID id, String code, String name, UUID parentId) {
    }
}
