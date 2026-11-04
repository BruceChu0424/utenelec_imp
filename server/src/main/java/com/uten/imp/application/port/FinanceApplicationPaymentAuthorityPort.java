package com.uten.imp.application.port;

import java.util.*;

/** Read-only application authorization; the payroll adapter never guesses another domain's tables. */
public interface FinanceApplicationPaymentAuthorityPort {
    record Evidence(UUID id,String sha256,String sourceName) { }
    record Permit(UUID applicationId,UUID batchId,UUID actorUserId,UUID actorEmployeeId,String actorName,
            UUID applicantId,UUID finalApproverId,String sourceFingerprint,String instructionFingerprint,
            List<Evidence> cleanPaymentEvidence) { }
    /** Current FINANCE_REVIEW_2 node + live review lease and source fingerprint. */
    Permit requirePayrollPreparation(UUID applicationId,UUID batchId,String expectedSourceFingerprint);
    /** APPROVED + exact frozen plan + execution authority + clean proof + payer != final approver/applicant. */
    Permit requirePayrollExecution(FinancePayrollPaymentPort.Execute command);
    /** Exact original posted payment; view and confirmation action, without posting a new amount. */
    Permit requirePayrollConfirmation(UUID applicationId,UUID batchId,UUID expectedPaymentVoucherId);
    /** Exact original posted payment and actual reverse authority; ledger/period checks still belong to the bridge. */
    Permit requirePayrollReversal(UUID applicationId,UUID batchId,FinancePayrollPaymentPort.Reverse command);
}
