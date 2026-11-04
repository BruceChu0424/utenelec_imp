package com.uten.imp.features.finance.application;
import java.util.*;

public final class FinanceApplicationContracts {
    private FinanceApplicationContracts() { }
    public record SettingsInput(long expectedVersion,boolean enabled,String sourceReference) { }
    public record RoleInput(UUID id,long expectedVersion,String roleKey,UUID departmentId,UUID employeeId,String sourceReference) { }
    public record RequestLine(UUID id,String label,String amountOriginal,UUID appliedLedgerId,UUID expenseStyleId) { }
    public record DraftInput(UUID requestId,UUID id,long expectedVersion,String kind,String title,String remark,String requestedDate,
            UUID sourceId,UUID travelApplicationId,String paymentNature,UUID supplierId,UUID currencyId,List<RequestLine> lines,
            String destination,String travelStart,String travelEnd,String travelPurpose) { }
    public record Action(UUID requestId,long expectedVersion,String sourceFingerprint,UUID expectedClaimId,String reason) { }
    public record Assign(UUID requestId,long expectedVersion,List<UUID> employeeIds,String reason) { }
    public record Execute(UUID requestId,long expectedVersion,String sourceFingerprint,UUID accountId,String paymentDate,
            String bankBookedAt,String bankReference,String bankAmount,String bankFee,UUID bankFeeStyleId,UUID expenseStyleId,
            String exchangeRate,String postingPurpose) { }
    public record PayrollPreparation(UUID requestId,long expectedVersion,String sourceFingerprint,UUID expectedClaimId,
            com.uten.imp.application.port.FinancePayrollPaymentPort.Instruction instruction) { }
    public record InvoiceVerification(UUID requestId,long expectedVersion,String sourceFingerprint,UUID expectedClaimId,
            UUID invoiceId,Long nativeVersion,String result,String remark) { }
    public record Assignment(UUID employeeId,UUID userId,String name) { }
}
