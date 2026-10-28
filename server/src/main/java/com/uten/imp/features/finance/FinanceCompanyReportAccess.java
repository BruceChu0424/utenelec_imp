package com.uten.imp.features.finance;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;

/** One authority gate for company-wide finance projections, including their interactive entry points. */
public final class FinanceCompanyReportAccess {
    private FinanceCompanyReportAccess() { }
    public static void require(FinanceDocumentAccessPolicy access) {
        if(!access.scope().seeAll())throw new ApiException(ErrorCode.FORBIDDEN,
                "该报表包含公司级完整财务事实，仅超级管理员或具有 finance:view:all 权限的用户可访问");
    }
}
