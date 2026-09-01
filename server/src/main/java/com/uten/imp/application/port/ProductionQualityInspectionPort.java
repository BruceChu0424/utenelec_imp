package com.uten.imp.application.port;

import java.math.BigDecimal;
import java.util.UUID;

/**
 * Integration boundary for production final-quality inspection (FQC).
 *
 * <p>The warehouse-arrival registration transaction registers one inspection
 * per approved report line. A later FINISHED_IN producer must register its exact
 * stock-document line here in the same transaction; the implementation accepts
 * only quantity backed by append-only PASS decisions.  The port never mutates
 * stock, report progress, {@code iqty}, or parent MAKE readiness itself.</p>
 */
public interface ProductionQualityInspectionPort {

    /** Register every warehouse-registered exact line of an approved report. */
    void registerApprovedReport(UUID reportId);

    /**
     * Allocate qualified PASS quantity to one initial FINISHED_IN draft line.
     * Replays with the same key and request return the original authorization.
     */
    ReleaseAuthorization allocateReleasedQuantity(
            UUID sourceReportItemId,
            UUID stockDocumentItemId,
            BigDecimal quantity,
            String idempotencyKey);

    /** True only for report lines explicitly registered after FQC activation. */
    boolean managesReportItem(UUID sourceReportItemId);

    /**
     * Lock all inspections of one report in UUID order before report reversal
     * locks execution segments and plan rows.
     */
    void prelockForReportReversal(UUID reportId);

    /**
     * Cancel every inspection of a reversed source report after all active
     * FINISHED_IN documents have been reversed or removed.
     */
    void cancelForReversedReport(UUID reportId);

    /**
     * Require the pending stock line (or its V338 residual/reversal descendant)
     * to trace back to one exact qualified PASS release command.
     * A line without an inspection may bypass this gate only when it has an
     * explicit migration-cutover exemption.
     */
    void requireInboundReleased(
            UUID sourceReportItemId,
            UUID stockDocumentItemId,
            BigDecimal quantity);

    /** Require an explicit migration-cutover exemption for a pre-V414 line. */
    void requireLegacyExemption(UUID sourceReportItemId);

    record ReleaseAuthorization(
            UUID releaseCommandId,
            UUID inspectionId,
            UUID sourceReportItemId,
            UUID stockDocumentItemId,
            BigDecimal quantity) {
    }
}
