package com.uten.imp.common.report;

import com.uten.imp.common.readsnapshot.VersionedSummaryPages;
import com.uten.imp.common.web.*;
import org.aspectj.lang.ProceedingJoinPoint;
import org.aspectj.lang.annotation.*;
import org.springframework.stereotype.Component;
import org.springframework.web.context.request.*;
import java.util.*;

/** Original authorization, parameter resolution and selected grouped SQL share one owning RR snapshot. */
@Aspect
@Component
@org.springframework.core.annotation.Order(0)
public class NativeFacetSnapshotAspect {
    private final VersionedSummaryPages pages;
    public NativeFacetSnapshotAspect(VersionedSummaryPages pages) {this.pages=pages;}
    @Around("execution(public * com.uten.imp.features..*Controller.*(..))")
    public Object read(ProceedingJoinPoint invocation) throws Throwable {
        if(!NativeFacetCandidates.active())return invocation.proceed();
        if(!(RequestContextHolder.getRequestAttributes() instanceof ServletRequestAttributes attributes))
            throw new IllegalStateException("Native candidate reads require their owning HTTP request");
        var request=attributes.getRequest();
        if(!(request.getAttribute(NativeFacetCandidateInterceptor.ATTRIBUTE) instanceof NativeFacetCandidates.Scope scope))
            throw new IllegalStateException("Native candidate request scope missing");
        var route=NativeFacetRoutes.find(com.uten.imp.security.SecurityRequestPath.withinApplication(request));
        if(route==null)throw new IllegalStateException("Native candidate route authority missing");
        Map<String,List<String>> identity=new TreeMap<>();
        request.getParameterMap().forEach((key,values)->{
            if(!Set.of("__facetPage","__facetReadSnapshotRevision").contains(key))identity.put(key,List.of(values.clone()));
        });
        // Route and all original filter parameters are fixed in the token. Page is intentionally excluded.
        var specification=new VersionedSummaryPages.Request(route.dataDomain(),route.profile(),
                Map.of("route",com.uten.imp.security.SecurityRequestPath.withinApplication(request),"parameters",identity),
                "all",scope.page(),scope.size(),100,request.getParameter("__facetReadSnapshotRevision"));
        boolean tasks=Boolean.TRUE.equals(request.getAttribute(NativeFacetCandidateInterceptor.ATTRIBUTE+".tasks"));
        var snapshot=pages.read(specification,()->{},()->{
            try {return invocation.proceed();}
            catch(RuntimeException|Error error) {throw error;}
            catch(Throwable error) {throw new HandlerFailure(error);}
        },tasks);
        scope.snapshot(snapshot.readScopeVersion(),snapshot.readSnapshotRevision(),snapshot.readDataVersion());
        return snapshot.value();
    }
    private static final class HandlerFailure extends RuntimeException {
        private HandlerFailure(Throwable cause) {super(cause);}
    }
}
