package com.uten.imp.common.report;
import com.uten.imp.common.web.*;
import org.junit.jupiter.api.Test;
import org.springframework.mock.web.*;
import static org.assertj.core.api.Assertions.*;

class NativeFacetCandidateInterceptorTest {
    private final NativeFacetCandidateInterceptor interceptor=new NativeFacetCandidateInterceptor(null,null);
    private MockHttpServletRequest request(String path,String field) {
        var request=new MockHttpServletRequest("POST",path);request.setContentType("application/x-www-form-urlencoded;charset=UTF-8");
        request.setParameter("__facetField",field);request.setParameter("__facetPage","1");request.setParameter("__facetSize","100");return request;
    }
    @Test void completeRegistryHasTwentyOneExactRoutesAndThirtyThreeOriginalFields() {
        assertThat(NativeFacetRoutes.paths()).hasSize(21);
        assertThat(NativeFacetRoutes.paths().stream().mapToInt(path->NativeFacetRoutes.find(path).fields().size()).sum()).isEqualTo(33);
        for(String path:NativeFacetRoutes.paths())for(String field:NativeFacetRoutes.find(path).fields()) {
            var request=request(path,field);assertThat(interceptor.preHandle(request,new MockHttpServletResponse(),this)).isTrue();
            assertThat(NativeFacetCandidates.active()).isTrue();interceptor.afterCompletion(request,new MockHttpServletResponse(),this,new RuntimeException());
            assertThat(NativeFacetCandidates.active()).isFalse();
        }
        assertThat(NativeFacetRoutes.find("/api/finance/payables/facets/extra")).isNull();
    }
    @Test void rejectsUrlBodiesUnknownFieldsDuplicateParametersOverflowAndOversizeBeforeOpeningScope() {
        var response=new MockHttpServletResponse();
        var missing=new MockHttpServletRequest("POST","/api/finance/payables/facets");missing.setContentType("application/x-www-form-urlencoded");
        assertThatThrownBy(()->interceptor.preHandle(missing,response,this)).isInstanceOf(ApiException.class);
        for(String invalid:new String[]{"mobile","bankAccount","sourceDocNo;drop"})assertThatThrownBy(()->interceptor.preHandle(request("/api/finance/payables/facets",invalid),response,this)).isInstanceOf(ApiException.class);
        var url=request("/api/finance/payables/facets","sourceDocNo");url.setQueryString("keyword=private");assertThatThrownBy(()->interceptor.preHandle(url,response,this)).isInstanceOf(ApiException.class);
        var duplicate=request("/api/finance/payables/facets","sourceDocNo");duplicate.setParameter("__facetPage","1","2");assertThatThrownBy(()->interceptor.preHandle(duplicate,response,this)).isInstanceOf(ApiException.class);
        var overflow=request("/api/finance/payables/facets","sourceDocNo");overflow.setParameter("__facetPage","2147483648");assertThatThrownBy(()->interceptor.preHandle(overflow,response,this)).isInstanceOf(ApiException.class);
        var big=request("/api/finance/payables/facets","sourceDocNo");big.setParameter("keyword","x".repeat(32769));assertThatThrownBy(()->interceptor.preHandle(big,response,this)).isInstanceOf(ApiException.class);
        assertThat(NativeFacetCandidates.active()).isFalse();
    }
    @Test void getCompatibilityAndAsyncRetirementDoNotLeakScope() {
        var get=new MockHttpServletRequest("GET","/api/finance/payables/facets");interceptor.preHandle(get,new MockHttpServletResponse(),this);assertThat(NativeFacetCandidates.active()).isFalse();
        var post=request("/api/finance/payables/facets","sourceDocNo");interceptor.preHandle(post,new MockHttpServletResponse(),this);
        interceptor.afterConcurrentHandlingStarted(post,new MockHttpServletResponse(),this);assertThat(NativeFacetCandidates.active()).isFalse();
    }
}
