package com.uten.imp.features.finance.statement;

import com.uten.imp.application.port.FinanceAuxiliaryLedgerReadPort;
import com.fasterxml.jackson.annotation.JsonFormat;
import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.*;

public final class FinanceStatementDocumentContracts {
    private FinanceStatementDocumentContracts() { }
    /** currencyId is the actual unit printed on the paper; the material context owns its separate book currency. */
    public record Context(String templateKey,String partyRole,UUID partyId,UUID currencyId,LocalDate dateFrom,LocalDate dateTo,
            @com.fasterxml.jackson.annotation.JsonInclude(com.fasterxml.jackson.annotation.JsonInclude.Include.NON_NULL) UUID materialContextId,
            @com.fasterxml.jackson.annotation.JsonInclude(com.fasterxml.jackson.annotation.JsonInclude.Include.NON_NULL) Boolean allMaterialContexts) {
        public Context{allMaterialContexts=materialContextId==null?null:allMaterialContexts==null?Boolean.TRUE:allMaterialContexts;}
        public Context(String templateKey,String partyRole,UUID partyId,UUID currencyId,LocalDate dateFrom,LocalDate dateTo){
            this(templateKey,partyRole,partyId,currencyId,dateFrom,dateTo,null,null);
        }
        public Context(String templateKey,String partyRole,UUID partyId,UUID currencyId,LocalDate dateFrom,LocalDate dateTo,UUID materialContextId){
            this(templateKey,partyRole,partyId,currencyId,dateFrom,dateTo,materialContextId,null);
        }
    }
    /** Actual print data, maintained explicitly. Account number is not copied from a tail-only native field. */
    public record Organization(String organizationName,String address,String phone,String fax,String bankHolder,
            String bankName,String bankAccount,String receiver,String receiverPhone,String printRemark) { }
    /** Retention is a labelled part of the existing receivable/payable, never an extra addition. */
    public record Retention(LocalDate effectiveFrom,@JsonFormat(shape=JsonFormat.Shape.STRING) BigDecimal amount,
            String sourceReference) { }
    public record BalanceSelection(String accountCode,UUID auxiliaryId,UUID accountingCurrencyId,UUID originalCurrencyId,
            boolean originalAmounts,int normalDirection) {
        public FinanceAuxiliaryLedgerReadPort.Scope scope(LocalDate from,LocalDate to){return new FinanceAuxiliaryLedgerReadPort.Scope(accountCode,auxiliaryId,accountingCurrencyId,originalCurrencyId,from,to);}
    }
    public record Settings(BalanceSelection balance,List<Retention> retentions,String printRemark,List<BalanceSelection> additionalBalances) {
        public Settings(BalanceSelection balance,List<Retention> retentions,String printRemark){this(balance,retentions,printRemark,null);}
        public List<BalanceSelection> balances(){var all=new ArrayList<BalanceSelection>();if(balance!=null){all.add(balance);}if(additionalBalances!=null){all.addAll(additionalBalances);}return Collections.unmodifiableList(all);}
    }
    public record ProfileSave(UUID requestId,long expectedRevision,String kind,String templateKey,String partyRole,
            UUID partyId,UUID currencyId,Organization organization,Settings settings,String sourceReference) { }
    public record Decision(boolean approve,String reason) { }
    public record ReviewSave(UUID requestId,Context context,String expectedSourceFingerprint) { }
    /** A new paper version keeps its immutable original and separately reviewed
     * document deductions; callers never provide an editable net amount. */
    public record SettlementPreview(UUID basedReviewId,String expectedBasedFingerprint,
            boolean explicitlyNoDeductions,String sourceReference) { }
    public record SettlementSave(UUID requestId,SettlementPreview source,String expectedSourceFingerprint) { }
    public record CounterpartConfirmation(String documentSha256,String signatoryName,LocalDate confirmedDate,String sourceReference) { }
}
