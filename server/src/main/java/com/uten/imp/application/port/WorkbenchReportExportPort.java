package com.uten.imp.application.port;

import com.uten.imp.common.export.ExportPayload;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.security.AuthUser;
import java.util.Set;

/** Purchase workbench owns its original task filters and export authority. */
public interface WorkbenchReportExportPort {
    void validateRequest(ReportExportQuery query);
    ExportPayload read(ReportExportQuery query);

    static void authorize(AuthUser user) {
        Set<String> reads = Set.of("purchase_request:view", "purchase_order:view", "purchase_receipt:view", "purchase_return:view");
        if (user.isVisitor() || user.isMustChangePassword() || !user.isAccountNonLocked() || user.getImpersonatedBy() != null
                || !user.getPermissions().contains("purchase_report:export")
                || reads.stream().noneMatch(user.getPermissions()::contains))
            throw new ApiException(ErrorCode.FORBIDDEN);
    }
}
