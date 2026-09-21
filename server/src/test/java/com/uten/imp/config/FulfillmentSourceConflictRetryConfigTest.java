package com.uten.imp.config;

import com.uten.imp.application.concurrency.FulfillmentSourceConflictRetryInterceptor;
import org.junit.jupiter.api.Test;
import org.springframework.aop.Advisor;
import org.springframework.aop.PointcutAdvisor;
import org.springframework.core.Ordered;
import org.springframework.transaction.annotation.Transactional;

import java.lang.reflect.Method;

import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertInstanceOf;
import static org.junit.jupiter.api.Assertions.assertTrue;

/** 重跑 Advisor 的切点与顺序: 只挂本应用的 @Transactional 方法, 且位于事务拦截器之外。 */
class FulfillmentSourceConflictRetryConfigTest {

    static class Service {
        @Transactional
        public void command() { }

        public void query() { }
    }

    @Transactional
    static class ClassLevelService {
        public void command() { }
    }

    private static boolean matches(PointcutAdvisor advisor, Class<?> type, String name) throws NoSuchMethodException {
        Method method = type.getMethod(name);
        return advisor.getPointcut().getClassFilter().matches(type)
                && advisor.getPointcut().getMethodMatcher().matches(method, type);
    }

    @Test
    void advisorWrapsOnlyTransactionalMethodsOfThisApplication() throws Exception {
        Advisor advisor = new FulfillmentSourceConflictRetryConfig().fulfillmentSourceConflictRetryAdvisor();
        PointcutAdvisor pointcutAdvisor = assertInstanceOf(PointcutAdvisor.class, advisor);
        assertInstanceOf(FulfillmentSourceConflictRetryInterceptor.class, advisor.getAdvice());
        assertTrue(matches(pointcutAdvisor, Service.class, "command"), "方法级 @Transactional 命令进入重跑边界");
        assertTrue(matches(pointcutAdvisor, ClassLevelService.class, "command"), "类级 @Transactional 同样覆盖");
        assertFalse(matches(pointcutAdvisor, Service.class, "query"), "无事务方法不被拦截");
        assertFalse(pointcutAdvisor.getPointcut().getClassFilter().matches(
                org.springframework.transaction.support.TransactionTemplate.class),
                "框架/第三方类即使带事务语义也不挂本应用的重跑");
    }

    @Test
    void advisorRunsOutsideTheTransactionInterceptor() {
        Advisor advisor = new FulfillmentSourceConflictRetryConfig().fulfillmentSourceConflictRetryAdvisor();
        Ordered ordered = assertInstanceOf(Ordered.class, advisor);
        assertTrue(FulfillmentSourceConflictRetryConfig.wrapsTransactionInterceptor(ordered.getOrder()));
        assertTrue(ordered.getOrder() > 600, "位于方法安全拦截(100..600)之内, 重跑不重复鉴权");
    }
}
