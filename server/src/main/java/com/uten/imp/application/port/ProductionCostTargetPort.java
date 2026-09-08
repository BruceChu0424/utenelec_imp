package com.uten.imp.application.port;

import java.util.UUID;

/** Queue cost rebasing only after the real final-report approval or reversal changed its target. */
public interface ProductionCostTargetPort {
    void targetChangedByReport(UUID reportId,UUID actorUserId);
}
