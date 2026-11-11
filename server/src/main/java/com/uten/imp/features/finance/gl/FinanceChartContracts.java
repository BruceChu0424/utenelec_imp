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
                          boolean applied,int columnContractVersion) {
        public Preview(UUID importId,String sourceName,String sha256,List<SourceRow> rows,List<Issue> issues,boolean applied){this(importId,sourceName,sha256,rows,issues,applied,com.uten.imp.common.importing.ImportColumnGuard.VERSION);}
    }
    public record Apply(UUID importId) { }
    public record Repreview(UUID requestId) implements com.uten.imp.features.finance.FinanceOperationJournal.OriginalBodyCommand { }
    public record Mapping(UUID requestId,Long expectedVersion,List<UUID> styleIds,String balanceLineKey,String profitLineKey,String classification,UUID currencyId) implements com.uten.imp.features.finance.FinanceOperationJournal.OriginalBodyCommand {
        public Mapping(long expectedVersion,List<UUID> styleIds,String balanceLineKey,String profitLineKey,String classification,UUID currencyId){this(null,expectedVersion,styleIds,balanceLineKey,profitLineKey,classification,currencyId);}
        public Mapping(long expectedVersion,List<UUID> styleIds,String balanceLineKey,String profitLineKey){this(null,expectedVersion,styleIds,balanceLineKey,profitLineKey,null,null);}
        public Mapping(long expectedVersion,List<UUID> styleIds,String balanceLineKey,String profitLineKey,String classification){this(null,expectedVersion,styleIds,balanceLineKey,profitLineKey,classification,null);}
    }
    public record CreateTarget(UUID requestId,Long expectedVersion,String category,String classification,UUID currencyId,String balanceLineKey,String profitLineKey) implements com.uten.imp.features.finance.FinanceOperationJournal.OriginalBodyCommand {
        public CreateTarget(long expectedVersion,String category,String classification,UUID currencyId,String balanceLineKey,String profitLineKey){this(null,expectedVersion,category,classification,currencyId,balanceLineKey,profitLineKey);}
        public CreateTarget(long expectedVersion,String category,String classification,UUID currencyId){this(null,expectedVersion,category,classification,currencyId,null,null);}
        public CreateTarget(long expectedVersion,String category){this(null,expectedVersion,category,null,null,null,null);}
        public CreateTarget(long expectedVersion,String category,String classification){this(null,expectedVersion,category,classification,null,null,null);}
    }
    public record CreateAccount(UUID requestId,String code,String name,String currencyName,String category,String sourceReference,String classification,UUID currencyId) implements com.uten.imp.features.finance.FinanceOperationJournal.OriginalBodyCommand {
        public CreateAccount(UUID requestId,String code,String name,String currencyName,String category,String sourceReference){this(requestId,code,name,currencyName,category,sourceReference,null,null);}
    }
    public record CreateAccountResult(UUID requestId,String code,String status) { }
    public record UpdateAccount(UUID requestId,long expectedVersion,String name,String sourceReference) { }
    public record UpdateAccountResult(UUID requestId,String code,String status,String previousName,String name,String sourceReference) { }
    public record MutationResult(UUID requestId,String code,String status,long version,List<UUID> styleIds,String category,
                                 String classification,UUID currencyId,List<String> lineKeys) { }
    public record Target(UUID id,String code,String name,String category) { }
    public record Account(String code,String name,String currencyName,long version,List<Target> targets,List<String> lineKeys,String classification,UUID currencyId) {
        public Account(String code,String name,String currencyName,long version,List<Target> targets,List<String> lineKeys){this(code,name,currencyName,version,targets,lineKeys,null,null);}
    }
    public record Result(UUID importId,int imported,String status) { }
}
