package com.uten.imp.application.port;
import com.uten.imp.security.AuthUser;
import java.util.UUID;

/** Original-source lifecycle hooks and exact trusted execution contexts, not another amount system. */
public interface FinanceApplicationControlPort {
    record NativePermit(UUID applicationId,UUID applicantId,UUID approvedBy,String approvedName) { }
    NativePermit requireNativeCreation(String docType);
    NativePermit nativeExecutionPermit(String docType,UUID documentId);
    void requireNativeSettlementAction(String docType,UUID documentId,String action);
    void registerExpenseDraft(UUID claimId,String requestedKind,UUID travelApplicationId);
    default void requireExpenseMainAuthority(UUID claimId) { }
    boolean expenseSubmitted(UUID claimId);
    void expenseWithdrawn(UUID claimId);
    boolean expenseManaged(UUID claimId);
    boolean mayReadExpense(UUID claimId,AuthUser actor);
    java.util.Set<UUID> readableApplications(java.util.Collection<UUID> applicationIds,AuthUser actor);
    void requireLegacyExpenseDecision(UUID claimId);
    void requireExpenseDecisionContext(UUID claimId);
    void requireExpenseInvoiceVerification(UUID claimId);
    void requireExpensePayment(UUID claimId);
    void requireExpenseReversalContext(UUID claimId,UUID financeExpenseId);
    void requirePaymentExecution(UUID paymentId);
    void requireExpenseExecution(UUID expenseId);
}
