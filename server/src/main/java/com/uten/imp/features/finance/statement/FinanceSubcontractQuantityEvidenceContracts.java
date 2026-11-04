package com.uten.imp.features.finance.statement;

import com.uten.imp.application.port.FinanceSubcontractQuantityEvidenceReadPort.Input;
import java.util.UUID;

/** Write commands use the same source/quantity contract as every report reader. */
public final class FinanceSubcontractQuantityEvidenceContracts {
    private FinanceSubcontractQuantityEvidenceContracts() { }
    public record Save(UUID requestId,long expectedRevision,Input input,UUID attachmentEvidenceId) {
        public Save(UUID requestId,long expectedRevision,Input input){this(requestId,expectedRevision,input,null);}
    }
    public record Decision(Boolean approve,String reason) { }
}
