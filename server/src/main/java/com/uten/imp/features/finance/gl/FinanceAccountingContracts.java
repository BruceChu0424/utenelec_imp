package com.uten.imp.features.finance.gl;

import com.uten.imp.application.port.FinancialAuxiliaryValidationPort.Ref;
import com.fasterxml.jackson.annotation.JsonFormat;
import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.*;

public final class FinanceAccountingContracts {
    private FinanceAccountingContracts() { }
    public record AccountSelection(String accountCode,UUID styleId,long chartVersion,UUID currencyId) { }
    public record OpeningAllocation(String accountCode,UUID auxiliaryId,UUID currencyId,
            @JsonFormat(shape=JsonFormat.Shape.STRING) BigDecimal openingDebit,@JsonFormat(shape=JsonFormat.Shape.STRING) BigDecimal openingCredit,
            @JsonFormat(shape=JsonFormat.Shape.STRING) BigDecimal originalNet,@JsonFormat(shape=JsonFormat.Shape.STRING) BigDecimal exchangeRate,
            String sourceReference,String accountPathName,UUID originalCurrencyId) {
        public OpeningAllocation(String accountCode,UUID auxiliaryId,UUID currencyId,BigDecimal openingDebit,BigDecimal openingCredit,
                BigDecimal originalNet,BigDecimal exchangeRate,String sourceReference,String accountPathName){this(accountCode,auxiliaryId,currencyId,openingDebit,openingCredit,originalNet,exchangeRate,sourceReference,accountPathName,null);}
    }
    public record Submit(long expectedVersion,UUID balanceImportId,long balanceVersion,List<AccountSelection> accounts,
                         Map<String,String> voucherPurposes,Map<String,UUID> entryAuxiliaries,List<UUID> auxiliarySourceIds,
                         Set<String> omittedZeroBalanceProfitCodes,boolean appendPeriod,boolean completeOriginalPeriod,String reason,List<OpeningAllocation> openingAllocations,Map<String,UUID> sourceCurrencyMappings) {
        public Submit(long expectedVersion,UUID balanceImportId,long balanceVersion,List<AccountSelection> accounts,Map<String,String> voucherPurposes,
                Map<String,UUID> entryAuxiliaries,List<UUID> auxiliarySourceIds,Set<String> omittedZeroBalanceProfitCodes,boolean appendPeriod,boolean completeOriginalPeriod,String reason) {
            this(expectedVersion,balanceImportId,balanceVersion,accounts,voucherPurposes,entryAuxiliaries,auxiliarySourceIds,omittedZeroBalanceProfitCodes,appendPeriod,completeOriginalPeriod,reason,List.of(),Map.of());
        }
        public Submit(long expectedVersion,UUID balanceImportId,long balanceVersion,List<AccountSelection> accounts,Map<String,String> voucherPurposes,
                Map<String,UUID> entryAuxiliaries,List<UUID> auxiliarySourceIds,Set<String> omittedZeroBalanceProfitCodes,boolean appendPeriod,boolean completeOriginalPeriod,String reason,List<OpeningAllocation> openingAllocations) {
            this(expectedVersion,balanceImportId,balanceVersion,accounts,voucherPurposes,entryAuxiliaries,auxiliarySourceIds,omittedZeroBalanceProfitCodes,appendPeriod,completeOriginalPeriod,reason,openingAllocations,Map.of());
        }
    }
    public record Review(UUID requestId,long expectedVersion,String reason) {
        public Review(long expectedVersion,String reason){this(UUID.randomUUID(),expectedVersion,reason);}
    }
    public record Preview(UUID importId,String kind,String sourceName,String sourceSystem,String sha256,String status,long version,
                          UUID submittedBy,FinanceAccountingWorkbookParser.Parsed source,Object review,Object result) { }
    record Line(String accountCode,UUID styleId,UUID currencyId,int direction,@JsonFormat(shape=JsonFormat.Shape.STRING) BigDecimal amount,
                @JsonFormat(shape=JsonFormat.Shape.STRING) BigDecimal original,@JsonFormat(shape=JsonFormat.Shape.STRING) BigDecimal exchangeRate,
                Ref auxiliary,String accountName,String pathName,int sourceRow,String sourceEntryId,
                String summary,Map<String,String> source,UUID originalCurrencyId) {
        Line(String accountCode,UUID styleId,UUID currencyId,int direction,BigDecimal amount,BigDecimal original,BigDecimal exchangeRate,Ref auxiliary,
                String accountName,String pathName,int sourceRow,String sourceEntryId,String summary,Map<String,String> source){this(accountCode,styleId,currencyId,direction,amount,original,exchangeRate,auxiliary,accountName,pathName,sourceRow,sourceEntryId,summary,source,original==null?null:currencyId);}
    }
    record Journal(String key,String type,String number,String sourceId,LocalDate date,String purpose,List<Line> lines) { }
    record ZeroOpening(String accountCode,UUID currencyId,Ref auxiliary,String accountName,int sourceRow,UUID sourceImportId,String sha256,
            @JsonFormat(shape=JsonFormat.Shape.STRING) BigDecimal originalNet,@JsonFormat(shape=JsonFormat.Shape.STRING) BigDecimal exchangeRate,String sourceReference,UUID originalCurrencyId) {
        ZeroOpening(String accountCode,UUID currencyId,Ref auxiliary,String accountName,int sourceRow,UUID sourceImportId,String sha256) {
            this(accountCode,currencyId,auxiliary,accountName,sourceRow,sourceImportId,sha256,null,null,null,null);
        }
        ZeroOpening(String accountCode,UUID currencyId,Ref auxiliary,String accountName,int sourceRow,UUID sourceImportId,String sha256,BigDecimal originalNet,BigDecimal exchangeRate,String sourceReference){this(accountCode,currencyId,auxiliary,accountName,sourceRow,sourceImportId,sha256,originalNet,exchangeRate,sourceReference,originalNet==null?null:currencyId);}
    }
    record Plan(LocalDate effectiveFrom,String ledger,String company,int year,int month,List<Journal> journals,
                List<ZeroOpening> zeroOpenings,List<AccountSelection> accounts,List<UUID> auxiliarySources) { }
    public record Result(UUID importId,UUID balanceImportId,String status,List<UUID> voucherIds,int entries) { }
}
