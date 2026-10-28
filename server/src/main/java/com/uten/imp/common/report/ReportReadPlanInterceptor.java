package com.uten.imp.common.report;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.ReadScopeVersionAuthority;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.SecurityRequestPath;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import org.springframework.web.servlet.AsyncHandlerInterceptor;

/** GET and declared POST reads share one contract; exports open their own row-only scope. */
public class ReportReadPlanInterceptor implements AsyncHandlerInterceptor {
    private static final String SCOPE = ReportReadPlanInterceptor.class.getName() + ".scope";
    private final ReadScopeVersionAuthority authority;
    private final SecurityContextCurrentUser users;
    public ReportReadPlanInterceptor() {this(null,null);}
    public ReportReadPlanInterceptor(ReadScopeVersionAuthority authority,SecurityContextCurrentUser users) {
        this.authority=authority;this.users=users;
    }

    @Override
    public boolean preHandle(HttpServletRequest request, HttpServletResponse response, Object handler) {
        boolean declaredPost = "POST".equalsIgnoreCase(request.getMethod())
                && handler instanceof org.springframework.web.method.HandlerMethod method
                && method.hasMethodAnnotation(ReadOnlyReportQuery.class);
        if (!"GET".equalsIgnoreCase(request.getMethod()) && !declaredPost) return true;
        String path=SecurityRequestPath.withinApplication(request);
        boolean count=flag(request,"includeCount"),facets=flag(request,"includeFacets"),totals=flag(request,"includeTotals");
        boolean reuse=flag(request,"metadataReuse",false);
        String[] supplied=request.getParameterValues("readScopeVersion");
        if(supplied!=null && (supplied.length!=1 || supplied[0].length()>256))
            throw new ApiException(ErrorCode.VALIDATION_FAILED,"读取范围版本无效");
        String version=null;
        if(authority!=null) {
            var match=java.util.regex.Pattern.compile("^/api/(sales|purchase|subcontract|production|stock|finance)/reports(?:/.*)?$").matcher(path);
            if(match.matches()) {
                version=ReadScopePublication.capture(request,authority,users,match.group(1));
            }
        }
        if(reuse && (version==null || supplied==null || !version.equals(supplied[0])))count=facets=totals=true;
        ReportReadPlan plan = new ReportReadPlan(count,facets,totals,version);
        request.setAttribute(SCOPE, ReportReadPlan.open(plan));
        return true;
    }

    private static boolean flag(HttpServletRequest request, String name) {
        return flag(request,name,true);
    }
    private static boolean flag(HttpServletRequest request, String name,boolean fallback) {
        String[] values = request.getParameterValues(name);
        if (values == null) return fallback;
        if (values.length == 1) {
            if ("true".equalsIgnoreCase(values[0])) return true;
            if ("false".equalsIgnoreCase(values[0])) return false;
        }
        throw new ApiException(ErrorCode.VALIDATION_FAILED, name + " 必须为 true 或 false，且不能重复");
    }

    @Override
    public void afterCompletion(HttpServletRequest request, HttpServletResponse response,
                                Object handler, Exception exception) {
        close(request);
    }

    @Override
    public void afterConcurrentHandlingStarted(HttpServletRequest request, HttpServletResponse response, Object handler) {
        close(request);
    }

    private static void close(HttpServletRequest request) {
        Object scope = request.getAttribute(SCOPE);
        request.removeAttribute(SCOPE);
        if (scope instanceof ReportReadPlan.Scope reportScope) reportScope.close();
    }
}
