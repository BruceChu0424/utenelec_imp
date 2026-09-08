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
    void wasteRecorded(UUID wasteId,UUID actorUserId,boolean reversal);
    WasteValue wasteValue(UUID wasteItemId);
}
