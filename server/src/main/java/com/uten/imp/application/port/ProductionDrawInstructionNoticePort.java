package com.uten.imp.application.port;

import java.util.UUID;

/** Publish an exact instruction change; the notice owner rereads current actionable quantities. */
public interface ProductionDrawInstructionNoticePort {
    void notifyProductionDrawInstructionsChanged(UUID stockDocumentId, UUID receivingConfirmationId, boolean reverse);
}
