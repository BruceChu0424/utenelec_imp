package com.uten.imp.security;

import com.uten.imp.application.port.TaskAudiencePort;
import org.aopalliance.intercept.MethodInterceptor;
import org.springframework.aop.Advisor;
import org.springframework.aop.support.DefaultPointcutAdvisor;
import org.springframework.aop.support.annotation.AnnotationMatchingPointcut;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.context.annotation.Role;
import org.springframework.beans.factory.config.BeanDefinition;
import org.springframework.beans.factory.ObjectProvider;

/** Task identity must be selected before the @PreAuthorize advisor (order 200). */
@Configuration(proxyBeanMethods = false)
public class BusinessTaskReadConfiguration {
    @Bean
    @Role(BeanDefinition.ROLE_INFRASTRUCTURE)
    public Advisor businessTaskReadAdvisor(ObjectProvider<TaskAudiencePort> audience) {
        MethodInterceptor interceptor = invocation -> {
            try {
                return audience.getObject().read(() -> {
                    try {
                        return invocation.proceed();
                    } catch (RuntimeException | Error failure) {
                        throw failure;
                    } catch (Throwable failure) {
                        throw new TaskInvocationFailure(failure);
                    }
                });
            } catch (TaskInvocationFailure failure) {
                throw failure.getCause();
            }
        };
        var advisor = new DefaultPointcutAdvisor(
                new AnnotationMatchingPointcut(null, BusinessTaskRead.class, true), interceptor);
        advisor.setOrder(100);
        return advisor;
    }

    private static final class TaskInvocationFailure extends RuntimeException {
        private TaskInvocationFailure(Throwable cause) { super(cause); }
    }
}
