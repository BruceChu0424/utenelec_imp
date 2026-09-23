package com.uten.imp.application.concurrency;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import org.aopalliance.intercept.MethodInvocation;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;
import org.springframework.aop.ProxyMethodInvocation;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;
import org.springframework.transaction.support.TransactionSynchronizationManager;

import java.lang.reflect.AccessibleObject;
import java.lang.reflect.Method;
import java.util.ArrayList;
import java.util.List;
import java.util.function.Supplier;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertSame;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * 履约互斥守卫瞬时冲突的自动重跑: 只在最外层事务边界、只对可重跑冲突、有上限。
 */
class FulfillmentSourceConflictRetryInterceptorTest {

    static class Target {
        @Transactional
        public String command() { return "ok"; }

        @Transactional(propagation = Propagation.MANDATORY)
        public void nested() { }

        @Transactional(propagation = Propagation.SUPPORTS)
        public void supports() { }

        public void plain() { }
    }

    @Transactional
    static class ClassLevel {
        public void command() { }
    }

    /** 最小 ProxyMethodInvocation: proceed() 计数并按脚本返回/抛出。 */
    static final class FakeInvocation implements ProxyMethodInvocation {
        final Object target;
        final Method method;
        final Supplier<Object> body;
        int proceeds;

        FakeInvocation(Object target, Method method, Supplier<Object> body) {
            this.target = target; this.method = method; this.body = body;
        }
        @Override public Object proceed() { proceeds++; return body.get(); }
        @Override public MethodInvocation invocableClone() { return this; }
        @Override public MethodInvocation invocableClone(Object... arguments) { return this; }
        @Override public Object getProxy() { return target; }
        @Override public void setArguments(Object... arguments) { }
        @Override public void setUserAttribute(String key, Object value) { }
        @Override public Object getUserAttribute(String key) { return null; }
        @Override public Method getMethod() { return method; }
        @Override public Object[] getArguments() { return new Object[0]; }
        @Override public Object getThis() { return target; }
        @Override public AccessibleObject getStaticPart() { return method; }
    }

    private final List<Long> pauses = new ArrayList<>();
    private final FulfillmentSourceConflictRetryInterceptor interceptor =
            new FulfillmentSourceConflictRetryInterceptor(pauses::add);

    @AfterEach
    void clearTransactionFlag() {
        if (TransactionSynchronizationManager.isActualTransactionActive()) {
            TransactionSynchronizationManager.setActualTransactionActive(false);
        }
    }

    private static Method method(Class<?> type, String name) throws NoSuchMethodException {
        return type.getMethod(name);
    }

    @Test
    void retryableConflictIsReRunUntilTheCommandSucceeds() throws Throwable {
        int[] attempts = {0};
        FakeInvocation invocation = new FakeInvocation(new Target(), method(Target.class, "command"), () -> {
            if (++attempts[0] < 3) throw new FulfillmentSourceConflictException("来源集合在预读后变化", true);
            return "ok";
        });
        assertEquals("ok", interceptor.invoke(invocation));
        assertEquals(3, invocation.proceeds, "两次瞬时冲突后第三次成功");
        assertEquals(2, pauses.size());
        for (long pause : pauses) assertTrue(pause >= 20 && pause <= 20L * 2 + 40, "递增抖动间隔: " + pause);
    }

    @Test
    void structuralConflictIsNotRetried() throws Throwable {
        FakeInvocation invocation = new FakeInvocation(new Target(), method(Target.class, "command"), () -> {
            throw new FulfillmentSourceConflictException("只能登记本事务新建的商业来源", false);
        });
        FulfillmentSourceConflictException failure = assertThrows(
                FulfillmentSourceConflictException.class, () -> interceptor.invoke(invocation));
        assertFalse(failure.retryable());
        assertEquals(1, invocation.proceeds);
        assertTrue(pauses.isEmpty());
    }

    @Test
    void retryableConflictGivesUpAfterTheAttemptLimitWithTheOriginalUserMessage() throws Throwable {
        FakeInvocation invocation = new FakeInvocation(new Target(), method(Target.class, "command"), () -> {
            throw new FulfillmentSourceConflictException("来源集合在预读后变化", true);
        });
        ApiException failure = assertThrows(ApiException.class, () -> interceptor.invoke(invocation));
        assertEquals(ErrorCode.CONFLICT, failure.getCode());
        assertEquals(FulfillmentSourceConflictException.USER_MESSAGE, failure.getMessage());
        assertEquals(FulfillmentSourceConflictRetryInterceptor.MAX_ATTEMPTS, invocation.proceeds);
        assertEquals(FulfillmentSourceConflictRetryInterceptor.MAX_ATTEMPTS - 1, pauses.size());
    }

    /** ADR-107: 第一次冲突之后的重跑累计超过预算就停, 慢命令不会被放大成几倍时长。 */
    @Test
    void retryableConflictStopsOnceTheRetryBudgetIsSpent() throws Throwable {
        long[] now = {0};
        var budgeted = new FulfillmentSourceConflictRetryInterceptor(pauses::add, () -> now[0]);
        FakeInvocation invocation = new FakeInvocation(new Target(), method(Target.class, "command"), () -> {
            now[0] += 6_000_000_000L; // every attempt takes six seconds
            throw new FulfillmentSourceConflictException("来源集合在预读后变化", true);
        });
        assertThrows(FulfillmentSourceConflictException.class, () -> budgeted.invoke(invocation));
        assertEquals(3, invocation.proceeds,
                "first conflict at 6 s starts the 10 s retry budget; 6 s spent: re-run; 12 s spent: give up");
        assertEquals(2, pauses.size());
    }

    /**
     * 评审补充: 前一个命令持锁 4 秒, 本命令排队等锁后才发现来源变了——等锁的时间不算进重跑预算,
     * 服务端照样替用户重跑一次并成功(2026-09-21 引入自动重跑要解决的正是这种情形)。
     */
    @Test
    void aFirstAttemptThatQueuedBehindALongLockHolderIsStillReRun() throws Throwable {
        long[] now = {0};
        var budgeted = new FulfillmentSourceConflictRetryInterceptor(pauses::add, () -> now[0]);
        int[] attempts = {0};
        FakeInvocation invocation = new FakeInvocation(new Target(), method(Target.class, "command"), () -> {
            if (++attempts[0] == 1) {
                now[0] += 4_000_000_000L; // queued four seconds behind the committing holder
                throw new FulfillmentSourceConflictException("来源集合在预读后变化", true);
            }
            now[0] += 300_000_000L;
            return "ok";
        });
        assertEquals("ok", budgeted.invoke(invocation));
        assertEquals(2, invocation.proceeds);
    }

    /** 命令开始已过 30 秒不再发起新的一次: 再跑大概率在客户端 45 秒放弃之后才提交, 界面会误报失败。 */
    @Test
    void noNewAttemptStartsTooCloseToTheClientDeadline() throws Throwable {
        long[] now = {0};
        var budgeted = new FulfillmentSourceConflictRetryInterceptor(pauses::add, () -> now[0]);
        FakeInvocation invocation = new FakeInvocation(new Target(), method(Target.class, "command"), () -> {
            now[0] += 31_000_000_000L;
            throw new FulfillmentSourceConflictException("来源集合在预读后变化", true);
        });
        assertThrows(FulfillmentSourceConflictException.class, () -> budgeted.invoke(invocation));
        assertEquals(1, invocation.proceeds);
        assertTrue(pauses.isEmpty());
    }

    @Test
    void nestedCallInsideAnActiveTransactionIsNeverReRun() throws Throwable {
        TransactionSynchronizationManager.setActualTransactionActive(true);
        FakeInvocation invocation = new FakeInvocation(new Target(), method(Target.class, "command"), () -> {
            throw new FulfillmentSourceConflictException("来源集合在预读后变化", true);
        });
        assertThrows(FulfillmentSourceConflictException.class, () -> interceptor.invoke(invocation));
        assertEquals(1, invocation.proceeds, "已有事务时冲突交给外层, 不能在同一事务里重跑");
        assertTrue(pauses.isEmpty());
    }

    @Test
    void onlyMethodsThatOpenTheirOwnTransactionAreCommandBoundaries() throws Exception {
        Target target = new Target();
        assertTrue(FulfillmentSourceConflictRetryInterceptor.startsOwnTransaction(
                new FakeInvocation(target, method(Target.class, "command"), () -> null)));
        assertTrue(FulfillmentSourceConflictRetryInterceptor.startsOwnTransaction(
                new FakeInvocation(new ClassLevel(), method(ClassLevel.class, "command"), () -> null)));
        assertFalse(FulfillmentSourceConflictRetryInterceptor.startsOwnTransaction(
                new FakeInvocation(target, method(Target.class, "nested"), () -> null)));
        assertFalse(FulfillmentSourceConflictRetryInterceptor.startsOwnTransaction(
                new FakeInvocation(target, method(Target.class, "supports"), () -> null)));
        assertFalse(FulfillmentSourceConflictRetryInterceptor.startsOwnTransaction(
                new FakeInvocation(target, method(Target.class, "plain"), () -> null)));
    }

    @Test
    void nonBoundaryMethodsProceedOnceWithoutInterference() throws Throwable {
        Target target = new Target();
        FakeInvocation invocation = new FakeInvocation(target, method(Target.class, "plain"), () -> {
            throw new FulfillmentSourceConflictException("来源集合在预读后变化", true);
        });
        assertThrows(FulfillmentSourceConflictException.class, () -> interceptor.invoke(invocation));
        assertEquals(1, invocation.proceeds);
        assertSame(target, invocation.getThis());
    }

    @Test
    void otherExceptionsPassThroughUntouched() throws Throwable {
        FakeInvocation invocation = new FakeInvocation(new Target(), method(Target.class, "command"), () -> {
            throw new ApiException(ErrorCode.CONFLICT, "检验报告明细待检数量已变化，请刷新后重试");
        });
        ApiException failure = assertThrows(ApiException.class, () -> interceptor.invoke(invocation));
        assertEquals("检验报告明细待检数量已变化，请刷新后重试", failure.getMessage());
        assertEquals(1, invocation.proceeds);
    }
}
