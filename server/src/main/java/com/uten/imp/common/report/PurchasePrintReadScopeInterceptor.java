package com.uten.imp.common.report;
import com.uten.imp.security.*;
import jakarta.servlet.http.*;
import org.springframework.web.servlet.HandlerInterceptor;

/** Same document-owner authority for the initial snapshot and its final print authorization. */
public final class PurchasePrintReadScopeInterceptor implements HandlerInterceptor {
    private final ReadScopeVersionAuthority scopes;
    private final SecurityContextCurrentUser users;
    public PurchasePrintReadScopeInterceptor(ReadScopeVersionAuthority scopes,SecurityContextCurrentUser users){this.scopes=scopes;this.users=users;}
    @Override public boolean preHandle(HttpServletRequest request,HttpServletResponse response,Object handler) {
        if(scopes==null||users==null)return true; // Legacy standalone MVC fixtures; production constructor requires both beans.
        String domain=ProcurementReadRoutes.printDataScope(SecurityRequestPath.withinApplication(request));
        if("GET".equals(request.getMethod())&&domain!=null)
            ReadScopePublication.capture(request,scopes,users,domain,false);
        return true;
    }
}
