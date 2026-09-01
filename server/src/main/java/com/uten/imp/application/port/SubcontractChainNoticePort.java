package com.uten.imp.application.port;

import java.util.UUID;

/** Durable notice projections emitted by the subcontract lifecycle. */
public interface SubcontractChainNoticePort {
    void notifySubcontractPreparationRequired(UUID planItemId);

    void notifySubcontractOutboundReady(UUID planItemId);

    void notifySubcontractOutboundCompleted(UUID issueId);

    void notifySubcontractOutboundReversed(UUID issueId);
}
