package com.uten.imp.application.port;

import java.math.BigDecimal;
import java.util.UUID;

/**
 * Creates one initial warehouse FINISHED_IN draft for an exact FQC PASS lot.
 *
 * <p>The implementation owns stock-document construction only. The FQC
 * caller must allocate the returned stock item against qualified release
 * quantity before the surrounding transaction commits.</p>
 */
public interface ProductionFinishedInboundReleasePort {

    CreatedDraft createReleasedDraft(ReleaseRequest request);

    record ReleaseRequest(
            UUID inspectionId,
            UUID decisionEventId,
            UUID sourceReportId,
            UUID sourceReportItemId,
            BigDecimal quantity) {
    }

    record CreatedDraft(
            UUID stockDocumentId,
            UUID stockDocumentItemId) {
    }
}
