package com.uten.imp.features.expenseclaim;

import com.uten.imp.security.AuthUser;
import com.uten.imp.security.OwnerVisibility;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;

/** Additional observer scope only; existing applicant/reviewer/payment scopes stay independent. */
@Component
@RequiredArgsConstructor
public class ExpenseClaimReadPolicy {
    private final OwnerVisibility owners;

    public OwnerVisibility.OwnerScope scope(AuthUser user) {
        if (user == null || !user.getPermissions().contains("expense:view")) {
            return new OwnerVisibility.OwnerScope(false, java.util.Set.of(), java.util.Set.of());
        }
        return owners.evaluate("expense", "expense:view:all");
    }

    static boolean contains(OwnerVisibility.OwnerScope scope, java.util.UUID applicant) {
        return applicant != null && (scope.seeAll() || scope.visibleOwners().contains(applicant));
    }

    /** One row policy for lists' detail loading, attachments and retained evidence. */
    static boolean canRead(AuthUser user, ExpenseClaim claim, OwnerVisibility.OwnerScope observerScope) {
        if (user == null || user.isVisitor() || user.getEmployeeId() == null) return false;
        if (contains(observerScope, claim.getApplicantId())) return true;
        java.util.UUID actor=user.getEmployeeId();
        if (actor.equals(claim.getApplicantId()) && has(user,"expense:apply")) return true;
        if (has(user,"expense:approve") && (java.util.Set.of("SUBMITTED","REVIEWING").contains(claim.getStatus())
                || actor.equals(claim.getApprovedBy()) || actor.equals(claim.getRejectedBy()))) return true;
        return java.util.Set.of("APPROVED","PAID").contains(claim.getStatus()) && has(user,"expense:pay");
    }

    private static boolean has(AuthUser user,String permission) {
        return user.isSuperAdmin() || user.getPermissions().contains(permission);
    }
}
