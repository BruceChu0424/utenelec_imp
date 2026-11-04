package com.uten.imp.common.finance;

import com.uten.imp.security.TxSessionVars;
import org.jspecify.annotations.Nullable;
import org.springframework.beans.factory.ObjectProvider;
import org.springframework.stereotype.Component;
import org.springframework.transaction.*;
import org.springframework.transaction.support.TransactionSynchronizationManager;

/** Transaction-local choices cover Java and SQL on the same connection, including read-only reports. */
@Component
public class BusinessPrecisionTransactionBinder implements TransactionExecutionListener {
    private final ObjectProvider<TxSessionVars> vars;
    public BusinessPrecisionTransactionBinder(ObjectProvider<TxSessionVars> vars){this.vars=vars;}
    @Override public void afterBegin(TransactionExecution transaction,@Nullable Throwable failure){
        if(failure!=null||!transaction.isNewTransaction()||!TransactionSynchronizationManager.isActualTransactionActive()||BusinessPrecisionContext.choices().isEmpty())return;
        try{vars.getObject().bindBusinessPrecision(BusinessPrecisionContext.json());}
        catch(RuntimeException problem){
            // afterBegin must not throw and leak transaction resources. A failed
            // SQL binding leaves that transaction failed; it can never commit a
            // silently different numeric policy.
            transaction.setRollbackOnly();
            try{vars.getObject().markBusinessPrecisionRollbackOnly();}catch(RuntimeException ignored){ }
            BusinessPrecisionContext.bindingFailed(problem);
            org.slf4j.LoggerFactory.getLogger(getClass()).warn("Business precision binding failed: {}",problem.getClass().getSimpleName());
        }
    }
    @Override public void afterCommit(TransactionExecution transaction,@Nullable Throwable failure){
        if(failure==null&&transaction.isNewTransaction()&&!transaction.isReadOnly())BusinessPrecisionContext.writeCommitted();
    }
}
