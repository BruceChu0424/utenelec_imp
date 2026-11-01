package com.uten.imp.common.report;

import com.uten.imp.security.BusinessTaskRead;
import com.uten.imp.security.ReadScopeVersionAuthority;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.SecurityRequestPath;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import org.springframework.web.method.HandlerMethod;
import org.springframework.web.servlet.HandlerInterceptor;

import java.util.List;
import java.util.regex.Pattern;

/** Fixed native task read profiles share the same before/after publication fence.
 * This selects authorization dimensions, never grants a route or command. */
public record NativeTaskReadScopeInterceptor(ReadScopeVersionAuthority authority,
        SecurityContextCurrentUser users) implements HandlerInterceptor {
    private record Route(Pattern path,String profile) { }
    private static final String ID="[0-9a-fA-F-]{36}";
    private static final List<Route> ROUTES=List.of(
            route("/api/production/workshop-tasks(?:/(?:facets|count|"+ID+"/materials))?","native_workshop_tasks"),
            route("/api/procurement/arrival-exceptions/(?:tasks|count|"+ID+")","native_feature"));

    private static Route route(String path,String profile) {return new Route(Pattern.compile("^"+path+"$"),profile);}
    public static String profile(String path) {
        return ROUTES.stream().filter(route->route.path().matcher(path).matches())
                .map(Route::profile).findFirst().orElse(null);
    }
    @Override public boolean preHandle(HttpServletRequest request,HttpServletResponse response,Object handler) {
        if(!"GET".equals(request.getMethod()))return true;
        String profile=profile(SecurityRequestPath.withinApplication(request));
        if(profile==null)return true;
        boolean tasks=handler instanceof HandlerMethod method && method.hasMethodAnnotation(BusinessTaskRead.class);
        ReadScopePublication.capture(request,authority,users,profile,tasks);
        return true;
    }
}
