package com.uten.imp.features.reporting.export;

import com.uten.imp.application.port.ExportLimitPort;
import com.uten.imp.audit.*;
import com.uten.imp.common.export.ExportPayload;
import com.uten.imp.common.report.ReportQueryKit;
import com.uten.imp.common.web.*;
import com.uten.imp.security.*;
import org.springframework.stereotype.Component;
import java.util.*;

/** The existing investigator view and session view retain their own filters and original authorities. */
@Component
public class AuditReportExportSource {
    private static final Set<String> PARAMETERS=Set.of("action","actorAccount","actorId","actorScope","riskLevel","eventCategory","outcome",
            "keyword","targetType","targetId","eventSource","requestId","operationKind","dateFrom","dateTo","snapshotId","activityOnly");
    private final AuditQueryService activity;
    private final AuditSessionTableExportService sessions;
    private final ExportLimitPort limits;
    public AuditReportExportSource(AuditQueryService activity,AuditSessionTableExportService sessions,ExportLimitPort limits) {
        this.activity=activity;this.sessions=sessions;this.limits=limits;
    }
    public static void authorize(AuthUser user) {
        if(user.isVisitor()||user.isMustChangePassword()||!user.isAccountNonLocked()||user.getImpersonatedBy()!=null
                ||!user.getPermissions().containsAll(Set.of("audit_log:view","audit_log:export")))throw new ApiException(ErrorCode.FORBIDDEN);
    }
    public static AuditSearchCriteria criteria(ReportExportRequest request) {
        if(!Set.of("activity","sessions").contains(request.report())||!PARAMETERS.containsAll(request.parameters().keySet()))throw invalid();
        var p=request.parameters();
        try {
            String actor=p.get("actorId"),snapshot=p.get("snapshotId");
            var result=new AuditSearchCriteria(p.get("action"),p.get("actorAccount"),p.get("actorScope"),p.get("riskLevel"),p.get("eventCategory"),
                    p.get("outcome"),p.get("keyword"),p.get("targetType"),p.get("targetId"),p.get("eventSource"),p.get("requestId"),p.get("operationKind"),
                    ReportQueryKit.parseDate(p.get("dateFrom")),ReportQueryKit.parseDate(p.get("dateTo")),
                    snapshot==null||snapshot.isBlank()?null:Long.valueOf(snapshot),actor==null||actor.isBlank()?null:UUID.fromString(actor),
                    !p.containsKey("activityOnly")||ReportQueryKit.parseRequiredBoolean(p.get("activityOnly")));
            AuditQueryService.validateFilterValues(result);return result;
        }catch(IllegalArgumentException|java.time.DateTimeException failure){throw invalid();}
    }
    public ExportPayload read(ReportExportRequest request) {
        CurrentAuthorityGuard.requireAll("audit_log:view","audit_log:export");
        var criteria=criteria(request);
        return "sessions".equals(request.report())?sessions.export(criteria.actorId(),criteria.dateFrom(),criteria.dateTo(),criteria.snapshotId(),limits.exportMaxRows())
                :activity.export(criteria,limits.exportMaxRows());
    }
    private static ApiException invalid(){return new ApiException(ErrorCode.VALIDATION_FAILED,"审计导出筛选参数无效");}
}
