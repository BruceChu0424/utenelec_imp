package com.uten.imp.features.finance.statement;

import java.util.*;

public final class FinanceAuxiliaryContracts {
    private FinanceAuxiliaryContracts() { }
    public record Item(UUID id,String sourceSystem,String sourceCode,String sourceName,String role,UUID partyId,
                       String partyCode,String partyName,String status,long version,String sourceReference) { }
    public record Save(UUID id,Long expectedVersion,String sourceSystem,String sourceCode,String sourceName,String role,
                       UUID partyId,String sourceReference,String accountCode) { }
    public record Party(UUID id,String sourceSystem,String sourceCode,String sourceName,long version) { }
    public record PartyInput(String sourceSystem,String sourceCode,String sourceName) { }
    public record Rule(String accountCode,boolean required,List<String> allowedRoles,String sourceReference,long version,boolean explicit) { }
    public record RuleInput(long expectedVersion,boolean required,List<String> allowedRoles,String sourceReference) { }
}
