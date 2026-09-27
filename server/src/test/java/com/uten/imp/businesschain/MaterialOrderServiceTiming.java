package com.uten.imp.businesschain;

import java.lang.reflect.Method;
import java.util.*;
import org.aopalliance.intercept.MethodInterceptor;
import org.springframework.aop.Advisor;
import org.springframework.aop.support.DefaultPointcutAdvisor;
import org.springframework.aop.support.StaticMethodMatcherPointcut;
import org.springframework.boot.test.context.TestConfiguration;
import org.springframework.context.annotation.Bean;

/** Test-only aggregate timings. Neither SQL, business arguments nor results are retained. */
final class MaterialOrderServiceTiming {
    private static final ThreadLocal<Sample> ACTIVE=new ThreadLocal<>();
    private static final Set<String> TYPES=Set.of("MaterialAnalysisCommandService","ProductionPlanService",
            "ProductionPlanningPackageService","ProductionExecutionPackageCommandService",
            "ProductionPlanningDraftService","ChainNoticeService","ProductionFulfillmentLedgerService",
            "ProductionMaterialAllocationFacade","ProductionPlanningRequestValidator",
            "ProductionExecutionPlanningService","PreplanAnalysisStockPegService",
            "ProductionPlanMutationFootprintService");
    private static final class Frame { long children; }
    private static final class Totals { long calls,nanos,self,max; }
    private static final class Sample {
        final Deque<Frame> stack=new ArrayDeque<>();final Map<String,Totals> methods=new TreeMap<>();
    }
    static void begin(){if(ACTIVE.get()!=null)throw new IllegalStateException("nested service measurement");ACTIVE.set(new Sample());}
    static Map<String,Map<String,Number>> end(){
        Sample sample=ACTIVE.get();ACTIVE.remove();Map<String,Map<String,Number>> result=new TreeMap<>();
        if(sample!=null)sample.methods.forEach((name,time)->result.put(name,Map.of("calls",time.calls,"inclusiveMillis",time.nanos/1_000_000.0,
                "selfMillis",time.self/1_000_000.0,"maxMillis",time.max/1_000_000.0)));
        return result;
    }
    @TestConfiguration(proxyBeanMethods=false)
    static class Configuration {
        @Bean static Advisor materialOrderTimingAdvisor(){
            var pointcut=new StaticMethodMatcherPointcut(){
                @Override public boolean matches(Method method,Class<?> target){
                    return TYPES.contains(target.getSimpleName())&&method.getDeclaringClass()!=Object.class;
                }
            };
            return new DefaultPointcutAdvisor(pointcut,(MethodInterceptor)invocation->{
                Sample sample=ACTIVE.get();if(sample==null)return invocation.proceed();
                String name=invocation.getMethod().getDeclaringClass().getSimpleName()+"."+invocation.getMethod().getName();
                Frame frame=new Frame();sample.stack.push(frame);long started=System.nanoTime();
                try{return invocation.proceed();}
                finally{
                    long elapsed=System.nanoTime()-started;sample.stack.pop();
                    if(!sample.stack.isEmpty())sample.stack.peek().children+=elapsed;
                    Totals totals=sample.methods.computeIfAbsent(name,ignored->new Totals());
                    totals.calls++;totals.nanos+=elapsed;totals.self+=Math.max(elapsed-frame.children,0);totals.max=Math.max(totals.max,elapsed);
                }
            });
        }
    }
}
