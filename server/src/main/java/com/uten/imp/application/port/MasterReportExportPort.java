package com.uten.imp.application.port;

import com.uten.imp.common.export.ExportPayload;
import com.uten.imp.common.export.TableColumnProjection;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import java.util.Set;

/** Master data owns filter decoding, authority, import columns and streaming reads. */
public interface MasterReportExportPort {
    Set<String> REPORTS = Set.of("goods", "client", "supplier", "account", "currency", "color", "unit", "mould", "warehouse", "settlement_method");
    void validate(ReportExportQuery query);
    ExportPayload read(ReportExportQuery query);
    TableColumnProjection projection(ReportExportQuery query);

    static void requireReport(String report) {
        if (report == null || !REPORTS.contains(report))
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "主档导出筛选参数无效");
    }
    static String permission(String report) { requireReport(report); return report + ":export"; }
    static String projectionScope(String report) { requireReport(report); return "master_" + report; }
    static String authorityDomain(String report) {
        requireReport(report);
        return "client".equals(report) || "supplier".equals(report) ? report : "master_" + report;
    }
}
