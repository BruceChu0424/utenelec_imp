package com.uten.imp.features.sales.intake;

import com.uten.imp.application.port.AiJobUsagePort;
import org.junit.jupiter.api.Test;
import org.springframework.context.annotation.AnnotationConfigApplicationContext;
import org.springframework.context.annotation.Configuration;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.TransactionDefinition;
import org.springframework.transaction.annotation.EnableTransactionManagement;
import org.springframework.transaction.annotation.Transactional;
import org.springframework.transaction.support.AbstractPlatformTransactionManager;
import org.springframework.transaction.support.DefaultTransactionStatus;
import org.springframework.transaction.support.SmartTransactionObject;
import org.springframework.transaction.support.TransactionSynchronization;
import org.springframework.transaction.support.TransactionSynchronizationManager;
import org.springframework.transaction.support.TransactionTemplate;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.UUID;
import java.util.concurrent.atomic.AtomicBoolean;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyInt;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

/**
 * 版式学习用真实的 Spring 事件与事务同步机制验证: 保存事务里什么都不做, 提交后(最先执行的提交后回调)在独立只读事务里
 * 读结果、再写版式; 就算采用任务的提交后回调先注册也排在它后面; 读结果出错不影响保存提交; 事务回滚时什么都不做。
 */
class SalesIntakeLayoutLearnerOrderingTest {

    @Configuration
    @EnableTransactionManagement
    static class Config {
    }

    /**
     * 不连数据库的事务管理器: 驱动事务同步回调, 并像 DataSourceTransactionManager 一样支持加入已有事务
     * (参与者出错会把整个事务标成只能回滚, 提交时抛 UnexpectedRollbackException)、挂起与独立新事务。
     */
    static final class NoOpTransactionManager extends AbstractPlatformTransactionManager {
        private final Object key = new Object();

        /** 绑定在线程上的「连接」: 只记是否被标成只能回滚。 */
        static final class Resource {
            boolean rollbackOnly;
        }

        static final class Tx implements SmartTransactionObject {
            Resource resource;

            @Override
            public boolean isRollbackOnly() {
                return resource != null && resource.rollbackOnly;
            }

            @Override
            public void flush() {
            }
        }

        @Override
        protected Object doGetTransaction() {
            Tx tx = new Tx();
            tx.resource = (Resource) TransactionSynchronizationManager.getResource(key);
            return tx;
        }

        @Override
        protected boolean isExistingTransaction(Object transaction) {
            return ((Tx) transaction).resource != null;
        }

        @Override
        protected void doBegin(Object transaction, TransactionDefinition definition) {
            Resource resource = new Resource();
            TransactionSynchronizationManager.bindResource(key, resource);
            ((Tx) transaction).resource = resource;
        }

        @Override
        protected Object doSuspend(Object transaction) {
            ((Tx) transaction).resource = null;
            return TransactionSynchronizationManager.unbindResource(key);
        }

        @Override
        protected void doResume(Object transaction, Object suspendedResources) {
            TransactionSynchronizationManager.bindResource(key, suspendedResources);
        }

        @Override
        protected void doSetRollbackOnly(DefaultTransactionStatus status) {
            ((Tx) status.getTransaction()).resource.rollbackOnly = true;
        }

        @Override
        protected void doCommit(DefaultTransactionStatus status) {
        }

        @Override
        protected void doRollback(DefaultTransactionStatus status) {
        }

        @Override
        protected void doCleanupAfterCompletion(Object transaction) {
            TransactionSynchronizationManager.unbindResourceIfPossible(key);
        }
    }

    private static Map<String, Object> result() {
        Map<String, Object> extraction = new LinkedHashMap<>();
        extraction.put("layoutSource", "RULES");
        extraction.put("layoutFingerprint", "b".repeat(64));
        extraction.put("headerTexts", "A=s/n|B=part no.");
        extraction.put("columnRoles", Map.of("A", "LINE_NO", "B", "PART_NO", "C", "QTY"));
        return Map.of("extraction", extraction);
    }

    private static SalesIntakeLayoutLearner learner(AnnotationConfigApplicationContext ctx, AiJobUsagePort usage,
                                                   IntakeReferenceData store, List<String> order) {
        return new SalesIntakeLayoutLearner(usage, store, ctx.getBean(PlatformTransactionManager.class)) {
            @Override
            LayoutFacts capture(SalesIntakeUsedEvent event) {
                order.add(TransactionSynchronizationManager.isCurrentTransactionReadOnly() ? "capture(readOnly)" : "capture");
                return super.capture(event);
            }

            @Override
            void write(SalesIntakeUsedEvent event, LayoutFacts facts) {
                order.add("write");
                super.write(event, facts);
            }
        };
    }

    @Test
    void layoutIsReadAndWrittenAfterCommitBeforeOtherAfterCommitCallbacks() {
        AiJobUsagePort usage = mock(AiJobUsagePort.class);
        IntakeReferenceData store = mock(IntakeReferenceData.class);
        AtomicBoolean purged = new AtomicBoolean(false);
        UUID job = UUID.randomUUID();
        UUID user = UUID.randomUUID();
        when(usage.resultFor(job, user)).thenAnswer(inv -> purged.get() ? Optional.empty() : Optional.of(result()));
        List<String> order = new ArrayList<>();
        try (AnnotationConfigApplicationContext ctx = new AnnotationConfigApplicationContext()) {
            ctx.register(Config.class);
            ctx.registerBean(PlatformTransactionManager.class, NoOpTransactionManager::new);
            ctx.registerBean(SalesIntakeLayoutLearner.class, () -> learner(ctx, usage, store, order));
            ctx.refresh();
            TransactionTemplate tx = new TransactionTemplate(ctx.getBean(PlatformTransactionManager.class));
            tx.executeWithoutResult(status -> {
                TransactionSynchronizationManager.registerSynchronization(new TransactionSynchronization() {
                    @Override
                    public void afterCommit() {
                        order.add("markUsed");
                        purged.set(true);
                    }
                });
                ctx.publishEvent(new SalesIntakeUsedEvent(job, user, "order", UUID.randomUUID(), null));
                order.add("published");
            });
        }
        assertThat(order).containsExactly("published", "capture(readOnly)", "write", "markUsed");
        verify(store).upsertLayout(anyString(), any(), anyString(), any(), anyInt());
    }

    /** 平台适配器的真实形状: 读结果的方法带 @Transactional(readOnly = true), 默认传播方式。 */
    static class FailingUsage implements AiJobUsagePort {
        @Override
        @Transactional(readOnly = true)
        public Optional<Map<String, Object>> resultFor(UUID jobId, UUID userId) {
            throw new IllegalStateException("result store unavailable");
        }

        @Override
        @Transactional
        public void markUsed(UUID jobId, UUID userId, String docType, UUID docId) {
        }
    }

    @Test
    void failingResultReadNeverMarksTheSaveRollbackOnly() {
        IntakeReferenceData store = mock(IntakeReferenceData.class);
        AtomicBoolean committed = new AtomicBoolean(false);
        try (AnnotationConfigApplicationContext ctx = new AnnotationConfigApplicationContext()) {
            ctx.register(Config.class);
            ctx.registerBean(PlatformTransactionManager.class, NoOpTransactionManager::new);
            ctx.registerBean(FailingUsage.class);
            ctx.registerBean(SalesIntakeLayoutLearner.class, () -> new SalesIntakeLayoutLearner(
                    ctx.getBean(AiJobUsagePort.class), store, ctx.getBean(PlatformTransactionManager.class)));
            ctx.refresh();
            assertThat(org.springframework.aop.support.AopUtils.isAopProxy(ctx.getBean(AiJobUsagePort.class))).isTrue();
            TransactionTemplate tx = new TransactionTemplate(ctx.getBean(PlatformTransactionManager.class));
            tx.executeWithoutResult(status -> {
                TransactionSynchronizationManager.registerSynchronization(new TransactionSynchronization() {
                    @Override
                    public void afterCompletion(int completionStatus) {
                        committed.set(completionStatus == STATUS_COMMITTED);
                    }
                });
                ctx.publishEvent(new SalesIntakeUsedEvent(UUID.randomUUID(), UUID.randomUUID(), "order", UUID.randomUUID(),
                        null));
            });
        }
        assertThat(committed).isTrue();
        verify(store, never()).upsertLayout(anyString(), any(), anyString(), any(), anyInt());
    }

    @Test
    void componentScanWiresTheHandlerStoreAndLearner() {
        try (AnnotationConfigApplicationContext ctx = new AnnotationConfigApplicationContext()) {
            ctx.registerBean(PlatformTransactionManager.class, NoOpTransactionManager::new);
            ctx.registerBean(org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate.class,
                    () -> mock(org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate.class));
            ctx.registerBean(com.fasterxml.jackson.databind.ObjectMapper.class, () -> new com.fasterxml.jackson.databind.ObjectMapper());
            ctx.registerBean(com.uten.imp.application.port.MasterIntakeLookupPort.class,
                    () -> mock(com.uten.imp.application.port.MasterIntakeLookupPort.class));
            ctx.registerBean(com.uten.imp.application.port.AiCompletionPort.class,
                    () -> mock(com.uten.imp.application.port.AiCompletionPort.class));
            ctx.registerBean(AiJobUsagePort.class, () -> mock(AiJobUsagePort.class));
            ctx.registerBean(com.uten.imp.security.SecurityContextCurrentUser.class);
            ctx.scan("com.uten.imp.features.sales.intake");
            ctx.refresh();
            assertThat(ctx.getBeansOfType(com.uten.imp.application.port.AiJobHandler.class)).hasSize(1);
            assertThat(ctx.getBean(com.uten.imp.application.port.AiJobHandler.class).kind())
                    .isEqualTo(SalesDocumentIntakeJobHandler.KIND);
            assertThat(ctx.getBean(SalesIntakeLayoutLearner.class)).isNotNull();
            assertThat(ctx.getBean(IntakeReferenceData.class)).isNotNull();
        }
    }

    @Test
    void rolledBackSaveLearnsNothing() {
        AiJobUsagePort usage = mock(AiJobUsagePort.class);
        IntakeReferenceData store = mock(IntakeReferenceData.class);
        when(usage.resultFor(any(), any())).thenReturn(Optional.of(result()));
        try (AnnotationConfigApplicationContext ctx = new AnnotationConfigApplicationContext()) {
            ctx.register(Config.class);
            ctx.registerBean(PlatformTransactionManager.class, NoOpTransactionManager::new);
            ctx.registerBean(SalesIntakeLayoutLearner.class, () -> new SalesIntakeLayoutLearner(usage, store,
                    ctx.getBean(PlatformTransactionManager.class)));
            ctx.refresh();
            TransactionTemplate tx = new TransactionTemplate(ctx.getBean(PlatformTransactionManager.class));
            tx.executeWithoutResult(status -> {
                ctx.publishEvent(new SalesIntakeUsedEvent(UUID.randomUUID(), UUID.randomUUID(), "quote", UUID.randomUUID(), null));
                status.setRollbackOnly();
            });
        }
        verify(usage, never()).resultFor(any(), any());
        verify(store, never()).upsertLayout(anyString(), any(), anyString(), any(), anyInt());
    }
}
