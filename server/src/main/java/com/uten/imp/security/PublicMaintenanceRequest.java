package com.uten.imp.security;

import jakarta.servlet.http.HttpServletRequest;

/** Anonymous, bounded, read-only update status must work while session authority is unavailable. */
public final class PublicMaintenanceRequest {
    private PublicMaintenanceRequest() {}

    public static boolean matches(HttpServletRequest request) {
        return "GET".equals(request.getMethod())
                && "/api/system/maintenance".equals(SecurityRequestPath.withinApplication(request));
    }
}
