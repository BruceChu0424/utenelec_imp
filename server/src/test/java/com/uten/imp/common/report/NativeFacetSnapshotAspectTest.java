package com.uten.imp.common.report;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.readsnapshot.VersionedSummaryPages;
import com.uten.imp.common.web.*;
import org.aspectj.lang.ProceedingJoinPoint;
import org.junit.jupiter.api.*;
import org.springframework.mock.web.MockHttpServletRequest;
import org.springframework.web.context.request.*;
import java.util.*;
import java.util.function.*;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

class NativeFacetSnapshotAspectTest {
    @AfterEach void clear() {RequestContextHolder.resetRequestAttributes();}
    @Test void originalHandlerAndAllFilterBindingsRunOnceInsideTheSelectedTaskSnapshot() throws Throwable {
        var pages=mock(VersionedSummaryPages.class);var invocation=mock(ProceedingJoinPoint.class);
        var request=new MockHttpServletRequest("POST","/api/production/workshop-tasks/facets");
        request.setParameter("__facetField","sourcePlan");request.setParameter("__facetKeyword","中文 %_");request.setParameter("__facetPage","2");request.setParameter("__facetSize","100");request.setParameter("__facetReadSnapshotRevision","a".repeat(64));request.setParameter("workshopId","actual-authority-id");
        RequestContextHolder.setRequestAttributes(new ServletRequestAttributes(request));
        boolean[] active={false};when(invocation.proceed()).thenAnswer(call->{assertThat(active[0]).isTrue();return Map.of("sourcePlan",List.of());});
        when(pages.read(any(),any(),any(),eq(true))).thenAnswer(call->{
            VersionedSummaryPages.Request specification=call.getArgument(0);
            assertThat(specification.authorizationDomain()).isEqualTo("native_workshop_tasks");assertThat(specification.maxReadSize()).isEqualTo(100);assertThat(specification.expectedReadSnapshotRevision()).isEqualTo("a".repeat(64));
            assertThat(specification.queryIdentity().toString()).contains("actual-authority-id","中文 %_").doesNotContain("__facetPage","__facetReadSnapshotRevision");
            active[0]=true;Object value=((Supplier<?>)call.getArgument(2)).get();active[0]=false;
            return new VersionedSummaryPages.Snapshot<>(value,"task-auth","a".repeat(64),"b".repeat(64));
        });
        try(var scope=NativeFacetCandidates.open("sourcePlan","中文 %_",2,100)) {
            scope.requireSnapshot();request.setAttribute(NativeFacetCandidateInterceptor.ATTRIBUTE,scope);request.setAttribute(NativeFacetCandidateInterceptor.ATTRIBUTE+".tasks",true);
            Object value=new NativeFacetSnapshotAspect(pages).read(invocation);assertThat(scope.result(value,"task-auth").readSnapshotRevision()).isEqualTo("a".repeat(64));
        }
        verify(invocation,times(1)).proceed();
    }
    @Test void legacyNonCandidateHandlerDoesNotOpenANewTransactionOrChangeItsValue() throws Throwable {
        var pages=mock(VersionedSummaryPages.class);var invocation=mock(ProceedingJoinPoint.class);Object value=new Object();when(invocation.proceed()).thenReturn(value);
        assertThat(new NativeFacetSnapshotAspect(pages).read(invocation)).isSameAs(value);verifyNoInteractions(pages);verify(invocation).proceed();
    }
    @Test void originalReadApiDelegatesExplicitFalseWithoutInvokingTheReaderAgain() {
        var seen=new ArrayList<Boolean>();var output=new VersionedSummaryPages.Snapshot<>(Map.of("rows",List.of()),"auth","snapshot","data");
        var pages=new VersionedSummaryPages(null,null,null,new ObjectMapper(),null) {
            @Override @SuppressWarnings("unchecked") public <T> Snapshot<T> read(Request request,Runnable authorize,Supplier<T> supplier,boolean tasks) {seen.add(tasks);return (Snapshot<T>)output;}
        };
        assertThat(pages.read(null,()->{throw new AssertionError();},()->{throw new AssertionError();})).isSameAs(output);assertThat(seen).containsExactly(false);
    }
}
