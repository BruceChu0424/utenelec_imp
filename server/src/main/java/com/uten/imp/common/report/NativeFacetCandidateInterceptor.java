package com.uten.imp.common.report;

import com.uten.imp.common.web.*;
import com.uten.imp.security.*;
import jakarta.servlet.http.*;
import org.springframework.web.method.HandlerMethod;
import org.springframework.web.servlet.AsyncHandlerInterceptor;

import java.util.Set;

/** Candidate reads bind original handler filters from a bounded body, never the URL. */
public final class NativeFacetCandidateInterceptor implements AsyncHandlerInterceptor {
    static final String ATTRIBUTE=NativeFacetCandidateInterceptor.class.getName()+".scope";
    private static final Set<String> RESERVED=Set.of("__facetField","__facetKeyword","__facetPage","__facetSize");
    private final ReadScopeVersionAuthority authority;
    private final SecurityContextCurrentUser users;
    public NativeFacetCandidateInterceptor(ReadScopeVersionAuthority authority,SecurityContextCurrentUser users) {
        this.authority=authority;this.users=users;
    }
    @Override public boolean preHandle(HttpServletRequest request,HttpServletResponse response,Object handler) {
        var route=NativeFacetRoutes.find(SecurityRequestPath.withinApplication(request));
        if(route==null||!"POST".equals(request.getMethod()))return true;
        if(request.getQueryString()!=null&&!request.getQueryString().isEmpty())throw invalid("候选筛选只接受请求体");
        String content=request.getContentType();
        if(content==null||!content.split(";",2)[0].strip().equalsIgnoreCase("application/x-www-form-urlencoded"))
            throw invalid("候选筛选须使用表单请求体");
        if(request.getContentLengthLong()>65_536)throw invalid("候选筛选请求体过大");
        long chars=0;
        for(var entry:request.getParameterMap().entrySet()) {
            chars+=entry.getKey().length();
            if(entry.getKey().startsWith("__facet")&&!RESERVED.contains(entry.getKey()))throw invalid("未知候选参数");
            for(String value:entry.getValue())chars+=value.length();
        }
        if(chars>32_768||request.getParameterMap().size()>80)throw invalid("候选筛选请求体过大");
        String field=single(request,"__facetField",null);
        if(field==null||!route.fields().contains(field))throw invalid("此入口不支持该候选字段");
        long page=number(single(request,"__facetPage","1"));
        long size=number(single(request,"__facetSize","100"));
        if(size>100)throw invalid("候选每页最多100项");
        boolean tasks=handler instanceof HandlerMethod method&&method.hasMethodAnnotation(BusinessTaskRead.class);
        ReadScopePublication.capture(request,response,authority,users,route.profile(),tasks);
        var scope=NativeFacetCandidates.open(field,single(request,"__facetKeyword",""),page,(int)size);
        request.setAttribute(ATTRIBUTE,scope);
        com.uten.imp.audit.AuditRequestContext.markControlledRead(request);
        return true;
    }
    @Override public void afterCompletion(HttpServletRequest request,HttpServletResponse response,Object handler,Exception error) {
        if(request.getAttribute(ATTRIBUTE) instanceof NativeFacetCandidates.Scope scope) {
            request.removeAttribute(ATTRIBUTE);scope.close();
        }
    }
    @Override public void afterConcurrentHandlingStarted(HttpServletRequest request,HttpServletResponse response,Object handler) {
        afterCompletion(request,response,handler,null);
    }
    private static String single(HttpServletRequest request,String name,String fallback) {
        String[] values=request.getParameterValues(name);
        if(values==null)return fallback;
        if(values.length!=1)throw invalid("候选参数不能重复");
        return values[0];
    }
    private static long number(String value) {
        if(value==null||!value.matches("[1-9][0-9]{0,9}"))throw invalid("候选分页无效");
        try{return Long.parseLong(value);}catch(NumberFormatException error){throw invalid("候选分页无效");}
    }
    private static ApiException invalid(String message){return new ApiException(ErrorCode.VALIDATION_FAILED,message);}
}
