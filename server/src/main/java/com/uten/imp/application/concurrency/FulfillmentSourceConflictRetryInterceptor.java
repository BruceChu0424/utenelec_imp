package com.uten.imp.application.concurrency;

import org.aopalliance.intercept.MethodInterceptor;
import org.aopalliance.intercept.MethodInvocation;
import org.springframework.aop.ProxyMethodInvocation;
import org.springframework.aop.support.AopUtils;
import org.springframework.core.annotation.AnnotatedElementUtils;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;
import org.springframework.transaction.support.TransactionSynchronizationManager;

import java.lang.reflect.Method;
import java.util.concurrent.ThreadLocalRandom;
import java.util.function.LongSupplier;

/**
 * 履约互斥守卫瞬时冲突的统一自动重跑(2026-09-21 用户实测: 品质「批量审批」4 条并行通道同时
 * 提交同一张订货单的两张回厂收货单, 第二张在 COMMIT 前被 {@code verifyUnchanged} 以
 * 「来源集合在预读后变化」拒绝, 页面只能人工「重试原报告」——所有走 FulfillmentMutationLocks
 * 的单据链(收货登记/IQC/仓库入库/出仓发料/财务批准/出货……)都有同一问题)。
 *
 * <p>只在<b>最外层事务边界</b>生效: 进入 {@code @Transactional}(REQUIRED/REQUIRES_NEW/NESTED)
 * 方法时当前线程还没有事务, 说明这个调用就是一次完整命令; 命令抛出
 * {@link FulfillmentSourceConflictException#retryable() 可重跑}冲突时, 事务已整体回滚、什么都没
 * 生效, 用同一参数重新执行整个方法(重新预读来源、重新按稳定顺序拿锁)——这正是守卫设计里
 * 「新请求使用新事实」的含义, 只是不再要客户端来做。嵌套调用(已有事务)一律不重跑, 交给外层。
 * 结构性冲突(预锁顺序/归属错误)不重跑, 原样 409。</p>
 *
 * <p>重跑上限 {@value #MAX_ATTEMPTS} 次, 间隔按次数递增并带随机抖动, 让同批并行命令错开。
 * 时长有两道预算(ADR-107):</p>
 * <ul>
 *   <li>重跑预算 {@value #RETRY_BUDGET_MILLIS} ms <b>从第一次冲突开始</b>计: 第一次执行(含排队等锁)
 *       是命令本来就要花的时间, 恰恰是「等锁期间别人先提交、来源变了」这种要重跑的情形, 不能算进重跑的账;
 *       之后的重跑(含它们各自的等锁)累计超过预算就停, 慢命令不会被放大成几倍时长。</li>
 *   <li>命令从开始算已过 {@value #LATEST_RETRY_START_MILLIS} ms 不再发起新的一次: 客户端 45 秒放弃等待,
 *       再跑一遍大概率在它放弃之后才提交, 界面会误报失败而库里已成功。</li>
 * </ul>
 * <p>超过上限或预算返回原 409(带 Retry-After)。客户端不会自动重发业务写请求, 用户看到提示后自行重新提交。</p>
 */
public final class FulfillmentSourceConflictRetryInterceptor implements MethodInterceptor {

    public static final int MAX_ATTEMPTS = 5;
    /** 第一次冲突之后, 重跑(含其等锁)累计可用的时长。 */
    public static final long RETRY_BUDGET_MILLIS = 10_000;
    /** 命令开始后超过这个时长不再发起新的一次(客户端 45 秒放弃等待)。 */
    public static final long LATEST_RETRY_START_MILLIS = 30_000;
    private static final org.slf4j.Logger LOG =
            org.slf4j.LoggerFactory.getLogger(FulfillmentSourceConflictRetryInterceptor.class);

    /** 可替换的等待实现, 单元测试不真睡。 */
    @FunctionalInterface
    public interface Sleeper {
        void sleep(long millis) throws InterruptedException;
    }

    private final Sleeper sleeper;
    private final LongSupplier nanoClock;

    public FulfillmentSourceConflictRetryInterceptor() {
        this(Thread::sleep);
    }

    FulfillmentSourceConflictRetryInterceptor(Sleeper sleeper) {
        this(sleeper, System::nanoTime);
    }

    FulfillmentSourceConflictRetryInterceptor(Sleeper sleeper, LongSupplier nanoClock) {
        this.sleeper = sleeper;
        this.nanoClock = nanoClock;
    }

    @Override
    public Object invoke(MethodInvocation invocation) throws Throwable {
        if (TransactionSynchronizationManager.isActualTransactionActive()
                || !(invocation instanceof ProxyMethodInvocation proxied)
                || !startsOwnTransaction(invocation)) {
            return invocation.proceed();
        }
        long started = nanoClock.getAsLong();
        long firstConflict = 0;
        for (int attempt = 1; ; attempt++) {
            try {
                return proxied.invocableClone().proceed();
            } catch (FulfillmentSourceConflictException conflict) {
                long now = nanoClock.getAsLong();
                if (attempt == 1) firstConflict = now;
                long elapsedMillis = (now - started) / 1_000_000L;
                long retryingMillis = (now - firstConflict) / 1_000_000L;
                if (!conflict.retryable() || attempt >= MAX_ATTEMPTS || retryingMillis >= RETRY_BUDGET_MILLIS
                        || elapsedMillis >= LATEST_RETRY_START_MILLIS) {
                    if (conflict.retryable()) {
                        LOG.warn("Fulfillment source conflict not resolved after {} attempts / {} ms: {} ({})",
                                attempt, elapsedMillis, describe(invocation), conflict.internalReason());
                    }
                    throw conflict;
                }
                long pause = backoffMillis(attempt);
                LOG.debug("Fulfillment source conflict, re-running {} (attempt {} of {}, after {} ms): {}",
                        describe(invocation), attempt + 1, MAX_ATTEMPTS, pause, conflict.internalReason());
                sleeper.sleep(pause);
            }
        }
    }

    /** 20/40/60/80 ms 递增 + 0..40 ms 抖动: 同批并行命令按到达顺序错开, 不会一起再撞。 */
    static long backoffMillis(int attempt) {
        return 20L * attempt + ThreadLocalRandom.current().nextInt(41);
    }

    /** 方法或其类上的 @Transactional 会在此处开启新事务(REQUIRED/REQUIRES_NEW/NESTED)才算命令边界。 */
    static boolean startsOwnTransaction(MethodInvocation invocation) {
        Object target = invocation.getThis();
        Class<?> targetClass = target == null ? invocation.getMethod().getDeclaringClass()
                : AopUtils.getTargetClass(target);
        Method method = AopUtils.getMostSpecificMethod(invocation.getMethod(), targetClass);
        Transactional transactional = AnnotatedElementUtils.findMergedAnnotation(method, Transactional.class);
        if (transactional == null) {
            transactional = AnnotatedElementUtils.findMergedAnnotation(targetClass, Transactional.class);
        }
        if (transactional == null) return false;
        Propagation propagation = transactional.propagation();
        return propagation == Propagation.REQUIRED
                || propagation == Propagation.REQUIRES_NEW
                || propagation == Propagation.NESTED;
    }

    private static String describe(MethodInvocation invocation) {
        Method method = invocation.getMethod();
        return method.getDeclaringClass().getSimpleName() + "." + method.getName();
    }
}
