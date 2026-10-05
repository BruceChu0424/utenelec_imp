package com.uten.imp.application.port;

import java.util.Optional;
import java.util.UUID;

/**
 * 车间内料仓(原名线边仓)的只读端口(ADR-147 起; 取代 V595 / ADR-089 的「第一次直送时自动配置」)。
 *
 * <p>内料仓只能在「车间内料仓」里由开通命令建出(唯一真源是 {@code workshop_bins} 开通记录),
 * 生产(production)的车间直送只读取收料车间已开通的那一个内料仓, 不再建仓。收料车间没开通时
 * 直送资格判定 {@code fn_workshop_direct_targets} 已给出原因码 WORKSHOP_BIN_NOT_OPEN, 报工这部分送入仓库。
 */
public interface LineSideWarehousePort {

    /** 车间已开通的内料仓; 没开通返回空。 */
    Optional<UUID> openedBinOf(UUID workshopDepartmentId);
}
