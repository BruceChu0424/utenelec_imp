package com.uten.imp.application.port;

import java.util.Collection;
import java.util.UUID;

/**
 * ADR-098 × ADR-090(2026-10-05): 委外回厂走「先入库后质检」时, 货在登记时已经按库位上架; 这张收货单
 * 还有待委外判定的回厂短交, 品质合格照常记结论, 但自动转为可用库存先扣住。委外判定(分批到货 /
 * 接受损耗)后, 判定所在的同一事务经本端口把这些订货明细上不再被扣住的已上架合格品补做自动转正
 * (委外 feature 不直连仓库 feature, ADR-017)。
 *
 * <p>调用方必须已在本事务首次预锁时并入这些收货单的品质与入库足迹
 * ({@code ProcurementMutationLocks.subcontractShortDeliveryDecision}); 仍被扣住的收货单原样跳过。
 */
public interface SubcontractPreStockReleasePort {

    /**
     * @param orderItemIds 刚判定 / 刚到齐的委外订货明细
     * @return 本次自动转正的品质放行事件数
     */
    int releaseHeldPreStock(Collection<UUID> orderItemIds);
}
