package com.uten.imp.common.report;
import com.uten.imp.security.*;
import jakarta.servlet.http.*;
import org.springframework.web.servlet.HandlerInterceptor;

/** Publishes each master reader's own policy; it does not add a feature permission gate. */
public class MasterReadScopeInterceptor implements HandlerInterceptor {
    private static final java.util.Map<String,String> DOMAINS=java.util.Map.of(
            "clients","client","suppliers","supplier","goods","master_goods","accounts","master_account",
            "currencies","master_currency","colors","master_color","units","master_unit",
            "moulds","master_mould","warehouses","master_warehouse");
    private final ReadScopeVersionAuthority authority;
    private final SecurityContextCurrentUser users;
    public MasterReadScopeInterceptor(ReadScopeVersionAuthority authority,SecurityContextCurrentUser users) {
        this.authority=authority;this.users=users;
    }
    @Override public boolean preHandle(HttpServletRequest request,HttpServletResponse response,Object handler) {
        if(authority==null||users==null)return true;
        String path=SecurityRequestPath.withinApplication(request);
        if("GET".equals(request.getMethod())&&path.equals("/api/master/goods/cost-sheets/actual")) {
            ReadScopePublication.capture(request,response,authority,users,"master_goods");return true;
        }
        if("GET".equals(request.getMethod())&&path.matches("^/api/master/reference-methods/settlement-admin(?:/page)?$")) {
            ReadScopePublication.capture(request,response,authority,users,"master_settlement_method");return true;
        }
        var matcher=java.util.regex.Pattern.compile("^/api/master/(clients|suppliers|goods|accounts|currencies|colors|units|moulds|warehouses)(?:/(lookup|dict|facets|facet-values|summary|locate|search-category-ids|search|search-context|[0-9a-fA-F-]{36}))?$").matcher(path);
        if(!matcher.matches())return true;
        boolean search="POST".equals(request.getMethod()) && ("search".equals(matcher.group(2)) || "search-context".equals(matcher.group(2)));
        if("GET".equals(request.getMethod()) || search)
            ReadScopePublication.capture(request,response,authority,users,DOMAINS.get(matcher.group(1)));
        return true;
    }
}
