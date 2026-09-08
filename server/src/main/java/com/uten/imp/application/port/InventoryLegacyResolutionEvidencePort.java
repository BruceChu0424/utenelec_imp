package com.uten.imp.application.port;

import java.math.BigDecimal;
import java.time.OffsetDateTime;
import java.util.Optional;
import java.util.UUID;

/** Finance-owned approval evidence. A legacy gl_voucher status=1 is not such an approval. */
public interface InventoryLegacyResolutionEvidencePort {
    enum ResolutionKind { FORWARD_ADJUSTMENT, NO_ADJUSTMENT_REQUIRED }

    record ApprovedResolution(UUID caseId, UUID approvalDecisionId, long decisionVersion,
                              UUID approvedByUserId, UUID approvedByEmployeeId, OffsetDateTime approvedAt,
                              ResolutionKind kind, BigDecimal approvedAdjustmentLocal, UUID forwardGlEventId,
                              String explanation, String evidenceHash) {}

    /** Return only a live, case-specific approval and its posted forward adjustment (or approved no-adjustment decision).
     * Read-only: the finance caller must already hold its approval/source lock through case closure;
     * this lookup must neither acquire late business locks nor generate a voucher as a side effect.
     */
    Optional<ApprovedResolution> findApproved(UUID caseId, UUID approvalDecisionId);
}
