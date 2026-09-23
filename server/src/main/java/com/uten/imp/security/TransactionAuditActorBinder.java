package com.uten.imp.security;

import org.springframework.beans.factory.ObjectProvider;
import org.springframework.lang.Nullable;
import org.springframework.stereotype.Component;
import org.springframework.transaction.TransactionExecution;
import org.springframework.transaction.TransactionExecutionListener;
import org.springframework.transaction.support.TransactionSynchronizationManager;

/**
 * 每个新开的读写事务一开始就绑定一次审计操作人(当前登录人 + 请求元数据), 供数据库审计触发器读取。
 *
 * <p>以前靠每个写方法首行手写 {@code tx.bind()}, 漏写一处审计行就没有操作人(dup-backend-split-15)。
 * 现在由事务基础设施统一做: Spring Boot 把本监听器挂到自动配置的事务管理器上, 事务开始后立即调用
 * {@link TxSessionVars#bind()}。只读事务不绑(不会产生审计行); 嵌套保存点不是新事务, 沿用外层绑定。
 * 业务代码里残留的 {@code tx.bind()} 在同一事务同一身份下只做内存比较, 不再往返数据库;
 * 后台任务用 {@link TxSessionVars#bindActor} 显式换成系统操作人的语义不变。</p>
 */
@Component
public class TransactionAuditActorBinder implements TransactionExecutionListener {
    private static final org.slf4j.Logger LOG = org.slf4j.LoggerFactory.getLogger(TransactionAuditActorBinder.class);

    private final ObjectProvider<TxSessionVars> sessionVars;

    public TransactionAuditActorBinder(ObjectProvider<TxSessionVars> sessionVars) {
        this.sessionVars = sessionVars;
    }

    @Override
    public void afterBegin(TransactionExecution transaction, @Nullable Throwable beginFailure) {
        if (beginFailure != null || !transaction.isNewTransaction() || transaction.isReadOnly()) return;
        if (!TransactionSynchronizationManager.isActualTransactionActive()) return;
        try {
            sessionVars.getObject().bind();
        } catch (RuntimeException failure) {
            // 事务管理器在这个回调抛异常时不会清理已绑定的连接和事务状态, 会漏到本线程的下一次调用;
            // 这里只记日志放行: 业务代码里显式的 bind() 仍会重试, 数据库出错也会在下一条语句照常暴露。
            LOG.warn("Audit actor binding at transaction begin failed: {}", failure.toString());
        }
    }
}
