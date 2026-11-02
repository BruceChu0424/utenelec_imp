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
            route("/api/business-references/clients(?:/(?:search|search-context))?","client"),
            route("/api/business-references/goods(?:/(?:categories|search-category-ids|facet-values|facets))?","master_goods"),
            route("/api/business-references/suppliers(?:/(?:search|search-context))?","supplier"),
            route("/api/business-references/accounts","master_account"),
            route("/api/business-references/warehouses","master_warehouse"),
            route("/api/business-references/(?:supplier-categories|client-categories|departments)","native_feature"),
            route("/api/master/(?:payment-styles/tree|reference-methods/(?:settlement|finance))","native_feature"),
            route("/api/org/employee-references(?:/(?:by-ids|departments))?","native_feature"),
            route("/api/production/workshop-tasks(?:/(?:facets|count|"+ID+"/materials))?","native_workshop_tasks"),
            route("/api/workshop-material/segments/"+ID+"/stock-readiness","native_workshop_tasks"),
            route("/api/procurement/arrival-exceptions/(?:tasks|count|"+ID+")","native_feature"),
            route("/api/master/warehouses/my-scope","native_warehouse_tasks"),
            route("/api/warehouse/task-center/(?:inbound|outbound)(?:/[A-Z_]+:[A-Z_]+:"+ID+"(?::[^/]+)?/detail)?","native_warehouse_tasks"),
            route("/api/warehouse/document-history/(?:purchase-receipts|subcontract-receipts|subcontract-material-issues|subcontract-returns|subcontract-material-returns|subcontract-wastes)(?:/(?:facets|"+ID+"))?","native_warehouse_tasks"),
            route("/api/warehouse/quality-results(?:/(?:facets|status-counts|type-counts|(?:PURCHASE|SUBCONTRACT)/"+ID+"))?","native_warehouse_tasks"),
            route("/api/warehouse/production-finished-in/(?:tasks(?:/(?:facets|count))?|arrival-registrations/batch)","native_warehouse_tasks"),
            route("/api/warehouse/inbound/(?:expectations(?:/(?:facets|count|by-ids))?|arrival-exceptions(?:/(?:facets|count))?)","native_warehouse_tasks"),
            route("/api/warehouse/sales-outbound(?:/(?:facets|count|counts|"+ID+"))?","native_warehouse_tasks"),
            route("/api/warehouse/subcontract-outbound/tasks(?:/(?:count|"+ID+"))?","native_warehouse_tasks"),
            route("/api/operations/workbench/warehouse(?:/(?:overview|count|status-breakdown))?","native_warehouse_tasks"),
            route("/api/workshop-material/(?:task-status|requisitions(?:/"+ID+")?)","native_warehouse_tasks"),
            route("/api/stock/count-requests(?:/(?:counts|"+ID+"))?","native_warehouse_tasks"),
            route("/api/stock/insights/(?:health|cycle-count)","native_warehouse_tasks"),
            route("/api/stock/docs(?:/facets)?","native_warehouse_tasks"),
            route("/api/stock/goods/"+ID+"/production-trace","native_warehouse_tasks"),
            route("/api/production/reports/where-used/(?:subjects|trace)","native_warehouse_tasks"));

    private static Route route(String path,String profile) {return new Route(Pattern.compile("^"+path+"$"),profile);}
    public static String profile(String path) {
        return ROUTES.stream().filter(route->route.path().matcher(path).matches())
                .map(Route::profile).findFirst().orElse(null);
    }
    @Override public boolean preHandle(HttpServletRequest request,HttpServletResponse response,Object handler) {
        String path=SecurityRequestPath.withinApplication(request);
        boolean referenceSearch="POST".equals(request.getMethod()) && java.util.Set.of(
                "/api/business-references/suppliers/search-context", "/api/business-references/clients/search-context",
                "/api/business-references/suppliers/search", "/api/business-references/clients/search").contains(path);
        if(!"GET".equals(request.getMethod()) && !referenceSearch)return true;
        // The original authenticated metadata endpoint remains available to
        // password-change/visitor flows. Only the new explicit browse mode
        // participates in the staff task publication protocol.
        String[] readMode=request.getParameterValues("forRead");
        boolean legacyMode=readMode==null || readMode.length==1 && readMode[0]!=null && java.util.Set.of("false","off","no","0","")
                .contains(readMode[0].toLowerCase(java.util.Locale.ROOT));
        if(path.equals("/api/master/warehouses/my-scope") && legacyMode)return true;
        String profile=profile(path);
        if(profile==null)return true;
        boolean tasks=handler instanceof HandlerMethod method && method.hasMethodAnnotation(BusinessTaskRead.class);
        ReadScopePublication.capture(request,authority,users,profile,tasks);
        return true;
    }
}
