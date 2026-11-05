package com.uten.imp.application.port;

import java.util.UUID;
import java.math.BigDecimal;
import com.uten.imp.application.port.InventoryValuationPort.State;

/** Physical loss classification keeps the original company material value separate from supplier claims. */
public interface SubcontractMaterialValuePort {
    /** Published amounts are current value-node projections; null means unresolved, never free material. */
    record WasteValue(UUID orderItemId,UUID normalValueNodeId,UUID excessValueNodeId,
                      BigDecimal normalValueLocal,BigDecimal excessValueLocal,State state) {}
    void validateWaste(UUID wasteId);
    default void requireWasteReversalAvailable(UUID wasteId) {
        throw new com.uten.imp.common.web.ApiException(com.uten.imp.common.web.ErrorCode.CONFLICT,"当前无法核对损耗原成本的反向条件");
    }
    void wasteRecorded(UUID wasteId,UUID actorUserId,boolean reversal);
    /** Publish the responsibility snapshot after this transaction's final
     * material-cost revisions, before commit; failure rolls back both facts. */
    default void afterWasteCostsPrepared(UUID wasteId,Runnable publication) {
        throw new IllegalStateException("Deferred subcontract loss-cost publication is unavailable");
    }
    WasteValue wasteValue(UUID wasteItemId);
}
