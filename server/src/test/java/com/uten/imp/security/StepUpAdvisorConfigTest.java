package com.uten.imp.security;

import org.junit.jupiter.api.Test;
import org.springframework.aop.support.DefaultPointcutAdvisor;
import org.springframework.beans.factory.ObjectProvider;
import org.springframework.core.Ordered;
import org.springframework.security.authorization.method.AuthorizationInterceptorsOrder;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.Mockito.mock;

/**
 * ADR-110: 再认证凭证在方法级权限判定之后才核销 (无权的人不会先被要求输密码, 凭证也不会被
 * 无权请求白白用掉), 并在事务与履约冲突自动重跑之外 (重跑不会再核销一次)。
 */
class StepUpAdvisorConfigTest {

    @Test
    @SuppressWarnings("unchecked")
    void stepUpRunsAfterMethodSecurityAndOutsideRetriesAndTransactions() {
        DefaultPointcutAdvisor advisor = (DefaultPointcutAdvisor) new StepUpAdvisorConfig()
                .stepUpAdvisor(mock(ObjectProvider.class));

        assertEquals(StepUpAdvisorConfig.ORDER, advisor.getOrder());
        assertTrue(StepUpAdvisorConfig.runsAfterMethodSecurity(advisor.getOrder()));
        assertTrue(advisor.getOrder() > AuthorizationInterceptorsOrder.PRE_AUTHORIZE.getOrder());
        // 履约冲突自动重跑 (FulfillmentSourceConflictRetryConfig) 为 1000, 事务拦截为最低优先级
        assertTrue(advisor.getOrder() < 1000);
        assertTrue(advisor.getOrder() < Ordered.LOWEST_PRECEDENCE);
        assertTrue(advisor.getAdvice() instanceof StepUpInterceptor);
    }
}
