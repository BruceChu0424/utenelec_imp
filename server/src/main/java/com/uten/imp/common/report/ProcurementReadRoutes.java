package com.uten.imp.common.report;

import java.util.*;
import java.util.regex.Pattern;

/** One exact route-to-owner contract for procurement document and workbench publication. */
public final class ProcurementReadRoutes {
    private static final Map<String,String> OWNER_SCOPES = Map.of(
            "purchase", "native_purchase_owner", "subcontract", "native_subcontract_owner");
    private static final Pattern PRINT_DATA = Pattern.compile(
            "^/api/(purchase|subcontract)/orders/[0-9a-fA-F-]{36}/print-data$");
    private static final Pattern WORKBENCH_EXPORT = Pattern.compile(
            "^/api/operations/workbench/(purchase|subcontract)/export$");
    private static final Pattern PRINT_PERMISSION_QUERY = Pattern.compile(
            "^/api/(purchase|subcontract)/orders/print-authorization$");
    private ProcurementReadRoutes() { }
    public static String printDataScope(String path) {
        var match = PRINT_DATA.matcher(path);
        return match.matches() ? OWNER_SCOPES.get(match.group(1)) : null;
    }
    public static List<String> printDataPaths() {
        return OWNER_SCOPES.keySet().stream().sorted().map(module -> "/api/" + module + "/orders/*/print-data").toList();
    }
    public static String workbenchExportScope(String path) {
        var match = WORKBENCH_EXPORT.matcher(path);
        return match.matches() ? OWNER_SCOPES.get(match.group(1)) : null;
    }
    public static String workbenchDomainScope(String domain) {
        return domain != null && domain.startsWith("workbench_") ? OWNER_SCOPES.get(domain.substring(10)) : null;
    }
    /** POST-only digest verification query; the route performs no write and grants nothing here. */
    public static boolean printPermissionQuery(String method, String path) {
        return "POST".equals(method) && path != null && PRINT_PERMISSION_QUERY.matcher(path).matches();
    }
}
