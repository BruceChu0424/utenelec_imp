package com.uten.imp.application.port;

import java.util.Optional;
import java.util.UUID;

/**
 * 车间内料仓(原名线边仓)端口(ADR-147 起; 取代 V595 / ADR-089 的「第一次直送时自动配置」)。
 *
 * <p>内料仓的开通记录唯一真源是 {@code workshop_bins}(开通命令在「车间内料仓」页办理)。
 * V837(ADR-173) 起车间直送不再要求收料车间预先开通: 审核直送时经
 * {@link #ensureOpenedBinOf} 按需建仓并写开通行(单一真源保留, 发料来源仓置空);
 * 候选资格判定 {@code fn_workshop_direct_targets} 同步拆掉 WORKSHOP_BIN_NOT_OPEN 门槛。
 */
public interface LineSideWarehousePort {

    /** 车间已开通的内料仓; 没开通返回空。 */
    Optional<UUID> openedBinOf(UUID workshopDepartmentId);

    /**
     * 直送审核按需开通(V837/ADR-173): 已开通直接复用; 没开通就建出内料仓并写开通行,
     * 返回内料仓 id。sameMainWarehouseId = 收料需求所在仓(内料仓优先挂靠它同主仓,
     * 行级守卫要求与收料需求同主仓), actor = 直送审核人(记入 opened_by)。
     * 整批领料不受影响: 它仍必须由开通命令显式开启。
     */
    UUID ensureOpenedBinOf(UUID workshopDepartmentId, UUID sameMainWarehouseId, UUID actor);
}
