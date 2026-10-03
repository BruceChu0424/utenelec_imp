package com.uten.imp.common.history;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.security.AuthUser;
import org.springframework.security.core.context.SecurityContextHolder;

/** Raw replaced rows can contain historical cost fields omitted by normal DTOs. */
public final class RetainedRecordAccess {
    private RetainedRecordAccess() { }
    public static void requireUnmaskedCostOriginal(boolean priceMasked) {
        var authentication=SecurityContextHolder.getContext().getAuthentication();
        if (priceMasked || authentication==null || !(authentication.getPrincipal() instanceof AuthUser user)
                || !(user.isSuperAdmin() || user.getPermissions().contains("goods:cost:view"))) {
            throw new ApiException(ErrorCode.FORBIDDEN,"查看完整历史明细需要价格及成本查看权限");
        }
    }
}
