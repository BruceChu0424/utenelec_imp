package com.uten.imp.config;

import com.uten.imp.application.concurrency.FulfillmentSourceConflictRetryInterceptor;
import org.springframework.aop.Advisor;
import org.springframework.aop.ClassFilter;
import org.springframework.aop.Pointcut;
import org.springframework.aop.support.ComposablePointcut;
import org.springframework.aop.support.DefaultPointcutAdvisor;
import org.springframework.aop.support.Pointcuts;
import org.springframework.aop.support.annotation.AnnotationMatchingPointcut;
import org.springframework.beans.factory.config.BeanDefinition;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.context.annotation.Role;
import org.springframework.core.Ordered;
import org.springframework.transaction.annotation.Transactional;

/**
 * 把 {@link FulfillmentSourceConflictRetryInterceptor} 挂到本应用所有 {@code @Transactional}
 * 方法(类级或方法级)外面。
 *
 * <p>不引入 AspectJ: 与 {@code @Transactional} / {@code @PreAuthorize} 一样注册为基础设施
 * Advisor, 由 Spring 既有的 InfrastructureAdvisorAutoProxyCreator 织入同一个代理。顺序 {@value #ORDER}
 * 落在方法安全拦截(100..600)之后、事务拦截(LOWEST_PRECEDENCE)之前: 重跑不再重复鉴权,
 * 但每次都重新开启事务。拦截器本身只在「进入时线程无事务」时才会重跑, 所以嵌套的
 * MANDATORY/REQUIRED 服务调用不会被重复执行。</p>
 */
@Configuration(proxyBeanMethods = false)
public class FulfillmentSourceConflictRetryConfig {

    static final int ORDER = 1000;
    static final String APPLICATION_PACKAGE_PREFIX = "com.uten.imp.";

    @Bean
    @Role(BeanDefinition.ROLE_INFRASTRUCTURE)
    public Advisor fulfillmentSourceConflictRetryAdvisor() {
        Pointcut transactional = Pointcuts.union(
                new AnnotationMatchingPointcut(Transactional.class, true),
                AnnotationMatchingPointcut.forMethodAnnotation(Transactional.class));
        ClassFilter applicationOnly = clazz -> clazz.getName().startsWith(APPLICATION_PACKAGE_PREFIX);
        Pointcut pointcut = new ComposablePointcut(transactional).intersection(applicationOnly);
        DefaultPointcutAdvisor advisor = new DefaultPointcutAdvisor(
                pointcut, new FulfillmentSourceConflictRetryInterceptor());
        advisor.setOrder(ORDER);
        return advisor;
    }

    /** 让配置意图可测: 顺序必须位于事务拦截器之前(数值更小)。 */
    static boolean wrapsTransactionInterceptor(int order) {
        return order < Ordered.LOWEST_PRECEDENCE;
    }
}
