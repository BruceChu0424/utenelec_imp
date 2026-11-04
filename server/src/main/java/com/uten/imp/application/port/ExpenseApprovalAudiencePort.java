package com.uten.imp.application.port;

import java.util.Set;
import java.util.UUID;

/** Object-level approval recipient policy owned by the reimbursement domain. */
public interface ExpenseApprovalAudiencePort {
    Set<String> APPROVAL_PERMISSIONS=Set.of("expense:approve:department","expense:approve:finance_initial",
            "expense:approve:finance_review","expense:approve:executive");
    boolean eligible(UUID userId,UUID employeeId,Set<String> permissions,UUID claimId);
    boolean eligiblePayment(UUID userId,UUID employeeId,Set<String> permissions,UUID claimId);
    default String route(UUID userId,UUID employeeId,Set<String> permissions,UUID departmentId,String stage) { return "/expense/approval"; }
}
