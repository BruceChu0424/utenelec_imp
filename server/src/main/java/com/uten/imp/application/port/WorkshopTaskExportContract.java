package com.uten.imp.application.port;

import com.uten.imp.common.report.ReportQueryKit;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.security.AuthUser;
import java.time.LocalDate;
import java.util.*;

/** The workshop export keeps its task reader's authority and filter contract. */
public final class WorkshopTaskExportContract {
    private WorkshopTaskExportContract() {}
    public static final String REPORT = "workshop-tasks";
    private static final Set<String> FILTERS = Set.of("report", "sort", "order", "keyword", "status",
            "preparationFilter", "routeFilter", "workshopDepartmentId", "dateFrom", "dateTo", "analysisNo", "segmentCode");
    public static boolean matches(String domain, String report) {
        return "production".equals(domain) && REPORT.equals(report);
    }
    public static void authorize(AuthUser user) {
        if (user.isVisitor() || user.isMustChangePassword() || !user.isAccountNonLocked() || user.getImpersonatedBy() != null
                || !user.getPermissions().containsAll(Set.of("production_execution:view", "production_report:export")))
            throw new ApiException(ErrorCode.FORBIDDEN);
    }
    public static void validate(Map<String, String> p, String sort, String order) {
        if (p == null || p.keySet().stream().anyMatch(key -> !FILTERS.contains(key))
                || !Set.of("PREPARING", "IN_PROGRESS", "REPORT_INSPECTION", "COMPLETED").contains(p.getOrDefault("status", ""))
                || sort != null && !Set.of("sourcePlan", "order", "segment").contains(sort)
                || order != null && !Set.of("asc", "desc").contains(order.toLowerCase(Locale.ROOT))) throw invalid();
        if (p.containsKey("preparationFilter") && !Set.of("WAITING_MATERIAL", "DRAW_FULL_KIT", "DRAW_PARTIAL",
                "SAME_WORKSHOP_MAKE_ONLY", "DRAW_NOT_REQUESTED", "DRAW_REQUESTED", "READY_TO_START").contains(p.get("preparationFilter")))
            throw invalid();
        if (p.containsKey("routeFilter") && !Set.of("UNCONFIRMED", "FULL_KIT", "CONTINUOUS", "BATCH").contains(p.get("routeFilter")))
            throw invalid();
        ReportQueryKit.parseUuid(p.get("workshopDepartmentId"));
        LocalDate from = ReportQueryKit.parseDate(p.get("dateFrom")), to = ReportQueryKit.parseDate(p.get("dateTo"));
        if (from != null && to != null && from.isAfter(to)) throw invalid();
    }
    private static ApiException invalid() { return new ApiException(ErrorCode.VALIDATION_FAILED, "车间任务导出条件无效"); }
}
