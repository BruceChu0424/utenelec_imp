package com.uten.imp.audit;

import com.uten.imp.security.SecurityContextCurrentUser;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;

import java.util.UUID;

/** Records one authorized, successfully resolved business-detail view. */
@Component
@RequiredArgsConstructor
public class AuditDetailViewRecorder {

    private final AuditService audit;
    private final SecurityContextCurrentUser currentUser;

    public void record(
            String action,
            String targetType,
            UUID targetId,
            String billNo,
            Integer legacyId,
            String documentLabel) {
        if (action == null || !action.startsWith("view_")
                || targetType == null || targetType.isBlank()
                || targetId == null
                || documentLabel == null || documentLabel.isBlank()) {
            throw new IllegalArgumentException("Invalid detail-view audit contract");
        }
        var request = AuditRequestContext.currentRequest();
        AuditRequestContext.VerifiedActor verified =
                AuditRequestContext.verifiedActor(request);
        UUID actorId;
        String actorAccount;
        if (verified != null) {
            actorId = verified.actorId();
            actorAccount = verified.actorAccount();
        } else {
            var actor = currentUser.get().orElseThrow(
                    () -> new IllegalStateException("Authenticated detail viewer is missing"));
            actorId = actor.getId();
            actorAccount = actor.getLoginAccount();
        }
        String safeDocumentLabel = documentLabel.trim();
        String safeBillNo = billNo == null ? "" : billNo.trim();
        Integer safeLegacyId = legacyId != null && legacyId > 0 ? legacyId : null;
        String effectiveAction = safeLegacyId == null ? action : action + "_history";
        audit.logSuccessfulDetailView(
                actorId,
                actorAccount,
                effectiveAction,
                targetType,
                targetId,
                safeDocumentLabel,
                safeBillNo.isBlank() ? null : safeBillNo,
                safeLegacyId == null ? null : safeLegacyId.toString());
    }
}
