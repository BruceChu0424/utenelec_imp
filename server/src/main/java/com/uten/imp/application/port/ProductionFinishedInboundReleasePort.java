package com.uten.imp.application.port;

import java.math.BigDecimal;
import java.util.List;
import java.util.Map;
import java.util.UUID;

/**
 * Creates the initial warehouse FINISHED_IN drafts for the exact FQC PASS lots of one command.
 *
 * <p>ADR-148: releases that share one physical handoff (same report, arrival registration,
 * warehouse, production plan and pre-stocked lane) become one document with one line per
 * release, so the warehouse gets one count task, one plan link and one pending notice per
 * handoff instead of one per accounting slice. Different plans are never merged.</p>
 *
 * <p>The implementation owns stock-document construction only. The FQC caller must allocate
 * every returned stock item against qualified release quantity before the surrounding
 * transaction commits.</p>
 */
public interface ProductionFinishedInboundReleasePort {

    /** Returns one draft line per request, keyed by the request's decision event id. */
    Map<UUID, CreatedDraft> createReleasedDrafts(List<ReleaseRequest> requests);

    record ReleaseRequest(
            UUID inspectionId,
            UUID decisionEventId,
            UUID sourceReportId,
            UUID sourceReportItemId,
            BigDecimal quantity) {
    }

    /**
     * @param preStockedAutoConfirm the document belongs to a proven "stock in before inspection"
     *        registration: the FQC caller confirms it automatically once, after allocating every line
     */
    record CreatedDraft(
            UUID stockDocumentId,
            UUID stockDocumentItemId,
            boolean preStockedAutoConfirm) {
    }
}
