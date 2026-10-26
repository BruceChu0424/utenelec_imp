package com.uten.imp.common.report;

import com.uten.imp.common.web.*;
import com.uten.imp.common.export.ExportProjectionAccessGuard;
import com.uten.imp.common.export.ExportProjectionPublication;
import com.uten.imp.security.ReadScopeVersionAuthority;
import org.springframework.core.MethodParameter;
import org.springframework.http.*;
import org.springframework.http.converter.HttpMessageConverter;
import org.springframework.http.server.*;
import org.springframework.web.bind.annotation.RestControllerAdvice;
import org.springframework.web.servlet.mvc.method.annotation.ResponseBodyAdvice;

/** A grant revoked while a query is running must not escape in its late response. */
@RestControllerAdvice
public class ReportReadScopeAdvice implements ResponseBodyAdvice<Object> {
    private final ReadScopeVersionAuthority authority;
    private final ExportProjectionAccessGuard projections;
    @org.springframework.beans.factory.annotation.Autowired
    public ReportReadScopeAdvice(ReadScopeVersionAuthority authority,ExportProjectionAccessGuard projections) {
        this.authority=authority;this.projections=projections;
    }
    /** Existing focused tests without projected platform columns. */
    public ReportReadScopeAdvice(ReadScopeVersionAuthority authority) {this(authority,null);}
    @Override public boolean supports(MethodParameter parameter,Class<? extends HttpMessageConverter<?>> converter) {return true;}
    @Override public Object beforeBodyWrite(Object body,MethodParameter parameter,MediaType mediaType,
            Class<? extends HttpMessageConverter<?>> converter,ServerHttpRequest request,ServerHttpResponse response) {
        if(request instanceof ServletServerHttpRequest servlet
                && (!(response instanceof ServletServerHttpResponse target) || target.getServletResponse().getStatus()<400)) {
            var proof=servlet.getServletRequest().getAttribute(ReadScopePublication.ATTRIBUTE);
            ReadScopePublication.Proof access=proof instanceof ReadScopePublication.Proof actual?actual:null;
            if(access!=null) {
                String fresh=access.domain().startsWith("native_")||access.businessTasks()
                    ?authority.scopeFor(access.domain(),access.subject(),access.businessTasks())
                    :authority.scopeFor(access.domain(),access.subject());
                if(!access.version().equals(fresh))throw new ApiException(ErrorCode.READ_SCOPE_CHANGED);
            }
            if(body instanceof byte[])ExportProjectionPublication.verify(servlet.getServletRequest(),projections);
            if(access!=null) {
                response.getHeaders().set(ReadScopePublication.HEADER,access.version());
                if(access.domain().startsWith("native_")) response.getHeaders().set("X-Uten-Read-Scope-Domain",
                        access.domain()+(access.businessTasks()?":task":":browse"));
            }
        }
        return body;
    }
}
