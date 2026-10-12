package com.uten.imp.common.review;

import com.uten.imp.application.port.DocumentUnapprovalPort.Eligibility;
import com.uten.imp.common.util.CanonicalFingerprint;
import com.uten.imp.common.web.ApiException;
import java.util.List;

/** Only existing pure domain assertions run here; no reversal, rollback rehearsal or writes. */
public final class DocumentUnapprovalPreflight {
    private DocumentUnapprovalPreflight() { }
    public static Eligibility evaluate(String family, String facts, Runnable checks) {
        String snapshot = CanonicalFingerprint.sha256(List.of(family, facts));
        try {
            checks.run();
            return Eligibility.ready(snapshot);
        } catch (ApiException blocked) {
            return Eligibility.blocked("DOMAIN_BLOCKED", blocked.getMessage().replace("红冲", "反审"), snapshot);
        }
    }
}
