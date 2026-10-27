package com.uten.imp.common.report;
import com.uten.imp.security.*;
import jakarta.servlet.http.*;
import org.springframework.web.servlet.HandlerInterceptor;
import java.util.*;

/** Initial and final publication use the same original authority as each bounded synchronous reader. */
public final class LegacyExportReadScopeInterceptor implements HandlerInterceptor {
    private final ReadScopeVersionAuthority scopes;private final SecurityContextCurrentUser users;
    public LegacyExportReadScopeInterceptor(ReadScopeVersionAuthority scopes,SecurityContextCurrentUser users){this.scopes=scopes;this.users=users;}
    private static final Map<String,String> MASTER=Map.of("goods","master_goods","clients","client","suppliers","supplier","accounts","master_account",
            "currencies","master_currency","colors","master_color","units","master_unit","moulds","master_mould","warehouses","master_warehouse");
    @Override public boolean preHandle(HttpServletRequest request,HttpServletResponse response,Object handler) {
        if(scopes==null||users==null||!"POST".equals(request.getMethod()))return true;
        String path=SecurityRequestPath.withinApplication(request),domain=null;
        var report=java.util.regex.Pattern.compile("^/api/(sales|purchase|subcontract|production|stock|finance)/reports/export$").matcher(path);
        var master=java.util.regex.Pattern.compile("^/api/master/(goods|clients|suppliers|accounts|currencies|colors|units|moulds|warehouses)/export$").matcher(path);
        if(report.matches())domain=report.group(1);
        else if(master.matches())domain=MASTER.get(master.group(1));
        else if(path.equals("/api/master/reference-methods/settlement-admin/export"))domain="master_settlement_method";
        else if(path.equals("/api/admin/audit-logs/export"))domain="audit";
        else if(ProcurementReadRoutes.workbenchExportScope(path)!=null)domain=ProcurementReadRoutes.workbenchExportScope(path);
        else if(path.equals("/api/production/reports/where-used/export"))domain="production";
        else if(path.equals("/api/master/goods/cost-sheets/actual/export")||path.equals("/api/master/goods/cost-sheets/export")
                ||path.matches("^/api/master/goods/[0-9a-fA-F-]{36}/bom/export$"))domain="master_goods";
        if(domain!=null)ReadScopePublication.capture(request,scopes,users,domain,false);
        return true;
    }
}
