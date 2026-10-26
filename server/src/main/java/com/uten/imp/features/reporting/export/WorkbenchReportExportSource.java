package com.uten.imp.features.reporting.export;

import com.uten.imp.application.port.ExportLimitPort;
import com.uten.imp.common.export.ExportPayload;
import com.uten.imp.common.report.ReportQueryKit;
import com.uten.imp.common.web.*;
import com.uten.imp.features.operations.workbench.*;
import com.uten.imp.security.*;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;
import java.time.LocalDate;
import java.util.Set;

/** Original purchase task authority and row semantics, independent of the purchase report family. */
@Component
@RequiredArgsConstructor
public class WorkbenchReportExportSource {
    private static final Set<String> READ_PERMISSIONS=Set.of("purchase_request:view","purchase_order:view","purchase_receipt:view","purchase_return:view");
    private final FulfillmentWorkbenchQueryService queries;
    private final ExportLimitPort limits;
    private final SecurityContextCurrentUser users;
    public static void authorize(AuthUser user) {
        if(user.isVisitor()||user.isMustChangePassword()||!user.isAccountNonLocked()||user.getImpersonatedBy()!=null
                ||!user.getPermissions().contains("purchase_report:export")
                ||READ_PERMISSIONS.stream().noneMatch(user.getPermissions()::contains))throw new ApiException(ErrorCode.FORBIDDEN);
    }
    public static void validate(ReportExportRequest request) { table(request); }
    private static FulfillmentWorkbenchTableQuery table(ReportExportRequest request) {
        if(!"tasks".equals(request.report()))throw invalid();
        var p=request.parameters();
        if(p.keySet().stream().anyMatch(key->!Set.of("status","keyword","exception","dateFrom","dateTo","issuedFrom","issuedTo","needFrom","needTo").contains(key)
                &&!key.startsWith("f.")&&!key.startsWith("search.")))throw invalid();
        try {
            LocalDate from=ReportQueryKit.parseDate(p.get("dateFrom")),to=ReportQueryKit.parseDate(p.get("dateTo"));
            if(from!=null&&to!=null&&from.isAfter(to))throw invalid();
            return FulfillmentWorkbenchTableQuery.from(request.sort(),request.order(),p,
                    ReportQueryKit.parseDate(p.get("issuedFrom")),ReportQueryKit.parseDate(p.get("issuedTo")),
                    ReportQueryKit.parseDate(p.get("needFrom")),ReportQueryKit.parseDate(p.get("needTo")));
        }catch(IllegalArgumentException | java.time.DateTimeException invalid){throw invalid();}
    }
    public ExportPayload read(ReportExportRequest request) {
        authorize(users.get().orElseThrow(()->new ApiException(ErrorCode.UNAUTHORIZED)));
        var p=request.parameters();var table=table(request);
        return queries.exportPurchase(p.getOrDefault("status",""),p.getOrDefault("keyword",""),p.getOrDefault("exception",""),
                ReportQueryKit.parseDate(p.get("dateFrom")),ReportQueryKit.parseDate(p.get("dateTo")),table,limits.exportMaxRows());
    }
    private static ApiException invalid(){return new ApiException(ErrorCode.VALIDATION_FAILED,"采购任务导出条件无效");}
}
