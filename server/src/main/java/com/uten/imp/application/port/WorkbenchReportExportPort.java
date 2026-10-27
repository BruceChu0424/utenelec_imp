package com.uten.imp.application.port;

import com.uten.imp.common.export.ExportPayload;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.security.AuthUser;
import java.util.Set;

/** Each procurement workbench owns its task filters and export authority. */
public interface WorkbenchReportExportPort {
    void validateRequest(ReportExportQuery query);
    ExportPayload read(ReportExportQuery query);

    static void authorize(AuthUser user) {
        authorize(user, "workbench_purchase");
    }
    static void authorize(AuthUser user, String domain) {
        boolean subcontract = "workbench_subcontract".equals(domain);
        if (!subcontract && !"workbench_purchase".equals(domain))
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "任务导出类型无效");
        Set<String> reads = subcontract ? Set.of("subcontract_application:view", "subcontract_order:view",
                "subcontract_receipt:view", "subcontract_return:view", "subcontract_material_issue:view",
                "subcontract_material_return:view", "subcontract_waste:view")
                : Set.of("purchase_request:view", "purchase_order:view", "purchase_receipt:view", "purchase_return:view");
        if (user.isVisitor() || user.isMustChangePassword() || !user.isAccountNonLocked() || user.getImpersonatedBy() != null
                || !user.getPermissions().contains((subcontract ? "subcontract" : "purchase") + "_report:export")
                || reads.stream().noneMatch(user.getPermissions()::contains))
            throw new ApiException(ErrorCode.FORBIDDEN);
    }
}
