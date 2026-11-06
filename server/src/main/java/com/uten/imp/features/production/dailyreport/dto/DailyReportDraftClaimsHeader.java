package com.uten.imp.features.production.dailyreport.dto;

import com.fasterxml.jackson.annotation.JsonInclude;
import java.time.LocalDate;
import java.util.List;
import java.util.UUID;

/** Only navigation, lifecycle and exact draft evidence needed by an accepted task set. */
@JsonInclude(JsonInclude.Include.ALWAYS)
public record DailyReportDraftClaimsHeader(UUID id, String billNo, LocalDate billDate, Short status,
        boolean closed, boolean canceled, String rowVersion, int draftClaimsVersion,
        String draftClaimsFingerprint, List<DailyReportDraftClaim> draftClaims) {
    /** Closed Spring Data projection: no entity/detail/name or attachment hydration. */
    public interface Projection {
        UUID getId();
        String getBillNo();
        LocalDate getBillDate();
        Short getStatus();
        boolean isClosed();
        boolean isCanceled();
        Long getRowVersion();
    }
}
