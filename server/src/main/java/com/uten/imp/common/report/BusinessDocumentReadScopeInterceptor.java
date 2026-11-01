package com.uten.imp.common.report;

import com.uten.imp.security.ReadScopeVersionAuthority;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.SecurityRequestPath;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import org.springframework.web.servlet.HandlerInterceptor;

/** Owner-scoped business reads use the existing publication proof, including observer grants. */
public record BusinessDocumentReadScopeInterceptor(ReadScopeVersionAuthority authority,
        SecurityContextCurrentUser users) implements HandlerInterceptor {
    @Override public boolean preHandle(HttpServletRequest request,HttpServletResponse response,Object handler) {
        String path=SecurityRequestPath.withinApplication(request);
        boolean fieldRead=path.matches("^/api/platform-columns/expense_claim(?:_item)?/(?:definitions|values/[0-9a-fA-F-]{36}/history)$") && "GET".equals(request.getMethod())
                || path.matches("^/api/platform-columns/expense_claim(?:_item)?/values:batch$") && "POST".equals(request.getMethod());
        if (fieldRead || "GET".equals(request.getMethod()) && path.matches(
                "^/api/expense-claims(?:/(?:browse|mine|pending|payable|history|facets|summary|[0-9a-fA-F-]{36}(?:/history(?:/rows)?)?))?$")) {
            ReadScopePublication.capture(request,authority,users,"expense");
        }
        return true;
    }
}
