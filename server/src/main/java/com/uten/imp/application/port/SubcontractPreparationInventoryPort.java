package com.uten.imp.application.port;

import java.util.UUID;

/** Cross-feature hook for exact make-before-subcontract finished inventory. */
public interface SubcontractPreparationInventoryPort {

    /** Called after FINISHED_IN physical stock and iqty are committed in the caller transaction. */
    void afterFinishedInboundApproved(UUID stockDocumentId, UUID warehouseId);

    /** Called before FINISHED_IN stock removal; must reject already-outbound slices. */
    void beforeFinishedInboundReversed(UUID stockDocumentId);
}
