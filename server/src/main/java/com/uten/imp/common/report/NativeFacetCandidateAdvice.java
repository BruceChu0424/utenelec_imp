package com.uten.imp.common.report;

import com.uten.imp.common.web.NativeFacetCandidates;
import org.springframework.core.*;
import org.springframework.core.annotation.Order;
import org.springframework.http.*;
import org.springframework.http.converter.HttpMessageConverter;
import org.springframework.http.server.*;
import org.springframework.web.bind.annotation.RestControllerAdvice;
import org.springframework.web.servlet.mvc.method.annotation.ResponseBodyAdvice;

/** Wrap success once, then let the shared publication advice freshly reauthorize it. */
@Order(Ordered.HIGHEST_PRECEDENCE+50)
@RestControllerAdvice(basePackages="com.uten.imp.features")
public final class NativeFacetCandidateAdvice implements ResponseBodyAdvice<Object> {
    @Override public boolean supports(MethodParameter parameter,Class<? extends HttpMessageConverter<?>> converter){return true;}
    @Override public Object beforeBodyWrite(Object body,MethodParameter parameter,MediaType mediaType,
            Class<? extends HttpMessageConverter<?>> converter,ServerHttpRequest request,ServerHttpResponse response) {
        if(request instanceof ServletServerHttpRequest servlet
                &&(!(response instanceof ServletServerHttpResponse target)||target.getServletResponse().getStatus()<400)
                &&servlet.getServletRequest().getAttribute(NativeFacetCandidateInterceptor.ATTRIBUTE) instanceof NativeFacetCandidates.Scope scope) {
            String version=servlet.getServletRequest().getAttribute(ReadScopePublication.ATTRIBUTE) instanceof ReadScopePublication.Proof proof?proof.version():null;
            return scope.result(body,version);
        }
        return body;
    }
}
