package com.uten.imp.application.port;

import java.util.UUID;

/**
 * 线边仓自动配置端口(V595 / ADR-089)。
 *
 * <p>仓库主档(master)拥有仓库行；生产(production)在车间直送时只需要「本车间与收料仓同主仓的
 * 那个线边仓」，没有就建一个。实现必须运行在调用方事务里：直送事实、班组自检放行、入线边仓
 * 三笔写入要与建仓同生共死，失败整单回滚不留半个空仓。
 */
public interface LineSideWarehousePort {

    /**
     * 返回车间与 {@code demandWarehouseId} 同主仓的线边仓；没有就在同一事务里配置一个
     * (auto_created、挂收料主仓下、参与核算、非不良、叶子仓、归属该车间)。
     */
    UUID ensure(UUID workshopDepartmentId, UUID demandWarehouseId);
}
