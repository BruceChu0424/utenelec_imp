package com.uten.imp.application.port;

import java.math.BigDecimal;
import java.util.List;
import java.util.UUID;

/**
 * Integration boundary for production final-quality inspection (FQC).
 *
 * <p>The warehouse-arrival registration transaction registers one inspection
 * per selected approved report line. Unselected lines remain pending for a later
 * registration batch. A later FINISHED_IN producer must register its exact
 * stock-document line here in the same transaction; the implementation accepts
 * only quantity backed by append-only PASS decisions.  The port never mutates
 * stock, report progress, {@code iqty}, or parent MAKE readiness itself.</p>
 */
public interface ProductionQualityInspectionPort {

    /**
     * Register the exact warehouse-registered lines selected in one arrival
     * command. A report may be handed to FQC in several batches, while every
     * report line keeps one permanent registration and inspection identity.
     */
    void registerApprovedReportItems(
            UUID reportId,
            List<UUID> reportItemIds,
            UUID registrationId);

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
