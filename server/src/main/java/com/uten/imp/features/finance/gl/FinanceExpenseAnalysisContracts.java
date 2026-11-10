package com.uten.imp.features.finance.gl;

import java.util.*;

public final class FinanceExpenseAnalysisContracts {
    private FinanceExpenseAnalysisContracts() { }
    public record GroupInput(UUID id,String period,long expectedVersion,String label,UUID employeeId,String channel,
            String salesAmountLocal,boolean salesConfirmed,boolean reviewed,String sourceReference,int sortOrder) { }
    public record Allocation(UUID groupId,String feeKey,UUID clientId,String amountLocal) { }
    public record AssignmentInput(UUID entryId,String sourceFingerprint,long expectedVersion,List<Allocation> allocations,String sourceReference) { }
    public record NoteInput(String period,String lineKey,long expectedVersion,String remark,String varianceReason) { }
    public record PolicyInput(String period,long expectedVersion,boolean confirmed,String sourceReference,boolean locked,String unlockReason) { }
    public record NoteImportRow(int sourceRow,String lineKey,String category,String sub,String item,String remark,String varianceReason,long expectedVersion) { }
    public record ImportIssue(int sourceRow,String field,String message) { }
    public record NoteImportPreview(UUID importId,String period,String sourceName,String sha256,List<NoteImportRow> rows,List<ImportIssue> issues,boolean applied,int columnContractVersion) {
        public NoteImportPreview(UUID importId,String period,String sourceName,String sha256,List<NoteImportRow> rows,List<ImportIssue> issues,boolean applied){this(importId,period,sourceName,sha256,rows,issues,applied,1);}
    }
    public record ImportApply(UUID importId) { }
    public record LaborSplitInput(String period,long expectedVersion,String sourceFingerprint,String directPositive,
            String indirectPositive,String directNegative,String indirectNegative,boolean reviewed,String sourceReference) { }
}
