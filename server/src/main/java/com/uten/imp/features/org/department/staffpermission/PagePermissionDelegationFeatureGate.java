package com.uten.imp.features.org.department.staffpermission;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Component;

/** Default-enabled runtime switch for the page workspace and delegated permission contribution. */
@Component
public final class PagePermissionDelegationFeatureGate {

    public static final String PROPERTY =
            "uten.features.manager-permission-delegation-enabled";

    private final boolean enabled;

    public PagePermissionDelegationFeatureGate(
            @Value("$" + "{" + PROPERTY + ":true}") boolean enabled) {
        this.enabled = enabled;
    }

    public boolean enabled() {
        return enabled;
    }

    public void requireEnabled() {
        if (!enabled) {
            throw new ApiException(
                    ErrorCode.CONFLICT,
                    "页面权限委派已由运行配置显式关闭");
        }
    }
}
