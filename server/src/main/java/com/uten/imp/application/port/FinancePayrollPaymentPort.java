package com.uten.imp.application.port;

import java.math.BigDecimal;
import com.fasterxml.jackson.annotation.JsonFormat;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.util.*;

/**
 * Approved payroll is the sole salary amount authority. The application workflow owns
 * its reviewers; the payroll bridge owns its original facts, one accrual and actual
 * account/GL settlement. Callers hold the source header, then their workflow/claim.
 */
public interface FinancePayrollPaymentPort {
    record Item(UUID id,String code,String name,String type,@JsonFormat(shape=JsonFormat.Shape.STRING) BigDecimal amount,String sourceType,String description) {
        public Item(UUID id,String code,String name,String type,BigDecimal amount,String sourceType){this(id,code,name,type,amount,sourceType,null);}
    }
    record Slip(UUID id,UUID employeeId,String employeeCode,String employeeName,UUID departmentId,String departmentName,
            @JsonFormat(shape=JsonFormat.Shape.STRING) BigDecimal grossIncome,@JsonFormat(shape=JsonFormat.Shape.STRING) BigDecimal totalDeduction,@JsonFormat(shape=JsonFormat.Shape.STRING) BigDecimal netIncome,List<Item> items) {
        public Slip(UUID id,UUID employeeId,String employeeCode,String employeeName,UUID departmentId,BigDecimal grossIncome,BigDecimal totalDeduction,BigDecimal netIncome,List<Item> items){this(id,employeeId,employeeCode,employeeName,departmentId,null,grossIncome,totalDeduction,netIncome,items);}
    }
    record Source(UUID batchId,String period,String nativeStatus,UUID generatedBy,UUID departmentId,
            UUID currencyId,@JsonFormat(shape=JsonFormat.Shape.STRING) BigDecimal grossIncome,@JsonFormat(shape=JsonFormat.Shape.STRING) BigDecimal totalDeduction,@JsonFormat(shape=JsonFormat.Shape.STRING) BigDecimal netIncome,
            String fingerprint,List<Slip> slips) { }
    enum AccrualMode { NATIVE_APPROVED_PAYROLL, EXISTING_CONFIRMED_LIABILITY }
    enum ExistingLiabilityBasis { GROSS_BEFORE_DEDUCTIONS,NET_AFTER_DEDUCTIONS }
    record OpenItemReference(String kind,UUID sourceId,Integer allocationNo,String sourceFingerprint) { }
    /** No amount override: the deduction amount is always the original payroll item amount. */
    record DeductionSettlement(UUID payrollItemId,UUID auxiliaryId,OpenItemReference original,String sourceReference) { }
    enum DeductionPurpose { STANDARD_LIABILITY,STANDARD_INCOME,EMPLOYEE_SETTLEMENT,EXPENSE_REDUCTION,MANUFACTURING_COST_REDUCTION }
    /** A confirmed split of one exact native item; amount never replaces the native item or batch total. */
    record DeductionAllocation(UUID id,DeductionPurpose purpose,UUID styleId,String amount,UUID auxiliaryId,
            OpenItemReference original,String sourceReference) { }
    record ExistingLiabilityLine(UUID entryId,int allocationNo,String sourceFingerprint,String amountLocal,String amountOriginal) {
        public ExistingLiabilityLine(UUID entryId,String sourceFingerprint,String amountLocal){this(entryId,0,sourceFingerprint,amountLocal,null);}
    }
    record Instruction(AccrualMode mode,UUID wagePayableStyleId,Map<UUID,UUID> expenseStyleByDepartment,
            Map<String,UUID> deductionStyleByCode,UUID existingAccrualVoucherId,String sourceReference,
            ExistingLiabilityBasis existingLiabilityBasis,List<ExistingLiabilityLine> existingLiabilityLines,
            List<DeductionSettlement> deductionSettlements,List<UUID> originalEvidenceIds,LocalDate accountingAsOf,
            Map<UUID,List<DeductionAllocation>> deductionAllocations) {
        public Instruction(AccrualMode mode,UUID wagePayableStyleId,Map<UUID,UUID> expenseStyleByDepartment,Map<String,UUID> deductionStyleByCode,UUID existingAccrualVoucherId,String sourceReference,ExistingLiabilityBasis existingLiabilityBasis,List<ExistingLiabilityLine> existingLiabilityLines,List<DeductionSettlement> deductionSettlements,List<UUID> originalEvidenceIds){this(mode,wagePayableStyleId,expenseStyleByDepartment,deductionStyleByCode,existingAccrualVoucherId,sourceReference,existingLiabilityBasis,existingLiabilityLines,deductionSettlements,originalEvidenceIds,null,null);}
        public Instruction(AccrualMode mode,UUID wagePayableStyleId,Map<UUID,UUID> expenseStyleByDepartment,Map<String,UUID> deductionStyleByCode,UUID existingAccrualVoucherId,String sourceReference,ExistingLiabilityBasis existingLiabilityBasis,List<ExistingLiabilityLine> existingLiabilityLines,List<DeductionSettlement> deductionSettlements,List<UUID> originalEvidenceIds,LocalDate accountingAsOf){this(mode,wagePayableStyleId,expenseStyleByDepartment,deductionStyleByCode,existingAccrualVoucherId,sourceReference,existingLiabilityBasis,existingLiabilityLines,deductionSettlements,originalEvidenceIds,accountingAsOf,null);}
    }
    record Issue(String field,String sourceRow,String message) { }
    record Prepared(UUID applicationId,UUID batchId,String sourceFingerprint,String instructionFingerprint,
            List<Issue> issues) { public boolean ready(){return issues.isEmpty();} }
    record Execute(UUID requestId,UUID applicationId,UUID batchId,String sourceFingerprint,String instructionFingerprint,
            UUID accountId,LocalDate paymentDate,String bankReference,String bankAmount,String bankFee,UUID bankFeeStyleId,OffsetDateTime bankBookedAt) {
        public Execute(UUID requestId,UUID applicationId,UUID batchId,String sourceFingerprint,String instructionFingerprint,UUID accountId,LocalDate paymentDate,String bankReference,String bankAmount,String bankFee,UUID bankFeeStyleId){this(requestId,applicationId,batchId,sourceFingerprint,instructionFingerprint,accountId,paymentDate,bankReference,bankAmount,bankFee,bankFeeStyleId,null);}
    }
    enum ReceiptKind { BANK_PAYMENT,NON_CASH_CLEARED,NO_FINANCIAL_EVENT }
    record Result(UUID applicationId,UUID batchId,UUID paymentId,UUID requestId,UUID accrualVoucherId,UUID paymentVoucherId,UUID nonCashVoucherId,
            UUID accountFlowId,String state,ReceiptKind receiptKind,boolean sourceClaimOnly,@JsonFormat(shape=JsonFormat.Shape.STRING) BigDecimal netAmount,@JsonFormat(shape=JsonFormat.Shape.STRING) BigDecimal feeAmount,@JsonFormat(shape=JsonFormat.Shape.STRING) BigDecimal bankAmount,
            OffsetDateTime paidAt,UUID paidBy) {
        public Result(UUID applicationId,UUID batchId,UUID paymentId,UUID requestId,UUID accrualVoucherId,UUID paymentVoucherId,UUID accountFlowId,String state,BigDecimal netAmount,BigDecimal feeAmount,BigDecimal bankAmount,OffsetDateTime paidAt,UUID paidBy){this(applicationId,batchId,paymentId,requestId,accrualVoucherId,paymentVoucherId,null,accountFlowId,state,ReceiptKind.BANK_PAYMENT,false,netAmount,feeAmount,bankAmount,paidAt,paidBy);}
        public Result(UUID applicationId,UUID batchId,UUID paymentId,UUID requestId,UUID accrualVoucherId,UUID paymentVoucherId,UUID accountFlowId,String state,ReceiptKind kind,BigDecimal netAmount,BigDecimal feeAmount,BigDecimal bankAmount,OffsetDateTime paidAt,UUID paidBy){this(applicationId,batchId,paymentId,requestId,accrualVoucherId,paymentVoucherId,null,accountFlowId,state,kind,false,netAmount,feeAmount,bankAmount,paidAt,paidBy);}
        public Result(UUID applicationId,UUID batchId,UUID paymentId,UUID requestId,UUID accrualVoucherId,UUID paymentVoucherId,UUID nonCashVoucherId,UUID accountFlowId,String state,ReceiptKind kind,BigDecimal netAmount,BigDecimal feeAmount,BigDecimal bankAmount,OffsetDateTime paidAt,UUID paidBy){this(applicationId,batchId,paymentId,requestId,accrualVoucherId,paymentVoucherId,nonCashVoucherId,accountFlowId,state,kind,false,netAmount,feeAmount,bankAmount,paidAt,paidBy);}
    }
    record Reverse(UUID requestId,UUID applicationId,UUID expectedClearingVoucherId,String reason) {
        /** Compatibility accessor; the receipt kind determines payment versus noncash GL. */
        public UUID paymentVoucherId(){return expectedClearingVoucherId;}
    }

    /** No guessed salary or deductions: active slips in APPROVED/PUBLISHED batches only. */
    Source source(UUID batchId,boolean forUpdate);
    /** Persist reviewed mapping metadata; return every missing/unreconciled source as an issue. */
    Prepared prepare(UUID applicationId,UUID batchId,String expectedSourceFingerprint,Instruction instruction);
    /** Trusted workflow call after approval + clean payment proof; no caller-supplied salary amount. */
    Result execute(Execute command);
    Optional<Result> result(UUID applicationId);
    /** Confirm the posted, exact original payment without generating another expense. */
    Result confirm(UUID applicationId,UUID requestId,UUID expectedPaymentVoucherId);
    /** Reverse original account/GL facts once; never rerun salary calculation or silently reverse its accrual. */
    Result reverse(Reverse command);
}
