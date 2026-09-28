package com.uten.imp.features.warehouse.materialbin;

import java.util.UUID;

/**
 * 请求"本事务提交后尝试结算这一期" (ADR-131 §5.8)。
 *
 * <p>提交盘点、更正盘点、补录进已盘点的那一期、报工审核被"未审报工"拦住时调用; 结算本身在
 * {@code close} 子包 (提交后投递到后台执行)。结算实现还没接入时没有这个 bean, 调用方跳过,
 * 由每 10 分钟的定时补做接上 (期间已标为排队结算)。
 */
public interface WorkshopMaterialCloseRequester {

    /** 在当前事务里登记: 提交后以 actorUserId 为操作人尝试结算 periodId。 */
    void requestAfterCommit(UUID periodId, UUID actorUserId);
}
