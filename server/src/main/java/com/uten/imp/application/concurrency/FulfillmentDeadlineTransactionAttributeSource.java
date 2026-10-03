package com.uten.imp.application.concurrency;

import org.springframework.lang.Nullable;
import org.springframework.transaction.interceptor.DelegatingTransactionAttribute;
import org.springframework.transaction.interceptor.TransactionAttribute;
import org.springframework.transaction.interceptor.TransactionAttributeSource;

import java.lang.reflect.Method;

/** Keeps Spring's transaction contract and limits only the current attempt's timeout. */
public final class FulfillmentDeadlineTransactionAttributeSource implements TransactionAttributeSource {
    private final TransactionAttributeSource delegate;

    public FulfillmentDeadlineTransactionAttributeSource(TransactionAttributeSource delegate) {
        this.delegate = delegate;
    }

    @Override
    public boolean isCandidateClass(Class<?> targetClass) {
        return delegate.isCandidateClass(targetClass);
    }

    @Override
    @Nullable
    public TransactionAttribute getTransactionAttribute(Method method, @Nullable Class<?> targetClass) {
        TransactionAttribute attribute = delegate.getTransactionAttribute(method, targetClass);
        FulfillmentCommandDeadline deadline = FulfillmentCommandDeadline.current();
        if (attribute == null || deadline == null) return attribute;
        // Do not mutate/cache a deadline on the shared annotation attribute.
        return new DelegatingTransactionAttribute(attribute) {
            @Override
            public int getTimeout() {
                return deadline.boundedTimeoutSeconds(attribute.getTimeout());
            }
        };
    }
}
