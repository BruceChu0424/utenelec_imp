package com.uten.imp.features.master.warehouse.dto;

import java.util.List;
import java.util.UUID;

/**
 * 当前账号的「我的仓库」(ADR-115), 仓库任务中心仓库范围选择器用。
 *
 * @param keeperWarehouses  本人被登记为负责人的仓库(登记在主仓上的只列主仓, 范围里已含其子仓)
 * @param scopeWarehouseIds 「我的仓库」实际范围: 本人负责的仓(含子仓) + 尚无有效负责人的仓
 * @param keepersConfigured 全公司是否已登记过任何负责人(没有 = 「我的仓库」等于全部仓库)
 */
public record MyWarehouseScope(
        List<KeeperWarehouse> keeperWarehouses,
        List<UUID> scopeWarehouseIds,
        boolean keepersConfigured) {

    /** 本人负责的一个仓库。 */
    public record KeeperWarehouse(UUID id, String code, String name) {
    }
}
