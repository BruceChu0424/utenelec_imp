package com.uten.imp.security;

import com.uten.imp.features.auth.StepUpService;
import org.springframework.aop.Advisor;
import org.springframework.aop.support.DefaultPointcutAdvisor;
import org.springframework.aop.support.annotation.AnnotationMatchingPointcut;
import org.springframework.beans.factory.ObjectProvider;
import org.springframework.beans.factory.config.BeanDefinition;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.context.annotation.Role;
import org.springframework.security.authorization.method.AuthorizationInterceptorsOrder;

/**
 * 把 {@link StepUpInterceptor} 挂到所有 {@link RequiresStepUp} 方法上 (ADR-110)。
 *
 * <p>与 {@code @PreAuthorize}、{@code @Transactional} 一样注册为基础设施 Advisor, 由既有的
 * InfrastructureAdvisorAutoProxyCreator 织入同一个代理 (不引入 AspectJ)。顺序 {@value #ORDER} 排在全部
 * 方法安全拦截 (100..600) 之后: 先判权限再核销凭证, 没有权限的人不会被要求输入密码, 凭证也不会被
 * 无权请求白白用掉; 排在履约冲突自动重跑 (1000) 与事务拦截之前: 自动重跑不会再次核销同一张凭证。</p>
 */
@Configuration(proxyBeanMethods = false)
@Role(BeanDefinition.ROLE_INFRASTRUCTURE)
public class StepUpAdvisorConfig {

    static final int ORDER = 700;

    @Bean
    @Role(BeanDefinition.ROLE_INFRASTRUCTURE)
    public Advisor stepUpAdvisor(ObjectProvider<StepUpService> stepUp) {
        DefaultPointcutAdvisor advisor = new DefaultPointcutAdvisor(
                AnnotationMatchingPointcut.forMethodAnnotation(RequiresStepUp.class),
                new StepUpInterceptor(stepUp));
        advisor.setOrder(ORDER);
        return advisor;
    }

    /** 让顺序意图可测: 必须在全部方法安全拦截之后。 */
    static boolean runsAfterMethodSecurity(int order) {
        return order > AuthorizationInterceptorsOrder.POST_FILTER.getOrder();
    }
}
