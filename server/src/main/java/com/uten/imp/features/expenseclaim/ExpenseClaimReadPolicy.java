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
    @org.springframework.beans.factory.annotation.Autowired(required=false)
    private com.uten.imp.application.port.FinanceApplicationControlPort applications;

    public boolean mayRead(AuthUser user,ExpenseClaim claim,OwnerVisibility.OwnerScope scope){
        if(applications!=null&&applications.expenseManaged(claim.getId())){
            if(contains(scope,claim.getApplicantId()))return true;
            return applications.mayReadExpense(claim.getId(),user);
        }
        return canReadWorkflow(user,claim,scope);
    }
    @org.springframework.beans.factory.annotation.Autowired
    private ExpenseApprovalPolicy approvalPolicy;
    @org.springframework.beans.factory.annotation.Autowired
    private ExpenseClaimEventRepository events;

    boolean canReadWorkflow(AuthUser user,ExpenseClaim claim,OwnerVisibility.OwnerScope scope) {
        if(canRead(user,claim,scope))return true;
        if(approvalPolicy.canApprove(user,claim))return true;
        return ExpenseApprovalPolicy.hasAny(user) && events.existsByClaimIdAndActorEmployeeIdAndEventTypeIn(
                claim.getId(),user.getEmployeeId(),java.util.Set.of("STAGE_APPROVED","APPROVED","REJECTED"));
    }

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
        if (ExpenseApprovalPolicy.hasAny(user) && (actor.equals(claim.getApprovedBy()) || actor.equals(claim.getRejectedBy()))) return true;
        return ("PAID".equals(claim.getStatus())&&has(user,"expense:pay"))||ExpenseApprovalPolicy.canPayFacts(user,claim);
    }

    private static boolean has(AuthUser user,String permission) {
        return user.getPermissions().contains(permission);
    }
}
