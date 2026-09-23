package com.uten.imp.security;

import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.support.StaticListableBeanFactory;
import org.springframework.transaction.TransactionExecution;
import org.springframework.transaction.support.TransactionSynchronizationManager;

import static org.junit.jupiter.api.Assertions.assertDoesNotThrow;
import static org.mockito.Mockito.*;

/**
 * 事务开始时自动绑定审计操作人(ADR-107): 只对新开的读写事务绑定; 绑定出错绝不能从这个回调抛出——
 * 事务管理器此时不会清理已绑定的连接和事务状态, 抛出去会漏到本线程的下一次调用。
 */
class TransactionAuditActorBinderTest {

    @AfterEach
    void clear() {
        TransactionSynchronizationManager.setActualTransactionActive(false);
    }

    @Test
    void bindsOnlyNewReadWriteTransactionsAndNeverThrows() {
        TxSessionVars vars = mock(TxSessionVars.class);
        var beans = new StaticListableBeanFactory();
        beans.addBean("txSessionVars", vars);
        var binder = new TransactionAuditActorBinder(beans.getBeanProvider(TxSessionVars.class));
        TransactionSynchronizationManager.setActualTransactionActive(true);

        binder.afterBegin(execution(true, true), null);
        binder.afterBegin(execution(false, false), null);
        binder.afterBegin(execution(true, false), new IllegalStateException("begin failed"));
        verifyNoInteractions(vars);

        binder.afterBegin(execution(true, false), null);
        verify(vars).bind();

        doThrow(new IllegalStateException("database unavailable")).when(vars).bind();
        assertDoesNotThrow(() -> binder.afterBegin(execution(true, false), null));
    }

    private static TransactionExecution execution(boolean newTransaction, boolean readOnly) {
        TransactionExecution execution = mock(TransactionExecution.class);
        when(execution.isNewTransaction()).thenReturn(newTransaction);
        when(execution.isReadOnly()).thenReturn(readOnly);
        return execution;
    }
}
