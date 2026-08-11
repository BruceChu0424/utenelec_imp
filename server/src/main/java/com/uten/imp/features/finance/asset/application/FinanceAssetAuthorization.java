package com.uten.imp.features.finance.asset.application;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;

import java.util.Set;
import java.util.UUID;

/** Service-layer authorization guard; controller annotations are intentionally not the only barrier. */
@Component
@RequiredArgsConstructor
public class FinanceAssetAuthorization {

    public static final String VIEW = "finance_asset:view";
    public static final String EDIT = "finance_asset:edit";
    public static final String APPROVE = "finance_asset:approve";
    public static final String POST = "finance_asset:post";
    public static final String DISPOSE = "finance_asset:dispose";
    public static final String PERIOD_MANAGE = "finance_asset_period:manage";

    private final SecurityContextCurrentUser currentUser;
    private final FinanceAssetFeatureGate featureGate;

    public AuthUser require(String permission) {
        AuthUser actor = currentUser.get().orElseThrow(() -> new ApiException(ErrorCode.UNAUTHORIZED));
        if (!actor.isSuperAdmin() && !actor.getPermissions().contains(permission)) {
            throw new ApiException(ErrorCode.FORBIDDEN);
        }
        return actor;
    }

    public boolean has(String permission) {
        return currentUser.get()
                .map(actor -> actor.isSuperAdmin() || actor.getPermissions().contains(permission))
                .orElse(false);
    }

    public UUID requireActorId(String permission) {
        return require(permission).getId();
    }

    public boolean isCurrentActor(UUID actorId) {
        UUID current = currentUser.id().orElse(null);
        return current != null && current.equals(actorId);
    }

    public Set<String> allowedActions(String status, UUID makerId, boolean deferredExpense) {
        UUID actorId = currentUser.id().orElse(null);
        return switch (status) {
            case "DRAFT" -> has(EDIT) ? Set.of("EDIT", "DELETE", "SUBMIT") : Set.of();
            case "PENDING_APPROVAL" -> has(APPROVE) && !same(actorId, makerId)
                    ? Set.of("APPROVE", "REJECT") : Set.of();
            case "APPROVED" -> featureGate.postedWorkflowsEnabled()
                    && has(POST) && !same(actorId, makerId) ? Set.of("ACTIVATE") : Set.of();
            case "ACTIVE" -> deferredExpense
                    ? union(featureGate.postedWorkflowsEnabled() && has(DISPOSE)
                            ? Set.of("TERMINATE") : Set.of())
                    : union(
                            has(EDIT) ? Set.of("TRANSFER", "OPERATING_STATUS") : Set.of(),
                            featureGate.postedWorkflowsEnabled() && has(DISPOSE)
                                    ? Set.of("DISPOSE") : Set.of());
            case "DISPOSAL_PENDING" -> pendingActions(actorId, makerId, false);
            case "TERMINATION_PENDING" -> pendingActions(actorId, makerId, true);
            default -> Set.of();
        };
    }

    private Set<String> pendingActions(UUID actorId, UUID makerId, boolean termination) {
        if (same(actorId, makerId) || !has(DISPOSE)) return Set.of();
        String reject = termination ? "REJECT_TERMINATION" : "REJECT_DISPOSAL";
        String approve = termination ? "APPROVE_TERMINATION" : "APPROVE_DISPOSAL";
        return featureGate.postedWorkflowsEnabled() && has(POST)
                ? Set.of(approve, reject) : Set.of(reject);
    }

    @SafeVarargs
    private static Set<String> union(Set<String>... parts) {
        java.util.LinkedHashSet<String> values = new java.util.LinkedHashSet<>();
        for (Set<String> part : parts) {
            values.addAll(part);
        }
        return Set.copyOf(values);
    }

    private static boolean same(UUID left, UUID right) {
        return left != null && left.equals(right);
    }
}
