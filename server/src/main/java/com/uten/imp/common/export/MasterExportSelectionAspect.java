package com.uten.imp.common.export;

import org.aspectj.lang.ProceedingJoinPoint;
import org.aspectj.lang.annotation.Around;
import org.aspectj.lang.annotation.Aspect;
import org.springframework.stereotype.Component;

/** One request scope for all existing master export controllers, including private contact bodies. */
@Aspect
@Component
public class MasterExportSelectionAspect {
    @Around("execution(public * com.uten.imp.features.master..*Controller.*(..))")
    public Object select(ProceedingJoinPoint invocation) throws Throwable {
        for (Object argument : invocation.getArgs()) {
            if (argument instanceof MasterExportSelectionRequest request) {
                try (var ignored = MasterExportSelection.open(request.selectedIds())) { return invocation.proceed(); }
            }
        }
        return invocation.proceed();
    }
}
