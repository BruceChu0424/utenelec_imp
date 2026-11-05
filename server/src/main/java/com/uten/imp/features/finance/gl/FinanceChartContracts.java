package com.uten.imp.features.finance.gl;

import java.util.List;
import java.util.UUID;

public final class FinanceChartContracts {
    private FinanceChartContracts() { }
    public record SourceRow(String code,String name,String currencyName,int sourceRow,Long existingVersion,String classification) {
        public SourceRow(String code,String name,String currencyName,int sourceRow,Long existingVersion){this(code,name,currencyName,sourceRow,existingVersion,null);}
    }
    public record Issue(int sourceRow,String field,String message) { }
    public record Preview(UUID importId,String sourceName,String sha256,List<SourceRow> rows,List<Issue> issues,
                          boolean applied) { }
    public record Apply(UUID importId) { }
    public record Mapping(long expectedVersion,List<UUID> styleIds,String balanceLineKey,String profitLineKey,String classification,UUID currencyId) {
        public Mapping(long expectedVersion,List<UUID> styleIds,String balanceLineKey,String profitLineKey){this(expectedVersion,styleIds,balanceLineKey,profitLineKey,null,null);}
        public Mapping(long expectedVersion,List<UUID> styleIds,String balanceLineKey,String profitLineKey,String classification){this(expectedVersion,styleIds,balanceLineKey,profitLineKey,classification,null);}
    }
    public record CreateTarget(long expectedVersion,String category,String classification,UUID currencyId,String balanceLineKey,String profitLineKey) {
        public CreateTarget(long expectedVersion,String category,String classification,UUID currencyId){this(expectedVersion,category,classification,currencyId,null,null);}
        public CreateTarget(long expectedVersion,String category){this(expectedVersion,category,null,null);}
        public CreateTarget(long expectedVersion,String category,String classification){this(expectedVersion,category,classification,null);}
    }
    public record CreateAccount(UUID requestId,String code,String name,String currencyName,String category,String sourceReference,String classification,UUID currencyId) {
        public CreateAccount(UUID requestId,String code,String name,String currencyName,String category,String sourceReference){this(requestId,code,name,currencyName,category,sourceReference,null,null);}
    }
    public record CreateAccountResult(UUID requestId,String code,String status) { }
    public record UpdateAccount(UUID requestId,long expectedVersion,String name,String sourceReference) { }
    public record UpdateAccountResult(UUID requestId,String code,String status,String previousName,String name,String sourceReference) { }
    public record Target(UUID id,String code,String name,String category) { }
    public record Account(String code,String name,String currencyName,long version,List<Target> targets,List<String> lineKeys,String classification,UUID currencyId) {
        public Account(String code,String name,String currencyName,long version,List<Target> targets,List<String> lineKeys){this(code,name,currencyName,version,targets,lineKeys,null,null);}
    }
    public record Result(UUID importId,int imported,String status) { }
}
