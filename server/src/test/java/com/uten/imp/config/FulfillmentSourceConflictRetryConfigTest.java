package com.uten.imp.config;

import com.uten.imp.application.concurrency.FulfillmentSourceConflictRetryInterceptor;
import org.junit.jupiter.api.Test;
import org.springframework.aop.Advisor;
import org.springframework.aop.PointcutAdvisor;
import org.springframework.beans.factory.config.BeanDefinition;
import org.springframework.context.annotation.Role;
import org.springframework.core.Ordered;
import org.springframework.transaction.annotation.Transactional;

import java.lang.reflect.Method;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertInstanceOf;
import static org.junit.jupiter.api.Assertions.assertNotNull;
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

    /**
     * 配置类与 Advisor 都必须是基础设施角色: 自动代理创建器取 Advisor 时会提前实例化这个配置类,
     * 少标一处启动日志里就会冒出 BeanPostProcessorChecker 的 "not eligible" 警告。
     */
    @Test
    void configAndAdvisorAreInfrastructureBeans() throws Exception {
        Role onClass = FulfillmentSourceConflictRetryConfig.class.getAnnotation(Role.class);
        assertNotNull(onClass, "配置类要标 @Role, 否则它被提前实例化时会触发启动期 WARN");
        assertEquals(BeanDefinition.ROLE_INFRASTRUCTURE, onClass.value(), "配置类是基础设施 bean");

        Role onBean = FulfillmentSourceConflictRetryConfig.class
                .getMethod("fulfillmentSourceConflictRetryAdvisor").getAnnotation(Role.class);
        assertNotNull(onBean, "Advisor 也要标 @Role");
        assertEquals(BeanDefinition.ROLE_INFRASTRUCTURE, onBean.value(), "Advisor 是基础设施 bean");
    }
}
