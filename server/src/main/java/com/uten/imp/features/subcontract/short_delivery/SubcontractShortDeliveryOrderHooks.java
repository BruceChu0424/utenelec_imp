package com.uten.imp.features.subcontract.short_delivery;

import java.util.UUID;

/**
 * 委外订货单生命周期对短交案件的回调(同 feature 内, 订货服务经 ObjectProvider 懒取, 避免
 * 订货服务 ↔ 短交服务构造注入成环)。
 */
public interface SubcontractShortDeliveryOrderHooks {

    /** ADR-072 受控改量之后：新订货量 ≤ 累计回厂 → 开放案件自然完成; 否则刷新案件数字。 */
    void reevaluateAfterOrderQuantityChange(UUID orderId);

    /** 订货单红冲：开放案件作废并撤回通知。 */
    void cancelOpenCasesForOrder(UUID orderId, String reason);

    /** Reverse the independent fulfilment credit when its physical loss is reversed. */
    default void lossReversed(UUID wasteId) {}
}
